import Foundation

/// When a playlist changes wallpaper: WE's "Change wallpaper" setting (`settings.mode`), stored
/// under WE's values.
enum PlaylistTiming: String, CaseIterable, Codable, Identifiable, Sendable {
    /// "When logging in": one step each time the app starts (it starts at login).
    case logon
    /// "On a timer": every `duration`, or when a video ends with "Change wallpaper when a video ends".
    case timer
    /// "Time of day": each item has a slot of the day (`daytimeend`), and the playlist shows the
    /// item whose slot it is.
    case daytime
    /// "Day of week": up to seven items share the week, the playlist shows today's.
    case dayofweek
    /// "Never": only Next and Previous change it.
    case never

    var id: String { rawValue }

    /// The order WE's dialog lists them in.
    static let menuOrder: [PlaylistTiming] = [.logon, .timer, .daytime, .dayofweek, .never]

    var title: LocalizedStringResource {
        switch self {
        case .logon: return LocalizedStringResource("When logging in", comment: "Playlist: change wallpaper when the user logs in")
        case .timer: return LocalizedStringResource("On a timer", comment: "Playlist: change wallpaper on a timer")
        case .daytime: return LocalizedStringResource("Time of day", comment: "Playlist: each wallpaper shows at its time of day")
        case .dayofweek: return LocalizedStringResource("Day of week", comment: "Playlist: each wallpaper shows on its days of the week")
        case .never: return LocalizedStringResource("Never", comment: "Playlist: never change wallpaper automatically")
        }
    }

    /// Whether the items' slots, not the order, pick the wallpaper.
    var isScheduled: Bool { self == .daytime || self == .dayofweek }

    /// WE's dialog only lets the timer's options (video end, change while paused, begin with the
    /// first wallpaper, intro) be set on a timer; they apply only there.
    var usesTimerOptions: Bool { self == .timer }

    /// WE's limit for a day-of-week playlist.
    static let maxDayOfWeekItems = 7
}
