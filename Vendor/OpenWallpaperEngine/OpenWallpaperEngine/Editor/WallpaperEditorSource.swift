import Foundation

/// The wallpaper's scene.json as it ships: from its `.pkg` when it has one (which the loader
/// prefers), else the loose file.
enum WallpaperEditorSource {
    struct Read {
        let scene: Data
        let package: PKGParser?
        let packageName: String?
    }

    static func read(_ wallpaper: WEWallpaper) throws -> Read {
        let directory = wallpaper.wallpaperDirectory
        let file = wallpaper.project.file
        let packageName = (file as NSString).deletingPathExtension + ".pkg"
        let packageURL = directory.appending(path: packageName)
        if FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) {
            let package = try PKGParser(url: packageURL)
            if let scene = package.extractFile(named: file) {
                return Read(scene: scene, package: package, packageName: packageName)
            }
        }
        guard let scene = try AssetPathResolver.data(file, in: directory) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.appending(path: file).path])
        }
        return Read(scene: scene, package: nil, packageName: nil)
    }
}
