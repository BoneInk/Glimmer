import Foundation
import OWEControlProtocol

/// A playlist's Playlist Settings as `playlist_update` reads and changes them: when it changes
/// wallpaper, the timer's options, the items' time-of-day ends and the transition.
struct ControlPlaylistSettings: Equatable {
    var timing: PlaylistTiming = .timer
    var changesWhilePaused = false
    var beginsWithFirst = false
    var playsFirstAtStartupOnly = false
    var transition = WallpaperTransitionSettings.playlistDefault
    /// Each item's time-of-day end, in the playlist's order.
    var daytimeEnds: [Double?] = []

    init() {}

    init(_ playlist: WallpaperPlaylist) {
        timing = playlist.timing
        changesWhilePaused = playlist.changesWhilePaused
        beginsWithFirst = playlist.beginsWithFirst
        playsFirstAtStartupOnly = playlist.playsFirstAtStartupOnly
        transition = playlist.transition
        daytimeEnds = playlist.daytimeEnds
    }

    /// Writes them into `playlist`; ends beyond its items are ignored.
    func apply(to playlist: inout WallpaperPlaylist) {
        playlist.timing = timing
        playlist.changesWhilePaused = changesWhilePaused
        playlist.beginsWithFirst = beginsWithFirst
        playlist.playsFirstAtStartupOnly = playsFirstAtStartupOnly
        playlist.transition = transition
        for index in playlist.items.indices {
            playlist.items[index].daytimeEnd = index < daytimeEnds.count ? daytimeEnds[index] : nil
        }
    }

    // MARK: - The control channel's names

    static func timing(named name: String) -> PlaylistTiming? { PlaylistTiming(rawValue: name) }

    static func name(of kind: WallpaperTransitionKind) -> String {
        ControlPlaylistOptions.transitionKinds[kind.rawValue]
    }

    static func kind(named name: String) -> WallpaperTransitionKind? {
        ControlPlaylistOptions.transitionKinds.firstIndex(of: name).flatMap(WallpaperTransitionKind.init(rawValue:))
    }

    static func name(of choice: WallpaperTransitionSettings.Choice) -> String {
        switch choice {
        case .noneReducingFlicker: return "none_reduce_flicker"
        case .none: return "none"
        case .random: return "random"
        case .kind(let kind): return name(of: kind)
        }
    }

    static func choice(named name: String) -> WallpaperTransitionSettings.Choice? {
        switch name {
        case "none_reduce_flicker": return .noneReducingFlicker
        // Spelled out: a bare `.none` is the Optional's.
        case "none": return WallpaperTransitionSettings.Choice.none
        case "random": return .random
        default: return kind(named: name).map { .kind($0) }
        }
    }

    /// "HH:MM" (24-hour) as a fraction of the day; nil when it isn't one.
    static func dayFraction(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...24).contains(hours), (0..<60).contains(minutes), hours * 60 + minutes <= 1440 else { return nil }
        return Double(hours * 60 + minutes) / 1440
    }

    /// A fraction of the day as "HH:MM"; midnight at the end is "24:00".
    static func clock(_ fraction: Double) -> String {
        let minutes = Int((min(max(fraction, 0), 1) * 1440).rounded())
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// The settings as `playlist_update` returns them, with each item's slot for the scheduled
    /// timings.
    func json(itemCount: Int, calendar: Calendar) -> [String: JSONValue] {
        var result: [String: JSONValue] = [
            "change_wallpaper": .string(timing.rawValue),
            "change_while_paused": .bool(changesWhilePaused),
            "begin_with_first_wallpaper": .bool(beginsWithFirst),
            "first_wallpaper_at_startup_only": .bool(playsFirstAtStartupOnly),
            "transition": .string(Self.name(of: transition.choice)),
            "transition_pool": .array(transition.poolKinds.map { .string(Self.name(of: $0)) }),
            "transition_time_ms": .number(Double(transition.milliseconds)),
        ]
        switch timing {
        case .daytime:
            result["daytime_slots"] = .array(PlaylistSchedule.daySlots(ends: daytimeEnds).map {
                ["start": .string(Self.clock($0.start)), "end": .string(Self.clock($0.end))]
            })
        case .dayofweek:
            var english = Calendar(identifier: .gregorian)
            english.locale = Locale(identifier: "en_US_POSIX")
            let names = english.standaloneWeekdaySymbols
            result["weekdays"] = .array((0..<min(itemCount, PlaylistTiming.maxDayOfWeekItems)).map { item in
                .array(PlaylistSchedule.weekdays(of: item, itemCount: itemCount, calendar: calendar).map {
                    .string(names[($0 + 1) % 7])
                })
            })
        case .logon, .timer, .never:
            break
        }
        return result
    }
}
