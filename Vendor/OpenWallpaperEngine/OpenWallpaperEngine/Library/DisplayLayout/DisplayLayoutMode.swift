import Foundation

/// How wallpapers spread over the displays: WE's `wallpaperconfig.layout` (its values, so a
/// layout reads the same in both): a wallpaper per display, one wallpaper stretched over all of
/// them, or one wallpaper cloned onto each (docs/architecture.md "Display layouts").
enum DisplayLayoutMode: Int, Codable, CaseIterable, Hashable {
    /// "Wallpaper per display": each display shows its own; clone and stretch groups of some
    /// displays may sit beside them (`DisplayGroup`).
    case perDisplay = 0
    /// "Stretch single wallpaper": one wallpaper spans the bounding box of the displays.
    case stretch = 1
    /// "Clone single wallpaper": every display shows the main clone display's wallpaper.
    case clone = 2
}
