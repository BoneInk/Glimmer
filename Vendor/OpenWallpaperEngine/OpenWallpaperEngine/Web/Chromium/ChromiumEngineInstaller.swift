import Foundation

/// What `ChromiumEngineInstaller` is doing.
enum ChromiumEngineInstallPhase: VersionedInstallPhase {
    case idle
    case downloading(fraction: Double?)
    case verifying
    case unpacking
    case installed
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .unpacking: return true
        case .idle, .installed, .failed: return false
        }
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Installs the optional Chromium web engine (CEF) on demand, the way `SteamCmdInstaller`
/// installs SteamCMD: nothing of CEF ships with the app.
///
/// Layout under `<Application Support>/Open Wallpaper Engine/ChromiumEngine` (or the isolated
/// sibling `AppStorageLocation` picks), a `VersionedInstallStore`:
///
///     <version>/Chromium Embedded Framework.framework   one folder per installed CEF version
///     <version>/LICENSE.txt
///     <version>/.owe-chromium-engine.json                written last: marks a complete install
///     .state.json                                        the active and the previous version
///     .profile/                                          CEF's profile (cookies, cache)
///     .staging-<uuid>/                                   one install in progress
///
/// An install downloads the archive, checks the SHA-256 pinned in `ChromiumEnginePin`, unpacks it
/// into the staging folder and only then renames the result into place (`VersionedInstallStore`
/// has the rest: rollback, and keeping only the active and the previous version).
///
/// Updates follow the app: when an app release pins a new build, `needsUpdate` turns on and
/// Update installs the new pin. There is no "latest".
@MainActor
final class ChromiumEngineInstaller: VersionedInstaller<ChromiumEngineInstallPhase> {
    typealias Phase = ChromiumEngineInstallPhase

    nonisolated static var defaultRoot: URL {
        AppStorageLocation.current.supportDirectory.appending(path: "ChromiumEngine", directoryHint: .isDirectory)
    }

    /// The build this app release wants, nil on an architecture with no pin.
    let pin: ChromiumEnginePin?

    init(root: URL = ChromiumEngineInstaller.defaultRoot,
         pin: ChromiumEnginePin? = ChromiumEnginePin.current(),
         downloader: SteamCmdPackageDownloading = URLSessionSteamCmdDownloader(),
         trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.pin = pin
        super.init(store: ChromiumEngineInstallJob.store(in: root), downloader: downloader,
                   message: ChromiumEngineInstaller.message(for:), trash: trash)
    }

    /// Whether an engine is installed, read from the folder without an installer (any thread).
    nonisolated static var hasActiveInstall: Bool {
        let root = defaultRoot
        guard let active = VersionedInstallState.read(in: root).active else { return false }
        return ChromiumEnginePackage.manifest(in: root.appending(path: active)) != nil
    }

    /// Whether the pinned build is the active install.
    var isCurrent: Bool { pin != nil && installedVersion == pin?.version }

    /// An older (or other) build is installed and this release pins a different one.
    var needsUpdate: Bool { installedVersion != nil && !isCurrent && pin != nil }

    /// CEF's profile folder.
    var profileDirectory: URL { root.appending(path: ".profile", directoryHint: .isDirectory) }

    override func activeVersion() -> String? {
        guard let active = VersionedInstallState.read(in: root).active,
              ChromiumEnginePackage.manifest(in: root.appending(path: active)) != nil else { return nil }
        return active
    }

    /// Web wallpapers move to the engine that is now there (`WebEngineRouter`).
    override func installedVersionDidChange() {
        NotificationCenter.default.post(name: .chromiumEngineChanged, object: nil)
    }

    // MARK: Install, update

    /// Installs the pinned build; also what Update does.
    func install() {
        guard let pin else { return }
        let job = ChromiumEngineInstallJob(root: root, pin: pin, downloader: downloader)
        start(version: pin.version, initialFraction: nil) { progress, phase in
            try await job.run(progress: progress, phase: phase)
        }
    }

    func update() {
        install()
    }

    /// A message the user can act on: offline and a full disk get their own.
    nonisolated static func message(for error: Error) -> String {
        VersionedInstallFailure.message(
            for: error,
            offline: {
                String(localized: "Can't reach the server to download the Chromium engine. Check your internet connection and try again.",
                       comment: "Chromium engine install error")
            },
            diskFull: {
                String(localized: "There isn't enough free disk space to install the Chromium engine.",
                       comment: "Chromium engine install error")
            })
    }
}

/// The work of one install, off the main actor.
struct ChromiumEngineInstallJob: Sendable {
    let root: URL
    let pin: ChromiumEnginePin
    let downloader: SteamCmdPackageDownloading
    /// The helper apps copied into the engine bundle; nil copies none (tests).
    var helpers: URL? = ChromiumEngineHelpers.bundled

    static let stagingPrefix = VersionedInstallStore.stagingPrefix

    static func store(in root: URL) -> VersionedInstallStore {
        VersionedInstallStore(root: root, category: .web, subject: "Chromium engine")
    }

    private var store: VersionedInstallStore { Self.store(in: root) }

    func run(progress: @escaping @Sendable (Double?) -> Void,
             phase: @escaping @Sendable (ChromiumEngineInstallPhase) -> Void) async throws {
        try await store.install(version: pin.version) { staging in
            let archive = staging.appending(path: pin.archiveName)
            try await store.fetch(pin.downloadURL, sha256: pin.sha256, to: archive, downloader: downloader,
                                  progress: progress, verifying: { phase(.verifying) },
                                  mismatch: { ChromiumEnginePackage.Failure.checksumMismatch(expected: $0.expected, actual: $0.actual) })
            ChromiumEnginePackage.removeQuarantine(fromVerified: archive)
            try Task.checkCancellation()

            phase(.unpacking)
            let scratch = staging.appending(path: "scratch", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
            try ChromiumEnginePackage.unpack(archive, pin: pin, scratch: scratch, into: unpacked, helpers: helpers)
            try Task.checkCancellation()
            return unpacked
        }
    }

    /// Renames `unpacked` into place, records it as active and prunes (`VersionedInstallStore`).
    func commit(_ unpacked: URL, staging: URL) throws {
        try store.commit(unpacked, version: pin.version, staging: staging)
    }
}
