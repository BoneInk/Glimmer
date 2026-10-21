import Foundation

/// The screen saver's shared folder, where the app writes what the savers read: the live frames'
/// manifest (`ScreenSaverLiveManifest`) and the stills (`ScreenSaverStills`).
///
/// **Path.** `~/Library/Application Support/Open Wallpaper Engine/ScreenSaver`
/// (`ScreenSaverManifest.sharedFolder`). macOS stops the app writing into the screen saver host's
/// container, but the host (`legacyScreenSaver`) may read any path, so the saver reads them there.
/// An isolated copy (`AppStorageLocation`) writes under its own support folder instead, where no
/// saver looks, so a test or development run never changes what the user's saver shows.
///
/// Earlier versions also kept videos here (scenes' recordings, and video wallpapers' own files
/// linked or copied in for the saver to play); `removeOldRecordings` and `removeOldVideoFiles`
/// delete them.
struct ScreenSaverVideoStore: Sendable {
    let directory: URL

    static var current: ScreenSaverVideoStore {
        ScreenSaverVideoStore(location: .current, home: ScreenSaverManifest.userHome)
    }

    init(directory: URL) { self.directory = directory }

    init(location: AppStorageLocation, home: URL) {
        directory = location.isIsolated
            ? location.supportDirectory.appending(path: "ScreenSaver", directoryHint: .isDirectory)
            : ScreenSaverManifest.sharedFolder(home: home)
    }

    func url(fileName: String) -> URL { directory.appending(path: fileName, directoryHint: .notDirectory) }

    /// Whether `name` is one of the stills (`stills.json`, a picture, or one being written:
    /// `ScreenSaverStillPublisher` stages it as `.<uuid>-still-…`).
    static func isStill(_ name: String) -> Bool {
        name == ScreenSaverStills.fileName || name.hasPrefix("still-") || name.hasPrefix(".") && name.contains("-still-")
    }

    // MARK: Earlier versions' recordings

    /// Whether `name` is a video an earlier version recorded here: a scene's or a page's loop
    /// (`<wallpaper>_<content>-<property hash>-<width>x<height>-r<revision>.mov`) or a Screen Saver
    /// mode recording of one (the same with `-rec<time>`). A video wallpaper's own file
    /// (`…-video-r<revision>.<extension>`) and anything else isn't.
    static func isOldRecording(_ name: String) -> Bool {
        name.range(of: #"^[^/]+-[0-9a-f]{12}-[0-9]+x[0-9]+-r[0-9]+(-rec[0-9]+)?\.mov$"#, options: .regularExpression) != nil
            && !name.contains("-video-r")
    }

    /// Deletes the loop videos and recordings earlier versions made: only regular files directly
    /// in `folder` named as they were (`isOldRecording`), never one `keep` lists, never a link,
    /// a folder or anything outside it. Each deletion is logged. Returns the names deleted.
    @discardableResult
    static func removeOldRecordings(in folder: URL, keeping keep: Set<String> = []) -> [String] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            // Optional: no folder means nothing to delete.
            return []
        }
        var removed: [String] = []
        for file in files where isOldRecording(file.lastPathComponent) && !keep.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) // Optional: unreadable is skipped.
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                removed.append(file.lastPathComponent)
                OWELog.info(.app, "Screen saver: deleted the old recording \(file.lastPathComponent) from \(folder.lastPathComponent)")
            } catch {
                OWELog.error(.app, "Screen saver: can't delete the old recording \(file.lastPathComponent): \(error)")
            }
        }
        return removed
    }

    /// Deletes what earlier versions left: the recordings and video files in this folder
    /// (`removeOldVideoFiles`), and the recordings' staging folder in Caches, which goes once empty.
    func removeOldFiles(cachesDirectory: URL) {
        Self.removeOldRecordings(in: directory)
        Self.removeOldVideoFiles(in: directory)
        let staging = cachesDirectory.appending(path: "ScreenSaverRecordings", directoryHint: .isDirectory)
        Self.removeOldRecordings(in: staging)
        if let left = try? FileManager.default.contentsOfDirectory(atPath: staging.path(percentEncoded: false)), left.isEmpty { // Optional: absent is fine.
            try? FileManager.default.removeItem(at: staging) // Optional: an empty folder of ours.
        }
    }

    // MARK: Earlier versions' video files

    /// The manifest of the videos earlier versions' savers played.
    static let oldVideoManifest = "current.json"

    /// Whether `name` is a video wallpaper's own file an earlier version put here for the saver
    /// (`<wallpaper>_<content>-video-r<revision>.<mp4|m4v|mov>`, a hard link, a copy or a repaired
    /// copy; with `-rec<time>` when it was set as the screen saver), one it was staging
    /// (`.staging-<uuid>.<extension>`), or the manifest that listed them. Nothing else is.
    static func isOldVideoFile(_ name: String) -> Bool {
        name == oldVideoManifest
            || name.range(of: #"^[^/]+-video-r[0-9]+(-rec[0-9]+)?\.(mp4|m4v|mov)$"#, options: .regularExpression) != nil
            || name.range(of: #"^\.staging-[0-9A-Fa-f-]{36}\.(mp4|m4v|mov)$"#, options: .regularExpression) != nil
    }

    /// Deletes the video files earlier versions put directly in `folder` (`isOldVideoFile`): only
    /// regular files and links (a link goes, never what it points to; a hard link's other name, the
    /// library's file, stays), never a folder or anything outside it or not named so. Each deletion
    /// is logged. Returns the names deleted.
    @discardableResult
    static func removeOldVideoFiles(in folder: URL) -> [String] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            // Optional: no folder means nothing to delete.
            return []
        }
        var removed: [String] = []
        for file in files where isOldVideoFile(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) // Optional: unreadable is skipped.
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                removed.append(file.lastPathComponent)
                OWELog.info(.app, "Screen saver: deleted the old video file \(file.lastPathComponent) from \(folder.lastPathComponent)")
            } catch {
                OWELog.error(.app, "Screen saver: can't delete the old video file \(file.lastPathComponent): \(error)")
            }
        }
        return removed
    }

    /// The plugin was turned off: the manifests go, the stills stay (`isStill`), so a
    /// saver shown before the next enable, or right after it, isn't left blank. The folder goes
    /// once nothing is left in it.
    func removeAll() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            // Optional: no folder means nothing to remove.
            return
        }
        for file in files where !Self.isStill(file.lastPathComponent) {
            do { try FileManager.default.removeItem(at: file) } catch {
                OWELog.error(.app, "Screen saver: can't remove \(file.lastPathComponent): \(error)")
            }
        }
        if let left = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)), left.isEmpty { // Optional: gone is fine.
            try? FileManager.default.removeItem(at: directory) // Optional: an empty folder of ours.
        }
    }
}
