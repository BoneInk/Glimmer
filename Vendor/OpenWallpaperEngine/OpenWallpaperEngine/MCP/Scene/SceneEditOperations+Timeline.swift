import Foundation
import OWEControlProtocol
import OWESceneEditing

/// Timeline edits, as the editor's timeline makes them (`SceneTimelineEditor`): a property's
/// keyframes added, set, moved, eased and deleted, its clip's options, and the track removed.
/// A track is a layer's own field (`field`: origin, scale, angles, alpha, color, …) or a constant
/// of one of its scene's effects (`effect` and `constant`); `timeline_get` lists what each layer
/// can animate. Frames count from 0 at the clip's fps.
extension SceneEditOperations {
    static var timelineOperations: [String: Operation] {
        [
            "timeline_add_keyframe": { edit, context in
                try Self.changeClip(edit, context, creating: true) { clip, target, property in
                    let frame = try Self.keyframeFrame(edit)
                    let values = try Self.keyframeValues(edit, clip: clip, target: target, frame: frame, channels: property.channelCount, context)
                    for channel in clip.channels.indices {
                        clip.setKeyframe(channel: channel, frame: frame, value: channel < values.count ? values[channel] : 0)
                    }
                    if frame > clip.length { clip.length = frame }
                }
            },
            "timeline_set_keyframe": { edit, context in
                try Self.changeClip(edit, context) { clip, target, property in
                    let frame = try Self.keyframeFrame(edit)
                    let channels = try Self.keyframeChannels(edit, clip: clip, frame: frame)
                    let values = try Self.keyframeValues(edit, clip: clip, target: target, frame: frame, channels: property.channelCount, context)
                    for channel in channels { clip.setKeyframe(channel: channel, frame: frame, value: channel < values.count ? values[channel] : 0) }
                }
            },
            "timeline_move_keyframe": { edit, context in
                try Self.changeClip(edit, context) { clip, _, _ in
                    let frame = try Self.keyframeFrame(edit)
                    let channels = try Self.keyframeChannels(edit, clip: clip, frame: frame)
                    let target = try edit.requiredInt("to_frame")
                    guard target >= 0 else { throw ControlError(.invalidParams, "to_frame must be 0 or later.") }
                    clip.moveKeyframes(Dictionary(uniqueKeysWithValues: channels.map { ($0, Set([frame])) }), by: target - frame)
                    if target > clip.length { clip.length = target }
                }
            },
            "timeline_delete_keyframe": { edit, context in
                try Self.changeClip(edit, context) { clip, _, _ in
                    let frame = try Self.keyframeFrame(edit)
                    for channel in try Self.keyframeChannels(edit, clip: clip, frame: frame) { clip.removeKeyframe(channel: channel, frame: frame) }
                }
            },
            "timeline_set_ease": { edit, context in
                try Self.changeClip(edit, context) { clip, _, _ in
                    let frame = try Self.keyframeFrame(edit)
                    let name = try edit.required("ease")
                    guard let ease = TimelineEase(rawValue: easeNames[name] ?? name) else {
                        throw ControlError(.invalidParams, "ease must be one of \(easeNames.keys.sorted().joined(separator: ", ")).")
                    }
                    let channels = try Self.keyframeChannels(edit, clip: clip, frame: frame)
                    clip.applyEase(ease, to: Dictionary(uniqueKeysWithValues: channels.map { ($0, Set([frame])) }))
                }
            },
            "timeline_set_clip": { edit, context in
                try Self.changeClip(edit, context) { clip, _, _ in
                    if let fps = try edit.double("fps") {
                        guard fps > 0 else { throw ControlError(.invalidParams, "fps must be above 0.") }
                        clip.fps = fps
                    }
                    if let length = try edit.int("frames") {
                        guard length > 0 else { throw ControlError(.invalidParams, "frames must be at least 1.") }
                        clip.length = length
                    }
                    if let mode = try edit.string("mode") {
                        guard let value = TimelineClip.Mode(rawValue: mode) else {
                            throw ControlError(.invalidParams, "mode must be \"loop\", \"mirror\" or \"single\".")
                        }
                        clip.mode = value
                    }
                    if let name = try edit.string("name") { clip.name = name.isEmpty ? nil : name }
                }
            },
            "timeline_remove_track": { edit, context in
                let (target, _) = try Self.timelineTarget(edit, context)
                guard context.timeline.clip(target) != nil else { throw ControlError(.notFound, "That property has no timeline.") }
                context.timeline.removeTrack(target, actionName: "")
                return ["track": trackJSON(target)]
            },
        ]
    }

