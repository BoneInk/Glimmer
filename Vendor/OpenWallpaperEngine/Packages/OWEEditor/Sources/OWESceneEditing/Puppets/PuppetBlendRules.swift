import Foundation
import simd

/// A Puppet Warp blend rule as the editor holds it (Wallpaper Engine's Edit Constraints › Blend
/// Rules; docs/models-plan.md §2.15): the bone it is on is pulled toward `target` by a weight each
/// clip keys ("Blend rules › Bone <target>", 0…1). Written as the `.mdl`'s constraints, one per
/// rule in bone order, and each clip's constraint tracks, the weight baked per frame.
public struct PuppetBlendRule: Codable, Hashable, Sendable {
    public var target: Int
    /// Per clip id, the weight's keys by frame; a clip without keys plays weight 0 [?: what
    /// Wallpaper Engine's compiler bakes for a clip that doesn't key the rule wasn't captured].
    public var weights: [UInt64: [Int: Float]]
    /// The constraint's flags and floats as the file had them (Wallpaper Engine's compiler writes
    /// flags 0 and no floats for a blend rule).
    public var flags: UInt32
    public var floats: SIMD2<Float>?

    public init(target: Int, weights: [UInt64: [Int: Float]] = [:], flags: UInt32 = 0, floats: SIMD2<Float>? = nil) {
        self.target = target
        self.weights = weights
        self.flags = flags
        self.floats = floats
    }

    /// The weight in clip `clip` at `frame`: a key, else the keys around it interpolated, else the
    /// nearest key; 0 without keys.
    public func weight(clip: UInt64, at frame: Float) -> Float {
        guard let keys = weights[clip], !keys.isEmpty else { return 0 }
        let frames = keys.keys.sorted()
        let before = frames.last { Float($0) <= frame }
        let after = frames.first { Float($0) >= frame }
        switch (before, after) {
        case let (a?, b?) where a != b:
            let t = (frame - Float(a)) / Float(b - a)
            return keys[a]! + (keys[b]! - keys[a]!) * t
        case let (a?, _): return keys[a]!
        case let (_, b?): return keys[b]!
        default: return 0
        }
    }

    /// Keys from baked samples: a frame is dropped where its neighbours' interpolation gives it
    /// back within `tolerance` (`PuppetClipBaker.keys`).
    public static func keys(from samples: [Float], tolerance: Float = 1e-4) -> [Int: Float] {
        guard !samples.isEmpty else { return [:] }
        var kept = [0]
        var index = 1
        while index < samples.count {
            let start = kept.last!
            var end = index
            while end + 1 < samples.count {
                let candidate = end + 1
                let fits = (start + 1..<candidate).allSatisfy { frame in
                    let t = Float(frame - start) / Float(candidate - start)
                    return abs(samples[start] + (samples[candidate] - samples[start]) * t - samples[frame]) <= tolerance
                }
                guard fits else { break }
                end = candidate
            }
            kept.append(end)
            index = end + 1
        }
        return Dictionary(uniqueKeysWithValues: kept.map { ($0, samples[$0]) })
    }

    /// The baked samples of clip `clip`, frames 0…`frames`.
    public func samples(clip: UInt64, frames: Int) -> [Float] {
        (0...max(frames, 0)).map { weight(clip: clip, at: Float($0)) }
    }
}

extension PuppetDocument {
    /// Every rule in the file's order (bone order, then each bone's own): its index there is the
    /// weight index the `.mdl` names.
    public var blendRuleOrder: [(bone: Int, rule: Int)] {
        bones.indices.flatMap { bone in (bones[bone].blendRules ?? []).indices.map { (bone, $0) } }
    }

    /// The bones `bone` can have a rule toward: every other bone.
    public func blendRuleTargets(of bone: Int) -> [Int] {
        bones.indices.filter { $0 != bone }
    }

    /// Adds a rule on `bone` toward `target`; false when that rule is there already.
    @discardableResult
    public mutating func addBlendRule(bone: Int, target: Int) -> Bool {
        guard bones.indices.contains(bone), bones.indices.contains(target), bone != target,
              !(bones[bone].blendRules ?? []).contains(where: { $0.target == target }) else { return false }
        bones[bone].blendRules = (bones[bone].blendRules ?? []) + [PuppetBlendRule(target: target)]
        return true
    }

    public mutating func removeBlendRule(bone: Int, at index: Int) {
        guard bones.indices.contains(bone), var rules = bones[bone].blendRules, rules.indices.contains(index) else { return }
        rules.remove(at: index)
        bones[bone].blendRules = rules.isEmpty ? nil : rules
    }

