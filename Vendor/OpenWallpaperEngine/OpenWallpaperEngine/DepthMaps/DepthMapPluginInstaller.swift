import CoreML
import Foundation
import OWEEditor

/// What `DepthMapPluginInstaller` is doing.
enum DepthMapPluginInstallPhase: VersionedInstallPhase {
    case idle
    case downloading(fraction: Double?)
    case compiling
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .compiling: return true
        case .idle, .installed, .failed: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Installs the optional Depth Map Generation plugin on demand, the way `ChromiumEngineInstaller`
/// installs the Chromium engine: nothing of the model ships with the app, and it is off until the
/// user installs it in Settings › Plugins.
///
/// Layout: `DepthMapPluginLayout`, under `<Application Support>/Open Wallpaper Engine/Plugins/
/// DepthMaps` (or the isolated sibling `AppStorageLocation` picks, so an isolated copy has its
/// own), a `VersionedInstallStore`. An install downloads every file of the pinned `.mlpackage`
/// (`DepthMapModelPin`) into a staging folder, checks each against its SHA-256, compiles the
/// package (`MLModel.compileModel`) and only then renames the result into place
/// (`VersionedInstallStore` has the rest: rollback, and keeping only the active and the previous
/// version).
@MainActor
final class DepthMapPluginInstaller: VersionedInstaller<DepthMapPluginInstallPhase> {
    typealias Phase = DepthMapPluginInstallPhase

    nonisolated static var defaultRoot: URL {
        DepthMapPluginLayout.root(supportDirectory: AppStorageLocation.current.supportDirectory)
    }

    let pin: DepthMapModelPin
    private let compile: @Sendable (URL) async throws -> URL

    init(root: URL = DepthMapPluginInstaller.defaultRoot,
         pin: DepthMapModelPin = .pinned,
         downloader: SteamCmdPackageDownloading = URLSessionSteamCmdDownloader(),
         compile: @escaping @Sendable (URL) async throws -> URL = { try await MLModel.compileModel(at: $0) },
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.pin = pin
        self.compile = compile
        super.init(store: DepthMapPluginInstallJob.store(in: root), downloader: downloader,
                   message: DepthMapPluginInstaller.message(for:), trash: trash)
    }

    var isCurrent: Bool { installedVersion == pin.version }
    var needsUpdate: Bool { installedVersion != nil && !isCurrent }

    override func activeVersion() -> String? {
        DepthMapPluginLayout.activeModel(in: root)?.version
    }

    // MARK: Install, update

    func install() {
        let job = DepthMapPluginInstallJob(root: root, pin: pin, downloader: downloader, compile: compile)
        start(version: pin.version, initialFraction: 0) { progress, phase in
            try await job.run(progress: progress, phase: phase)
        }
    }

    func update() {
        install()
    }

    nonisolated static func message(for error: Error) -> String {
        VersionedInstallFailure.message(
            for: error,
            offline: {
                String(localized: "Can’t reach Hugging Face to download the depth model. Check your internet connection and try again.",
                       table: "DepthMaps", comment: "Depth Map Generation install error")
            },
            diskFull: {
                String(localized: "There isn’t enough free disk space to install the depth model.",
                       table: "DepthMaps", comment: "Depth Map Generation install error")
            })
    }
}

/// The work of one install, off the main actor.
struct DepthMapPluginInstallJob: Sendable {
    enum Failure: LocalizedError, Equatable {
        case checksumMismatch(path: String)
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return String(localized: "The depth model download doesn’t match the version this app expects, so it wasn’t installed. Try again later.",
                              table: "DepthMaps", comment: "Depth Map Generation install error: a downloaded file's checksum is wrong")
            case .compileFailed(let reason):
                return String(localized: "The depth model can’t be prepared for this Mac: \(reason)",
                              table: "DepthMaps", comment: "Depth Map Generation install error; %@ is the system's reason")
            }
        }
    }

    let root: URL
    let pin: DepthMapModelPin
    let downloader: SteamCmdPackageDownloading
    let compile: @Sendable (URL) async throws -> URL

    static func store(in root: URL) -> VersionedInstallStore {
        VersionedInstallStore(root: root, category: .app, subject: "depth model")
    }

    func run(progress: @escaping @Sendable (Double?) -> Void,
             phase: @escaping @Sendable (DepthMapPluginInstallPhase) -> Void) async throws {
        let store = Self.store(in: root)
        try await store.install(version: pin.version) { staging in
            // Every file of the package, each checked against its own pin before it is kept.
            let package = staging.appending(path: pin.packageName, directoryHint: .isDirectory)
            let total = Double(max(pin.downloadSize, 1))
            var done: Int64 = 0
            var checksums: [String: String] = [:]
            for file in pin.files {
                let before = done
                try await store.fetch(pin.downloadURL(for: file), sha256: file.sha256, to: package.appending(path: file.path),
                                      downloader: downloader,
                                      progress: { fraction in progress((Double(before) + Double(file.size) * (fraction ?? 0)) / total) },
                                      mismatch: { _ in Failure.checksumMismatch(path: file.path) })
                checksums[file.path] = file.sha256
                done += file.size
                progress(Double(done) / total)
            }
            phase(.compiling)
            let compiled: URL
            do {
                compiled = try await compile(package)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw Failure.compileFailed(error.localizedDescription)
            }
            try Task.checkCancellation()
            let fileManager = FileManager.default
            let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: false)
            try fileManager.moveItem(at: compiled, to: unpacked.appending(path: DepthMapPluginLayout.compiledModelName, directoryHint: .isDirectory))
            try Data(pin.notice.utf8).write(to: unpacked.appending(path: DepthMapPluginLayout.noticeName))
            let manifest = DepthMapPluginLayout.Manifest(version: pin.version, repository: DepthMapModelPin.repository,
                                                         revision: pin.revision, files: checksums)
            try JSONEncoder().encode(manifest).write(to: unpacked.appending(path: DepthMapPluginLayout.manifestName), options: .atomic)
            return unpacked
        }
    }
}
