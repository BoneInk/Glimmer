import Foundation

/// The curve shapes the timeline offers for keyframes, in WE's handle model.
public enum TimelineEase: String, CaseIterable, Sendable {
    /// Both handles disabled: WE samples (0, 0), a straight line (the docs' "none" curve).
    case linear
    /// WE's default handles, (−1, 0) and (1, 0): flat at the keyframe on both sides.
    case easeInOut
    /// Flat arriving at the keyframe, straight leaving it.
    case easeIn
    /// Straight arriving, flat leaving.
    case easeOut
    /// Hold the previous value up to this keyframe (`step`).
    case hold
}

/// Which handle of a keyframe.
public enum TimelineHandleSide: Hashable, Sendable {
    case back, front
}

/// Keyframe editing on a clip. Every change keeps each channel in strictly increasing frame order
/// (WE drops a keyframe that doesn't move forward), and frames at 0 or later.
extension TimelineClip {
    public func keyframe(channel: Int, frame: Int) -> TimelineKeyframe? {
        guard channels.indices.contains(channel) else { return nil }
        return channels[channel].first { $0.frame == frame }
    }

    /// Sets the value at `frame`: the keyframe there keeps its handles; a new one gets WE's
    /// default handles.
    public mutating func setKeyframe(channel: Int, frame: Int, value: Double) {
        guard channels.indices.contains(channel) else { return }
        let frame = max(frame, 0)
        if let index = channels[channel].firstIndex(where: { $0.frame == frame }) {
            channels[channel][index].value = value
        } else {
            insert(TimelineKeyframe(frame: frame, value: value), channel: channel)
        }
    }

    /// Puts `keyframe` in its place, replacing one at the same frame.
    public mutating func insert(_ keyframe: TimelineKeyframe, channel: Int) {
        guard channels.indices.contains(channel) else { return }
        var keyframe = keyframe
        keyframe.frame = max(keyframe.frame, 0)
        channels[channel].removeAll { $0.frame == keyframe.frame }
        let index = channels[channel].firstIndex { $0.frame > keyframe.frame } ?? channels[channel].endIndex
        channels[channel].insert(keyframe, at: index)
    }

    public mutating func removeKeyframe(channel: Int, frame: Int) {
        guard channels.indices.contains(channel) else { return }
        channels[channel].removeAll { $0.frame == frame }
    }

    /// Moves the keyframes at `frames` (by channel) by `delta` frames, as far as frame 0 lets the
    /// earliest go. A moved keyframe replaces one that stays where it lands. Returns the delta used.
    @discardableResult
    public mutating func moveKeyframes(_ frames: [Int: Set<Int>], by delta: Int, valueDelta: Double = 0) -> Int {
        let earliest = frames.values.flatMap { $0 }.min() ?? 0
        let delta = max(delta, -earliest)
        guard delta != 0 || valueDelta != 0 else { return 0 }
        for (channel, moving) in frames where channels.indices.contains(channel) {
            let moved = channels[channel].filter { moving.contains($0.frame) }
            channels[channel].removeAll { moving.contains($0.frame) }
            for var keyframe in moved {
                keyframe.frame += delta
                keyframe.value += valueDelta
                insert(keyframe, channel: channel)
            }
        }
        return delta
    }

    /// Gives the keyframes at `frames` (by channel) the ease's handles.
    public mutating func applyEase(_ ease: TimelineEase, to frames: [Int: Set<Int>]) {
        for (channel, selected) in frames where channels.indices.contains(channel) {
            for index in channels[channel].indices where selected.contains(channels[channel][index].frame) {
                var keyframe = channels[channel][index]
                keyframe.step = false
                switch ease {
                case .linear: keyframe.back = .none; keyframe.front = .none
                case .easeInOut: keyframe.back = .back; keyframe.front = .front
                case .easeIn: keyframe.back = .back; keyframe.front = .none
                case .easeOut: keyframe.back = .none; keyframe.front = .front
                case .hold: keyframe.step = true
                }
                channels[channel][index] = keyframe
            }
        }
    }

