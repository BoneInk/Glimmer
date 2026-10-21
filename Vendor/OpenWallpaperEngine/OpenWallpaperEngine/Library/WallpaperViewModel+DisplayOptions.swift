import SwiftUI
import AVKit
import Combine

extension WallpaperViewModel {
    /// The display options of the wallpaper on `screenId` there.
    func displayOptions(on screenId: String) -> WallpaperDisplayOptions {
        displayOptions.options(for: wallpaper(for: screenId), on: screenId)
    }

    /// Sets `wallpaper`'s display options on `screenIds`.
    func setDisplayOptions(_ options: WallpaperDisplayOptions, for wallpaper: WEWallpaper, on screenIds: Set<String>) {
        displayOptions.set(options, for: wallpaper, on: screenIds)
    }

    /// The playback rate (`WallpaperDisplayOptions.playbackRate`) a video running once for every
    /// display showing it plays at: its rate on the main display when that shows it, else on the
    /// display with the lowest id that does; 1 when no display shows it.
    func displayPlaybackRate(of wallpaper: WEWallpaper) -> Float {
        let directory = wallpaper.wallpaperDirectory.standardizedFileURL
        let screens = wallpapers.filter { $0.value.wallpaperDirectory.standardizedFileURL == directory }.keys
        let main = NSScreen.main.map(Self.screenId(for:))
        guard let screen = screens.first(where: { $0 == main }) ?? screens.sorted().first else { return 1 }
        return Float(displayOptions.options(for: wallpaper, on: screen).playbackRate)
    }
}