    /// The names `timeline_set_ease` takes, and the timeline's eases they are.
    static let easeNames: [String: String] = [
        "linear": TimelineEase.linear.rawValue, "ease_in_out": TimelineEase.easeInOut.rawValue,
        "ease_in": TimelineEase.easeIn.rawValue, "ease_out": TimelineEase.easeOut.rawValue, "hold": TimelineEase.hold.rawValue,
    ]

    /// The track the edit names, and what the scene says of the property.
    static func timelineTarget(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> (TimelineTarget, TimelineSceneIndex.Property) {
        let layer = try Self.layer(edit, context)
        let target: TimelineTarget
        if let effectKey = try edit.string("effect") {
            guard let index = Int(effectKey) else {
                throw ControlError(.unsupported, "Only the scene's own effects (keys \"0\", \"1\", …) have timelines; \(effectKey) was added in the editor.")
            }
            target = .constant(try edit.required("constant"), effect: index, pass: try edit.int("pass") ?? 0, of: layer.id)
        } else {
            target = .field(try edit.required("field"), of: layer.id)
        }
        guard let property = context.timelineIndex.property(target) else {
            let animatable = context.timelineIndex.properties(of: layer.id).map { property in
                property.target.effect.map { "effect \($0) \(property.target.key)" } ?? property.target.key
            }.joined(separator: ", ")
            throw ControlError(.notFound, "Layer \(layer.id) can't animate that. " + (animatable.isEmpty ? "It has nothing to animate." : "It can animate: \(animatable)."))
        }
        guard !property.isUserBound else { throw ControlError(.refused, "A user property sets it; a timeline can't.") }
        return (target, property)
    }

    private static func changeClip(_ edit: ControlParameters, _ context: SceneEditOperationContext, creating: Bool = false,
                                   _ change: (inout TimelineClip, TimelineTarget, TimelineSceneIndex.Property) throws -> Void) throws -> JSONValue {
        let (target, property) = try Self.timelineTarget(edit, context)
        var clip: TimelineClip
        if let existing = context.timeline.clip(target) {
            clip = existing
        } else if creating {
            clip = TimelineClip(channelCount: property.channelCount, fps: try edit.double("fps") ?? 30,
                                length: try edit.int("frames") ?? 150)
        } else {
            throw ControlError(.notFound, "That property has no timeline; timeline_add_keyframe makes one.")
        }
        try change(&clip, target, property)
        context.timeline.commit([target: clip], actionName: "")
        return ["track": trackJSON(target)]
    }

    private static func keyframeFrame(_ edit: ControlParameters) throws -> Int {
        let frame = try edit.requiredInt("frame")
        guard frame >= 0 else { throw ControlError(.invalidParams, "frame must be 0 or later.") }
        return frame
    }

    /// The channel `channel` names, else every channel with a keyframe at `frame`.
    private static func keyframeChannels(_ edit: ControlParameters, clip: TimelineClip, frame: Int) throws -> [Int] {
        if let channel = try edit.int("channel") {
            guard clip.keyframe(channel: channel, frame: frame) != nil else {
                throw ControlError(.notFound, "Channel \(channel) has no keyframe at frame \(frame).")
            }
            return [channel]
        }
        let channels = clip.channels.indices.filter { clip.keyframe(channel: $0, frame: frame) != nil }
        guard !channels.isEmpty else {
            throw ControlError(.notFound, "No keyframe at frame \(frame). Keyframes: \(clip.keyframeFrames.map(String.init).joined(separator: ", ")).")
        }
        return Array(channels)
    }

    /// `value` (`"x y z"`, one number per channel), else the property's value there now.
    private static func keyframeValues(_ edit: ControlParameters, clip: TimelineClip, target: TimelineTarget, frame: Int,
                                       channels: Int, _ context: SceneEditOperationContext) throws -> [Double] {
        if let text = try edit.string("value") {
            return try SceneControlValues.vector(text, count: channels, fallback: Array(repeating: 0, count: channels), name: "value")
        }
        guard !clip.relative else { throw ControlError(.invalidParams, "This timeline stores offsets (relative): give value.") }
        let staticValue = context.timeline.staticValue(target)
        if !clip.isEmpty, clip.fps > 0 {
            return clip.values(atPlayhead: Double(frame) / clip.fps, staticValue: staticValue).map(Double.init)
        }
        return SceneVector.components(staticValue, fallback: Array(repeating: 0, count: channels))
    }

    static func trackJSON(_ target: TimelineTarget) -> JSONValue {
        var object: [String: JSONValue] = ["layer": .number(Double(target.layer)), "key": .string(target.key)]
        if let effect = target.effect {
            object["effect"] = .string(String(effect))
            object["pass"] = .number(Double(target.pass ?? 0))
        }
        return .object(object)
    }
}
