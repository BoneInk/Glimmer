import Foundation
import IOSurface

/// The app's side of the screen saver extension's XPC transport: an anonymous listener whose
/// endpoint is registered with the broker (`owe-saver-broker`, a launchd agent; an app can't
/// publish a Mach service itself). Each extension process connects, attaches its views
/// (`LiveSaverServiceProtocol`), and gets the rings (`LiveSaverFramesMessage`, the surfaces as XPC
/// objects) and each frame's stamp. Its views' attaches and pings count as a saver showing
/// (`onAlive`). Without the broker (it isn't registered) nothing connects and the extension plays
/// its video. Thread-safe: XPC calls in on its own queues.
final class ScreenSaverFrameService: NSObject, NSXPCListenerDelegate, @unchecked Sendable { // `lock` owns `clients`, `latest`.
    let listener = NSXPCListener.anonymous()
    /// A view attached or pinged (not a preview), on the main queue.
    var onAlive: (@MainActor () -> Void)?
    /// Whether the app draws for the screen saver now (the reply to an attach).
    var isDrawing: @Sendable () -> Bool = { false }
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var latest: LiveSaverFramesMessage?
    private var broker: NSXPCConnection?
    /// Peers must be signed by this requirement; nil accepts any (an unsigned build).
    private let peerRequirement: String?

    init(peerRequirement: String? = ScreenSaverFrameService.ownTeamRequirement) {
        self.peerRequirement = peerRequirement
        super.init()
        listener.delegate = self
        listener.resume()
    }

    /// Hands the endpoint to the broker; false when it can't be reached (not registered).
    func registerWithBroker(service: String = ScreenSaverLiveNames.brokerService) {
        let connection = NSXPCConnection(machServiceName: service)
        connection.remoteObjectInterface = LiveSaverFramesMessage.brokerInterface()
        connection.interruptionHandler = { [weak self] in
            // The broker exited (launchd starts it again on demand): register again.
            OWELog.info(.app, "Live screen saver: the broker restarted; registering again")
            self?.sendEndpoint()
        }
        connection.invalidationHandler = { [weak self] in
            OWELog.info(.app, "Live screen saver: no broker (the screen saver extension can't reach the app)")
            self?.lock.withLock { self?.broker = nil }
        }
        connection.resume()
        lock.withLock { broker = connection }
        sendEndpoint()
    }

    private func sendEndpoint() {
        guard let broker = lock.withLock({ broker }) else { return }
        let proxy = broker.remoteObjectProxyWithErrorHandler { error in
            OWELog.info(.app, "Live screen saver: the broker didn't take the endpoint: \(error.localizedDescription)")
        } as? LiveSaverBrokerProtocol
        proxy?.register(listener.endpoint)
    }

    func invalidate() {
        listener.invalidate()
        let (all, broker) = lock.withLock { (Array(clients.values), self.broker) }
        broker?.invalidate()
        all.forEach { $0.connection.invalidate() }
    }

    // MARK: Frames (any thread)

    /// New rings (or none): every client gets them.
    func use(_ message: LiveSaverFramesMessage) {
        let all = lock.withLock {
            latest = message
            return Array(clients.values)
        }
        for client in all { client.proxy?.use(message) }
    }

    func show(ring: Int, stamp: UInt64) {
        let all = lock.withLock { clients.values.filter(\.isAttached) }
        for client in all { client.proxy?.show(ring: ring, stamp: stamp) }
    }

    var connectedClients: Int { lock.withLock { clients.count } }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let peerRequirement { connection.setCodeSigningRequirement(peerRequirement) }
        let client = Client(connection: connection, service: self)
        connection.exportedInterface = LiveSaverFramesMessage.serviceInterface()
        connection.exportedObject = client
        connection.remoteObjectInterface = LiveSaverFramesMessage.clientInterface()
        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            self?.lock.withLock { self?.clients[id] = nil }
            OWELog.info(.app, "Live screen saver: an extension disconnected")
        }
        client.proxy = connection.remoteObjectProxyWithErrorHandler { error in
            OWELog.info(.app, "Live screen saver: an extension call failed: \(error.localizedDescription)")
        } as? LiveSaverClientProtocol
        lock.withLock { clients[id] = client }
        connection.resume()
        OWELog.info(.app, "Live screen saver: an extension connected (pid \(connection.processIdentifier))")
        return true
    }

    fileprivate func attached(_ client: Client, isPreview: Bool) {
        let latest = lock.withLock { self.latest }
        if let latest { client.proxy?.use(latest) }
        if !isPreview { alive() }
    }

    fileprivate func alive() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onAlive?() }
        }
    }

    /// Peers signed by this app's team; nil for an unsigned or ad-hoc build.
    static let ownTeamRequirement: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }()

    /// One extension process: its views and its proxy.
    fileprivate final class Client: NSObject, LiveSaverServiceProtocol, @unchecked Sendable { // `lock` owns `views`.
        let connection: NSXPCConnection
        weak var service: ScreenSaverFrameService?
        var proxy: LiveSaverClientProtocol?
        private let lock = NSLock()
        private var views: [String: Bool] = [:]

        init(connection: NSXPCConnection, service: ScreenSaverFrameService) {
            self.connection = connection
            self.service = service
        }

        var isAttached: Bool { lock.withLock { !views.isEmpty } }

        func attach(viewID: String, display: String?, isPreview: Bool, reply: @escaping (Bool) -> Void) {
            lock.withLock { views[viewID] = isPreview }
            OWELog.info(.app, "Live screen saver: extension view \(viewID) attached (display \(display ?? "unknown"), preview \(isPreview))")
            service?.attached(self, isPreview: isPreview)
            reply(service?.isDrawing() ?? false)
        }

        func ping(viewID: String) {
            guard lock.withLock({ views[viewID] }) == false else { return }
            service?.alive()
        }

        func detach(viewID: String) {
            lock.withLock { views[viewID] = nil }
        }
    }
}
