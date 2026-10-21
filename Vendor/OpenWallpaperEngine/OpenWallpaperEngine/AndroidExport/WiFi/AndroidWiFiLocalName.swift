import dnssd
import Foundation
import SystemConfiguration

/// Advertises one multicast-DNS host name (`owe-fileshare.pyxis.local`) for one address, with an
/// `_http._tcp` service on it; `AndroidWiFiLocalName` picks the name.
@MainActor
protocol AndroidWiFiNameRegistering: AnyObject {
    /// Claims `host` (`owe-fileshare.pyxis`, without `.local`) for `address` on its interface, plus the
    /// service at `port`. Calls `completion` once with the first answer; `onLost` later if another
    /// device claims the name after all. Replaces any earlier registration.
    func register(host: String, address: AndroidLANAddress, port: UInt16,
                  completion: @escaping @MainActor (AndroidWiFiNameOutcome) -> Void,
                  onLost: @escaping @MainActor () -> Void)
    /// Withdraws the name and the service.
    func unregister()
}

enum AndroidWiFiNameOutcome: Equatable {
    case registered
    /// Another device on the network has the name.
    case conflict
    case failed(Int32)
}

/// The share's `.local` name while it serves: `owe-fileshare.<LocalHostName>.local`
/// (`owe-fileshare.pyxis.local`, from the Mac's Bonjour name), or `owe-fileshare-2.pyxis.local`
/// and so on when the name is taken. Without one (multicast DNS blocked, or every name taken) the
/// share uses its IP address.
@MainActor
final class AndroidWiFiLocalName {
    nonisolated static let baseName = "owe-fileshare"
    /// Names tried before giving up: `owe-fileshare`, `owe-fileshare-2` … `-9`.
    nonisolated static let attempts = 9

    private let registrar: AndroidWiFiNameRegistering
    /// The Mac's LocalHostName as a DNS label (`pyxis`); nil when it has none.
    private let macName: String?
    private var generation = 0
    /// Ends the claim in progress.
    private var pending: (@MainActor (AndroidWiFiNameOutcome) -> Void)?
    /// The name in use, with `.local`.
    private(set) var host: String?
    /// Whether the last `advertise` got no answer in time.
    private(set) var timedOut = false

    /// How long a name may take to be confirmed (mDNS probes for about a second).
    let timeout: Duration
    /// How long until a name that got no answer is tried again.
    let retryDelay: Duration

    /// `registrar` is DNS-SD by default; `localHostName` the Mac's (`scutil --get LocalHostName`).
    init(registrar: AndroidWiFiNameRegistering? = nil,
         localHostName: String? = SCDynamicStoreCopyLocalHostName(nil) as String?,
         timeout: Duration = .seconds(4), retryDelay: Duration = .seconds(5)) {
        self.registrar = registrar ?? AndroidWiFiDNSSDRegistrar()
        self.timeout = timeout
        self.retryDelay = retryDelay
        macName = localHostName.flatMap(Self.label)
    }

    /// The `attempt`th name, without `.local`: `owe-fileshare.pyxis`, `owe-fileshare-2.pyxis`, …
    /// (`owe-fileshare`, … without a Mac name).
    nonisolated static func name(attempt: Int, macName: String?) -> String {
        let first = attempt <= 1 ? baseName : "\(baseName)-\(attempt)"
        return macName.map { "\(first).\($0)" } ?? first
    }

    func name(attempt: Int) -> String { Self.name(attempt: attempt, macName: macName) }

    /// `text` as one DNS label: lower-case letters, digits and hyphens, no hyphen at either end,
    /// at most 63 characters; nil when nothing is left.
    nonisolated static func label(_ text: String) -> String? {
        var label = ""
        for character in text.lowercased().unicodeScalars {
            let ok = ("a"..."z").contains(character) || ("0"..."9").contains(character)
            if ok { label.unicodeScalars.append(character) } else if !label.isEmpty, !label.hasSuffix("-") { label += "-" }
        }
        while label.hasSuffix("-") { label.removeLast() }
        label = String(label.prefix(63))
        while label.hasSuffix("-") { label.removeLast() }
        return label.isEmpty ? nil : label
    }

    /// Claims the first free name for `address` and `port`; nil when none could be had.
    /// `onLost` runs if the name is taken later, after the name was dropped.
    func advertise(address: AndroidLANAddress, port: UInt16, onLost: @escaping @MainActor () -> Void) async -> String? {
        withdraw()
        timedOut = false
        let current = generation
        for attempt in 1...Self.attempts {
            let name = self.name(attempt: attempt)
            let outcome = await claim(name, address: address, port: port) { [weak self] in
                guard let self, self.generation == current else { return }
                OWELog.info(.app, "Send over Wi-Fi: \(name).local was claimed by another device")
                self.withdraw()
                onLost()
            }
            guard current == generation else { return nil }
            switch outcome {
            case .registered:
                host = "\(name).local"
                OWELog.info(.app, "Send over Wi-Fi: advertising \(name).local for \(address.host)")
                return host
            case .conflict:
                OWELog.info(.app, "Send over Wi-Fi: \(name).local is taken, trying the next name")
            case .failed(let code):
                timedOut = Int(code) == kDNSServiceErr_Timeout
                OWELog.error(.app, "Send over Wi-Fi: advertising \(name).local failed (\(code)); using the IP address")
                registrar.unregister()
                return nil
            }
        }
        registrar.unregister()
        return nil
    }

