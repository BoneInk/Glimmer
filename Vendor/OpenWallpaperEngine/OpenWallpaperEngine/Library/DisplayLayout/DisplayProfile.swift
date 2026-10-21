import Foundation

/// A named display setup, WE's "Save Profile": a copy of `wallpaperconfig`, the layout with its
/// groups, clone source, flips, mutes and splits, and each display's and region's wallpaper.
/// Selections are keyed by location (a display's identity, or a region's, `<identity>/L`…), so a
/// profile finds its displays again whatever ids they have now.
struct DisplayProfile: Codable, Equatable {
    var name: String
    var layout: DisplayLayoutConfiguration
    var selections: [String: WEWallpaper]

    init(name: String, layout: DisplayLayoutConfiguration, selections: [String: WEWallpaper] = [:]) {
        self.name = name
        self.layout = layout
        self.selections = selections
    }

    /// The selections of `wallpapers` (keyed by display or region id) on the `connected` displays,
    /// by location; a key of a display that isn't connected (or a preview's) has none and is left out.
    static func selections(of wallpapers: [String: WEWallpaper],
                           connected: [DisplayIdentity]) -> [String: WEWallpaper] {
        var selections: [String: WEWallpaper] = [:]
        for (id, wallpaper) in wallpapers {
            let screen = DisplayLayoutResolution.screen(of: id)
            guard let display = connected.first(where: { $0.screenId == screen }) else { continue }
            selections[display.identity + id.dropFirst(screen.count)] = wallpaper
        }
        return selections
    }

    /// The selections by display or region id on the `connected` displays; locations of displays
    /// that aren't connected are skipped.
    func wallpapers(on connected: [DisplayIdentity]) -> [String: WEWallpaper] {
        var wallpapers: [String: WEWallpaper] = [:]
        for (location, wallpaper) in selections {
            let identity = DisplayLayoutConfiguration.display(of: location)
            guard let display = connected.first(where: { $0.identity == identity }) else {
                OWELog.info(.app, "Display profile \"\(name)\": \(location) isn't connected, skipped")
                continue
            }
            wallpapers[display.screenId + location.dropFirst(identity.count)] = wallpaper
        }
        return wallpapers
    }

    static func == (lhs: DisplayProfile, rhs: DisplayProfile) -> Bool {
        guard lhs.name == rhs.name, lhs.layout == rhs.layout,
              Set(lhs.selections.keys) == Set(rhs.selections.keys) else { return false }
        return lhs.selections.allSatisfy { location, wallpaper in
            guard let other = rhs.selections[location] else { return false }
            return wallpaper.wallpaperDirectory == other.wallpaperDirectory
                && wallpaper.presetDirectory == other.presetDirectory && wallpaper.project == other.project
        }
    }

    private enum CodingKeys: String, CodingKey { case name, layout, selections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        layout = try container.decodeIfPresent(DisplayLayoutConfiguration.self, forKey: .layout)
            ?? DisplayLayoutConfiguration()
        // Selection by selection, so one that can't be read doesn't drop the others.
        selections = container.decodeEntries(WEWallpaper.self, forKey: .selections, userInfo: decoder.userInfo) ?? [:]
    }
}
