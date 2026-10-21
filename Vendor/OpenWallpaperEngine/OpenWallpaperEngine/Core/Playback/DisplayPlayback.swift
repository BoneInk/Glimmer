import Foundation

/// What a display's wallpaper does under the playback rules (Settings › Performance › Playback),
/// from least to most restrictive: WE's "Keep running", "Mute", "Pause" and "Stop (free memory)".
///
/// Each display gets its own (`PlaybackRules`). A wallpaper instance that several displays show
/// follows what they agree on (`shared(_:)`): it keeps rendering while one of them plays, and its
/// sound, which plays once, goes quiet only when none of them plays unmuted.
enum DisplayPlayback: Int, Comparable, CaseIterable {
    case run, mute, pause, stop

    static func < (lhs: DisplayPlayback, rhs: DisplayPlayback) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The display draws new frames; a paused or stopped one keeps its last frame.
    var rendersFrames: Bool { self <= .mute }

    /// The wallpaper's sound can be heard.
    var playsSound: Bool { self == .run }

    /// The display's wallpaper window is hidden (stopped).
    var hidesWindow: Bool { self == .stop }

    /// What the displays showing one instance agree on: the least restrictive of theirs, so the
    /// instance renders while any display plays and is silent only when every display is muted,
    /// paused or stopped. No display: it runs.
    static func shared<States: Sequence>(_ states: States) -> DisplayPlayback where States.Element == DisplayPlayback {
        states.min() ?? .run
    }

    /// What a rule's action does to the display it applies to.
    init(_ action: GSPlayback) {
        switch action {
        case .keepRunning: self = .run
        case .mute: self = .mute
        case .pause, .pauseAll: self = .pause
        case .stop: self = .stop
        }
    }
}
