import Foundation

/// A timeline event a clock crossed this frame (docs/timeline-plan.md §3.3). `site` is the clock
/// owner's: the animation whose clock advanced (a linked child's own events never fire, since its
/// own clock never moves). WE sends it as `animationEvent({name, frame}, value)` to the scripts of
/// the site's owner and to the animated property's own script (`0x1401726d8`).
struct SceneAnimationEvent: Equatable {
    var site: SceneAnimationSite
    var name: String
    /// The authored frame (`options.events[].frame`).
    var frame: Float
}

/// An `IAnimation`'s state, what scripts read (§3.1): the timeline's own clock and `rate`.
struct SceneAnimationState: Equatable {
    var name: String?
    /// `1 / frameDuration`.
    var fps: Float
    /// `length`.
    var frameCount: Int32
    /// Seconds.
    var duration: Float
    /// The script wrapper's `rate`: 1 until a script writes it.
    var rate: Float
    /// Seconds on this animation's own clock.
    var time: Float
    /// Only `paused`, `finished` and `reversed` change at run time; the mode bits are fixed.
    var flags: SceneTimelineClock.Flags
    /// `getFrame()`: `time / frameDuration`, fractional.
    var frame: Float
    /// The value the timeline set this frame (`c0`…`c3`, 0 past the last channel): what WE's
    /// setter wrote before the scripts run (§2.1), so bound scripts and reads see it.
    var value = SIMD4<Float>.zero

    var isPlaying: Bool { flags.isDisjoint(with: [.paused, .finished]) }
}

/// An `IAnimation` call (callbacks `0x140170770`…`0x1401708ba`), applied to the named animation's
/// own clock. On a linked child it changes a clock nobody samples, as in WE.
enum SceneAnimationControl: Equatable {
    case play, pause, stop
    case setFrame(Float)
    /// `rate = value`: the delta multiplier while this animation is a clock owner.
    case setRate(Float)
}

/// What one `SceneAnimationSet.advance(by:)` produced: the events crossed, in WE's firing order.
/// The values it sampled are read from the set (`value(of:)`, `components(at:)`).
struct SceneAnimationFrame {
    var events: [SceneAnimationEvent] = []
}
