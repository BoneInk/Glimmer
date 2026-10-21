import Foundation
import simd

/// A Puppet Warp rig's blend rules (Puppet Warp › bone › Edit Constraints › Blend Rules; the
/// `.mdl`'s constraints, `MDLSkeleton.Constraint`; docs/models-plan.md §2.15). A rule pulls its
/// bone's model-space matrix toward another bone's by a weight that clips key ("Blend rules ›
/// Bone <target>", 0…1, the clip's constraint tracks). WE's puppet update (0x1401fdf90) poses
/// the bones in order, parents first; right after a bone's matrix is chained from its parent
/// (0x140200c2e…0x140200dc5) and before its physics step (0x14020136e), every rule of the bone
/// (bone+0xd8, 20 bytes each: flags, the weight index, the target bone, two floats) blends it
/// toward the target (0x140200df2…0x1402011b9, `blend`), so its children follow. The target's
/// matrix is the one posed so far this frame: a target posed after its bone (a later index)
/// still holds last frame's (rig+0x2c8 keeps the bones from frame to frame). The rule's two
/// floats (the editor's `amin` 0 and `amax` 5, which the compiler doesn't write) aren't read
/// there. Models' update (0x14021c480) has no rules.
struct SceneBlendRules: Equatable {
    struct Rule: Equatable {
        /// The index into the weights the clips key (`SceneBoneScalars.blendRules`).
        var weight: Int
        var target: Int
    }

    /// Per bone, its rules in file order.
    let rules: [[Rule]]
    /// How many weights the clips key: one per constraint in the file.
    let weightCount: Int

    /// Nil for a skeleton without rules. A bone with flag 0x2 hangs its constraints on its link
    /// (0x140262961), an IK constraint, not a blend rule; a rule naming a weight or a target out
    /// of range is dropped [I: WE indexes without a check].
    init?(_ skeleton: MDLSkeleton) {
        let boneCount = skeleton.bones.count
        let weightCount = skeleton.constraints.count
        var rules = [[Rule]](repeating: [], count: boneCount)
        for constraint in skeleton.constraints {
            let bone = Int(constraint.bone), weight = Int(constraint.a), target = Int(constraint.b)
            guard bone < boneCount, skeleton.bones[bone].flags & 0x2 == 0 else { continue }
            guard weight < weightCount, target < boneCount, target != bone else {
                OWELog.debug(.scene, "Blend rule on bone \(bone): weight \(weight) or target \(target) out of range; dropped")
                continue
            }
            rules[bone].append(Rule(weight: weight, target: target))
        }
        guard rules.contains(where: { !$0.isEmpty }) else { return nil }
        self.rules = rules
        self.weightCount = weightCount
    }

    /// Bone `bone`'s model-space matrix `model` after its rules: `posed` holds the bones posed so
    /// far this frame (indices below `bone`), `previous` every bone as last frame left it.
    func apply(bone: Int, to model: simd_float4x4, posed: [simd_float4x4], previous: [simd_float4x4],
               weights: [Float]) -> simd_float4x4 {
        guard bone < rules.count else { return model }
        var model = model
        for rule in rules[bone] {
            let target: simd_float4x4
            if rule.target < posed.count {
                target = posed[rule.target]
            } else if rule.target < previous.count {
                target = previous[rule.target]
            } else {
                continue
            }
            let weight = rule.weight < weights.count ? weights[rule.weight] : 0
            model = Self.blend(model, toward: target, weight: weight)
        }
        return model
    }

    /// 0x140200e20…0x1402011b1: both matrices taken apart into a translation, Euler angles and
    /// the rows' lengths as the scale (WE's row-vector rows are these matrices' columns), each part
    /// lerped by `weight`, and put back together as `S · R · T` (row vectors; `T · R · S` here).
    /// A target angle more than π above the bone's comes down by π first, on each axis, and never
    /// the other way (0x140201033…0x14020108d, as WE does it). Weight 0 gives the bone's matrix
    /// back, 1 the target's, rebuilt from those parts.
    static func blend(_ own: simd_float4x4, toward target: simd_float4x4, weight: Float) -> simd_float4x4 {
        let a = Parts(own)
        var b = Parts(target)
        for axis in 0..<3 where b.angles[axis] - a.angles[axis] > Float.pi {
            b.angles[axis] -= Float.pi
        }
        let translation = a.translation + (b.translation - a.translation) * weight
        let angles = a.angles + (b.angles - a.angles) * weight
        let scale = a.scale + (b.scale - a.scale) * weight
        let rotation = Self.rotation(angles)
        return simd_float4x4(columns: (rotation.columns.0 * scale.x, rotation.columns.1 * scale.y,
                                       rotation.columns.2 * scale.z, SIMD4(translation, 1)))
    }

