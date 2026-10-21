import Foundation

/// A property timeline (the `animation` member of a bound value) read the way `wallpaper64.exe`
/// reads it (parse `0x1401a50b5`…`0x1401a57f4`, keyframes `0x1401a8ce0`, options `0x1401a96b0`,
/// events `0x1401a9410`; docs/timeline-plan.md §1.1):
///
/// ```json
/// {"c0": [{"frame": 0, "value": 1, "back": {"enabled": true, "x": -1, "y": 0},
///          "front": {"enabled": true, "x": 1, "y": 0}, "step": false}, …],
///  "c1": […], "options": {"fps": 30, "length": 120, "mode": "loop", "wraploop": true,
///  "startpaused": false, "name": "glow", "events": [{"name": "e", "frame": 12}],
///  "parent": {"key": "origin"}}, "relative": true}
/// ```
///
/// This is the file format only, with WE's reading rules (type checks, keyframes that don't
/// move forward are dropped, `asInt` frames). The load-time transforms (`relative`, `wraploop`)
/// and evaluation live in `SceneTimelineAnimation`.
struct SceneTimelineDocument: Decodable, Equatable {
    /// One keyframe, laid out as WE stores it (0x1c bytes: frame, value, flags, back, front).
    struct Keyframe: Equatable {
        struct Flags: OptionSet, Equatable {
            let rawValue: Int32
            /// `back.enabled`; the sampler never reads it.
            static let back = Flags(rawValue: 1)
            /// `front.enabled`; the sampler never reads it.
            static let front = Flags(rawValue: 2)
            /// `step`: hold the previous keyframe's value up to this one.
            static let step = Flags(rawValue: 4)
        }

        var frame: Int32
        var value: Float
        var flags: Flags
        /// The back handle: x in half-segment units, y in value units. (0, 0) when disabled.
        var back: SIMD2<Float>
        /// The front handle, in the same units as `back`.
        var front: SIMD2<Float>
    }

    /// `options.events[]`: `{name, frame}`.
    struct Event: Equatable {
        var name: String
        var frame: Float
    }

    /// `options`, when it is an object with numeric `fps` and `length`.
    struct Options: Equatable {
        enum Mode: Equatable {
            case loop, mirror, single
        }

        var fps: Float
        /// Frames (`asInt`).
        var length: Int32
        var mode: Mode
        /// Parsed but unused by WE's clock.
        var random: Bool
        var startPaused: Bool
        var wrapLoop: Bool
        var events: [Event]
    }

    /// `c0`, `c1`, … in order. WE stops at the first `cN` that isn't an array, so a gap ends the list.
    var channels: [[Keyframe]]
    /// Nil when `options` isn't an object or lacks a numeric `fps` or `length`.
    var options: Options?
    /// `options.name`.
    var name: String?
    /// `options.parent.key`: the property key of the animation whose clock this one follows.
    var parentKey: String?
    /// `relative` is present (its value is never read).
    var isRelative: Bool

    init(from decoder: Decoder) throws {
        try self.init(json: SceneJSON(from: decoder))
    }

    init(json: SceneJSON) throws {
        guard case .object(let root) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "animation is not an object: \(json)"))
        }
        let optionsObject = root["options"]?.timelineObject
        name = optionsObject?["name"]?.timelineString
        parentKey = optionsObject?["parent"]?.timelineObject?["key"]?.timelineString
        isRelative = root["relative"] != nil
        options = optionsObject.flatMap(Self.options(from:))

        var channels: [[Keyframe]] = []
        for index in 0..<4 {
            guard case .array(let list)? = root["c\(index)"] else { break }
            channels.append(Self.keyframes(from: list))
        }
        self.channels = channels
    }

    /// WE's keyframe rules: `frame` and `value` must be numbers; `frame` is truncated to an int and
    /// must be greater than the last kept keyframe's, otherwise the keyframe is dropped (never sorted).
    private static func keyframes(from list: [SceneJSON]) -> [Keyframe] {
        var keyframes: [Keyframe] = []
        var lastFrame: Int32 = -1
        for element in list {
            guard case .object(let entry) = element,
                  let value = entry["value"]?.timelineNumber,
                  let rawFrame = entry["frame"]?.timelineNumber else { continue }
            let frame = asInt(rawFrame)
            guard frame > lastFrame else { continue }
            var keyframe = Keyframe(frame: frame, value: Float(value), flags: [], back: .zero, front: .zero)
            if entry["step"]?.timelineBool == true {
                keyframe.flags = .step
            } else {
                if let back = handle(entry["back"]) {
                    keyframe.flags.insert(.back)
                    keyframe.back = back
                }
                if let front = handle(entry["front"]) {
                    keyframe.flags.insert(.front)
                    keyframe.front = front
                }
            }
            keyframes.append(keyframe)
            lastFrame = frame
        }
        return keyframes
    }

    /// An enabled handle: an object whose `enabled` is true or not a bool. Non-numeric x or y reads as 0.
    private static func handle(_ json: SceneJSON?) -> SIMD2<Float>? {
        guard case .object(let handle)? = json else { return nil }
        if case .bool(false)? = handle["enabled"] { return nil }
        return SIMD2(Float(handle["x"]?.timelineNumber ?? 0), Float(handle["y"]?.timelineNumber ?? 0))
    }

    private static func options(from object: [String: SceneJSON]) -> Options? {
        guard let length = object["length"]?.timelineNumber, let fps = object["fps"]?.timelineNumber else { return nil }
        let mode: Options.Mode
        switch object["mode"]?.timelineString {
        case "mirror": mode = .mirror
        case "single": mode = .single
        default: mode = .loop
        }
        var events: [Event] = []
        if case .array(let list)? = object["events"] {
            for element in list {
                guard case .object(let entry) = element,
                      let name = entry["name"]?.timelineString,
                      let frame = entry["frame"]?.timelineNumber else { continue }
                events.append(Event(name: name, frame: Float(frame)))
            }
        }
        return Options(fps: Float(fps), length: asInt(length), mode: mode,
                       random: object["random"]?.timelineBool == true,
                       startPaused: object["startpaused"]?.timelineBool == true,
                       wrapLoop: object["wraploop"]?.timelineBool == true,
                       events: events)
    }

    /// WE's `asInt` on a JSON number: truncation, with x86's out-of-range result (`INT_MIN`).
    static func asInt(_ number: Double) -> Int32 {
        let truncated = number.rounded(.towardZero)
        guard truncated >= Double(Int32.min), truncated <= Double(Int32.max) else { return Int32.min }
        return Int32(truncated)
    }
}

private extension SceneJSON {
    var timelineObject: [String: SceneJSON]? {
        if case .object(let object) = self { return object }
        return nil
    }

    var timelineString: String? {
        if case .string(let string) = self { return string }
        return nil
    }

    var timelineNumber: Double? {
        if case .number(let number) = self { return number }
        return nil
    }

    var timelineBool: Bool? {
        if case .bool(let bool) = self { return bool }
        return nil
    }
}
