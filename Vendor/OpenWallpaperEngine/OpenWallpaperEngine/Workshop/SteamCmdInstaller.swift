import Foundation
import Combine

/// Runs a freshly extracted steamcmd once, so it downloads its own updates before first use.
protocol SteamCmdFirstRunning: Sendable {
    func firstRun(_ executable: URL) async throws
}

/// Installs Valve's SteamCMD into the app's support folder (`<Application Support>/Open Wallpaper
/// Engine/steamcmd`, or the isolated sibling): download from Valve over HTTPS, check and extract
/// the archive, then let steamcmd update itself. Nothing of SteamCMD ships with the app.
///
/// On launch, and when the Workshop or Assets page opens, `autoInstallIfNeeded` installs it in the
/// background when no working steamcmd was found and the user hasn't turned that off. A failed
/// automatic install waits for the next of those moments instead of retrying on its own.
@MainActor
final class SteamCmdInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double?)
        case extracting
        case updating
        case installed
        case failed(String)
    }

    /// `UserDefaults.app` key of Settings › Assets › "Install SteamCMD automatically"; on when unset.
    nonisolated static let autoInstallKey = "InstallSteamCmdAutomatically"

    nonisolated static var defaultInstallDirectory: URL {
        AppStorageLocation.current.supportDirectory.appending(path: "steamcmd", directoryHint: .isDirectory)
    }

    @Published private(set) var phase: Phase = .idle
    /// Whether the running or last install started on its own rather than from a button.
    @Published private(set) var isAutomatic = false
    /// Bytes the app's own copy takes, nil without one.
    @Published private(set) var installedSize: Int64?

    let installDirectory: URL
    private let downloader: SteamCmdPackageDownloading
    private let firstRunner: SteamCmdFirstRunning
    private let defaults: UserDefaults
    private let isRunningTests: Bool
    private let onInstalled: @MainActor () -> Void
    private let trash: (URL) throws -> Void
    private var task: Task<Void, Never>?

    init(installDirectory: URL = SteamCmdInstaller.defaultInstallDirectory,
         downloader: SteamCmdPackageDownloading = URLSessionSteamCmdDownloader(),
         firstRunner: SteamCmdFirstRunning = ProcessSteamCmdFirstRunner(),
         defaults: UserDefaults = .app,
         isRunningTests: Bool = NSClassFromString("XCTestCase") != nil,
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         onInstalled: @escaping @MainActor () -> Void = {}) {
        self.trash = trash
        self.installDirectory = installDirectory
        self.downloader = downloader
        self.firstRunner = firstRunner
        self.defaults = defaults
        self.isRunningTests = isRunningTests
        self.onInstalled = onInstalled
        refreshSize()
    }

    var executable: URL { SteamCmdLocator.ownExecutable(in: installDirectory) }
    var hasOwnCopy: Bool { SteamCmdLocator.isExecutableFile(executable.path) }

    var isBusy: Bool {
        switch phase {
        case .downloading, .extracting, .updating: return true
        case .idle, .installed, .failed: return false
        }
    }

    var isAutoInstallEnabled: Bool {
        defaults.object(forKey: Self.autoInstallKey) as? Bool ?? true
    }

    // MARK: Automatic install

    /// Whether an automatic install should start now.
    nonisolated static func shouldAutoInstall(isRunningTests: Bool, isEnabled: Bool, steamCmdFound: Bool, phase: Phase) -> Bool {
        guard !isRunningTests, isEnabled, !steamCmdFound else { return false }
        switch phase {
        case .idle, .failed: return true
        case .downloading, .extracting, .updating, .installed: return false
        }
    }

    /// Starts an automatic install when no steamcmd was found; `steamCmdFound` is the result of a
    /// full detection. Returns whether it started.
    @discardableResult
    func autoInstallIfNeeded(steamCmdFound: Bool) -> Bool {
        guard Self.shouldAutoInstall(isRunningTests: isRunningTests, isEnabled: isAutoInstallEnabled,
                                     steamCmdFound: steamCmdFound, phase: phase) else { return false }
        OWELog.info(.workshop, "No steamcmd found; installing SteamCMD from Valve into \(installDirectory.path)")
        start(automatic: true)
        return true
    }

    /// Runs a full detection with `steamCmd`, then `autoInstallIfNeeded` with its result.
    func detectThenAutoInstall(_ steamCmd: SteamCmdService) {
        steamCmd.detectSteamCmd { [weak self] found in
            self?.autoInstallIfNeeded(steamCmdFound: found)
        }
    }

    // MARK: Install, cancel, remove

    func install() {
        start(automatic: false)
    }

    private func start(automatic: Bool) {
        guard !isBusy else { return }
        isAutomatic = automatic
        phase = .downloading(fraction: nil)
        let job = InstallJob(installDirectory: installDirectory, downloader: downloader, firstRunner: firstRunner)
        task = Task { [weak self] in
            do {
                try await job.run(
                    progress: { fraction in Task { @MainActor in self?.showDownload(fraction) } },
                    phase: { phase in Task { @MainActor in self?.showStep(phase) } })
                self?.finish(.success(()))
            } catch {
                self?.finish(.failure(error))
            }
        }
    }

    /// The running install awaits `wait()` in tests.
    func wait() async {
        await task?.value
    }

    func cancel() {
        task?.cancel()
    }

    /// Moves the app's own copy to the Trash.
    func remove() throws {
        guard !isBusy else { return }
        if FileManager.default.fileExists(atPath: installDirectory.path) {
            try trash(installDirectory)
        }
        Self.removeFrameworksLink(besides: installDirectory)
        phase = .idle
        refreshSize()
        onInstalled()
    }

    /// steamcmd's first run leaves a `Frameworks -> MacOS/Frameworks` link in the folder above its
    /// own, as if it ran inside an app bundle; it dangles and goes with the copy.
    nonisolated static func removeFrameworksLink(besides installDirectory: URL) {
        let link = installDirectory.deletingLastPathComponent().appending(path: "Frameworks")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == "MacOS/Frameworks" else {
            return // No such link: nothing to clean up.
        }
        do {
            try FileManager.default.removeItem(at: link)
        } catch {
            OWELog.error(.workshop, "Can't remove steamcmd's Frameworks link at \(link.path): \(error)")
        }
    }

    func refreshSize() {
        installedSize = hasOwnCopy ? SteamCmdPackage.size(of: installDirectory) : nil
    }

    private func showDownload(_ fraction: Double?) {
        guard case .downloading = phase else { return }
        phase = .downloading(fraction: fraction)
    }

    private func showStep(_ step: Phase) {
        guard isBusy else { return }
        phase = step
    }

    private func finish(_ result: Result<Void, Error>) {
        task = nil
        switch result {
        case .success:
            OWELog.info(.workshop, "SteamCMD installed at \(executable.path)")
            phase = .installed
            refreshSize()
            onInstalled()
        case .failure(let error) where error is CancellationError:
            OWELog.info(.workshop, "SteamCMD install cancelled")
            phase = .idle
        case .failure(let error):
            OWELog.error(.workshop, "SteamCMD install failed: \(error)")
            phase = .failed(Self.message(for: error))
        }
    }

    /// A message the user can act on: offline and a full disk get their own.
    nonisolated static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return String(localized: "Can't reach Valve's server to download SteamCMD. Check your internet connection and try again.",
                              comment: "SteamCMD install error")
            default:
                break
            }
        }
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
            || (error as? URLError)?.code == .cannotWriteToFile {
            return String(localized: "There isn't enough free disk space to install SteamCMD.", comment: "SteamCMD install error")
        }
        return error.localizedDescription
    }
}

