import AppKit
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle presents a native update prompt, then downloads and installs only
/// after the user confirms. It owns Ed25519 verification and relaunch as well.
/// User preferences stay in Sparkle's defaults so its dialogs and our settings
/// always agree. Constructing this object does not start the engine or read defaults.
@MainActor
@Observable
final class GWAppUpdater: NSObject {
    private(set) var isStarted = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = false
    private(set) var automaticallyDownloadsUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    private(set) var statusMessage = "尚未检查更新"
    private(set) var hasError = false

    @ObservationIgnored private let configuration: GWAppUpdateConfiguration
    #if canImport(Sparkle)
    @ObservationIgnored private var sparkleUpdater: SPUUpdater?
    @ObservationIgnored private var userDriver: (any SPUUserDriver)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    #endif

    init(configuration: GWAppUpdateConfiguration = .init(infoDictionary: Bundle.main.infoDictionary ?? [:])) {
        self.configuration = configuration
        super.init()
    }

    #if canImport(Sparkle)
    /// Allows isolated integration hosts to supply a driver that makes explicit
    /// install/dismiss choices. The app uses Sparkle's standard native dialogs.
    convenience init(userDriver: any SPUUserDriver,
                     configuration: GWAppUpdateConfiguration = .init(infoDictionary: Bundle.main.infoDictionary ?? [:])) {
        self.init(configuration: configuration)
        self.userDriver = userDriver
    }
    #endif

    /// Called by the composition root only after data migration and startup.
    func start() {
        guard !isStarted else { return }
        if let error = configuration.validationError {
            fail(error)
            return
        }
        #if canImport(Sparkle)
        let driver = userDriver ?? SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        sparkleUpdater = updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.automaticallyChecksForUpdates = value }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.automaticallyDownloadsUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                Task { @MainActor in self?.lastUpdateCheckDate = value }
            }
        ]
        do {
            try updater.start()
        } catch {
            observations.removeAll()
            sparkleUpdater = nil
            fail("无法启动自动更新：\(error.localizedDescription)")
            return
        }
        isStarted = true
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        hasError = false
        if canCheckForUpdates && GWAppUpdateConfiguration.shouldCheckAtLaunch(
            automaticChecks: automaticallyChecksForUpdates, lastCheck: lastUpdateCheckDate) {
            statusMessage = "正在检查更新…"
            updater.checkForUpdatesInBackground()
        }
        #else
        fail("此构建未包含自动更新组件。")
        #endif
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        hasError = false
        statusMessage = "正在检查更新…"
        #if canImport(Sparkle)
        sparkleUpdater?.checkForUpdates()
        #endif
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        #if canImport(Sparkle)
        guard let updater = sparkleUpdater, isStarted else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        #endif
    }

    private func fail(_ message: String) {
        statusMessage = message
        hasError = true
    }
}

#if canImport(Sparkle)
extension GWAppUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        statusMessage = "发现新版本 \(item.displayVersionString)，请在弹窗中确认是否更新"
        hasError = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        statusMessage = "没有适用于当前系统的新版本"
        hasError = false
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error = error as NSError? else { return }
        guard error.domain != SUSparkleErrorDomain || error.code != SUError.noUpdateError.rawValue else { return }
        if error.domain == SUSparkleErrorDomain && error.code == SUError.installationCanceledError.rawValue {
            statusMessage = "已取消安装更新"
            hasError = false
        } else {
            fail("检查或更新失败：\(error.localizedDescription)")
        }
    }
}
#endif
