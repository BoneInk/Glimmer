import Foundation

/// When the Installed, Discover and Workshop menus' "Set as Wallpaper" and "Set as Screen Saver"
/// can apply an item. Application wallpapers don't run on macOS; the screen saver takes scenes,
/// videos and web wallpapers (`ScreenSaverSelectionService.canSet`: a web page or WebM video
/// without the Chromium engine offers its install when chosen). A Workshop item
/// isn't downloaded yet, so its type is its Steam type tag; an item without one (a preset) is
/// checked once it is downloaded.
enum WallpaperSetAsRules {
    static func canSetWallpaper(_ wallpaper: WEWallpaper) -> Bool {
        wallpaper.project != .invalid && !isApplication(wallpaper.project.type)
    }

    static func canSetScreenSaver(_ wallpaper: WEWallpaper) -> Bool {
        ScreenSaverSelectionService.canSet(wallpaper)
    }

    static func canSetWallpaper(_ item: WorkshopItem) -> Bool {
        !(wallpaperType(of: item).map(isApplication) ?? false)
    }

    static func canSetScreenSaver(_ item: WorkshopItem) -> Bool {
        guard let type = wallpaperType(of: item) else { return true }
        return ["scene", "video", "web"].contains(type.lowercased())
    }

    /// The item's wallpaper type tag (`WorkshopTags.types`: Scene, Video, Web, Application).
    static func wallpaperType(of item: WorkshopItem) -> String? {
        item.tags.first { tag in WorkshopTags.types.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    private static func isApplication(_ type: String) -> Bool {
        type.caseInsensitiveCompare("application") == .orderedSame
    }
}
