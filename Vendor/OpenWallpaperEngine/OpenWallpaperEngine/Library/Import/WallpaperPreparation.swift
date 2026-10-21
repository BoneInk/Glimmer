import Foundation

/// The work done once for a wallpaper that joins the library (an import, a download, a kept
/// preview), so the first play doesn't have to: a scene's `.pkg` is converted to loose files, and
/// a video AVFoundation refuses as it is gets its repaired copy (`RepairedVideoCache`).
/// Reads and writes files: call it off the main thread.
enum WallpaperPreparation {
    static func prepare(wallpaperDirectory: URL) {
        WallpaperPackageConverter.convertIfNeeded(wallpaperDirectory: wallpaperDirectory)
        prepareVideo(wallpaperDirectory: wallpaperDirectory)
    }

    /// Makes the repaired copy of a local video wallpaper's file when it needs one.
    static func prepareVideo(wallpaperDirectory: URL) {
        let projectURL = WEProject.url(in: wallpaperDirectory)
        let project: WEProject
        do {
            project = try WEProject.read(in: wallpaperDirectory)
        } catch {
            OWELog.error(.importer, "Can't read \(projectURL.path(percentEncoded: false)) to prepare it: \(error)")
            return
        }
        guard project.type.lowercased() == "video" else { return }
        let wallpaper = WEWallpaper(using: project, where: wallpaperDirectory)
        guard !wallpaper.isRemoteMedia else { return }
        _ = RepairedVideoCache.current.playableURL(for: wallpaper.mediaURL)
    }
}
