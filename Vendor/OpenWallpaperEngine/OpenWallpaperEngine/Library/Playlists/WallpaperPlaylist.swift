import SwiftUI
import AVKit

struct WallpaperPlaylistItem: Codable, Identifiable, Equatable {
    let id: UUID
    var wallpaper: WEWallpaper
    var duration: TimeInterval
    /// Where the item's slot of the day ends in a "Time of day" playlist, as a fraction of the day
    /// (WE's `daytimeend`); nil: it shares the time up to the next end (`PlaylistSchedule`).
    var daytimeEnd: Double?

    init(wallpaper: WEWallpaper, duration: TimeInterval = 300) {
        self.id = UUID()
        self.wallpaper = wallpaper
        self.duration = max(duration, 1)
    }

    static func == (lhs: WallpaperPlaylistItem, rhs: WallpaperPlaylistItem) -> Bool {
        lhs.id == rhs.id && lhs.wallpaper.wallpaperDirectory == rhs.wallpaper.wallpaperDirectory
            && lhs.duration == rhs.duration && lhs.daytimeEnd == rhs.daytimeEnd
    }
}

struct WallpaperPlaylist: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var items: [WallpaperPlaylistItem]
    var duration: TimeInterval
    var changeWhenVideoEnds: Bool
    /// When the playlist changes wallpaper (WE's "Change wallpaper", `mode`).
    var timing: PlaylistTiming
    /// "Always begin with the first wallpaper" (WE's `beginfirst`): on a timer, the playlist starts
    /// at its first item when the app starts or the playlist is started, not where it left off.
    var beginsWithFirst: Bool
    /// "First wallpaper played at startup only" (WE's `playintro`): with `beginsWithFirst`, the
    /// first item plays when the playlist starts and the rotation leaves it out after.
    var playsFirstAtStartupOnly: Bool
    /// "Allow wallpaper to change while paused" (WE's `updateonpause`): on a timer, the time runs
    /// on while the wallpaper is paused; otherwise it stops until the wallpaper plays again.
    var changesWhilePaused: Bool
    /// The transition between its wallpapers (WE's `transition`, `transitionpool`, `transitiontime`).
    var transition: WallpaperTransitionSettings
    /// The system-wide shortcut that starts this playlist (`PlaylistShortcutController`).
    var shortcut: GlobalShortcut?
    /// The displays the playlist last showed its wallpapers on, so its shortcut starts it there.
    var displays: [String]?

    init(name: String, items: [WallpaperPlaylistItem] = [], duration: TimeInterval = 300,
         changeWhenVideoEnds: Bool = false, shortcut: GlobalShortcut? = nil) {
        self.id = UUID()
        self.name = name
        self.items = items
        self.duration = max(duration, 1)
        self.changeWhenVideoEnds = changeWhenVideoEnds
        self.timing = .timer
        self.beginsWithFirst = false
        self.playsFirstAtStartupOnly = false
        self.changesWhilePaused = false
        self.transition = .playlistDefault
        self.shortcut = shortcut
    }

    /// The item ends a "Time of day" playlist schedules with.
    var daytimeEnds: [Double?] { items.map(\.daytimeEnd) }

    /// The item `timing` shows at `date` (Time of day, Day of week); nil for the other timings.
    func scheduledIndex(at date: Date, calendar: Calendar) -> Int? {
        PlaylistSchedule.item(for: timing, at: date, ends: daytimeEnds, calendar: calendar)
    }

    /// Whether the first item is left out of the rotation: it played at startup only.
    var leavesOutFirstItem: Bool {
        timing.usesTimerOptions && beginsWithFirst && playsFirstAtStartupOnly && items.count > 1
    }

    /// Keeps the settings as WE's dialog saves them: the ends only in a "Time of day" playlist and
    /// in order (`PlaylistSchedule.normalizedDayEnds`), and the intro only with
    /// "Always begin with the first wallpaper".
    mutating func normalizeSettings() {
        let ends = timing == .daytime ? PlaylistSchedule.normalizedDayEnds(daytimeEnds) : items.map { _ in nil }
        for index in items.indices { items[index].daytimeEnd = ends[index] }
        if !beginsWithFirst { playsFirstAtStartupOnly = false }
    }

    /// The item auto-advance moves to after `current`, passing over any `isSkipped` item. Nil
    /// when the end is reached without `repeats`, or when every item is skipped. Shuffle never
    /// picks `current` again while another item can play.
    func nextIndex(after current: Int, shuffle: Bool, repeats: Bool, isSkipped: (Int) -> Bool,
                   random: (Range<Int>) -> Int = { Int.random(in: $0) }) -> Int? {
        guard !items.isEmpty else { return nil }
        if shuffle {
            let playable = items.indices.filter { !isSkipped($0) }
            let others = playable.filter { $0 != current }
            let pool = others.isEmpty ? playable : others
            guard !pool.isEmpty else { return nil }
            return pool[random(0..<pool.count)]
        }
        var index = current
        for _ in 0..<items.count {
            index += 1
            if index >= items.count {
                guard repeats else { return nil }
                index = 0
            }
            if !isSkipped(index) { return index }
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, items, duration, changeWhenVideoEnds, shortcut, displays
        case timing = "mode"
        case beginsWithFirst = "beginfirst"
        case playsFirstAtStartupOnly = "playintro"
        case changesWhilePaused = "updateonpause"
        case transition
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([WallpaperPlaylistItem].self, forKey: .items)
        duration = max(try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
            ?? items.first?.duration ?? 300, 1)
        changeWhenVideoEnds = try container.decodeIfPresent(Bool.self, forKey: .changeWhenVideoEnds) ?? false
        shortcut = try? container.decodeIfPresent(GlobalShortcut.self, forKey: .shortcut)
        displays = try container.decodeIfPresent([String].self, forKey: .displays)
        // A mode this version doesn't know runs on a timer rather than dropping the playlist.
        timing = try container.decodeIfPresent(String.self, forKey: .timing).flatMap(PlaylistTiming.init(rawValue:)) ?? .timer
        beginsWithFirst = try container.decodeIfPresent(Bool.self, forKey: .beginsWithFirst) ?? false
        playsFirstAtStartupOnly = try container.decodeIfPresent(Bool.self, forKey: .playsFirstAtStartupOnly) ?? false
        changesWhilePaused = try container.decodeIfPresent(Bool.self, forKey: .changesWhilePaused) ?? false
        // Saved before transitions: none, as WE shows a playlist without the setting.
        transition = try container.decodeIfPresent(WallpaperTransitionSettings.self, forKey: .transition) ?? .unset
    }
}
