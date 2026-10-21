import Foundation

/// A wallpaper's own clock: seconds since its scene loaded, advanced by each frame's wall-clock
/// delta times the playback rate. Changing the rate changes how fast time runs from then on,
/// never where it is, so animations don't jump. Every consumer of scene time (keyframe
/// animations, `g_Time`, particles, scripts, camera shake and parallax) reads this one clock.
///
/// It follows `wallpaper64.exe`'s main loop:
/// 1. The frame's wall time (a stopwatch, 0x1400604d0) is clamped to 0.0001…0.25 s (0x140111355).
/// 2. It is multiplied by the playback rate: the wallpaper's `rate` setting ÷ 100, at least 0.1
///    (0x140114d58…0x140114d98), and clamped to 0.0001…0.25 s again (0x1401114c3…0x14011150f).
/// 3. The scene adds that to a double and keeps a float copy, the time the shaders (`g_Time`),
///    particles and camera shake read. Once the float passes 432 000 s (five days) both go back
///    to 0 (0x14017fcca…0x14017fcf6), so a float's precision never falls below 1/32 s.
///
/// 4. A pause eases the rate to 0 rather than stopping it (`playback`, WE's +0x170): each frame the
///    factor moves min(6·dt, 1) of its gap to 0 (paused) or 1, and jumps there once the gap is
///    under 0.01 (0x14011137f…0x1401113d7, 0x140492860 = 6, 0x140492620 = 0.01; dt is step 1's).
///    The rate of step 2 is multiplied by it (0x1401114c3…0x1401114cc). WE stops drawing a paused
///    wallpaper only once the factor is 0 (0x140111452…0x140111498), and so does the app
///    (`hasStopped`). After a pause the first frame's dt is the clamp's 0.25 s, so it resumes at
///    once, as WE's does after its paused loop's 250 ms sleeps.
struct SceneClock {
    /// Frames further apart than this (a stall, a sleep) advance the clock by this much only.
    static let maximumFrameDelta = 0.25
    /// The shortest step a frame takes, however close to the last it came.
    static let minimumFrameDelta = 0.0001
    /// The slowest playback rate WE allows.
    static let minimumRate = 0.1
    /// The scene time past which WE starts again from 0.
    static let wrapTime: Float = 432_000

    /// Scene seconds since load (or since the last wrap), rate applied.
    private(set) var time: Double = 0
    /// Scene seconds the last frame advanced by, rate applied.
    private(set) var delta: Double = 0
    private var lastWallTime: Double?
    /// The last frame's wall-clock step, clamped (step 1): the step WE's fades take.
    private(set) var frame: Double = 0
    /// WE's playback ease (step 4): 1 while playing, eased to 0 while `paused`.
    private(set) var playback: Float = 1
    /// The wallpaper is paused: `playback` eases towards 0, and back towards 1 once this clears.
    var paused = false

    /// Advances to `wallTime` (e.g. `CACurrentMediaTime()`) at the playback rate `speed`. The first
    /// call only anchors the clock, so the uptime it starts at never reaches the scene time.
    mutating func advance(to wallTime: Double, speed: Double) {
        // A wall time that isn't a number would poison the clock for good; the frame stands still.
        guard wallTime.isFinite else { delta = 0; frame = 0; return }
        defer { lastWallTime = wallTime }
        guard let lastWallTime else { delta = 0; frame = 0; return }
        frame = Self.clamped(wallTime - lastWallTime)
        playback = Self.ease(playback, toward: paused ? 0 : 1, seconds: frame)
        delta = Self.clamped(frame * Self.rate(speed) * Double(playback))
        time += delta
        if Float(time) > Self.wrapTime { time = 0 }
    }

    /// Stands still for a frame: the time stays, the frame's step is 0, and the next `advance`
    /// steps from `wallTime`. Only test harnesses hold a clock (to draw until pipelines compile
    /// at time 0); WE's never stops.
    mutating func hold(at wallTime: Double) {
        delta = 0
        frame = 0
        if wallTime.isFinite { lastWallTime = wallTime }
    }

    /// Draws a frame again without stepping: the time stays and the frame's step is 0, and the
    /// next `advance` still steps from the last frame's wall time.
    mutating func standStill() {
        delta = 0
        frame = 0
    }

    /// The rate a speed runs the clock at: WE's floor of 0.1; a speed that isn't a number runs at 1.
    static func rate(_ speed: Double) -> Double {
        speed.isFinite ? max(speed, minimumRate) : 1
    }

    private static func clamped(_ seconds: Double) -> Double {
        min(max(seconds, minimumFrameDelta), maximumFrameDelta)
    }

    /// A paused clock whose ease reached 0: nothing moves any more, so the wallpaper can stop drawing.
    var hasStopped: Bool { paused && playback == 0 }

    /// WE's fade rate (0x140492860) and snap distance (0x140492620).
    static let easeRate: Float = 6
    static let easeSnap: Float = 0.01

    /// One frame of WE's ease (0x14011137f…0x1401113d7, the wallpaper volume's too at
    /// 0x1401113f8…0x140111434): `target` once the gap is under 0.01, else the gap shrunk by
    /// min(6·`seconds`, 1), in float as WE does.
    static func ease(_ value: Float, toward target: Float, seconds: Double) -> Float {
        guard abs(value - target) >= easeSnap else { return target }
        return (target - value) * min(Float(seconds) * easeRate, 1) + value
    }
}
