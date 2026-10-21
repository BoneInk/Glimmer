import Foundation

/// A property timeline ready to evaluate: WE's animation object after its load-time transforms
/// (docs/timeline-plan.md §2.2) with its own clock (§2.4).
///
/// Evaluation (§2.3): each channel is sampled at whole frames (`SceneTimelineChannel`) and the
/// value is blended linearly between the two frames around the clock's time. A linked child
/// (`parentKey`) samples its own channels on its parent's clock: pass that clock to `value(on:)`.
struct SceneTimelineAnimation: Equatable {
    /// Why an `animation` object gives no timeline. WE keeps such an animation without channels.
    enum LoadError: Error, Equatable, CustomStringConvertible {
        /// `options` isn't an object, or its `fps` or `length` isn't a number.
        case missingOptions
        /// `fps` ≤ 0, or `length / fps` ≤ 0.
        case invalidTiming(fps: Float, length: Int32)

        var description: String {
            switch self {
            case .missingOptions:
                return "options needs a numeric fps and length"
            case let .invalidTiming(fps, length):
                return "fps \(fps) and length \(length) give no duration"
            }
        }
    }

    /// `c0`, `c1`, …: one per component.
    var channels: [SceneTimelineChannel]
    var clock: SceneTimelineClock
    /// `options.name`, what `getAnimation(name)` finds.
    let name: String?
    /// `options.parent.key`: this animation runs on the clock of the same owner's animation on that property.
    let parentKey: String?

    /// Builds the timeline from its `animation` JSON and the holder's static `value`
    /// (only a string `value` is used, for `relative`).
    init(json: SceneJSON, staticValue: SceneJSON?) throws {
        try self.init(document: SceneTimelineDocument(json: json), staticValue: staticValue)
    }

    init(document: SceneTimelineDocument, staticValue: SceneJSON?) throws {
        guard let options = document.options else { throw LoadError.missingOptions }
        guard let clock = SceneTimelineClock(options: options) else {
            throw LoadError.invalidTiming(fps: options.fps, length: options.length)
        }
        var keyframeLists = document.channels
        if document.isRelative, case .string(let text)? = staticValue,
           let offsets = Self.relativeOffsets(text) {
            for index in keyframeLists.indices where index < 3 {
                for key in keyframeLists[index].indices {
                    keyframeLists[index][key].value += offsets[index]
                }
            }
        }
        if options.wrapLoop {
            for index in keyframeLists.indices {
                Self.wrapLoop(&keyframeLists[index], length: options.length)
            }
        }
        self.channels = keyframeLists.map(SceneTimelineChannel.init(keyframes:))
        self.clock = clock
        self.name = document.name
        self.parentKey = document.parentKey
    }

    // MARK: - Evaluation

    /// This animation's value on its own clock: one component per channel.
    mutating func value() -> [Float] {
        value(on: clock)
    }

    /// This animation's channels sampled at `clock`'s time and length: its own clock, or its
    /// parent's when it is linked.
    mutating func value(on clock: SceneTimelineClock) -> [Float] {
        let position = clock.samplePosition
        return channels.indices.map { sample($0, at: position) }
    }

    /// `value(on:)` without an array: the first four channels (`c0`…`c3`, all WE samples) in a
    /// vector, 0 past the last.
    mutating func components(on clock: SceneTimelineClock) -> SIMD4<Float> {
        let position = clock.samplePosition
        var components = SIMD4<Float>.zero
        for index in 0..<min(channels.count, 4) { components[index] = sample(index, at: position) }
        return components
    }

    private mutating func sample(_ channel: Int, at position: SceneTimelineClock.SamplePosition) -> Float {
        let upper = channels[channel].sample(position.frame1)
        let lower = channels[channel].sample(position.frame0)
        return upper * position.fraction + lower * (1 - position.fraction)
    }

    // MARK: - Load-time transforms

    /// `relative` (`0x1401a538a`): up to three floats from the static value string, each added to
    /// every keyframe of `c0`…`c2`. WE applies nothing unless the string has at least two spaces
    /// between tokens (three tokens); a token is read by `atof`, so text that isn't a number is 0.
    static func relativeOffsets(_ text: String) -> SIMD3<Float>? {
        var bytes = Array(text.utf8.prefix { $0 != 0 })
        guard !bytes.isEmpty else { return .zero }
        bytes.append(0)
        let space = UInt8(ascii: " ")
        var index = 0
        var offsets = SIMD3<Float>.zero
        for component in 0..<3 {
            offsets[component] = Float(atof(bytes, from: index))
            guard component < 2 else { break }
            while bytes[index] != 0, bytes[index] != space { index += 1 }
            guard bytes[index] == space else { return nil }
            while bytes[index] == space { index += 1 }
        }
        return offsets
    }

    /// C's `atof` in the "C" locale on NUL-terminated bytes: leading whitespace, then the longest
    /// decimal, hexadecimal, `inf` or `nan` prefix; 0 when there is none.
    private static func atof(_ bytes: [UInt8], from start: Int) -> Double {
        let text = String(decoding: bytes[start..<(bytes.firstIndex(of: 0) ?? bytes.endIndex)], as: Unicode.ASCII.self)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = atofPrefix.firstMatch(in: text, range: range),
              let sign = Range(match.range(at: 1), in: text),
              let body = Range(match.range(at: 2), in: text) else { return 0 }
        var literal = String(text[body])
        if literal.lowercased().hasPrefix("0x"), !literal.lowercased().contains("p") { literal += "p0" }
        // The prefix is a valid literal, which Double parses with correct rounding.
        let magnitude = Double(literal) ?? 0
        return text[sign] == "-" ? -magnitude : magnitude
    }

    private static let atofPrefix = try! NSRegularExpression(pattern:
        #"^[ \t\n\x0B\f\r]*([+-]?)(0[xX](?:[0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?"# +
        #"|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?|[nN][aA][nN])"#)

    /// The `wraploop` fix-up (`0x1401a98b0`), per channel with at least two keyframes: keyframes
    /// past `length` are dropped from the end (keeping one); a keyframe is appended at `length`
    /// unless the last is there; the last keyframe takes the first one's value, and its back handle
    /// mirrors the first one's front handle when that is enabled, or loses its enabled bit.
    static func wrapLoop(_ keyframes: inout [SceneTimelineDocument.Keyframe], length: Int32) {
        guard keyframes.count > 1 else { return }
        let first = keyframes[0]
        while keyframes.count > 1, keyframes[keyframes.count - 1].frame > length {
            keyframes.removeLast()
        }
        guard keyframes.count > 1 else { return }
        if keyframes[keyframes.count - 1].frame != length {
            keyframes.append(.init(frame: length, value: 0, flags: [], back: .zero, front: .zero))
        }
        let last = keyframes.count - 1
        if first.flags.contains(.front) {
            keyframes[last].flags.insert(.back)
            keyframes[last].back = -first.front
        } else {
            keyframes[last].flags.remove(.back)
        }
        keyframes[last].value = first.value
    }
}
