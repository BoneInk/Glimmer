import Foundation

/// Settings › Assets › Library Folders: folders besides the Wallpaper Storage folder whose
/// wallpapers the Installed tab lists, each one a folder of wallpaper folders like the storage
/// folder (a Wallpaper Engine `projects/myprojects` or Workshop `content/431960` folder, say).
///
/// They are read only: downloads, imports and dependencies still go into the storage folder, and
/// nothing is moved into or out of them. The app isn't sandboxed, so a folder is kept by its path.
struct LibraryFolders {
    static let defaultsKey = "LibraryFolders"

    enum AddFailure: LocalizedError, Equatable {
        /// The folder is the Wallpaper Storage folder, which is always listed.
        case isStorage
        case alreadyAdded

        var errorDescription: String? {
            switch self {
            case .isStorage:
                return String(localized: "This is the Wallpaper Storage folder, which is always in the library.")
            case .alreadyAdded:
                return String(localized: "This folder is already in the library.")
            }
        }
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
    }

    /// The added folders, in the order they were added.
    var folders: [URL] {
        (defaults.stringArray(forKey: Self.defaultsKey) ?? []).filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Adds `folder`; throws when it is the storage folder or already added.
    func add(_ folder: URL, storage: URL = WallpaperStorage.directory) throws {
        let folder = folder.standardizedFileURL
        guard Self.path(of: folder) != Self.path(of: storage.standardizedFileURL) else { throw AddFailure.isStorage }
        var paths = folders.map(Self.path)
        guard !paths.contains(Self.path(of: folder)) else { throw AddFailure.alreadyAdded }
        paths.append(Self.path(of: folder))
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    func remove(_ folder: URL) {
        let removed = Self.path(of: folder.standardizedFileURL)
        defaults.set(folders.map(Self.path).filter { $0 != removed }, forKey: Self.defaultsKey)
    }

    /// The added folder `wallpaperDirectory` sits in; nil for the storage folder's wallpapers.
    func folder(containing wallpaperDirectory: URL) -> URL? {
        let parent = Self.path(of: wallpaperDirectory.standardizedFileURL.deletingLastPathComponent())
        return folders.first { Self.path(of: $0) == parent }
    }

    /// A folder's path without a trailing slash, so `/a/b/` and `/a/b` compare equal.
    private static func path(of folder: URL) -> String {
        let path = folder.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