    /// The ease the keyframe's handles make, if they are one of the presets.
    public func ease(channel: Int, frame: Int) -> TimelineEase? {
        guard let keyframe = keyframe(channel: channel, frame: frame) else { return nil }
        if keyframe.step { return .hold }
        let back = keyframe.back.effective, front = keyframe.front.effective
        let flatBack = SIMD2<Float>(-1, 0), flatFront = SIMD2<Float>(1, 0)
        if back == .zero, front == .zero { return .linear }
        if back == flatBack, front == flatFront { return .easeInOut }
        if back == flatBack, front == .zero { return .easeIn }
        if back == .zero, front == flatFront { return .easeOut }
        return nil
    }

    // MARK: Handles

    /// Half the frames of the segment a handle shapes (WE's handle x unit): the one after the
    /// keyframe for its front handle, before it for its back one. An end keyframe's outer handle
    /// borrows its other segment's, or 5 frames when the channel has one keyframe.
    func handleUnit(channel: Int, index: Int, side: TimelineHandleSide) -> Double {
        let keyframes = channels[channel]
        let neighbour = side == .front ? index + 1 : index - 1
        let other = side == .front ? index - 1 : index + 1
        for candidate in [neighbour, other] where keyframes.indices.contains(candidate) {
            let span = abs(keyframes[candidate].frame - keyframes[index].frame)
            if span > 0 { return Double(span) / 2 }
        }
        return 5
    }

    /// Where a handle's control point sits in (frame, value) space.
    public func handlePoint(channel: Int, frame: Int, side: TimelineHandleSide) -> SIMD2<Double>? {
        guard channels.indices.contains(channel),
              let index = channels[channel].firstIndex(where: { $0.frame == frame }) else { return nil }
        let keyframe = channels[channel][index]
        let handle = side == .front ? keyframe.front : keyframe.back
        let effective = handle.enabled ? SIMD2(handle.x, handle.y) : .zero
        let unit = handleUnit(channel: channel, index: index, side: side)
        return SIMD2(Double(keyframe.frame) + unit * effective.x, keyframe.value + effective.y)
    }

    /// Drags a handle's control point to `point` (frame, value). The handle stays on its side of
    /// the keyframe and within its segment (x in [0, 2] half-segments; past that WE's bisection
    /// can't solve the curve). With `lockAngle`, the other handle turns to stay opposite, keeping
    /// its length or, with `lockLength`, taking this one's.
    public mutating func setHandle(channel: Int, frame: Int, side: TimelineHandleSide, to point: SIMD2<Double>) {
        guard channels.indices.contains(channel),
              let index = channels[channel].firstIndex(where: { $0.frame == frame }) else { return }
        var keyframe = channels[channel][index]
        let unit = handleUnit(channel: channel, index: index, side: side)
        let sign: Double = side == .front ? 1 : -1
        let x = min(max((point.x - Double(keyframe.frame)) / unit * sign, 0), 2) * sign
        let y = point.y - keyframe.value
        let handle = TimelineHandle(x: x, y: y)
        keyframe.step = false
        if side == .front { keyframe.front = handle } else { keyframe.back = handle }

        if keyframe.lockAngle {
            // Opposite in (frame, value) space, so the curve stays smooth through the keyframe.
            let otherSide: TimelineHandleSide = side == .front ? .back : .front
            let otherUnit = handleUnit(channel: channel, index: index, side: otherSide)
            let other = side == .front ? keyframe.back : keyframe.front
            let dragged = SIMD2(x * unit, y)
            let draggedLength = (dragged * dragged).sum().squareRoot()
            if draggedLength > 0 {
                let otherReal = other.enabled ? SIMD2(other.x * otherUnit, other.y) : .zero
                let otherLength = keyframe.lockLength ? draggedLength : (otherReal * otherReal).sum().squareRoot()
                let opposite = -dragged / draggedLength * otherLength
                let mirrored = TimelineHandle(x: min(max(abs(opposite.x / otherUnit), 0), 2) * -sign, y: opposite.y)
                if side == .front { keyframe.back = mirrored } else { keyframe.front = mirrored }
            }
        }
        channels[channel][index] = keyframe
    }
}
