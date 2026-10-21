import Foundation
import simd

/// A document ready to pose, as the player poses a rig (docs/models-plan.md §2.8; `SceneSkeleton`,
/// `SceneAnimationLayerStack`): the bind chain and its inverse, the rest pose every frame starts
/// from, and each clip baked to its `frames + 1` samples, the way the `.mdl` stores them.
public struct PuppetRig: Sendable {
    public let parents: [Int?]
    public let bindWorld: [simd_float4x4]
    public let inverseBind: [simd_float4x4]
    /// The rest pose (relative to the parents): where a frame starts and additive layers add to.
    public let restPose: [PuppetPoseTransform]
    /// Per clip, per bone: the samples, nil for a track without keys (disabled).
    public let samples: [[[PuppetPoseTransform]?]]
    public let clips: [PuppetClip]
    /// Per bone, its blend rules (`PuppetBlendRule`).
    public let blendRules: [[PuppetBlendRule]]

    public init(_ document: PuppetDocument) {
        blendRules = document.bones.map { $0.blendRules ?? [] }
        parents = document.bones.map(\.parent)
        let locals = document.bones.map(\.local.matrix)
        bindWorld = PuppetMath.worlds(locals: locals, parents: parents)
        inverseBind = bindWorld.map(\.inverse)
        let rest = document.restLocals
        restPose = rest.map(PuppetPoseTransform.init)
        clips = document.clips
        samples = document.clips.map { clip in
            (0..<document.bones.count).map { bone -> [PuppetPoseTransform]? in
                PuppetClipBaker.samples(of: clip, bone: bone, rest: rest[bone]).map { $0.map(PuppetPoseTransform.init) }
            }
        }
    }

    public var boneCount: Int { parents.count }

    /// Model-space matrices of a pose.
    public func worlds(_ pose: [PuppetPoseTransform]) -> [simd_float4x4] {
        PuppetMath.worlds(locals: pose.map(\.matrix), parents: parents)
    }

    /// Model-space matrices of a pose with the blend rules pulled by `blendWeights` (one per rule,
    /// in `PuppetDocument.blendRuleOrder`), as the player poses a puppet.
    public func worlds(_ pose: [PuppetPoseTransform], blendWeights: [Float]) -> [simd_float4x4] {
        guard blendRules.contains(where: { !$0.isEmpty }) else { return worlds(pose) }
        return PuppetBlendMath.worlds(locals: pose.map(\.matrix), parents: parents, rules: blendRules, weights: blendWeights)
    }

    /// The blend rules' weights at a (fractional) frame of clip `clip`: the timeline's scrub.
    public func blendWeights(clip: Int, frame: Float) -> [Float] {
        guard clips.indices.contains(clip) else { return [] }
        return blendRules.flatMap { $0.map { $0.weight(clip: clips[clip].id, at: frame) } }
    }

    /// The pose and blend-rule weights of clip `clip` at `frame`, as model-space matrices.
    public func worlds(clip: Int, frame: Float) -> [simd_float4x4] {
        worlds(pose(clip: clip, frame: frame), blendWeights: blendWeights(clip: clip, frame: frame))
    }

    /// The skinning palette `world · inverseBind` (the identity in the bind pose).
    public func palette(worlds: [simd_float4x4]) -> [simd_float4x4] {
        zip(worlds, inverseBind).map { $0 * $1 }
    }

    /// Clip `clip`'s sample between `frame0` and `frame1` (translation and scale lerped, rotation
    /// nlerped); nil per bone whose track is disabled.
    public func sample(clip: Int, frame0: Int, frame1: Int, fraction: Float) -> [PuppetPoseTransform?] {
        samples[clip].map { track in
            guard let track, !track.isEmpty else { return nil }
            let a = track[max(0, min(frame0, track.count - 1))]
            let b = track[max(0, min(frame1, track.count - 1))]
            return PuppetPoseTransform.blend(a, b, fraction)
        }
    }

