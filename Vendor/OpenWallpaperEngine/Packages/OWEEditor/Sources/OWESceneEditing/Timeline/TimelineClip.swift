import Foundation

/// A keyframe's Bézier handle, as WE stores it: `{enabled, x, y}`, x in half-segment units (±1
/// reaches the segment's midpoint), y an offset in value units (docs/timeline-plan.md §2.3).
public struct TimelineHandle: Hashable, Sendable {
    public var enabled: Bool
    public var x: Double
    public var y: Double

    public init(enabled: Bool = true, x: Double, y: Double) {
        self.enabled = enabled
        self.x = x
        self.y = y
    }

    /// WE's default back handle: with the default front one, an ease in and out.
    public static let back = TimelineHandle(x: -1, y: 0)
    public static let front = TimelineHandle(x: 1, y: 0)
    /// A disabled handle: WE samples it as (0, 0), which makes its side of the segment linear.
    public static let none = TimelineHandle(enabled: false, x: 0, y: 0)

    /// What WE's sampler uses: the handle, or (0, 0) when disabled.
    public var effective: SIMD2<Float> { enabled ? SIMD2(Float(x), Float(y)) : .zero }
}

/// One keyframe of a channel (`c0`…`c3`).
public struct TimelineKeyframe: Hashable, Sendable {
    /// Whole frames from the clip's start (WE reads `frame` with `asInt`).
    public var frame: Int
    public var value: Double
    public var back: TimelineHandle
    public var front: TimelineHandle
    /// Hold the previous keyframe's value up to this one (WE's `step`; the later keyframe has it).
    public var step: Bool
    /// WE's editor state: moving one handle turns the other with it (`lockangle`) and gives it
    /// the same length (`locklength`). The player ignores both.
    public var lockAngle: Bool
    public var lockLength: Bool
    /// Keys the editor doesn't change (`magic`, …), written back as they were.
    public var extra: [String: SceneJSONValue]

    public init(frame: Int, value: Double, back: TimelineHandle = .back, front: TimelineHandle = .front,
                step: Bool = false, lockAngle: Bool = true, lockLength: Bool = false,
                extra: [String: SceneJSONValue] = [:]) {
        self.frame = frame
        self.value = value
        self.back = back
        self.front = front
        self.step = step
        self.lockAngle = lockAngle
        self.lockLength = lockLength
        self.extra = extra
    }

    /// The handles WE's sampler uses: none on a step keyframe (WE doesn't store them).
    public var effectiveBack: SIMD2<Float> { step ? .zero : back.effective }
    public var effectiveFront: SIMD2<Float> { step ? .zero : front.effective }
}

