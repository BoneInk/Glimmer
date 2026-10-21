import Foundation

/// A display's desktop page, shown by Chromium, that the live screen saver draws from instead of
/// opening a page of its own (`ScreenSaverLiveWeb`): a web wallpaper's model, or a WebM video's
/// player. While held, the page plays, silent, whatever the playback rules (the lock pauses the
/// desktop) and the windows covering it (the screen saver does) say. Registered with the display's
/// `WebPageMirrorRegistry` source.
@MainActor
protocol ScreenSaverPageSharing: AnyObject {
    /// The page, when Chromium shows it (a WebKit page can't be drawn from).
    var sharedPage: ChromiumBrowserPage? { get }
    /// Whether the page shows `wallpaper`.
    func shows(_ wallpaper: WEWallpaper) -> Bool
    func holdForScreenSaver(_ hold: Bool)
}

extension WebWallpaperViewModel: ScreenSaverPageSharing {
    var sharedPage: ChromiumBrowserPage? { page as? ChromiumBrowserPage }

    func shows(_ wallpaper: WEWallpaper) -> Bool {
        WebWallpaperView.pageURL(of: wallpaper) == WebWallpaperView.pageURL(of: currentWallpaper)
    }
}

extension WebKitVideoPlayer: ScreenSaverPageSharing {
    var sharedPage: ChromiumBrowserPage? { page as? ChromiumBrowserPage }

    func shows(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.mediaURL.standardizedFileURL == url.standardizedFileURL
    }
}
