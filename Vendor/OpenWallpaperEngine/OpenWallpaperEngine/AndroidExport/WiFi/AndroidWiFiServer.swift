import Foundation
import Network

/// "Send over Wi-Fi"'s HTTP server: a Network.framework listener on one local-network address
/// (`AndroidLANAddress`) that answers what `AndroidWiFiRouter` decides, for the packages it is
/// given (`update(files:)` changes them while it runs), until it expires or is stopped. With a
/// `lifetime`, each page, preview or download request moves the expiry to `lifetime` from then.
///
/// - It accepts only peers on that address's subnet (`acceptLocalOnly`, then the subnet checked
///   again), never cellular, and stops by itself at the router's expiry.
/// - Limits: connections in all and per device, a request budget per device (a token bucket,
///   429 beyond it), a time limit for a request's headers, and a device that asks for 20 paths
///   that don't exist (wrong tokens) is turned away until the server stops.
/// - One response per connection; files are read in chunks as the connection takes them.
///
/// The app isn't sandboxed; a sandboxed build would need the
/// `com.apple.security.network.server` entitlement for this listener.
///
/// All of its state belongs to `queue`: the listener's and connections' handlers run there, and
/// `start`/`stop` hop onto it.
final class AndroidWiFiServer: @unchecked Sendable {
    struct Limits: Sendable {
        var connections = 32
        var connectionsPerDevice = 8
        /// A device's request budget: `requestBurst` at once, refilled at `requestsPerSecond`.
        var requestBurst = 120.0
        var requestsPerSecond = 2.0
        /// Requests for paths that don't exist before the device is turned away.
        var notFound = 20
        var headerTimeout: TimeInterval = 10
        /// A file is sent in pieces this big.
        var chunk = 256 * 1024
    }

    enum StopReason: Equatable, Sendable {
        /// The sheet closed, or a new session replaced this one.
        case closed
        case expired
        case failed(String)
    }

    /// A download's progress, as the Mac's sheet shows it.
    struct Transfer: Equatable, Sendable {
        enum State: Equatable, Sendable { case running, completed, interrupted }
        var index: Int
        /// The phone's IPv4 address.
        var device: String
        /// How far into the file the download is.
        var position: Int64
        var size: Int64
        var state: State
    }

    enum Event: Equatable, Sendable {
        case transfer(Transfer)
        /// A request moved the expiry.
        case expiry(Date)
        case stopped(StopReason)
    }

    /// What it answers; `queue` owns it.
    private var router: AndroidWiFiRouter
    let address: AndroidLANAddress
    /// How long the share lasts after a request; nil for a fixed expiry.
    let lifetime: TimeInterval?
    let limits: Limits
    let queue = DispatchQueue(label: "OpenWallpaperEngine.AndroidWiFiServer", qos: .userInitiated)
    private let onEvent: @Sendable (Event) -> Void
    private let now: @Sendable () -> Date

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: AndroidWiFiConnection] = [:]
    private var budgets: [UInt32: (tokens: Double, at: Date)] = [:]
    private var notFound: [UInt32: Int] = [:]
    /// The files each device (its dotted address) downloaded whole.
    private var downloaded: [String: Set<Int>] = [:]
    private var reportedExpiry = Date.distantPast
    private var stopReason: StopReason?

    init(router: AndroidWiFiRouter, address: AndroidLANAddress, lifetime: TimeInterval? = nil, limits: Limits = Limits(),
         now: @escaping @Sendable () -> Date = { Date() }, onEvent: @escaping @Sendable (Event) -> Void) {
        self.router = router
        self.address = address
        self.lifetime = lifetime
        self.limits = limits
        self.now = now
        self.onEvent = onEvent
    }

    // MARK: Lifecycle

    /// Starts listening on `address` and returns the port macOS chose.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.prohibitedInterfaceTypes = [.cellular]
        guard let host = IPv4Address(address.host) else { throw AndroidWiFiError.noAddress }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(host), port: .any)
        let listener = try NWListener(using: parameters)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard stopReason == nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.listener = listener
                var resumed = false
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        guard !resumed else { return }
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: error)
                        }
                        self?.stop(.failed(error.localizedDescription))
                    case .cancelled:
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: CancellationError())
                        }
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                scheduleExpiry()
            }
        }
    }

    /// Stops at the router's expiry, or looks again then if a request moved it.
    private func scheduleExpiry() {
        let remaining = max(0, router.expiry.timeIntervalSince(now()))
        queue.asyncAfter(wallDeadline: .now() + remaining) { [weak self] in
            guard let self, self.stopReason == nil else { return }
            if self.now() < self.router.expiry { self.scheduleExpiry() } else { self.stop(.expired) }
        }
    }

    /// Serves `files` from now on; the page reloads its list.
    func update(files: [AndroidWiFiFile]) {
        queue.async { [self] in
            guard files != router.files else { return }
            router.files = files
            router.version += 1
        }
    }

    /// Stops listening and closes every connection; the first reason is the one reported.
    func stop(_ reason: StopReason = .closed) {
        queue.async { [self] in
            guard stopReason == nil else { return }
            stopReason = reason
            listener?.cancel()
            listener = nil
            for client in clients.values { client.cancel() }
            clients.removeAll()
            OWELog.info(.app, "Send over Wi-Fi: stopped (\(reason))")
            onEvent(.stopped(reason))
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard stopReason == nil,
              case .hostPort(host: .ipv4(let remote), port: _) = connection.endpoint,
              remote.rawValue.count == 4 else {
            connection.cancel()
            return
        }
        let device = remote.rawValue.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let fromDevice = clients.values.filter { $0.device == device }.count
        guard address.contains(device), notFound[device, default: 0] < limits.notFound,
              clients.count < limits.connections, fromDevice < limits.connectionsPerDevice else {
            connection.cancel()
            return
        }
        let client = AndroidWiFiConnection(connection: connection, device: device, server: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    /// The connection ended.
    func remove(_ client: AndroidWiFiConnection) {
        clients.removeValue(forKey: ObjectIdentifier(client))
    }

    /// The response to a connection's request, with the device's budget and wrong guesses counted.
    func respond(to request: AndroidWiFiHTTP.Request, from device: UInt32) -> AndroidWiFiHTTP.Response {
        let time = now()
        var budget = budgets[device] ?? (limits.requestBurst, time)
        budget.tokens = min(limits.requestBurst, budget.tokens + time.timeIntervalSince(budget.at) * limits.requestsPerSecond)
        budget.at = time
        guard budget.tokens >= 1 else {
            budgets[device] = budget
            return .text(429, [("Retry-After", "\(Int((1 / limits.requestsPerSecond).rounded(.up)))")])
        }
        budget.tokens -= 1
        budgets[device] = budget
        let route = router.route(request, now: time)
        let response = router.response(to: request, now: time, downloaded: downloaded[AndroidLANAddress.dotted(device)] ?? [])
        if response.status == 404 { notFound[device, default: 0] += 1 }
        if let lifetime, response.status < 400, route != .list {
            router.expiry = time.addingTimeInterval(lifetime)
            if router.expiry.timeIntervalSince(reportedExpiry) >= 1 {
                reportedExpiry = router.expiry
                onEvent(.expiry(router.expiry))
            }
        }
        return response
    }

    func report(_ transfer: Transfer) {
        if transfer.state == .completed { downloaded[transfer.device, default: []].insert(transfer.index) }
        onEvent(.transfer(transfer))
    }
}

enum AndroidWiFiError: LocalizedError {
    case noAddress

    var errorDescription: String? {
        String(localized: "This Mac isn't connected to a Wi-Fi or local network.")
    }
}
