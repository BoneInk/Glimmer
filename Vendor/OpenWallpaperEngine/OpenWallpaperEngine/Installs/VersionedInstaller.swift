import Combine
import Foundation

/// What a `VersionedInstaller` is doing. Each installer adds its own steps after the download
/// (verifying, unpacking, compiling); these are the ones they share.
protocol VersionedInstallPhase: Equatable, Sendable {
    static var idle: Self { get }
    static func downloading(fraction: Double?) -> Self
    static var installed: Self { get }
    static func failed(_ message: String) -> Self
    /// An install is running.
    var isBusy: Bool { get }
    var isDownloading: Bool { get }
}

/// The main-actor half of an on-demand, pinned install (`ChromiumEngineInstaller`,
/// `DepthMapPluginInstaller`): its phase, the installed version and size, and install, cancel and
/// remove. The work runs off the main actor in the specialization's job, over a
/// `VersionedInstallStore`; a specialization says which version is active and what its job does.
@MainActor
class VersionedInstaller<InstallPhase: VersionedInstallPhase>: ObservableObject {
    @Published private(set) var phase: InstallPhase = .idle
    /// The active install's version, nil without one.
    @Published private(set) var installedVersion: String?
    /// Bytes every installed version takes together, nil without any.
    @Published private(set) var installedSize: Int64?

    let root: URL
    let downloader: SteamCmdPackageDownloading
    private let store: VersionedInstallStore
    private let message: (Error) -> String
    private let trash: (URL) throws -> Void
    private var task: Task<Void, Never>?

    /// `message` turns a failure into what the user sees (`VersionedInstallFailure`).
    init(store: VersionedInstallStore,
         downloader: SteamCmdPackageDownloading,
         message: @escaping (Error) -> String,
         trash: @escaping (URL) throws -> Void) {
        self.root = store.root
        self.store = store
        self.downloader = downloader
        self.message = message
        self.trash = trash
        refresh()
    }

    var isBusy: Bool { phase.isBusy }

    /// The active install's folder, nil without one.
    var activeInstall: URL? {
        installedVersion.map { root.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// The version of the active, complete install on disk; nil without one.
    func activeVersion() -> String? { nil }

    /// The active version changed (also on the first read).
    func installedVersionDidChange() {}

    /// Re-reads what is on disk.
    func refresh() {
        let previousVersion = installedVersion
        installedVersion = activeVersion()
        if installedVersion != previousVersion {
            installedVersionDidChange()
        }
        installedSize = store.installedSize
    }

    // MARK: Install, cancel, remove

    /// Runs `job` (the specialization's install of `version`) unless one is running.
    func start(version: String, initialFraction: Double?,
               job: @escaping @Sendable (_ progress: @escaping @Sendable (Double?) -> Void,
                                         _ phase: @escaping @Sendable (InstallPhase) -> Void) async throws -> Void) {
        guard !isBusy else { return }
        phase = .downloading(fraction: initialFraction)
        task = Task { [weak self] in
            do {
                try await job(
                    { fraction in Task { @MainActor in self?.showDownload(fraction) } },
                    { phase in Task { @MainActor in self?.showStep(phase) } })
                self?.finish(.success(()), version: version)
            } catch {
                self?.finish(.failure(error), version: version)
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

    /// Moves every installed version, and anything else under `root`, to the Trash.
    func remove() throws {
        guard !isBusy else { return }
        if FileManager.default.fileExists(atPath: root.path) {
            try trash(root)
        }
        phase = .idle
        refresh()
    }

    private func showDownload(_ fraction: Double?) {
        guard phase.isDownloading else { return }
        phase = .downloading(fraction: fraction)
    }

    private func showStep(_ step: InstallPhase) {
        guard isBusy else { return }
        phase = step
    }

    private func finish(_ result: Result<Void, Error>, version: String) {
        task = nil
        switch result {
        case .success:
            OWELog.info(store.category, "\(store.subject) \(version) installed under \(root.path)")
            phase = .installed
        case .failure(let error) where error is CancellationError:
            OWELog.info(store.category, "\(store.subject) install cancelled")
            phase = .idle
        case .failure(let error):
            OWELog.error(store.category, "\(store.subject) install failed: \(error)")
            phase = .failed(message(error))
        }
        refresh()
    }
}
