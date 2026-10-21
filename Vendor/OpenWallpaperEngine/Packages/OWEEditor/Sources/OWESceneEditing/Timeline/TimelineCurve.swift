import Foundation

/// WE's evaluation of a timeline (docs/timeline-plan.md §2.2–§2.4), the same float32 arithmetic in
/// the same order as the player's `SceneTimelineChannel`, `SceneTimelineClock` and
/// `SceneTimelineAnimation`, so the curve the editor draws and the value it shows at the playhead
/// are what the wallpaper draws. (The app's tests hold the two to the same bits.)
public enum TimelineCurve {
    /// `S(frame)`, WE's per-frame sampler (`0x1401a9bc0`): no keyframes → 0; at or before the first
    /// → its value; at or after the last → its value; at a keyframe, or when the later keyframe is
    /// a step → the earlier value; otherwise the segment's cubic Bézier solved for x = frame.
    public static func sample(_ keyframes: [TimelineKeyframe], at frame: Int32) -> Float {
        guard let first = keyframes.first else { return 0 }
        if frame <= Int32(clamping: first.frame) { return Float(first.value) }
        for index in 1..<max(keyframes.count, 1) {
            let previous = keyframes[index - 1]
            let next = keyframes[index]
            let previousFrame = Int32(clamping: previous.frame), nextFrame = Int32(clamping: next.frame)
            guard previousFrame <= frame, frame < nextFrame else { continue }
            if previousFrame == frame || next.step { return Float(previous.value) }
            return bezier(from: previous, to: next, at: frame)
        }
        return Float(keyframes[keyframes.count - 1].value)
    }

    /// x control points `p.frame`, `p.frame + h·p.front.x`, `q.frame + h·q.back.x`, `q.frame` with
    /// `h = (q.frame − p.frame) / 2`; y control points `p.value`, `p.value + p.front.y`,
    /// `q.value + q.back.y`, `q.value`; `t` found by WE's bisection.
    private static func bezier(from p: TimelineKeyframe, to q: TimelineKeyframe, at frame: Int32) -> Float {
        let pFrame = Int32(clamping: p.frame), qFrame = Int32(clamping: q.frame)
        let front = p.effectiveFront, back = q.effectiveBack
        let pValue = Float(p.value), qValue = Float(q.value)
        let half = Float(qFrame &- pFrame) * 0.5
        let x0 = Float(pFrame)
        let x1 = half * front.x + x0
        let x2 = half * back.x + Float(qFrame)
        let x3 = Float(qFrame)
        let target = Float(frame)

        var t: Float = 0
        var step: Float = 0.999
        for _ in 0..<1000 {
            let x = cubic(x0, x1, x2, x3, t)
            if Double(abs(x - target)) < 0.01 { break }
            step *= 0.5
            if x > target { t -= step } else { t += step }
        }
        t = t < 1 ? t : 1
        if 0 > t { t = 0 }
        return cubic(pValue, pValue + front.y, qValue + back.y, qValue, t)
    }

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

    /// The value at clock time `time` (`0x1401723d8`…): the two whole frames around it, blended
    /// linearly. `f0 = clamp(trunc(time / frameDuration), 0, length − 1)`, `f1 = min(f0 + 1, length)`,
    /// weight `fmodf(time, frameDuration) / frameDuration`.
    public static func value(_ keyframes: [TimelineKeyframe], atTime time: Float, fps: Float, length: Int32) -> Float {
        guard fps > 0 else { return sample(keyframes, at: 0) }
        let frameDuration = 1 / fps
        let lastStart = length &- 1
        let truncated = convertTruncating(time / frameDuration)
        let frame0 = min(truncated, lastStart) <= 0 ? 0 : min(truncated, lastStart)
        let frame1 = min(frame0 + 1, length)
        let fraction = time.truncatingRemainder(dividingBy: frameDuration) / frameDuration
        let upper = sample(keyframes, at: frame1)
        let lower = sample(keyframes, at: frame0)
        return upper * fraction + lower * (1 - fraction)
    }

    static func convertTruncating(_ value: Float) -> Int32 {
        guard value.isFinite, value >= -2_147_483_648, value < 2_147_483_648 else { return Int32.min }
        return Int32(value)
    }

