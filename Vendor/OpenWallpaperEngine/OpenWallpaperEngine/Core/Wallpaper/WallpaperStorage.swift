import Foundation

enum WallpaperStorage {
    private static let customPathKey = "CustomWallpapersDirectory"

    static var defaultDirectory: URL {
        if let context = SceneBackendRuntimeContext.current { return context.roots.cacheRoot.appending(path: "storage", directoryHint: .isDirectory) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Open Wallpaper Engine")
    }

    static var directory: URL {
        if let customPath = UserDefaults.app.string(forKey: customPathKey), !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        return defaultDirectory
    }

    static var usesCustomDirectory: Bool {
        UserDefaults.app.string(forKey: customPathKey) != nil
    }

    /// The storage folder can't be used: it is on a volume that isn't connected, or can't be created.
    enum Unavailable: LocalizedError {
        case volumeNotMounted(directory: URL, volume: URL)
        case notCreatable(directory: URL, reason: String)

        var errorDescription: String? {
            switch self {
            case .volumeNotMounted(let directory, let volume):
                return String(localized: "The Wallpaper Storage folder \(directory.path) is on \(volume.lastPathComponent), which isn't connected. Connect it, or choose another folder in Settings → General.",
                              comment: "The first %@ is a folder path, the second a disk name")
            case .notCreatable(let directory, let reason):
                return String(localized: "Can't create the Wallpaper Storage folder \(directory.path): \(reason)",
                              comment: "The first %@ is a folder path, the second the system's reason")
            }
        }
    }

    /// The `/Volumes/<name>` a folder lives on when that volume isn't mounted; nil otherwise.
    /// Creating the folder then would put it on the startup disk instead, under a stale mount point.
    static func unmountedVolume(of directory: URL, fileManager: FileManager = .default) -> URL? {
        let components = directory.standardizedFileURL.pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        let volume = URL(fileURLWithPath: "/Volumes", isDirectory: true).appending(path: components[2], directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: volume.path) else { return volume }
        let resolved = volume.resolvingSymlinksInPath()
        // `/Volumes/Macintosh HD` links to `/`, which is a volume too.
        do {
            return try resolved.resourceValues(forKeys: [.isVolumeKey]).isVolume == true ? nil : volume
        } catch {
            OWELog.error(.library, "Can't tell whether \(volume.path) is mounted: \(error)")
            return volume
        }
    }

    /// The storage folder, created when it is missing. Throws instead of falling back to another
    /// place, so nothing is ever downloaded anywhere but the folder the user chose.
    static func availableDirectory(_ directory: URL = directory, fileManager: FileManager = .default) throws -> URL {
        if let volume = unmountedVolume(of: directory, fileManager: fileManager) {
            throw Unavailable.volumeNotMounted(directory: directory, volume: volume)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Unavailable.notCreatable(directory: directory, reason: error.localizedDescription)
        }
        return directory
    }

    static func setDirectory(_ newDirectory: URL, moveExisting: Bool) throws -> (source: URL, destination: URL)? {
        let fileManager = FileManager.default
        let sourceDirectory = directory.standardizedFileURL
        let destinationDirectory = newDirectory.standardizedFileURL
        guard sourceDirectory != destinationDirectory else { return nil }

        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        if moveExisting, fileManager.fileExists(atPath: sourceDirectory.path) {
            let moved = try moveContents(from: sourceDirectory, to: destinationDirectory, fileManager: fileManager)
            // Merged rather than moved when the destination has one; it lists which of the moved
            // items are dependencies.
            try WorkshopDependencyIndex.carry(from: sourceDirectory, to: destinationDirectory, movedItems: moved)
        }
        UserDefaults.app.set(destinationDirectory.path, forKey: customPathKey)
        return moveExisting ? (sourceDirectory, destinationDirectory) : nil
    }

    /// Whether a storage item moves with the folder: the wallpapers, and the app's own hidden data
    /// (`.owe-*`: the assets cache with its info file, SteamCMD's staging, converted packages).
    /// Other hidden files (`.DS_Store`, `._*`, `.Trashes`…) belong to the old folder, the dependency
    /// index is merged by `WorkshopDependencyIndex.carry`, and half-finished work (a download
    /// being unpacked, a staging copy) is left behind: it is rebuilt when needed.
    static func movesWithStorage(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return true }
        guard name.hasPrefix(".owe") else { return false }
        if name == WorkshopDependencyIndex.fileName { return false }
        if name == WallpaperEngineAssetsDownload.downloadFolderName { return false }
        return !name.hasPrefix(".owe-incoming-") && !name.hasSuffix(".partial")
    }

    /// Moves what `movesWithStorage` keeps from `source` into `destination`, never over an item of
    /// the same name. Returns the names moved.
    @discardableResult
    static func moveContents(from source: URL, to destination: URL,
                             fileManager: FileManager = .default) throws -> Set<String> {
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        var moved = Set<String>()
        for item in items where movesWithStorage(item.lastPathComponent) {
            let target = destination.appending(path: item.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try fileManager.moveItem(at: item, to: target)
            moved.insert(item.lastPathComponent)
        }
        return moved
    }

    /// Goes back to the default folder. Returns whether the folder changed, so the caller
    /// refreshes the library and its index as after choosing a folder.
    @discardableResult
    static func resetToDefault(defaults: UserDefaults = .app) -> Bool {
        let before = folder(defaults: defaults)
        defaults.removeObject(forKey: customPathKey)
        return folder(defaults: defaults) != before
    }

    /// The storage folder `defaults` names.
    static func folder(defaults: UserDefaults) -> URL {
        if let customPath = defaults.string(forKey: customPathKey), !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true).standardizedFileURL
        }
        return defaultDirectory.standardizedFileURL
    }
}