    /// A matrix's parts as WE reads them (0x1401e23d0 for the angles, 0x1401e24b0 for the
    /// lengths). `angles` holds (x, y, z) = (c, b, a), the order WE lerps them in.
    struct Parts {
        var translation: SIMD3<Float>
        var angles: SIMD3<Float>
        var scale: SIMD3<Float>

        init(_ m: simd_float4x4) {
            let r0 = m.columns.0, r1 = m.columns.1, r2 = m.columns.2
            translation = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let a = atan2f(r0.y, r0.x)
            let b = atan2f(-r0.z, (r1.z * r1.z + r2.z * r2.z).squareRoot())
            let sa = sinf(a), ca = cosf(a)
            let c = atan2f(sa * r2.x - ca * r2.y, ca * r1.y - sa * r1.x)
            // 0x140200fc1…0x14020102e: each angle fmod 2π (atan2 already lies within it).
            let turn = 2 * Float.pi
            angles = SIMD3(fmodf(c, turn), fmodf(b, turn), fmodf(a, turn))
            scale = SIMD3(simd_length(r0), simd_length(r1), simd_length(r2))
        }
    }

    /// 0x140215020: the rotation of the angles (x, y, z) = (c, b, a), whose rows (these columns)
    /// are (cb·ca, cb·sa, −sb), (sb·ca·sc − cc·sa, sb·sa·sc + cc·ca, sc·cb) and
    /// (cc·ca·sb + sc·sa, cc·sa·sb − sc·ca, cc·cb); `Parts` reads the same angles back.
    static func rotation(_ angles: SIMD3<Float>) -> simd_float4x4 {
        let sc = sinf(angles.x), cc = cosf(angles.x)
        let sb = sinf(angles.y), cb = cosf(angles.y)
        let sa = sinf(angles.z), ca = cosf(angles.z)
        return simd_float4x4(columns: (SIMD4(cb * ca, cb * sa, -sb, 0),
                                       SIMD4(sb * ca * sc - cc * sa, sb * sa * sc + cc * ca, sc * cb, 0),
                                       SIMD4(cc * ca * sb + sc * sa, cc * sa * sb - sc * ca, cc * cb, 0),
                                       SIMD4(0, 0, 0, 1)))
    }
}

extension SceneAnimationLayerStack {
    /// Lays one layer's constraint tracks over the blend-rule weights (0x1401fef80…0x1401ff021
    /// replace, 0x1401ff3f4…0x1401ff4bc lerp, 0x1401ff8e6…0x1401ff98f additive). A replacing layer
    /// (weight 1, not additive) sets each enabled track's value, and clears the weights first only
    /// when its clip has a disabled bone or link track (WE's 0x80000000 clip flag); any other
    /// layer clears them first (0x1401fee4f) and sets `weight · value`. A track whose tag has bit
    /// 0 set is disabled. The weights otherwise stay as the last layer left them, frame to frame.
    func applyBlendRuleWeights(_ layer: SceneAnimationLayer, weight: Float, to weights: inout [Float]) {
        guard weight != 0 else { return }
        let (clip, first) = source(of: layer.clip)
        let replaces = weight == 1 && !layer.additive
        if !replaces || clip.boneTracks.contains(where: \.isDisabled) || (clip.linkTracks ?? []).contains(where: \.isDisabled) {
            for index in weights.indices { weights[index] = 0 }
        }
        guard let tracks = clip.constraintTracks, !tracks.isEmpty else { return }
        let position = layer.clock.samplePosition
        let t = position.fraction
        for (index, track) in tracks.enumerated() where index < weights.count && track.tag & 1 == 0 && !track.samples.isEmpty {
            let last = track.samples.count - 1
            let a = track.samples[max(0, min(Int(position.frame0) + first, last))]
            let b = track.samples[max(0, min(Int(position.frame1) + first, last))]
            let value = a + (b - a) * t
            weights[index] = replaces ? value : value * weight
        }
    }
}
