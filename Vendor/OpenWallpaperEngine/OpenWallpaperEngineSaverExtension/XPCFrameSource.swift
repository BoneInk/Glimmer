import Foundation
import IOSurface

/// The extension's way to the app's live frames. It asks the broker (a launchd agent, the only
/// Mach service the app side can publish) for the app's endpoint, connects to it, attaches its
/// views and receives the rings' surfaces as XPC objects and each frame's stamp, filling `store`.
/// No app or no broker: nothing arrives and the views play their video. One per process.
final class XPCFrameSource: NSObject, LiveFrameSource, LiveSaverClientProtocol {
    static let shared = XPCFrameSource()

    let store = LiveFrameStore()
    /// Main thread: the views attached, the connection and its proxy.
    private var views: [String: (display: String?, isPreview: Bool)] = [:]
    private var connection: NSXPCConnection?
    private var service: LiveSaverServiceProtocol?
    private var connecting = false
    private var lastAttempt: TimeInterval = -.infinity
    /// Retry a missing app this often while a view shows.
    private static let retryInterval: TimeInterval = 2

    func attach(viewID: String, display: String?, isPreview: Bool) {
        views[viewID] = (display, isPreview)
        SaverLog.transport.notice("attach view=\(viewID, privacy: .public) display=\(display ?? "nil", privacy: .public) preview=\(isPreview) pid=\(getpid())")
        if let service {
            attach(viewID, on: service)
        } else {
            connectIfNeeded()
        }
    }

    func ping(viewID: String) {
        guard let view = views[viewID], !view.isPreview else { return }
        if let service { service.ping(viewID: viewID) } else { connectIfNeeded() }
    }

    func detach(viewID: String) {
        views[viewID] = nil
        service?.detach(viewID: viewID)
    }

    func refresh() {}

    // MARK: Connection (main thread)

    private func connectIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard connection == nil, !connecting, now - lastAttempt >= Self.retryInterval else { return }
        connecting = true
        lastAttempt = now
        let broker = NSXPCConnection(machServiceName: ScreenSaverLiveNames.brokerService)
        broker.remoteObjectInterface = LiveSaverFramesMessage.brokerInterface()
        broker.resume()
        let proxy = broker.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                SaverLog.transport.notice("broker unreachable: \(error.localizedDescription, privacy: .public)")
                broker.invalidate()
                self.connecting = false
            }
        } as? LiveSaverBrokerProtocol
        proxy?.endpoint { endpoint in
            DispatchQueue.main.async {
                broker.invalidate()
                guard let endpoint else {
                    SaverLog.transport.notice("broker has no app endpoint (the app isn't running)")
                    self.connecting = false
                    return
                }
                self.connect(to: endpoint)
            }
        }
    }

    private func connect(to endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = LiveSaverFramesMessage.serviceInterface()
        connection.exportedInterface = LiveSaverFramesMessage.clientInterface()
        connection.exportedObject = self
        let ended: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.connectionEnded() }
        }
        connection.invalidationHandler = ended
        connection.interruptionHandler = ended
        connection.resume()
        self.connection = connection
        service = connection.remoteObjectProxyWithErrorHandler { error in
            SaverLog.transport.error("app call failed: \(error.localizedDescription, privacy: .public)")
        } as? LiveSaverServiceProtocol
        connecting = false
        SaverLog.transport.notice("XPC connected to the app pid=\(connection.processIdentifier)")
        if let service { for viewID in views.keys { attach(viewID, on: service) } }
    }

    private func attach(_ viewID: String, on service: LiveSaverServiceProtocol) {
        guard let view = views[viewID] else { return }
        service.attach(viewID: viewID, display: view.display, isPreview: view.isPreview) { drawing in
            SaverLog.transport.notice("attached view=\(viewID, privacy: .public) appDrawing=\(drawing)")
        }
    }

    private func connectionEnded() {
        guard connection != nil else { return }
        connection = nil
        service = nil
        store.use(ScreenSaverLiveManifest(), surfaces: [:])
        SaverLog.transport.notice("XPC connection to the app ended")
    }

    // MARK: LiveSaverClientProtocol (XPC's queue)

    func use(_ message: LiveSaverFramesMessage) {
        var surfaces: [Int: [IOSurface]] = [:]
        for ring in message.manifest.rings { surfaces[ring.id] = message.surfaces(ofRing: ring.id) }
        store.use(message.manifest, surfaces: surfaces)
        SaverLog.transport.notice("XPC rings generation=\(message.manifest.generation) rings=\(message.manifest.rings.count) surfaces=\(message.surfaces.count) fps=\(message.manifest.frameRate)")
    }

    func show(ring: Int, stamp: UInt64) {
        guard let stamp = ScreenSaverLiveStamp(state: stamp) else { return }
        store.show(ring: ring, stamp: stamp)
    }
}