    /// The pose of one clip at a (fractional) frame over the rest pose: the timeline's scrub.
    public func pose(clip: Int, frame: Float) -> [PuppetPoseTransform] {
        guard samples.indices.contains(clip) else { return restPose }
        let frame0 = Int(frame.rounded(.down))
        let sampled = sample(clip: clip, frame0: frame0, frame1: frame0 + 1, fraction: frame - Float(frame0))
        return zip(restPose, sampled).map { $1 ?? $0 }
    }

    /// The mesh posed by `palette`: Σ wᵢ · paletteᵢ · p, a vertex without weights unmoved.
    public static func skin(_ document: PuppetDocument, palette: [simd_float4x4]) -> [SIMD2<Float>] {
        document.mesh.vertices.indices.map { index in
            let p = document.mesh.vertices[index].position
            let entries = index < document.weights.count ? document.weights[index] : []
            var sum = SIMD2<Float>.zero
            var total: Float = 0
            for entry in entries where palette.indices.contains(entry.bone) {
                sum += PuppetMath.transform(p, palette[entry.bone]) * entry.weight
                total += entry.weight
            }
            return total > 0 ? sum / total : p
        }
    }
}

/// Turns a clip's keyframes into the samples the `.mdl` stores: one per frame, 0…frames.
public enum PuppetClipBaker {
    /// Bone `bone`'s samples, nil when its track has no key (written disabled).
    public static func samples(of clip: PuppetClip, bone: Int, rest: PuppetTransform) -> [PuppetTransform]? {
        guard clip.tracks.indices.contains(bone), !clip.tracks[bone].isEmpty else { return nil }
        let track = clip.tracks[bone]
        return (0...max(clip.frames, 0)).map { track.transform(at: Float($0)) ?? rest }
    }

    /// Keyframes from baked samples: a frame is dropped where its neighbours' interpolation gives
    /// it back within `tolerance` (a 450-frame clip of a still bone keeps two keys).
    public static func keys(from samples: [PuppetTransform], tolerance: Float = 1e-4) -> [Int: PuppetTransform] {
        guard !samples.isEmpty else { return [:] }
        var kept = [0]
        var index = 1
        while index < samples.count {
            // Extend the span from the last kept key as far as interpolation holds every frame.
            let start = kept.last!
            var end = index
            while end + 1 < samples.count {
                let candidate = end + 1
                let fits = (start + 1..<candidate).allSatisfy { frame in
                    let t = Float(frame - start) / Float(candidate - start)
                    return PuppetTransform.lerp(samples[start], samples[candidate], t).isClose(to: samples[frame], tolerance: tolerance)
                }
                guard fits else { break }
                end = candidate
            }
            kept.append(end)
            index = end + 1
        }
        return Dictionary(uniqueKeysWithValues: kept.map { ($0, samples[$0]) })
    }
}

/// A clip's clock as the player keeps it (`SceneTimelineClock`, 0x1401a9f60): float time, mode
/// from the clip, frames sampled at `trunc(time / frameDuration)`.
public struct PuppetClipClock: Hashable, Sendable {
    public let frameDuration: Float
    public let duration: Float
    public let length: Int
    public let mode: PuppetClip.Mode
    public var time: Float = 0
    public var reversed = false
    public var finished = false

    public init(clip: PuppetClip) {
        frameDuration = clip.fps > 0 ? 1 / clip.fps : 1
        duration = clip.fps > 0 ? max(0, Float(clip.frames) / clip.fps) : 0
        length = clip.frames
        mode = clip.mode
    }

    /// Moves the clock by `delta` seconds; returns whether the clip reached its end (a single
    /// clip finished, a mirror turned, a loop wrapped).
    @discardableResult
    public mutating func advance(by delta: Float) -> Bool {
        guard !finished, duration > 0 else { return false }
        if mode == .single, time >= duration { return false }
        let step = reversed ? -delta : delta
        let new = time + step
        time = new
        switch mode {
        case .single:
            if new >= duration {
                finished = true
                time = duration
                return true
            }
        case .mirror:
            if reversed {
                if 0 >= new {
                    time = -new.truncatingRemainder(dividingBy: duration)
                    reversed = false
                    return true
                }
            } else if new >= duration {
                reversed = true
                time = duration - new.truncatingRemainder(dividingBy: duration)
                return true
            }
        case .loop:
            var wrapped = false
            if 0 > new {
                time = (new + duration).truncatingRemainder(dividingBy: duration)
                wrapped = true
            }
            if time >= duration {
                time = time.truncatingRemainder(dividingBy: duration)
                wrapped = true
            }
            return wrapped
        }
        return false
    }

