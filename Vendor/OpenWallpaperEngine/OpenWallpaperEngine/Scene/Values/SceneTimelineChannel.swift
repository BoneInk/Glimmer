import Foundation

/// One component's keyframes and WE's per-frame sampler (`0x1401a9bc0`, docs/timeline-plan.md §2.3).
///
/// `S(n)` is evaluated at integer frames only and cached per frame, as WE caches it (the channel's
/// `+0x18`). A frame is solved the first time it is asked for, never before: a jump far into the
/// channel (`setFrame`, a high `rate`, a mirror's way back) costs its two frames, not every frame
/// before them (test-risks TL20). Frames past `cachedFrames` (a hostile `length`, TL22) are solved
/// each time instead of growing the cache. All arithmetic is float32, in WE's operation order.
struct SceneTimelineChannel: Equatable {
    typealias Keyframe = SceneTimelineDocument.Keyframe

    /// The most frames a channel caches: 64 k floats (256 KiB). The library's longest is 600.
    static let cachedFrames = 1 << 16

    let keyframes: [Keyframe]
    /// `S(n)` by frame; `unsolved` where frame `n` hasn't been asked for yet.
    private var cache: [Float] = []

    /// Marks an unsolved frame: a signalling NaN, which no float arithmetic produces and no
    /// keyframe value (a JSON number) can be.
    private static let unsolved = Float(bitPattern: 0x7FA0_0DAD)

    /// A keyframe at the frame of an earlier one is dropped: WE 2.8.42 plays a camera path whose
    /// eye x has two keys at frame 30 (400, then −400) through 400 at frame 30, easing in and out
    /// of it, and never reaches −400 (docs/models-plan.md §5.22). The editor can't author two keys
    /// at one frame; a second one overwrites the first there.
    init(keyframes: [Keyframe]) {
        var frames = Set<Int32>()
        self.keyframes = keyframes.filter { frames.insert($0.frame).inserted }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.keyframes == rhs.keyframes
    }

    /// `S(frame)`, cached.
    mutating func sample(_ frame: Int32) -> Float {
        guard frame >= 0, Int(frame) < Self.cachedFrames else { return Self.evaluate(keyframes, at: frame) }
        let index = Int(frame)
        if index >= cache.count {
            cache.append(contentsOf: repeatElement(Self.unsolved, count: index + 1 - cache.count))
        }
        let cached = cache[index]
        if cached.bitPattern != Self.unsolved.bitPattern { return cached }
        let solved = Self.evaluate(keyframes, at: frame)
        cache[index] = solved
        return solved
    }

    /// `S(n)` without the cache:
    /// - no keyframes → 0; before or at the first → its value; at or after the last → its value;
    /// - at a keyframe, or when the later keyframe is a `step` → the earlier value;
    /// - otherwise a cubic Bézier between the two keyframes, solved for x = n by bisection.
    static func evaluate(_ keyframes: [Keyframe], at frame: Int32) -> Float {
        guard let first = keyframes.first else { return 0 }
        if frame <= first.frame { return first.value }
        for index in 1..<max(keyframes.count, 1) {
            let previous = keyframes[index - 1]
            let next = keyframes[index]
            guard previous.frame <= frame, frame < next.frame else { continue }
            if previous.frame == frame || next.flags.contains(.step) { return previous.value }
            return bezier(from: previous, to: next, at: frame)
        }
        return keyframes[keyframes.count - 1].value
    }

    /// The segment's Bézier: x control points `p.frame`, `p.frame + h·p.front.x`,
    /// `q.frame + h·q.back.x`, `q.frame` with `h = (q.frame − p.frame) / 2`; y control points
    /// `p.value`, `p.value + p.front.y`, `q.value + q.back.y`, `q.value`.
    private static func bezier(from p: Keyframe, to q: Keyframe, at frame: Int32) -> Float {
        let half = Float(q.frame &- p.frame) * 0.5
        let x0 = Float(p.frame)
        let x1 = half * p.front.x + x0
        let x2 = half * q.back.x + Float(q.frame)
        let x3 = Float(q.frame)
        let target = Float(frame)

        var t: Float = 0
        var step: Float = 0.999
        for _ in 0..<1000 {
            let x = cubic(x0, x1, x2, x3, t)
            // WE compares the float distance, widened to double, against the double 0.01.
            if Double(abs(x - target)) < 0.01 { break }
            step *= 0.5
            if x > target { t -= step } else { t += step }
        }
        t = t < 1 ? t : 1
        if 0 > t { t = 0 }
        return cubic(p.value, p.value + p.front.y, q.value + q.back.y, q.value, t)
    }

    /// `u³·a + 3u²t·b + 3ut²·c + t³·d`, u = 1 − t, grouped and summed as WE does.
    private static func cubic(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        let u = 1 - t
        let uuu = u * u * u
        let uut3 = 3 * u * u * t
        let utt3 = 3 * u * t * t
        let ttt = t * t * t
        var sum = uuu * a
        sum += uut3 * b
        sum += utt3 * c
        sum += ttt * d
        return sum
    }
}
