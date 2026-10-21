import Foundation
import OWEControlProtocol

/// `playlist_update`'s Playlist Settings: when the playlist changes wallpaper, the timer's options,
/// the time-of-day ends and the transition (`ControlPlaylistOptions` names the choices).
extension LibraryControlRequests {
    static let playlistSettingKeys = [
        "change_wallpaper", "change_while_paused", "begin_with_first_wallpaper", "first_wallpaper_at_startup_only",
        "daytime_ends", "transition", "transition_pool", "transition_time_ms",
    ]

    /// `current` with the parameters' changes, checked.
    static func playlistSettings(_ params: ControlParameters, current: ControlPlaylistSettings,
                                 itemCount: Int) throws -> ControlPlaylistSettings {
        var settings = current
        if let name = try params.string("change_wallpaper") {
            guard let timing = ControlPlaylistSettings.timing(named: name) else {
                throw ControlError(.invalidParams, "change_wallpaper must be one of \(ControlPlaylistOptions.timings.joined(separator: ", ")).")
            }
            settings.timing = timing
        }
        if let flag = try params.bool("change_while_paused") { settings.changesWhilePaused = flag }
        if let flag = try params.bool("begin_with_first_wallpaper") { settings.beginsWithFirst = flag }
        if let flag = try params.bool("first_wallpaper_at_startup_only") { settings.playsFirstAtStartupOnly = flag }
        if params.has("daytime_ends") {
            settings.daytimeEnds = try daytimeEnds(params.strings("daytime_ends"), itemCount: itemCount)
        }
        if let name = try params.string("transition") {
            guard let choice = ControlPlaylistSettings.choice(named: name) else {
                throw ControlError(.invalidParams, "transition must be one of \(ControlPlaylistOptions.transitionChoices.joined(separator: ", ")).")
            }
            settings.transition.choice = choice
        }
        if params.has("transition_pool") {
            let names = try params.strings("transition_pool")
            let kinds = try names.map { name -> WallpaperTransitionKind in
                guard let kind = ControlPlaylistSettings.kind(named: name) else {
                    throw ControlError(.invalidParams, "transition_pool: \"\(name)\" isn't a transition. They are \(ControlPlaylistOptions.transitionKinds.joined(separator: ", ")).")
                }
                return kind
            }
            var unique: [WallpaperTransitionKind] = []
            for kind in kinds where !unique.contains(kind) { unique.append(kind) }
            // As the setting stores it: every transition is no list.
            settings.transition.pool = Set(unique) == Set(WallpaperTransitionKind.allCases) ? nil : unique
        }
        if let milliseconds = try params.int("transition_time_ms") {
            guard ControlPlaylistOptions.transitionTimeRange.contains(milliseconds) else {
                throw ControlError(.invalidParams, "transition_time_ms must be from 0 to 3000.")
            }
            settings.transition.milliseconds = WallpaperTransitionSettings.snapped(milliseconds)
        }
        if settings.playsFirstAtStartupOnly && !settings.beginsWithFirst {
            throw ControlError(.invalidParams, "first_wallpaper_at_startup_only needs begin_with_first_wallpaper: true.")
        }
        return settings
    }

    private static func daytimeEnds(_ texts: [String], itemCount: Int) throws -> [Double?] {
        guard texts.count == itemCount else {
            throw ControlError(.invalidParams, "daytime_ends must have one entry per wallpaper: the playlist has \(itemCount).")
        }
        var previous = 0.0
        return try texts.enumerated().map { index, text -> Double? in
            // The last runs to midnight whatever it says.
            guard !text.isEmpty, index < texts.count - 1 else { return nil }
            guard let end = ControlPlaylistSettings.dayFraction(text) else {
                throw ControlError(.invalidParams, "daytime_ends[\(index)]: \"\(text)\" isn't a time; give \"HH:MM\" (24-hour) or \"\".")
            }
            guard end >= previous else {
                throw ControlError(.invalidParams, "daytime_ends[\(index)]: \(text) is before the end above it; ends must not go back in time.")
            }
            previous = end
            return end
        }
    }

    /// What changed, for the result's message.
    static func describe(_ updated: ControlPlaylistSettings, from current: ControlPlaylistSettings) -> [String] {
        var changes: [String] = []
        if updated.timing != current.timing { changes.append("it changes wallpaper: \(updated.timing.rawValue)") }
        if updated.changesWhilePaused != current.changesWhilePaused {
            changes.append(updated.changesWhilePaused ? "the timer runs while paused" : "the timer stands still while paused")
        }
        if updated.beginsWithFirst != current.beginsWithFirst {
            changes.append(updated.beginsWithFirst ? "it begins with the first wallpaper" : "it begins where it left off")
        }
        if updated.playsFirstAtStartupOnly != current.playsFirstAtStartupOnly {
            changes.append(updated.playsFirstAtStartupOnly ? "the first wallpaper plays at startup only" : "the first wallpaper is in the rotation")
        }
        if updated.daytimeEnds != current.daytimeEnds { changes.append("the time-of-day slots are set") }
        if updated.transition != current.transition {
            changes.append("the transition is \(ControlPlaylistSettings.name(of: updated.transition.choice)) over \(updated.transition.milliseconds) ms")
        }
        return changes
    }
}
