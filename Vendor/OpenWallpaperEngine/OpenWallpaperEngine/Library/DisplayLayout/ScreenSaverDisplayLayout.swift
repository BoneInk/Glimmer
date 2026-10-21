import Foundation

/// How the screen saver spreads over the displays: WE's `wallpaperconfigscreensaver =
/// {layout, sameaswallpaper}`, saved in the app's defaults. "Same as wallpaper" (the default)
/// follows the wallpapers' layout; otherwise the screen saver has its own: a loop per display,
/// one loop stretched over the displays, or one cloned onto each.
struct ScreenSaverDisplayLayout: Codable, Equatable {
    static let defaultsKey = "ScreenSaverDisplayLayout"

    var sameAsWallpaper = true
    /// The screen saver's own layout, used while `sameAsWallpaper` is off.
    var layout: DisplayLayoutMode = .perDisplay

    /// The layout the screen saver uses with the wallpapers' `wallpaperLayout`.
    func effectiveLayout(wallpaperLayout: DisplayLayoutMode) -> DisplayLayoutMode {
        sameAsWallpaper ? wallpaperLayout : layout
    }

    private enum CodingKeys: String, CodingKey {
        case sameAsWallpaper = "sameaswallpaper"
        case layout
    }

    init(sameAsWallpaper: Bool = true, layout: DisplayLayoutMode = .perDisplay) {
        self.sameAsWallpaper = sameAsWallpaper
        self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sameAsWallpaper = try container.decodeIfPresent(Bool.self, forKey: .sameAsWallpaper) ?? true
        layout = try container.decodeIfPresent(DisplayLayoutMode.self, forKey: .layout) ?? .perDisplay
    }

    static func load(from defaults: UserDefaults) -> ScreenSaverDisplayLayout {
        guard let data = defaults.data(forKey: defaultsKey) else { return ScreenSaverDisplayLayout() }
        do {
            return try JSONDecoder().decode(ScreenSaverDisplayLayout.self, from: data)
        } catch {
            OWELog.error(.app, "Screen saver layout unreadable, using the wallpapers' layout: \(error)")
            return ScreenSaverDisplayLayout()
        }
    }

    func save(to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.app, "Screen saver layout not saved: \(error)")
        }
    }
}
