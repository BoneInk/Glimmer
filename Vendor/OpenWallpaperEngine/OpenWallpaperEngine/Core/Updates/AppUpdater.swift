import Combine
import CoreGraphics
import Foundation
import AppKit
import Sparkle

/// Sparkle's standard updater, started only when the build carries a public EdDSA key
/// (`AppUpdateConfiguration.isConfigured`). Release builds get one from the release workflow;
/// Debug and local builds don't, and never check.
///
/// "Update automatically" is Sparkle's automatic checks plus automatic downloads: an update is
/// downloaded in the background and installed on quit, or earlier by `PendingUpdateInstallPolicy`.
/// Sparkle keeps its own preferences (automatic checks and downloads, last check) in the app's
/// defaults domain; the beta choice lives in `UserDefaults.app`.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let receivesBetaUpdatesKey = "ReceiveBetaUpdates"

    let configuration: AppUpdateConfiguration
    private let defaults: UserDefaults
    /// nil when the updater is off.
    private(set) var controller: SPUStandardUpdaterController?

    /// Called just before Sparkle relaunches the app to install an update.
    var willRelaunch: (() -> Void)?

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    private var observations: [NSKeyValueObservation] = []
    private let installPolicy: PendingUpdateInstallPolicy
    private var pendingInstall: (readySince: Date, install: () -> Void)?
    private var pendingInstallTimer: Timer?
    /// Compiles an update's shaders before it relaunches (`UpdateShaderPrewarmer`); nil when off.
    private var shaderPrewarmer: UpdateShaderPrewarmer?

    var isEnabled: Bool { controller != nil }

    init(configuration: AppUpdateConfiguration, defaults: UserDefaults = .app,
         installPolicy: PendingUpdateInstallPolicy = .init()) {
        self.configuration = configuration
        self.defaults = defaults
        self.installPolicy = installPolicy
        super.init()
    }

    /// Starts Sparkle (scheduled checks included) when the build is configured for updates.
    func start() {
        guard controller == nil else { return }
        guard configuration.isConfigured else {
            OWELog.info(.app, "Updates are off: this build has no Sparkle public key (SPARKLE_PUBLIC_ED_KEY)")
            return
        }
        shaderPrewarmer = UpdateShaderPrewarmer.standard(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? AppStorageLocation.realBundleIdentifier)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater: SPUUpdater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value: Bool = updater.canCheckForUpdates
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                let value: Date? = updater.lastUpdateCheckDate
                Task { @MainActor in self?.lastUpdateCheckDate = value }
            }
        ]
        do {
            try updater.start()
        } catch {
            OWELog.error(.app, "Sparkle updater failed to start: \(error.localizedDescription)")
            return
        }
        // Sparkle's schedule alone waits up to its interval after launch (and skips the first run),
        // so a launch checks at once when checks are on and the last one is over an hour old.
        if Self.checksAtLaunch(automaticChecks: updater.automaticallyChecksForUpdates,
                               lastCheck: updater.lastUpdateCheckDate, now: Date()) {
            updater.checkForUpdatesInBackground()
        }
    }

    /// Whether a launch checks for updates in the background right away.
    static func checksAtLaunch(automaticChecks: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard automaticChecks else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= 60 * 60
    }

    /// The app is quitting: stops a running shader prewarm (Sparkle installs on quit by itself).
    func stopShaderPrewarm() {
        shaderPrewarmer?.cancel()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Checks, downloads and installs by itself. Turning it off keeps automatic checks (Sparkle then
    /// asks before installing), which `automaticallyChecksForUpdates` can turn off too.
    var updatesAutomatically: Bool {
        get { automaticallyChecksForUpdates && automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            if newValue { controller?.updater.automaticallyChecksForUpdates = true }
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Off by default, on by default for a pre-release build.
    var receivesBetaUpdates: Bool {
        get { configuration.receivesBetaUpdates(storedPreference: defaults.object(forKey: Self.receivesBetaUpdatesKey) as? Bool) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.receivesBetaUpdatesKey)
            controller?.updater.resetUpdateCycleAfterShortDelay()
        }
    }

    fileprivate var allowedChannels: Set<String> {
        configuration.allowedChannels(storedPreference: defaults.object(forKey: Self.receivesBetaUpdatesKey) as? Bool)
    }

    // MARK: Installing a downloaded update

    fileprivate func holdPendingInstall(_ install: @escaping () -> Void) {
        pendingInstall = (pendingInstall?.readySince ?? Date(), install)
        OWELog.info(.app, "An update is ready; it installs on quit, when the Mac is idle, or within a day")
        guard pendingInstallTimer == nil else { return }
        pendingInstallTimer = Timer.scheduledTimer(withTimeInterval: installPolicy.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installPendingUpdateIfDue() }
        }
    }

    private func installPendingUpdateIfDue() {
        guard let pendingInstall else { return }
        // Any input: keyboard, mouse, trackpad.
        let idle: TimeInterval = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard installPolicy.shouldInstall(readySince: pendingInstall.readySince, now: Date(), userIdleSeconds: idle) else { return }
        OWELog.info(.app, "Installing the downloaded update and relaunching")
        pendingInstallTimer?.invalidate()
        pendingInstallTimer = nil
        self.pendingInstall = nil
        pendingInstall.install()
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { allowedChannels }
    }

    /// Keeps the notes of every newer version, for What's New after the update (offline too).
    nonisolated func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        MainActor.assumeIsolated {
            guard let installed = ReleaseVersion(configuration.versionLabel) else { return }
            var notes: [String: String] = [:]
            for item in appcast.items {
                guard let text = item.itemDescription, !text.isEmpty else { continue }
                notes[item.displayVersionString] = item.itemDescriptionFormat == "plain-text" ? text : Self.plainText(html: text)
            }
            ReleaseNotesStore(defaults: defaults).cache(notes, newerThan: installed)
        }
    }

    private static func plainText(html: String) -> String {
        do {
            let text = try NSAttributedString(
                data: Data(html.utf8),
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
            return text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            OWELog.error(.app, "Could not read an update's release notes: \(error)")
            return ""
        }
    }

    /// Every install that relaunches passes here once (Sparkle's `installWithToolAndRelaunch:`),
    /// the user's "Install and Relaunch" and `holdPendingInstall`'s immediate install alike; an
    /// install on quit doesn't. The update is extracted by now: its shaders are compiled first.
    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let version: String = item.versionString
        return MainActor.assumeIsolated {
            guard let shaderPrewarmer else { return false }
            shaderPrewarmer.prewarmThenInstall(version: version, install: installHandler)
            return true
        }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch?() }
    }

    /// Takes over installing a silently downloaded update, which Sparkle otherwise leaves until quit.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated { holdPendingInstall(immediateInstallHandler) }
        return true
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// Names versions by their release label: every pre-release shares `CFBundleShortVersionString`.
    nonisolated func standardUserDriverRequestsVersionDisplayer() -> (any SUVersionDisplay)? {
        UpdateVersionDisplay(installedLabel: AppVersion.label(infoDictionary: Bundle.main.infoDictionary ?? [:]))
    }
}