    /// Stops advertising.
    func withdraw() {
        generation += 1
        pending?(.failed(Int32(kDNSServiceErr_ServiceNotRunning)))
        pending = nil
        if host != nil { OWELog.info(.app, "Send over Wi-Fi: no longer advertising \(host ?? "")") }
        host = nil
        registrar.unregister()
    }

    private func claim(_ name: String, address: AndroidLANAddress, port: UInt16,
                       onLost: @escaping @MainActor () -> Void) async -> AndroidWiFiNameOutcome {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: @MainActor (AndroidWiFiNameOutcome) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            pending = finish
            registrar.register(host: name, address: address, port: port, completion: finish, onLost: onLost)
            Task { @MainActor in
                try? await Task.sleep(for: self.timeout)
                finish(.failed(Int32(kDNSServiceErr_Timeout)))
            }
        }
    }
}

/// `AndroidWiFiNameRegistering` with the DNS-SD API (`dns_sd.h`): an A record on the address's
/// interface (unique, so mDNSResponder probes for it and reports a conflict) and an `_http._tcp`
/// service pointing at it, both on one shared connection, as
/// `dns-sd -P "OWE File Share" _http._tcp local <port> owe-fileshare.local <ip>` does.
/// The service carries no TXT record: the token never leaves the QR code.
@MainActor
final class AndroidWiFiDNSSDRegistrar: AndroidWiFiNameRegistering {
    static let serviceName = "OWE File Share"

    /// The callbacks' context, kept alive until `unregister()`.
    private final class Context {
        var completion: (@MainActor (AndroidWiFiNameOutcome) -> Void)?
        let onLost: @MainActor () -> Void
        var registered = false

        init(completion: @escaping @MainActor (AndroidWiFiNameOutcome) -> Void, onLost: @escaping @MainActor () -> Void) {
            self.completion = completion
            self.onLost = onLost
        }

        /// The A record's answer: the first one completes; a later conflict means the name was lost.
        func answer(_ error: DNSServiceErrorType) {
            let outcome: AndroidWiFiNameOutcome = switch Int(error) {
            case kDNSServiceErr_NoError: .registered
            case kDNSServiceErr_NameConflict: .conflict
            default: .failed(error)
            }
            if let completion {
                self.completion = nil
                registered = outcome == .registered
                Task { @MainActor in completion(outcome) }
            } else if registered, outcome != .registered {
                registered = false
                let onLost = onLost
                Task { @MainActor in onLost() }
            }
        }
    }

    /// DNS-SD calls back on the main queue, so the callbacks and these stay on the main actor.
    private var connection: DNSServiceRef?
    private var context: Unmanaged<Context>?

    func register(host: String, address: AndroidLANAddress, port: UInt16,
                  completion: @escaping @MainActor (AndroidWiFiNameOutcome) -> Void,
                  onLost: @escaping @MainActor () -> Void) {
        unregister()
        let context = Unmanaged.passRetained(Context(completion: completion, onLost: onLost))
        self.context = context
        let interface = if_nametoindex(address.interface)
        var connection: DNSServiceRef?
        var error = DNSServiceCreateConnection(&connection)
        guard Int(error) == kDNSServiceErr_NoError, let connection else {
            context.takeUnretainedValue().answer(error)
            return
        }
        self.connection = connection
        error = DNSServiceSetDispatchQueue(connection, .main)
        guard Int(error) == kDNSServiceErr_NoError else {
            context.takeUnretainedValue().answer(error)
            return
        }
        let fullName = "\(host).local."
        var bytes = address.address.bigEndian
        var record: DNSRecordRef?
        error = DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), interface, fullName,
                                         UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN), 4, &bytes, 120,
                                         { _, _, _, error, context in
                                             guard let context else { return }
                                             Unmanaged<Context>.fromOpaque(context).takeUnretainedValue().answer(error)
                                         }, context.toOpaque())
        guard Int(error) == kDNSServiceErr_NoError else {
            context.takeUnretainedValue().answer(error)
            return
        }
        // The service shares the connection; its name may be renamed by mDNSResponder ("OWE File
        // Share (2)"), which is fine: the host name is what the URL uses.
        var service: DNSServiceRef? = connection
        error = DNSServiceRegister(&service, DNSServiceFlags(kDNSServiceFlagsShareConnection), interface, Self.serviceName,
                                   "_http._tcp", "local.", fullName, port.bigEndian, 0, nil, nil, nil)
        if Int(error) != kDNSServiceErr_NoError {
            OWELog.error(.app, "Send over Wi-Fi: registering the _http._tcp service failed (\(error))")
        }
    }

    func unregister() {
        // Deallocating the shared connection withdraws the record and the service with it.
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
        context?.release()
        context = nil
    }
}
