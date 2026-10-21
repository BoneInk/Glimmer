import Metal
import simd

/// What an animator (`ScenePuppetAnimator`) needs to keep a rig's blend-shape weights
/// (`SceneMorphWeights`) and, for a puppet, to make its morph uniforms (docs/models-plan.md §2.9).
struct SceneMorphRig {
    enum Kind: Equatable {
        /// Every mesh's morph tracks apply; a blended track's weight is clamped to 0…1 (0x14021ca11).
        case model
        /// Only the first mesh's tracks apply (0x140216020 with 0), unclamped (0x1401ff649).
        case puppet
    }

    let kind: Kind
    /// Per mesh, its target count; a puppet has one entry, its first mesh's.
    let targetCounts: [Int]
    /// A puppet's first mesh's targets, from which its uniforms are made.
    let puppetTargets: MDLMorphTargets?
    /// A puppet mesh's flag 0x2000 (`MORPHING_MODIFIERS`).
    let usesModifiers: Bool

    /// A model's: every mesh with targets, by `.mdl` mesh index.
    static func model(_ morphs: SceneModelMorphs) -> SceneMorphRig {
        SceneMorphRig(kind: .model, targetCounts: (0..<morphs.meshCount).map { morphs.meshes[$0]?.targets.targets.count ?? 0 },
                      puppetTargets: nil, usesModifiers: false)
    }

    /// A puppet's, from its first mesh; nil when it has no target.
    static func puppet(_ morphs: MDLMorphTargets?, meshFlags: UInt32) -> SceneMorphRig? {
        guard let morphs, !morphs.targets.isEmpty else { return nil }
        return SceneMorphRig(kind: .puppet, targetCounts: [morphs.targets.count], puppetTargets: morphs,
                             usesModifiers: meshFlags & 0x2000 != 0)
    }

    /// A puppet's uniforms (0x14020cff0): offsets stride the `MDMP` vertex count (mesh+0x64), the
    /// base weight the `MDMP` float (mesh+0x60), and the modifiers from the bones' model-space
    /// matrices (puppet+0x2c8) under `MORPHING_MODIFIERS`.
    func puppetUniforms(_ weights: [SceneMorphWeights], boneMatrices: [simd_float4x4]) -> SceneMorphUniforms? {
        guard kind == .puppet, let targets = puppetTargets, let first = weights.first else { return nil }
        var uniforms = SceneMorphUniforms(weights: first, baseWeight: targets.weight ?? 0,
                                          stride: Int(targets.vertexCount ?? 0))
        if usesModifiers {
            uniforms.setModifiers(targets.targets.map(\.modifier), active: first.activeTargets.map(\.index),
                                  boneMatrices: boneMatrices)
        }
        return uniforms
    }
}

/// A model's blend shapes (the `MDMP` section) as its plan carries them: each mesh with targets by
/// `.mdl` mesh index, its flags and vertex count, and WE's offset stride.
struct SceneModelMorphs {
    struct Mesh {
        let targets: MDLMorphTargets
        let flags: UInt32
        let vertexCount: Int
    }

    let meshes: [Int: Mesh]
    let meshCount: Int
    /// `g_MorphOffsets`' stride for every mesh: WE keeps one per object (obj+0x2e0), the vertex count
    /// of the last mesh with a morph texture as the model builder goes through them (0x140225295).
    let offsetStride: Int

    /// nil for a model without targets.
    init?(model: MDLModel) {
        var meshes: [Int: Mesh] = [:]
        for morphs in model.morphTargets ?? [] where !morphs.targets.isEmpty && morphs.mesh < model.meshes.count {
            let mesh = model.meshes[morphs.mesh]
            meshes[morphs.mesh] = Mesh(targets: morphs, flags: mesh.flags, vertexCount: mesh.vertexCount)
        }
        guard let last = meshes.keys.max(), let stride = meshes[last]?.vertexCount else { return nil }
        self.meshes = meshes
        meshCount = model.meshes.count
        offsetStride = stride
    }

    /// Mesh `index`'s uniforms from its weights (0x140222ad5…0x140222ef6); none without an
    /// animation state (a model without bones: WE sets no morph uniforms for it, 0x140222a83).
    func uniforms(mesh index: Int, weights: [SceneMorphWeights]?) -> SceneMorphUniforms {
        guard let mesh = meshes[index], let weights, index < weights.count else { return .none }
        return SceneMorphUniforms(weights: weights[index], baseWeight: mesh.targets.weight ?? 0, stride: offsetStride)
    }
}

/// The model meshes' morph textures, made on first draw and shared by the objects drawing a plan.
/// Render thread only.
final class SceneMorphTextureCache {
    private let device: MTLDevice
    private var textures: [ObjectIdentifier: [Int: MTLTexture?]] = [:]

    init(device: MTLDevice) { self.device = device }

    func removeAll() { textures.removeAll() }

    /// Drops `plan`'s textures (it no longer draws; its identifier may be reused).
    func remove(_ plan: SceneModelPlan) { textures[ObjectIdentifier(plan)] = nil }

    /// Mesh `index`'s texture of `plan`; nil when it has no targets (the empty stand-in is bound).
    func texture(_ plan: SceneModelPlan, mesh index: Int) -> MTLTexture? {
        let key = ObjectIdentifier(plan)
        if let made = textures[key]?[index] { return made }
        var made: MTLTexture?
        if let mesh = plan.morphs?.meshes[index],
           let packed = SceneMorphTexture.model(mesh.targets, meshFlags: mesh.flags, vertexCount: mesh.vertexCount) {
            made = SceneMorphTexture.makeTexture(packed, device: device, label: "morph")
            if made == nil { OWELog.error(.scene, "\(plan.path): mesh \(index)'s morph texture can't be made") }
        }
        textures[key, default: [:]][index] = made
        return made
    }
}

extension SceneAnimationLayerStack {
    /// Lays one layer's morph tracks over `morphs` with its weight (the model update 0x14021c80c…,
    /// the puppet update 0x1401ff0ae…): each track's value is its clip's samples lerped between
    /// the layer's two frames. Models take every mesh's tracks, puppets the first mesh's.
    func applyMorphs(_ layer: SceneAnimationLayer, weight: Float, to morphs: inout [SceneMorphWeights],
                     kind: SceneMorphRig.Kind) {
        let (clip, first) = source(of: layer.clip)
        guard weight != 0, let tracks = clip.meshTracks else { return }
        let position = layer.clock.samplePosition
        let t = position.fraction
        for (mesh, meshTrack) in tracks.enumerated() {
            if kind == .puppet, mesh > 0 { break }
            guard mesh < morphs.count, meshTrack.flags & 1 != 0 else { continue }
            for track in meshTrack.morphTracks ?? [] where !track.samples.isEmpty {
                let last = track.samples.count - 1
                let a = track.samples[max(0, min(Int(position.frame0) + first, last))]
                let b = track.samples[max(0, min(Int(position.frame1) + first, last))]
                morphs[mesh].apply(track: (1 - t) * a + t * b, to: Int(track.morph), layerWeight: weight,
                                   additive: layer.additive, clampsBlend: kind == .model)
            }
        }
    }
}

extension SceneModelRenderer {
    /// Mesh `mesh`'s morph uniforms for the model object `id` this frame: its animator's weights,
    /// or none for a model without bones.
    func morphUniforms(_ id: String, plan: SceneModelPlan, mesh: SceneModelPlan.Mesh) -> SceneMorphUniforms {
        guard let morphs = plan.morphs else { return .none }
        return morphs.uniforms(mesh: mesh.index, weights: animator(for: id)?.morphs)
    }
}