/// The work of one install, off the main actor.
private struct InstallJob: Sendable {
    let installDirectory: URL
    let downloader: SteamCmdPackageDownloading
    let firstRunner: SteamCmdFirstRunning

    func run(progress: @escaping @Sendable (Double?) -> Void,
             phase: @escaping @Sendable (SteamCmdInstaller.Phase) -> Void) async throws {
        let fileManager = FileManager.default
        let parent = installDirectory.deletingLastPathComponent()
        let staging = parent.appending(path: ".steamcmd-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { Self.remove(staging) }

        let archive = staging.appending(path: SteamCmdPackage.downloadURL.lastPathComponent)
        try await downloader.download(SteamCmdPackage.downloadURL, to: archive, progress: progress)
        try Task.checkCancellation()

        phase(.extracting)
        let extracted = staging.appending(path: "steamcmd", directoryHint: .isDirectory)
        _ = try SteamCmdPackage.extract(archive, into: extracted)
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: installDirectory.path) {
            try fileManager.removeItem(at: installDirectory)
        }
        try fileManager.moveItem(at: extracted, to: installDirectory)

        phase(.updating)
        do {
            try await firstRunner.firstRun(SteamCmdLocator.ownExecutable(in: installDirectory))
            try Task.checkCancellation()
        } catch {
            // A copy that never updated itself isn't left behind as if it worked.
            Self.remove(installDirectory)
            throw error
        }
    }

    private static func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            OWELog.error(.workshop, "Can't remove \(url.path): \(error)")
        }
    }
}

/// Runs `steamcmd.sh` with only `quit` on its stdin, the same as `steamcmd.sh +quit`.
struct ProcessSteamCmdFirstRunner: SteamCmdFirstRunning {
    enum Failure: LocalizedError {
        case exited(Int32, String)

        var errorDescription: String? {
            switch self {
            case .exited(let code, let line):
                return String(localized: "SteamCMD couldn't update itself (exit code \(Int(code))): \(line)",
                              comment: "SteamCMD install error; %1$lld is an exit code, %2$@ steamcmd's last output line")
            }
        }
    }

    /// Exit codes steamcmd returns after a successful self-update and `quit`.
    static let successCodes: Set<Int32> = [0, 7]

    func firstRun(_ executable: URL) async throws {
        let cancellation = SteamCmdCancellation()
        let run: SteamCmdRun = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SteamCmdRun, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    let result = ProcessSteamCmdRunner().run(executable: executable, script: SteamCmdScript(),
                                                             timeout: 15 * 60, cancellation: cancellation,
                                                             onOutput: { _ in })
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        OWELog.info(.workshop, "steamcmd first run exit=\(run.exitCode)\n\(run.output)")
        guard Self.successCodes.contains(run.exitCode) else {
            let last = run.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw Failure.exited(run.exitCode, last)
        }
    }
}
