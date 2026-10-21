import AppKit
import Observation

/// LaunchServices presents Apple's own Rosetta installer when it opens this Intel-only app.
/// We never invoke softwareupdate or accept Apple's license on the user's behalf.
@MainActor
@Observable
final class RosettaInstallController {
    enum State: Equatable {
        case idle
        case waiting
        case checkingSteamCMD
        case ready
        case cancelled
        case failed(String)

        var isBusy: Bool { self == .waiting || self == .checkingSteamCMD }
    }

    private(set) var state: State = .idle
    private(set) var launchNotice: String?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private let probe: @Sendable () async -> Bool
    @ObservationIgnored private let launch: @MainActor () async throws -> Void
    @ObservationIgnored private let continueWithSteamCMD: @MainActor () async -> Void
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maximumChecks: Int

    enum LaunchError: LocalizedError {
        case missingHelper
        var errorDescription: String? { "应用内 Rosetta 引导组件缺失，请重新安装完整应用。" }
    }

    convenience init(continueWithSteamCMD: @escaping @MainActor () async -> Void) {
        self.init(
            probe: { await Task.detached { SteamCMDCapabilityProbe.detectRosetta().isUsable }.value },
            launch: { try await RosettaInstallController.openSystemInstaller() },
            continueWithSteamCMD: continueWithSteamCMD
        )
    }

    init(
        probe: @escaping @Sendable () async -> Bool,
        launch: @escaping @MainActor () async throws -> Void,
        pollInterval: Duration = .seconds(2),
        maximumChecks: Int = 150,
        continueWithSteamCMD: @escaping @MainActor () async -> Void
    ) {
        self.probe = probe
        self.launch = launch
        self.pollInterval = pollInterval
        self.maximumChecks = maximumChecks
        self.continueWithSteamCMD = continueWithSteamCMD
    }

    func start() {
        guard !state.isBusy else { return }
        let token = UUID()
        generation = token
        state = .waiting
        launchNotice = nil
        // Poll independently: LaunchServices may wait for the system installer before completing.
        pollingTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<self.maximumChecks {
                await self.recheck()
                guard self.generation == token, self.state == .waiting, !Task.isCancelled else { return }
                do { try await Task.sleep(for: self.pollInterval) } catch { return }
            }
            guard self.generation == token, self.state == .waiting else { return }
            self.state = .failed("尚未检测到 Rosetta。若系统安装窗口已关闭或安装尚未完成，请完成安装后重试。")
            self.launchTask?.cancel()
        }
        launchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.launch()
            } catch {
                if let launchError = error as? LaunchError {
                    guard self.generation == token, self.state == .waiting else { return }
                    self.state = .failed(launchError.localizedDescription)
                    self.pollingTask?.cancel()
                    return
                }
                guard self.generation == token, self.state == .waiting else { return }
                // A helper can terminate immediately after successful install; verify before reporting launch errors.
                await self.recheck()
                guard self.generation == token, self.state == .waiting else { return }
                self.launchNotice = "正在等待系统安装。若没有出现安装窗口，或你已关闭它，请停止等待后重试。"
                // LaunchServices may report failure while the official Rosetta dialog is still open.
                // Keep monitoring until the user cancels or the bounded wait expires.
            }
        }
    }

    /// Also called on application activation, without reopening the installer.
    func recheck() async {
        guard state == .waiting, !isChecking else { return }
        let token = generation
        isChecking = true
        let usable = await probe()
        isChecking = false
        guard generation == token, state == .waiting, usable else { return }
        state = .checkingSteamCMD
        await continueWithSteamCMD()
        guard generation == token, state == .checkingSteamCMD else { return }
        state = .ready
    }

    func cancel() {
        generation = UUID()
        pollingTask?.cancel()
        launchTask?.cancel()
        state = .cancelled
        // This stops application-side waiting only; Apple's installer remains under user control.
    }

    private static func openSystemInstaller() async throws {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RosettaLauncher.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw LaunchError.missingHelper
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = true
        configuration.createsNewApplicationInstance = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
