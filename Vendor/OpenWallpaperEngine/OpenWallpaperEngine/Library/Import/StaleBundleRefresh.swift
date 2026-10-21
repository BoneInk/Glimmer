import Foundation

/// An installed bundle made by an older converter whose archived package is gone (the setting that
/// deletes originals removed it), so it can't be re-converted locally.
struct StaleBundle: Equatable {
    let directory: URL
    /// nil for a local import, which has nowhere to download the package from.
    let workshopId: String?
    let packageName: String
    let title: String
}

enum StaleBundleScanner {
    /// Bundles in `storage` older than the current converter with no package to re-convert from
    /// and changed by a newer version, in folder-name order; unaffected ones are stamped current. Reads only each folder's manifest and project; call off the main thread.
    static func scan(storage: URL, fileManager: FileManager = .default) -> [StaleBundle] {
        guard let entries = OWELog.attempt(.importer, "Stale bundles: listing \(storage.path(percentEncoded: false))", quietIfMissing: true, {
            try fileManager.contentsOfDirectory(at: storage, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])
        }) else { return [] }
        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { staleBundle(at: $0, fileManager: fileManager) }
    }

    static func staleBundle(at directory: URL, fileManager: FileManager = .default) -> StaleBundle? {
        guard let manifest = WallpaperPackageConverter.manifest(in: directory),
              manifest.converterVersion < WallpaperPackageConverter.converterVersion else { return nil }
        let packageName = manifest.sourcePackage
        let live = directory.appending(path: packageName)
        let archived = directory.appending(path: WallpaperPackageConverter.sourceFolderName).appending(path: packageName)
        guard !fileManager.fileExists(atPath: live.path(percentEncoded: false)),
              !fileManager.fileExists(atPath: archived.path(percentEncoded: false)) else { return nil }
        // Nothing a newer version changes: the bundle is already what it would produce.
        guard WallpaperPackageConverter.isAffectedByNewerVersions(manifest, directory: directory) else {
            WallpaperPackageConverter.stampCurrent(in: directory)
            return nil
        }
        let project = try? WEProject.read(in: directory)
        // The folder is named for the item Steam installed; project.json's id can be empty or point
        // at the author's earlier upload, so it's only the fallback.
        let isWorkshopId = { (id: String) in !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber } }
        let workshopId = [directory.lastPathComponent, project?.workshopid?.rawValue].compactMap { $0 }.first(where: isWorkshopId)
        return StaleBundle(directory: directory,
                           workshopId: workshopId,
                           packageName: packageName,
                           title: project?.title ?? directory.lastPathComponent)
    }
}

/// What the refresh needs from the Workshop download path; `SteamCmdService` in the app.
protocol StaleBundleDownloading: AnyObject {
    /// Calls back on the main queue with whether a signed-in SteamCMD session is there.
    func restoreSession(completion: @escaping (Bool) -> Void)
    /// Downloads the item and puts its `packageName` into the folder's `.owe-source/`, leaving the
    /// live files alone. Calls back on the main queue with whether the package landed.
    func fetchArchivedPackage(workshopId: String, packageName: String, into wallpaperDirectory: URL,
                              completion: @escaping (Bool) -> Void)
}

extension SteamCmdService: StaleBundleDownloading {}

/// Gets stale bundles their package back one at a time, then re-converts them once they aren't
/// on screen. Whatever can't be updated keeps its current files, is listed in one notice, and is
/// tried again on a later launch.
@MainActor
final class StaleBundleRefresher {
    private let downloader: StaleBundleDownloading
    private let isShown: (URL) -> Bool
    /// Re-converts a folder whose package is back; runs off the main thread.
    private let reconvert: (URL) -> Void
    private let notify: ([String]) -> Void
    private var queue: [StaleBundle] = []
    private var failed: [String] = []
    /// Folders whose package is back but which were on screen; converted once they're not.
    private(set) var pendingReconversion: [URL] = []
    private var onFinished: (() -> Void)?

    init(downloader: StaleBundleDownloading,
         isShown: @escaping (URL) -> Bool,
         reconvert: @escaping (URL) -> Void = StaleBundleRefresher.reconvertInBackground,
         notify: @escaping ([String]) -> Void) {
        self.downloader = downloader
        self.isShown = isShown
        self.reconvert = reconvert
        self.notify = notify
    }

    func run(_ bundles: [StaleBundle], onFinished: (() -> Void)? = nil) {
        self.onFinished = onFinished
        failed = bundles.filter { $0.workshopId == nil }.map(\.title)
        let workshop = bundles.filter { $0.workshopId != nil }
        guard !workshop.isEmpty else { return finish() }
        downloader.restoreSession { [weak self] signedIn in
            guard let self else { return }
            guard signedIn else {
                self.failed += workshop.map(\.title)
                return self.finish()
            }
            self.queue = workshop
            self.next()
        }
    }

    /// Call when the shown wallpapers change: converts what was waiting on them.
    func shownWallpapersChanged() {
        let ready = pendingReconversion.filter { !isShown($0) }
        pendingReconversion.removeAll { ready.contains($0) }
        ready.forEach(reconvert)
    }

    private func next() {
        guard !queue.isEmpty else { return finish() }
        let bundle = queue.removeFirst()
        downloader.fetchArchivedPackage(workshopId: bundle.workshopId!, packageName: bundle.packageName,
                                        into: bundle.directory) { [weak self] landed in
            guard let self else { return }
            if !landed {
                self.failed.append(bundle.title)
            } else if self.isShown(bundle.directory) {
                self.pendingReconversion.append(bundle.directory)
            } else {
                self.reconvert(bundle.directory)
            }
            self.next()
        }
    }

    private func finish() {
        if !failed.isEmpty { notify(failed) }
        failed = []
        onFinished?()
        onFinished = nil
    }

    /// Re-converts from the restored package and, with the setting on, deletes it again.
    nonisolated static func reconvertInBackground(_ directory: URL) {
        DispatchQueue.global(qos: .background).async {
            guard WallpaperPackageConverter.convertIfNeeded(wallpaperDirectory: directory) != nil else { return }
            if UserDefaults.app.bool(forKey: "ReclaimOriginalPackages") {
                WallpaperPackageConverter.reclaimSource(in: directory)
            }
        }
    }

    static func noticeMessage(for titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return String(localized: "Couldn't update \(names) to the latest conversion. They keep working as before, and Open Wallpaper Engine will try again next launch.",
                      comment: "Notice after launch; names is a list of wallpaper titles")
    }
}