    /// The frames around the time and the weight of the second.
    public var samplePosition: (frame0: Int, frame1: Int, fraction: Float) {
        let truncated = (time / frameDuration).isFinite ? Int(time / frameDuration) : 0
        let frame0 = max(0, min(truncated, length - 1))
        return (frame0, min(frame0 + 1, length), time.truncatingRemainder(dividingBy: frameDuration) / frameDuration)
    }

    public var frame: Float { time / frameDuration }
}

/// The image's animation layers played as the player plays them (`SceneAnimationLayerStack`):
/// the pose starts at rest each frame; each visible layer advances by `delta × rate`, samples its
/// clip and applies with its weight (1 replaces, additive adds its change from the rest pose,
/// any other non-zero weight nlerps from the pose below).
public struct PuppetLayerPlayer: Sendable {
    public struct Layer: Sendable {
        public var settings: PuppetAnimationLayer
        public let clip: Int
        public var clock: PuppetClipClock
        public var blendIn: Bool
        public let blendOut: Bool

        /// The weight this frame (0x14026c8b0), a looping clip's blend-in ending once its ramp is 1.
        mutating func weight() -> Float {
            let epsilon: Float = 1.1920929e-07
            let duration = clock.duration, time = clock.time, blendTime = settings.blendTime
            var weight = settings.blend
            if blendIn {
                var ramp: Float = 1
                if min(duration, blendTime) > epsilon { ramp = min(time / min(duration * 0.5, blendTime), 1) }
                weight = ramp * settings.blend
                if clock.mode != .single, ramp >= 1 { blendIn = false }
            }
            if blendOut, min(duration, blendTime) > epsilon {
                weight *= min((duration - time) / min(duration * 0.5, blendTime), 1)
            }
            return weight
        }
    }

    public let rig: PuppetRig
    public private(set) var layers: [Layer]
    /// The blend rules' weights the layers last set (the player's rig+0x250): a replacing layer
    /// sets its clip's values, any other layer `weight · value`.
    public private(set) var blendWeights: [Float] = []

    public init(rig: PuppetRig, layers: [PuppetAnimationLayer]) {
        self.rig = rig
        self.layers = layers.compactMap { settings in
            guard let clip = rig.clips.firstIndex(where: { $0.id == settings.clipID }) else { return nil }
            let mode = rig.clips[clip].mode
            return Layer(settings: settings, clip: clip, clock: PuppetClipClock(clip: rig.clips[clip]), blendIn: settings.blendIn,
                         blendOut: settings.blendOut && mode == .single)
        }
    }

    /// Advances every visible layer by `delta` seconds and returns the pose.
    public mutating func evaluate(delta: Float) -> [PuppetPoseTransform] {
        var pose = rig.restPose
        for index in layers.indices where layers[index].settings.visible {
            layers[index].clock.advance(by: delta * layers[index].settings.rate)
            let weight = layers[index].weight()
            guard weight != 0 else { continue }
            let position = layers[index].clock.samplePosition
            let sampled = rig.sample(clip: layers[index].clip, frame0: position.frame0, frame1: position.frame1,
                                     fraction: position.fraction)
            let values = rig.blendWeights(clip: layers[index].clip, frame: Float(position.frame0) + position.fraction)
            let replaces = weight == 1 && !layers[index].settings.additive
            blendWeights = replaces ? values : values.map { $0 * weight }
            for bone in pose.indices {
                guard bone < sampled.count, let sample = sampled[bone] else { continue }
                if layers[index].settings.additive {
                    pose[bone] = PuppetPoseTransform.add(sample, over: pose[bone], bind: rig.restPose[bone], weight: weight)
                } else if weight == 1 {
                    pose[bone] = sample
                } else {
                    pose[bone] = PuppetPoseTransform.blend(pose[bone], sample, weight)
                }
            }
        }
        return pose
    }
}