    /// Where a clip's clock stands when the editor's playhead is at `seconds`: the time itself
    /// within the clip; past its end, a loop wraps, a mirror runs back and a single holds its end.
    /// A time on a whole frame becomes WE's `setFrame` time for it (`frameDuration × frame`), so a
    /// keyframe's frame shows the keyframe's value (`0.5` s at 30 fps would otherwise sample just
    /// short of frame 15 and blend in frame 16). Every timeline of the canvas follows the one
    /// playhead this way (the renderer's scrub). `frameDuration` and `duration` are the clock's.
    public static func clockTime(atPlayhead seconds: Float, frameDuration: Float, duration: Float,
                                 mode: TimelineClip.Mode) -> Float {
        guard duration > 0, frameDuration > 0, seconds.isFinite else { return 0 }
        var time = max(seconds, 0)
        if time > duration {
            switch mode {
            case .loop:
                time = time.truncatingRemainder(dividingBy: duration)
            case .mirror:
                let phase = time.truncatingRemainder(dividingBy: 2 * duration)
                time = phase <= duration ? phase : 2 * duration - phase
            case .single:
                time = duration
            }
        }
        let frames = time / frameDuration
        let whole = frames.rounded()
        if abs(frames - whole) < 1e-3 { time = frameDuration * whole }
        return time
    }
}

extension TimelineClip {
    /// The keyframes the player samples for `channel`, after WE's load-time transforms (§2.2):
    /// `relative` adds the field's authored value (`staticValue`, a vector string) to `c0`…`c2`,
    /// and `wraploop` ends the channel on its first value at `length`.
    public func playerKeyframes(channel: Int, staticValue: SceneJSONValue? = nil) -> [TimelineKeyframe] {
        guard channels.indices.contains(channel) else { return [] }
        var keyframes = channels[channel]
        if relative, channel < 3, case .string(let text)? = staticValue, let offsets = Self.relativeOffsets(text) {
            // WE adds in float32.
            for index in keyframes.indices {
                keyframes[index].value = Double(Float(keyframes[index].value) + Float(offsets[channel]))
            }
        }
        if wrapLoop { Self.wrapLoop(&keyframes, length: length) }
        return keyframes
    }

    /// `relative`'s offsets: three numbers, separated by spaces, from the authored value; nil
    /// when there aren't three (WE then adds nothing), zero for an empty string.
    static func relativeOffsets(_ text: String) -> [Double]? {
        if text.isEmpty { return [0, 0, 0] }
        let tokens = text.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 3 else { return nil }
        return tokens.prefix(3).map { Double($0) ?? 0 }
    }

    /// The `wraploop` fix-up (`0x1401a98b0`), as the player applies it.
    static func wrapLoop(_ keyframes: inout [TimelineKeyframe], length: Int) {
        guard keyframes.count > 1 else { return }
        let first = keyframes[0]
        while keyframes.count > 1, keyframes[keyframes.count - 1].frame > length { keyframes.removeLast() }
        guard keyframes.count > 1 else { return }
        if keyframes[keyframes.count - 1].frame != length {
            keyframes.append(TimelineKeyframe(frame: length, value: 0, back: .none, front: .none))
        }
        let last = keyframes.count - 1
        // The player turns off the last keyframe's back flag without zeroing the handle, and its
        // sampler never reads the flag: the handle stays as it was.
        if first.front.enabled, !first.step {
            keyframes[last].back = TimelineHandle(x: -first.front.x, y: -first.front.y)
        }
        keyframes[last].value = first.value
    }

    /// Channel `channel`'s value at clock time `time` (seconds), as the player draws it.
    public func value(channel: Int, atTime time: Double, staticValue: SceneJSONValue? = nil) -> Float {
        TimelineCurve.value(playerKeyframes(channel: channel, staticValue: staticValue), atTime: Float(time),
                            fps: Float(fps), length: Int32(clamping: length))
    }

    /// Every channel's value when the editor's playhead is at `seconds`.
    public func values(atPlayhead seconds: Double, staticValue: SceneJSONValue? = nil) -> [Float] {
        let fps = Float(self.fps)
        let time = TimelineCurve.clockTime(atPlayhead: Float(seconds), frameDuration: 1 / fps,
                                           duration: Float(length) / fps, mode: mode)
        return channels.indices.map { value(channel: $0, atTime: Double(time), staticValue: staticValue) }
    }
}
