import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    private static let maxRecents = 10
    private static let recentsKey = "RecentWallpapers"

    func stopWallpapers() { isStopped = true }

    /// WE's Play: unpauses, and ends a stop.
    func resumeWallpapers() {
        if playRate == 0 { playRate = lastPlayRate == 0 ? 1 : lastPlayRate }
        isStopped = false
    }

    func loadRecents() {
        guard let data = UserDefaults.app.data(forKey: Self.recentsKey),
              let saved = OWELog.attempt(.library, "Saved recent wallpapers", { try JSONDecoder().decode([WEWallpaper].self, from: data) }) else { return }
        recentWallpapers = saved.filter { $0.project != .invalid }
    }

    func saveRecents() {
        if let data = OWELog.attempt(.library, "Saving recent wallpapers", { try JSONEncoder().encode(recentWallpapers) }) {
            UserDefaults.app.set(data, forKey: Self.recentsKey)
        }
    }

    /// The recent wallpapers whose folder still exists: a deleted one would apply a missing folder.
    func availableRecentWallpapers(folderExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> [WEWallpaper] {
        recentWallpapers.filter { folderExists($0.wallpaperDirectory) }
    }

    func addToRecents(_ wallpaper: WEWallpaper) {
        guard wallpaper.project != .invalid else { return }
        recentWallpapers.removeAll { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }
        recentWallpapers.insert(wallpaper, at: 0)
        if recentWallpapers.count > Self.maxRecents {
            recentWallpapers = Array(recentWallpapers.prefix(Self.maxRecents))
        }
        saveRecents()
    }
}
