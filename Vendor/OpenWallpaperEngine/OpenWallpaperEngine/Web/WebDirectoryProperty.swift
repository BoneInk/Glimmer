import Foundation

/// A web wallpaper's `directory` user property (docs: web/customization/properties): a folder the
/// user picks, whose files the page gets in one of two modes, as WE's web renderer
/// (`webwallpaper64.exe`) hands them out:
/// - `fetchall`: `wallpaperPropertyListener.userDirectoryFilesAddedOrChanged(name, paths)` with
///   every file, then each addition or change, and `userDirectoryFilesRemoved(name, paths)`.
/// - `ondemand`: the page asks `wallpaperRequestRandomFileForProperty(name, callback)` and gets
///   `callback(name, path)` with one file picked at random.
/// Only files of the property's `fileType` count, in the folder and its subfolders (WE watches the
/// folder's whole tree, `FindFirstChangeNotificationW(…, TRUE, …)`).
struct WebDirectoryProperty: Equatable, Sendable {
    enum Mode: String, Sendable {
        case fetchAll = "fetchall"
        case onDemand = "ondemand"
    }

    /// WE's `fileType`: image unless it says video.
    enum FileType: Equatable, Sendable {
        case image, video

        /// WE's lists (`webwallpaper64.exe` 0x14011f1a0 for images; `.webm`, `.ogv` for video).
        var extensions: Set<String> {
            switch self {
            case .image: return [".png", ".apng", ".jpg", ".jpeg", ".bmp", ".gif", ".svg", ".webp"]
            case .video: return [".webm", ".ogv"]
            }
        }

        func matches(_ url: URL) -> Bool {
            let ext = url.pathExtension.lowercased()
            return !ext.isEmpty && extensions.contains("." + ext)
        }
    }

    let key: String
    let mode: Mode
    let fileType: FileType

    /// The directory properties a project.json root declares. One without a valid `mode` is left
    /// out with an error, as WE reports "Web wallpaper property not configured correctly".
    static func declared(projectRoot: [String: Any]) -> [WebDirectoryProperty] {
        let raw = ((projectRoot["general"] as? [String: Any])?["properties"] as? [String: [String: Any]]) ?? [:]
        var result: [WebDirectoryProperty] = []
        for (key, entry) in raw where (entry["type"] as? String)?.lowercased() == "directory" {
            guard let modeName = entry["mode"] as? String, let mode = Mode(rawValue: modeName.lowercased()) else {
                OWELog.error(.web, "Web wallpaper property \(key) not configured correctly: directory without a fetchall or ondemand mode")
                continue
            }
            let fileType: FileType = (entry["fileType"] as? String)?.lowercased() == "video" ? .video : .image
            result.append(WebDirectoryProperty(key: key, mode: mode, fileType: fileType))
        }
        return result.sorted { $0.key < $1.key }
    }

    /// The matching regular files under `folder` (subfolders included, hidden items skipped),
    /// with their modification dates, keyed by path.
    static func files(in folder: URL, type: FileType) -> [String: Date] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                OWELog.debug(.web, "Directory property can't read \(url.lastPathComponent): \(error)")
                return true
            }) else { return [:] }
        var files: [String: Date] = [:]
        for case let url as URL in enumerator where type.matches(url) {
            // A file that vanished while listing is simply not there.
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files[url.standardizedFileURL.path(percentEncoded: false)] = values.contentModificationDate ?? .distantPast
        }
        return files
    }

    /// A path as the page gets it: without the leading slash, so `'file:///' + path` (WE's
    /// documented use, its paths being `C:/…`) is a well-formed file URL.
    static func pagePath(_ path: String) -> String {
        String(path.drop(while: { $0 == "/" }))
    }

    /// What changed between the files a page has and the files on disk: paths added or modified,
    /// and paths gone, each sorted.
    static func changes(from sent: [String: Date], to current: [String: Date]) -> (changed: [String], removed: [String]) {
        let changed = current.filter { sent[$0.key] != $0.value }.keys.sorted()
        let removed = sent.keys.filter { current[$0] == nil }.sorted()
        return (changed, removed)
    }
}

extension WebDirectoryProperty {
    static func declared(wallpaperDirectory: URL) -> [WebDirectoryProperty] {
        // A wallpaper without a readable project.json has no properties (its load reports why).
        guard let root = try? WEProject.json(in: wallpaperDirectory) else { return [] }
        return declared(projectRoot: root)
    }
}
