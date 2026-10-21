import Foundation

/// The choices `playlist_update` names, shared by `owe-mcp` (the tool's schema) and the app
/// (`LibraryControlRequests`, whose tests check it reads every one): when a playlist changes
/// wallpaper and its transitions.
public enum ControlPlaylistOptions {
    /// "Change wallpaper", by the values the app stores: at login, on a timer, by time of day, by
    /// day of week, or never.
    public static let timings = ["logon", "timer", "daytime", "dayofweek", "never"]

    /// Each transition, in the order of the ids the app stores (0 fade … 26 boilover).
    public static let transitionKinds = [
        "fade", "mosaic", "diffuse", "horizontal_slide", "vertical_slide", "horizontal_fade", "vertical_fade",
        "clouds", "burnt_paper", "circular", "zipper", "door", "lines", "zoom", "drip", "pixelate", "bricks",
        "paint", "fade_to_black", "twister", "black_hole", "crt", "radial_wipe", "glass_shatter", "bullets",
        "ice", "boilover",
    ]

    /// What `transition` takes: no transition ("none_reduce_flicker" is the setting's first choice),
    /// a random one from the pool, or one transition.
    public static let transitionChoices = ["none_reduce_flicker", "none", "random"] + transitionKinds

    /// `transition_time_ms`' range.
    public static let transitionTimeRange = 0...3000
}
