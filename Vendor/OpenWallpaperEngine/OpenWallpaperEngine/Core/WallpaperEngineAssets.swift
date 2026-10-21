import Foundation

/// Resolves the Wallpaper Engine asset tree used for effects, shared materials and the SceneScript
/// runtime. The app ships none of it: the files come from the user's own Wallpaper Engine copy,
/// looked up in this order:
///
/// 1. the `assets` folder of a Wallpaper Engine install the user chose in Settings › Assets;
/// 2. the copy the app keeps in the Wallpaper Storage folder (`<storage>/.owe-assets`), filled
///    from the user's Steam copy (`WallpaperEngineAssetsInstaller`);
/// 3. none: scenes then show that they need the assets, while video and web wallpapers still play.
///
/// Under XCTest only `OWE_ASSETS` counts, so a test run never picks up a developer's own cache.
enum WallpaperEngineAssets {
    enum Source: Equatable {
        /// A Wallpaper Engine install (or its `assets` folder) the user chose.
        case chosenFolder
        /// The copy in the Wallpaper Storage folder.
        case cache
        /// `OWE_ASSETS`, under XCTest.
        case testEnvironment
    }

    struct Resolution: Equatable {
        let directory: URL
        let source: Source
    }

    /// The defaults key of the chosen install; a path, or absent.
    static let chosenFolderKey = "WallpaperEngineAssetsDirectory"
    /// The cache's folder inside the Wallpaper Storage folder. Hidden, so the library ignores it.
    static let cacheFolderName = ".owe-assets"
    /// The environment variable naming an assets folder (or a WE install) for tests.
    static let testEnvironmentKey = "OWE_ASSETS"

    static func cacheDirectory(in storage: URL) -> URL {
        storage.appending(path: cacheFolderName, directoryHint: .isDirectory)
    }

    /// The asset tree of `folder`: a WE install's `assets` child when it has one, else the folder
    /// itself (an `assets` folder, or a copy such as the cache).
    static func assetsFolder(of folder: URL, fileManager: FileManager = .default) -> URL {
        let root = folder.standardizedFileURL
        guard root.lastPathComponent.caseInsensitiveCompare("assets") != .orderedSame else { return root }
        let child = root.appending(path: "assets", directoryHint: .isDirectory)
        return fileManager.fileExists(atPath: child.path) ? child : root
    }

    /// Whether `directory` holds an asset tree: the shared shaders and the built-in effects.
    static func isAssetTree(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: directory.appending(path: "shaders").path)
            && fileManager.fileExists(atPath: directory.appending(path: "effects").path)
    }

    /// The asset tree to use, by the order above. Pure apart from the file checks, for tests.
    static func resolve(chosenPath: String?, storage: URL?, testOverride: String?, isTesting: Bool,
                        fileManager: FileManager = .default) -> Resolution? {
        if isTesting {
            guard let testOverride, !testOverride.isEmpty else { return nil }
            let folder = assetsFolder(of: URL(fileURLWithPath: testOverride, isDirectory: true), fileManager: fileManager)
            return isAssetTree(folder, fileManager: fileManager) ? Resolution(directory: folder, source: .testEnvironment) : nil
        }
        if let chosenPath, !chosenPath.isEmpty {
            let folder = assetsFolder(of: URL(fileURLWithPath: chosenPath, isDirectory: true), fileManager: fileManager)
            if isAssetTree(folder, fileManager: fileManager) { return Resolution(directory: folder, source: .chosenFolder) }
        }
        if let storage {
            let cache = cacheDirectory(in: storage).standardizedFileURL
            if isAssetTree(cache, fileManager: fileManager) { return Resolution(directory: cache, source: .cache) }
        }
        return nil
    }

    static var isTesting: Bool { NSClassFromString("XCTestCase") != nil }

    /// The asset tree in use now, if any.
    static var current: Resolution? {
        if let context = SceneBackendRuntimeContext.current { return Resolution(directory: context.roots.assetsRoot, source: .chosenFolder) }
        return resolve(chosenPath: UserDefaults.app.string(forKey: chosenFolderKey),
                storage: WallpaperStorage.directory,
                testOverride: ProcessInfo.processInfo.environment[testEnvironmentKey],
                isTesting: isTesting)
    }

    static var directory: URL? {
        current?.directory
    }

    /// Where shared assets are looked up, in order.
    static var searchDirectories: [URL] {
        directory.map { [$0] } ?? []
    }

    /// The first of `relativePaths` that is a usable file inside its directory
    /// (`AssetPathResolver`), trying every path in each directory before the next.
    static func locate(_ relativePaths: [String], in directories: [URL]) -> URL? {
        for directory in directories {
            for path in relativePaths {
                if let candidate = AssetPathResolver.fileURL(path, in: directory) { return candidate }
            }
        }
        return nil
    }
}
