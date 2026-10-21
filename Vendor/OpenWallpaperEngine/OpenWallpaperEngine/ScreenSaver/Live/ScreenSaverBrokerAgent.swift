import AppKit
import ServiceManagement

/// The live screen saver's broker (`owe-saver-broker`) as a launch agent of the app
/// (`SMAppService`, `Contents/Library/LaunchAgents/app.openwallpaperengine.saver-broker.plist`):
/// registered while Settings › Plugins › Screen Saver is on, unregistered when it is turned off.
/// launchd then starts it on demand, for the extension's Mach lookup or the `.saver`'s Darwin
/// notification (`LaunchEvents`), and it launches the app when a saver shows while the app isn't
/// running.
///
/// macOS lists it under System Settings › General › Login Items › Allow in the Background, where
/// the user may turn it off: it then `requiresApproval`, which Settings › Plugins › Screen Saver
/// says, with a button to that pane. The state is read again whenever the app becomes active.
/// Only release builds carry the agent (the app target's "Embed Screen Saver Extension and Broker"
/// phase), and only the user's own copy registers it.
@MainActor
final class ScreenSaverBrokerAgent: ObservableObject {
    enum State: Equatable {
        /// This build carries no agent (a development build, or an isolated copy).
        case unavailable
        case notRegistered
        case enabled
        /// The user turned it off in Login Items, or hasn't allowed it yet.
        case requiresApproval
        /// Registering failed, with why.
        case failed(String)
    }

    static let plistName = "app.openwallpaperengine.saver-broker.plist"

    @Published private(set) var state: State = .unavailable
    private let service: SMAppService
    private let isEmbedded: Bool
    private let mayRegister: Bool
    private var activation: NSObjectProtocol?

    init(bundle: Bundle = .main, mayRegister: Bool = ScreenSaverInstaller.current.mayInstall) {
        service = SMAppService.agent(plistName: Self.plistName)
        isEmbedded = FileManager.default.fileExists(atPath: bundle.bundleURL
            .appending(path: "Contents/Library/LaunchAgents/\(Self.plistName)").path(percentEncoded: false))
        self.mayRegister = mayRegister
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// The Screen Saver plugin was turned on or off.
    func update(enabled: Bool) {
        guard isEmbedded, mayRegister else { return }
        if enabled {
            guard service.status != .enabled else { return refresh() }
            do {
                try service.register()
                OWELog.info(.app, "Live screen saver: registered the broker's launch agent")
            } catch {
                // Turned off in Login Items: the status says so (`requiresApproval`).
                OWELog.error(.app, "Live screen saver: can't register the broker's launch agent: \(error)")
                if service.status != .requiresApproval { state = .failed(error.localizedDescription) }
                return refresh(keepingFailure: true)
            }
        } else if service.status != .notRegistered && service.status != .notFound {
            service.unregister { error in
                if let error { OWELog.error(.app, "Live screen saver: can't unregister the broker's launch agent: \(error)") }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.refresh() } }
            }
        }
        refresh()
    }

    /// Reads the agent's status again (the user may have changed it in Login Items).
    func refresh(keepingFailure: Bool = false) {
        guard isEmbedded, mayRegister else {
            state = .unavailable
            return
        }
        if keepingFailure, case .failed = state { return }
        state = Self.state(service.status)
    }

    nonisolated static func state(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .notRegistered
        }
    }

    /// System Settings › General › Login Items, where the user allows it.
    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
