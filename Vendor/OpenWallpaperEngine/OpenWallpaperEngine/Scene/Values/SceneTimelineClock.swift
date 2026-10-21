import Foundation

/// One property timeline's clock, as WE keeps it at `animation+0x38` (docs/timeline-plan.md §2.4, §3.1).
///
/// The time is a float32 of this animation's own, advanced by deltas: it isn't a function of scene
/// time. Every clock starts at 0 when the scene loads. All arithmetic is float32, like WE's.
struct SceneTimelineClock: Equatable {
    /// WE's clock flag word (`clock+0xc`).
    struct Flags: OptionSet, Equatable {
        let rawValue: UInt32
        static let mirror = Flags(rawValue: 0x1)
        static let single = Flags(rawValue: 0x2)
        /// `options.random`: parsed, never read by the clock.
        static let random = Flags(rawValue: 0x4)
        static let wrapLoop = Flags(rawValue: 0x10)
        static let paused = Flags(rawValue: 0x2000_0000)
        static let finished = Flags(rawValue: 0x4000_0000)
        /// A mirror clock on its way back.
        static let reversed = Flags(rawValue: 0x8000_0000)
    }

    /// An `options.events` entry, stored at `time = frame × frameDuration`.
    struct Event: Equatable {
        var name: String
        /// The authored frame.
        var frame: Float
        /// Seconds on this clock.
        var time: Float
    }

    /// Where `value` samples: integer frames `f0`, `f1` and the linear weight of `f1`.
    struct SamplePosition: Equatable {
        var frame0: Int32
        var frame1: Int32
        var fraction: Float
    }

    /// 1 / fps.
    let frameDuration: Float
    /// `length / fps` seconds.
    let duration: Float
    /// Frames.
    let length: Int32
    let events: [Event]
    var time: Float = 0
    var flags: Flags

    /// WE's options validation (`0x1401a8c10`): nil when fps ≤ 0 or `length / fps` ≤ 0.
    init?(options: SceneTimelineDocument.Options) {
        let fps = options.fps
        guard fps > 0 else { return nil }
        let duration = Float(options.length) / fps
        guard duration > 0 else { return nil }
        let frameDuration = 1 / fps
        var flags: Flags = []
        switch options.mode {
        case .mirror: flags.insert(.mirror)
        case .single: flags.insert(.single)
        case .loop: break
        }
        if options.random { flags.insert(.random) }
        if options.startPaused { flags.insert(.paused) }
        if options.wrapLoop { flags.insert(.wrapLoop) }
        self.init(frameDuration: frameDuration, duration: duration, length: options.length, flags: flags,
                  events: options.events.map { Event(name: $0.name, frame: $0.frame, time: $0.frame * frameDuration) })
    }

    init(frameDuration: Float, duration: Float, length: Int32, flags: Flags, events: [Event] = []) {
        self.frameDuration = frameDuration
        self.duration = duration
        self.length = length
        self.flags = flags
        self.events = events
    }

    // MARK: - Advancing (`0x1401a9f60`)

    /// Moves the clock by `delta` seconds (the frame delta × the script's `rate`) and returns the
    /// events crossed, in firing order.
    @discardableResult
    mutating func advance(by delta: Float) -> [Event] {
        guard flags.isDisjoint(with: [.paused, .finished]) else { return [] }
        if flags.contains(.single), time >= duration { return [] }
        guard duration > 0 else { return [] }

        let step = flags.contains(.reversed) ? -delta : delta
        let old = time
        let new = step + old
        var fired: [Event] = step > 0
            ? events.filter { $0.time >= old && new > $0.time }
            : events.filter { $0.time > new && old >= $0.time }
        time = new

        if flags.contains(.single) {
            if new >= duration {
                flags.insert(.finished)
                time = duration
            }
        } else if flags.contains(.mirror) {
            if flags.contains(.reversed) {
                if 0 >= new {
                    time = -new.truncatingRemainder(dividingBy: duration)
                    flags.remove(.reversed)
                }
            } else if new >= duration {
                flags.insert(.reversed)
                time = duration - new.truncatingRemainder(dividingBy: duration)
            }
        } else {
            if 0 > new {
                time = (new + duration).truncatingRemainder(dividingBy: duration)
                if time >= 0 {
                    let wrapped = time
                    fired += events.filter { $0.time > wrapped && duration >= $0.time }
                }
            }
            if time >= duration {
                time = time.truncatingRemainder(dividingBy: duration)
                if duration > time {
                    let wrapped = time
                    fired += events.filter { $0.time >= 0 && wrapped > $0.time }
                }
            }
        }
        return fired
    }

    // MARK: - Sampling (`0x1401723d8`…`0x140172697`)

    /// The integer frames around `time` and the weight between them:
    /// `f0 = clamp(trunc(time / frameDuration), 0, length − 1)`, `f1 = min(f0 + 1, length)`,
    /// `fraction = fmodf(time, frameDuration) / frameDuration` (not clamped).
    var samplePosition: SamplePosition {
        let lastStart = length &- 1
        let truncated = Self.convertTruncating(time / frameDuration)
        let frame0 = min(truncated, lastStart) <= 0 ? 0 : min(truncated, lastStart)
        let frame1 = min(frame0 + 1, length)
        let fraction = time.truncatingRemainder(dividingBy: frameDuration) / frameDuration
        return SamplePosition(frame0: frame0, frame1: frame1, fraction: fraction)
    }

    /// x86 `cvttss2si`: truncation toward zero, `INT_MIN` for NaN and out-of-range values.
    static func convertTruncating(_ value: Float) -> Int32 {
        guard value.isFinite, value >= -2_147_483_648, value < 2_147_483_648 else { return Int32.min }
        return Int32(value)
    }

    // MARK: - Script API (`IAnimation`, `0x140170770`…`0x1401708ba`)

    /// `IAnimation.fps`.
    var fps: Float { 1 / frameDuration }

    /// `IAnimation.isPlaying()`: neither paused nor finished.
    var isPlaying: Bool { flags.isDisjoint(with: [.paused, .finished]) }

    /// `IAnimation.getFrame()`: fractional.
    var frame: Float { time / frameDuration }

    /// `IAnimation.play()`: a finished clock restarts from 0.
    mutating func play() {
        if flags.contains(.finished) { time = 0 }
        flags.subtract([.paused, .finished])
    }

    /// `IAnimation.pause()`.
    mutating func pause() {
        flags.insert(.paused)
    }

    /// `IAnimation.stop()`: paused, at 0, going forward.
    mutating func stop() {
        flags.insert(.paused)
        flags.subtract([.finished, .reversed])
        time = 0
    }

    /// `IAnimation.setFrame(frame)`: not clamped, and the play state is kept.
    mutating func setFrame(_ frame: Float) {
        time = frameDuration * frame
    }
}
