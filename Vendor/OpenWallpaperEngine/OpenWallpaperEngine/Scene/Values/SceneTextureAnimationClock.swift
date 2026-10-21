import Foundation

/// WE's clock of an animated texture (docs/timeline-plan.md §2.7, `0x14015f0e0`): one per texture,
/// shared by every material and layer that draws it, so it is a reference type. It advances at
/// most once per engine frame, by the engine frame time (never by a script's rate), and moves at
/// most one sprite frame per advance: a texture whose frame times are shorter than the frame
/// interval plays slower than authored, and a 0 s frame still shows for one engine frame. The
/// sprite frame is never interpolated.
///
/// WE advances it when a user binds the texture, so a texture nobody draws doesn't move.
/// A layer whose script took control (`ITextureAnimation.pause`, `stop`, `setFrame`, `rate ≠ 1`)
/// draws its own `SceneTextureAnimationControl` instead, until `join()`.
///
/// Confined to the thread that renders the wallpaper instance; not shared between instances.
final class SceneTextureAnimationClock {
    /// Each frame's time in seconds, in TEXS order (0 s frames included).
    let frameTimes: [Float]
    /// The frame shown, an index into `frameTimes`.
    private(set) var frame: Int32 = 0
    /// Seconds spent in `frame`.
    private(set) var time: Float = 0
    /// The engine frame of the last advance: later calls in the same engine frame don't move it.
    private var advancedTick: UInt64?

    init(frameTimes: [Float]) {
        self.frameTimes = frameTimes
    }

    convenience init(frames: [TEXAnimationFrame]) {
        self.init(frameTimes: frames.map(\.duration))
    }

    var frameCount: Int { frameTimes.count }

    /// `ITextureAnimation.duration`: the frame times summed in float, in order.
    var duration: Float { frameTimes.reduce(0, +) }

    /// Advances by `delta` (the engine frame time) the first time it's called for `tick` (the
    /// engine frame counter); every later call for the same tick is a no-op, so the users of the
    /// texture share one step. Returns the frame to draw.
    @discardableResult
    func advance(tick: UInt64, delta: Float) -> Int32 {
        guard advancedTick != tick else { return frame }
        advancedTick = tick
        Self.step(frame: &frame, time: &time, delta: delta, frameTimes: frameTimes)
        return frame
    }

    /// WE's per-step frame walk (`0x14015fdd0`, shared by the texture clock and a script's
    /// override), in float32:
    /// - `delta > 0`: `time += delta`; once `time ≥ frameTimes[frame]` the clock moves to the next
    ///   frame (wrapping to 0), subtracts the old frame's time and caps `time` at the new frame's.
    /// - `delta < 0`: `time += delta`; once `time ≤ 0` it moves to the previous frame (wrapping to
    ///   the last), adds that frame's time and floors `time` at 0.
    /// - `delta` 0 or NaN: nothing.
    /// A frame outside the list reads frame 0's time; stepping forward from it lands on frame 0
    /// (WE compares unsigned). Stepping backward from past the end is out of bounds in WE; here it
    /// lands on the last frame.
    static func step(frame: inout Int32, time: inout Float, delta: Float, frameTimes: [Float]) {
        let count = frameTimes.count
        guard count > 0 else { return }
        let inRange = frame >= 0 && Int(frame) < count
        let current = frameTimes[inRange ? Int(frame) : 0]
        if delta > 0 {
            time += delta
            guard time >= current else { return }
            time -= current
            var next = Int64(frame) + 1
            if next < 0 || next >= Int64(count) { next = 0 }
            frame = Int32(next)
            time = min(time, frameTimes[Int(next)])
        } else if delta < 0 {
            time += delta
            guard time <= 0 else { return }
            var previous = Int64(frame) - 1
            if previous < 0 { previous = Int64(count) - 1 }
            if previous >= Int64(count) { previous = Int64(count) - 1 }
            frame = Int32(previous)
            time = max(time + frameTimes[Int(previous)], 0)
        }
    }
}