/// A property timeline: WE's `animation` block (docs/timeline-plan.md §1.1), read with WE's rules
/// and written back in WE's format, so what the editor saves is what WE and our player read.
///
/// The overlay stores clips in that same JSON (`Codable` goes through `json`), so there is one
/// format, the one scene.json has.
public struct TimelineClip: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case loop, mirror, single
    }

    /// `c0`, `c1`, …: one per component, keyframes in increasing frame order.
    public var channels: [[TimelineKeyframe]]
    /// `options.fps`.
    public var fps: Double
    /// `options.length`, in frames.
    public var length: Int
    public var mode: Mode
    /// `options.wraploop`: at load, the last keyframe of each channel takes the first one's value.
    public var wrapLoop: Bool
    /// `options.startpaused`: the timeline holds its first frame until a script plays it.
    public var startPaused: Bool
    /// `options.name`, what `getAnimation(name)` finds.
    public var name: String?
    /// `relative`: every keyframe of `c0`…`c2` is an offset from the field's authored value.
    public var relative: Bool
    /// Option keys the editor doesn't change (`events`, `parent`, `children`, `random`, …).
    public var otherOptions: [String: SceneJSONValue]
    /// Other keys of the block (`previewvalue`, …).
    public var otherFields: [String: SceneJSONValue]

    /// A new clip: `channelCount` empty channels.
    public init(channelCount: Int, fps: Double = 30, length: Int = 150, mode: Mode = .loop) {
        channels = Array(repeating: [], count: max(1, min(channelCount, 4)))
        self.fps = fps
        self.length = length
        self.mode = mode
        wrapLoop = false
        startPaused = false
        name = nil
        relative = false
        otherOptions = [:]
        otherFields = [:]
    }

    /// Seconds: `length / fps`.
    public var duration: Double { fps > 0 ? Double(length) / fps : 0 }

    /// Every keyframe frame of any channel, ascending.
    public var keyframeFrames: [Int] {
        Array(Set(channels.flatMap { $0.map(\.frame) })).sorted()
    }

    public var isEmpty: Bool { channels.allSatisfy(\.isEmpty) }

    // MARK: Reading

    /// Reads an `animation` block with WE's rules (`0x1401a50b5`…): `options` needs numeric `fps` and
    /// `length` (nil otherwise: WE plays no channel of it); `c0`… up to the first that isn't an
    /// array; a keyframe needs numeric `frame` and `value`, its frame truncated and greater than
    /// the last kept one, or it is dropped.
    public init?(json: SceneJSONValue) {
        guard case .object(let root) = json, case .object(let options)? = root["options"],
              case .number(let fps)? = options["fps"], case .number(let length)? = options["length"] else { return nil }
        self.fps = fps
        self.length = Self.asInt(length)
        switch options["mode"]?.stringValue {
        case "mirror": mode = .mirror
        case "single": mode = .single
        default: mode = .loop
        }
        wrapLoop = options["wraploop"] == .bool(true)
        startPaused = options["startpaused"] == .bool(true)
        name = options["name"]?.stringValue
        relative = root["relative"] != nil
        otherOptions = options.filter { !Self.optionKeys.contains($0.key) }
        var channels: [[TimelineKeyframe]] = []
        for index in 0..<4 {
            guard case .array(let list)? = root["c\(index)"] else { break }
            channels.append(Self.keyframes(list))
        }
        self.channels = channels
        otherFields = root.filter { key, _ in
            key != "options" && key != "relative" && !(key.count == 2 && key.hasPrefix("c") && Int(key.dropFirst()) != nil)
        }
    }

    private static let optionKeys: Set<String> = ["fps", "length", "mode", "wraploop", "startpaused", "name"]
    private static let keyframeKeys: Set<String> = ["frame", "value", "back", "front", "step", "lockangle", "locklength"]

    private static func keyframes(_ list: [SceneJSONValue]) -> [TimelineKeyframe] {
        var keyframes: [TimelineKeyframe] = []
        var last = -1
        for element in list {
            guard case .object(let entry) = element, case .number(let value)? = entry["value"],
                  case .number(let rawFrame)? = entry["frame"] else { continue }
            let frame = asInt(rawFrame)
            guard frame > last else { continue }
            keyframes.append(TimelineKeyframe(
                frame: frame, value: value, back: handle(entry["back"]), front: handle(entry["front"]),
                step: entry["step"] == .bool(true),
                lockAngle: entry["lockangle"]?.boolValue ?? false, lockLength: entry["locklength"]?.boolValue ?? false,
                extra: entry.filter { !keyframeKeys.contains($0.key) }))
            last = frame
        }
        return keyframes
    }

    /// WE's handle: enabled unless `enabled` is false; a missing handle is disabled.
    private static func handle(_ json: SceneJSONValue?) -> TimelineHandle {
        guard case .object(let fields)? = json else { return .none }
        return TimelineHandle(enabled: fields["enabled"] != .bool(false),
                              x: fields["x"].flatMap(number) ?? 0, y: fields["y"].flatMap(number) ?? 0)
    }

    private static func number(_ value: SceneJSONValue) -> Double? {
        if case .number(let number) = value { return number }
        return nil
    }

    /// `asInt`: truncated toward zero; out of `Int32`'s range reads as its minimum, as x86 does.
    static func asInt(_ number: Double) -> Int {
        let truncated = number.rounded(.towardZero)
        guard truncated >= Double(Int32.min), truncated <= Double(Int32.max) else { return Int(Int32.min) }
        return Int(truncated)
    }

    // MARK: Writing

    /// The block in WE's format, as WE's editor writes it.
    public var json: SceneJSONValue {
        var root = otherFields
        for (index, channel) in channels.enumerated() {
            root["c\(index)"] = .array(channel.map(Self.json))
        }
        var options = otherOptions
        options["fps"] = .number(fps)
        options["length"] = .number(Double(length))
        options["mode"] = .string(mode.rawValue)
        options["wraploop"] = .bool(wrapLoop)
        options["startpaused"] = .bool(startPaused)
        if let name, !name.isEmpty { options["name"] = .string(name) }
        root["options"] = .object(options)
        if relative { root["relative"] = .bool(true) }
        return .object(root)
    }

    private static func json(_ keyframe: TimelineKeyframe) -> SceneJSONValue {
        var entry = keyframe.extra
        entry["frame"] = .number(Double(keyframe.frame))
        entry["value"] = .number(keyframe.value)
        entry["back"] = json(keyframe.back)
        entry["front"] = json(keyframe.front)
        entry["lockangle"] = .bool(keyframe.lockAngle)
        entry["locklength"] = .bool(keyframe.lockLength)
        if keyframe.step { entry["step"] = .bool(true) }
        return .object(entry)
    }

    private static func json(_ handle: TimelineHandle) -> SceneJSONValue {
        .object(["enabled": .bool(handle.enabled), "x": .number(handle.x), "y": .number(handle.y)])
    }
}

/// The overlay keeps a clip as its WE block.
extension TimelineClip: Codable {
    public init(from decoder: Decoder) throws {
        let json = try SceneJSONValue(from: decoder)
        guard let clip = TimelineClip(json: json) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "an animation needs numeric options.fps and options.length"))
        }
        self = clip
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}
