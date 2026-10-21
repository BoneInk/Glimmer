import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    func saveWallpapers() {
        do {
            UserDefaults.app.set(try JSONEncoder().encode(wallpapers), forKey: "ScreenWallpapers")
        } catch {
            OWELog.error(.library, "Saving the displays' wallpapers failed: \(error)")
        }
    }
}