    /// Keys rule `index` of `bone` at `frame` of clip `clip` (nil deletes the key).
    public mutating func setBlendRuleWeight(bone: Int, rule index: Int, clip: UInt64, frame: Int, to value: Float?) {
        guard bones.indices.contains(bone), let rules = bones[bone].blendRules, rules.indices.contains(index) else { return }
        var keys = rules[index].weights[clip] ?? [:]
        keys[frame] = value.map { min(max($0, 0), 1) }
        bones[bone].blendRules![index].weights[clip] = keys.isEmpty ? nil : keys
    }

    /// After a renumbering (`remapBones`): targets follow their bones, a rule toward a deleted
    /// bone goes.
    mutating func remapBlendRules(_ map: [Int?]) {
        for bone in bones.indices {
            guard let rules = bones[bone].blendRules else { continue }
            let kept = rules.compactMap { rule -> PuppetBlendRule? in
                guard map.indices.contains(rule.target), let target = map[rule.target], target != bone else { return nil }
                var moved = rule
                moved.target = target
                return moved
            }
            bones[bone].blendRules = kept.isEmpty ? nil : kept
        }
    }
}

/// The player's blend (`SceneBlendRules.blend`, WE's 0x140200e20…0x1402011b1): both matrices
/// taken apart into a translation, Euler angles and the rows' lengths, a target angle more than π
/// above the bone's brought down by π, each part lerped and rebuilt as `T · R · S`.
public enum PuppetBlendMath {
    public static func blend(_ own: simd_float4x4, toward target: simd_float4x4, weight: Float) -> simd_float4x4 {
        let a = parts(own)
        var b = parts(target)
        for axis in 0..<3 where b.angles[axis] - a.angles[axis] > Float.pi { b.angles[axis] -= Float.pi }
        let translation = a.translation + (b.translation - a.translation) * weight
        let angles = a.angles + (b.angles - a.angles) * weight
        let scale = a.scale + (b.scale - a.scale) * weight
        let sc = sinf(angles.x), cc = cosf(angles.x)
        let sb = sinf(angles.y), cb = cosf(angles.y)
        let sa = sinf(angles.z), ca = cosf(angles.z)
        return simd_float4x4(columns: (SIMD4(cb * ca, cb * sa, -sb, 0) * scale.x,
                                       SIMD4(sb * ca * sc - cc * sa, sb * sa * sc + cc * ca, sc * cb, 0) * scale.y,
                                       SIMD4(cc * ca * sb + sc * sa, cc * sa * sb - sc * ca, cc * cb, 0) * scale.z,
                                       SIMD4(translation, 1)))
    }

    static func parts(_ m: simd_float4x4) -> (translation: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) {
        let r0 = m.columns.0, r1 = m.columns.1, r2 = m.columns.2
        let a = atan2f(r0.y, r0.x)
        let b = atan2f(-r0.z, (r1.z * r1.z + r2.z * r2.z).squareRoot())
        let sa = sinf(a), ca = cosf(a)
        let c = atan2f(sa * r2.x - ca * r2.y, ca * r1.y - sa * r1.x)
        return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), SIMD3(c, b, a),
                SIMD3(simd_length(r0), simd_length(r1), simd_length(r2)))
    }

    /// The step that pulls bone `bone`'s model matrix (`model`, chained from its parent) toward
    /// each target by its weight (`weights` in `PuppetDocument.blendRuleOrder`), as the player does
    /// between the parent chain and the physics step. `posed` holds the bones before it; a later
    /// target gives `fallback`'s matrix [I: the player uses last frame's there].
    public static func adjust(rules: [[PuppetBlendRule]], weights: [Float], fallback: [simd_float4x4])
        -> (Int, simd_float4x4, [simd_float4x4]) -> simd_float4x4 {
        var first: [Int] = []
        var running = 0
        for list in rules {
            first.append(running)
            running += list.count
        }
        return { bone, model, posed in
            guard bone < rules.count else { return model }
            var model = model
            for (offset, rule) in rules[bone].enumerated() {
                let index = first[bone] + offset
                let weight = index < weights.count ? weights[index] : 0
                let target = rule.target < posed.count ? posed[rule.target]
                    : rule.target < fallback.count ? fallback[rule.target] : model
                model = blend(model, toward: target, weight: weight)
            }
            return model
        }
    }

    /// Model-space matrices from local ones with the rules applied, parents first.
    public static func worlds(locals: [simd_float4x4], parents: [Int?], rules: [[PuppetBlendRule]],
                              weights: [Float]) -> [simd_float4x4] {
        let step = adjust(rules: rules, weights: weights, fallback: PuppetMath.worlds(locals: locals, parents: parents))
        var worlds: [simd_float4x4] = []
        for index in locals.indices {
            let parent = index < parents.count ? parents[index].flatMap { $0 < index ? $0 : nil } : nil
            worlds.append(step(index, parent.map { worlds[$0] * locals[index] } ?? locals[index], worlds))
        }
        return worlds
    }
}
