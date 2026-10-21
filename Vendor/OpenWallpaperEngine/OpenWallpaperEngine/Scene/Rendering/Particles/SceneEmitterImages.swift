import Metal
import simd

/// The renderer's side of `layerimage` emitters while a wallpaper runs: a Puppet Warp layer's
/// bones each frame (`ParticleLayerBones`), and sampling a layer again for an emitter with flag
/// 0x20000 (`ParticleEmitterImageResampler`) from the texture the layer drew this frame. Render
/// thread only.
final class SceneEmitterImages {
    /// A rigged layer's bones as the emitters read them, made once per layer.
    private struct Rig {
        var rig: ParticleEmitterImageBones.Rig
        var inverseRest: [simd_float4x4]
        var flatInverseRest: [SceneAffineTransform]
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let deliver: (@escaping () -> Void) -> Void
    private var rigs: [String: Rig] = [:]
    /// Puppet layers' model-space bones before this frame's update, by layer id.
    private var previousWorlds: [String: [simd_float4x4]] = [:]
    /// Layers an emitter samples again, whose drawn texture is kept (`record`).
    private(set) var resampledLayers: Set<String> = []
    private var frames: [String: RenderTextureFrame] = [:]
    private var resampler: ParticleEmitterImageResampler?

    init(device: MTLDevice, queue: MTLCommandQueue, deliver: @escaping (@escaping () -> Void) -> Void) {
        self.device = device
        self.queue = queue
        self.deliver = deliver
    }

    /// New content: nothing carries over.
    func reset() {
        rigs.removeAll()
        previousWorlds.removeAll()
        resampledLayers.removeAll()
        frames.removeAll()
    }

    /// The scene's systems changed: the layers their resampling emitters read.
    func noteSystems(_ systems: [ParticleSystemRuntime]) {
        var layers = Set<String>()
        for system in systems where system.simulation == nil {
            for emitter in system.configuration.emitters where emitter.shape.kind == .image && emitter.shape.resamplesImage {
                if let image = system.emitterImages[safe: emitter.shape.imageIndex], !image.layerID.isEmpty {
                    layers.insert(image.layerID)
                }
            }
        }
        resampledLayers = layers
        frames = frames.filter { layers.contains($0.key) }
        if !layers.isEmpty, resampler == nil {
            resampler = ParticleEmitterImageResampler(device: device, queue: queue, deliver: deliver)
        }
    }

    /// The texture `layer` drew this frame, when an emitter samples it again.
    func record(_ frame: RenderTextureFrame, layer: String) {
        guard !resampledLayers.isEmpty, resampledLayers.contains(layer) else { return }
        frames[layer] = frame
    }

    /// A puppet layer's bones just before its update this frame: they become last frame's.
    func willAdvance(puppet layer: String, worlds: [simd_float4x4]) {
        previousWorlds[layer] = worlds
    }

    /// A rigged layer's bones this frame; nil for a layer without a puppet or without hit boxes,
    /// whose points have no bones.
    func bones(of layer: String, puppet: ScenePuppetPlan?, animator: ScenePuppetAnimator?) -> ParticleLayerBones? {
        guard let puppet, let animator, let rig = rig(layer, puppet) else { return nil }
        return ParticleLayerBones(
            motion: ParticleEmitterImageBones.motion(worlds: animator.worlds, inverseRest: rig.inverseRest),
            previous: previousWorlds[layer].map { ParticleEmitterImageBones.motion(worlds: $0, inverseRest: rig.inverseRest) },
            inverseRest: rig.flatInverseRest)
    }

    /// Samples again the images of `system` that are due (`ParticleSystemRuntime.imageResamplesDue`):
    /// from the texture the layer drew this frame (its first one before it drew, or a puppet's own
    /// image, which its mesh is drawn from) [I: WE reads the layer's texture object; for a sprite
    /// sheet that may be the whole sheet]. `layer` gives a layer's textures, puppet and size.
    func resample(_ system: ParticleSystemRuntime,
                  layer: (String) -> (frames: [RenderTextureFrame], puppet: ScenePuppetPlan?, size: SIMD2<Float>)?) {
        let due = system.imageResamplesDue
        system.imageResamplesDue.removeAll()
        guard let resampler else { return }
        for slot in due {
            guard let id = system.emitterImages[safe: slot]?.layerID, let source = layer(id),
                  let frame = source.puppet == nil ? frames[id] ?? source.frames.first : source.frames.first else { continue }
            let sampling = ParticleEmitterImagePoints.Sampling(texture: frame.texture, uvOrigin: frame.uvOrigin,
                                                               uvAxisX: frame.uvAxisX, uvAxisY: frame.uvAxisY)
            let rig = source.puppet.flatMap { self.rig(id, $0)?.rig }
            resampler.request(system, slot: slot, source: .init(sampling: sampling,
                                                                imageSize: SIMD2(Int(source.size.x), Int(source.size.y)), rig: rig))
        }
    }

    private func rig(_ layer: String, _ puppet: ScenePuppetPlan) -> Rig? {
        if let made = rigs[layer] { return made.rig.boxes.isEmpty ? nil : made }
        guard let rig = ParticleEmitterImageBones.Rig(puppet) else { return nil }
        let inverse = rig.restWorld.map(\.inverse)
        let made = Rig(rig: rig, inverseRest: inverse, flatInverseRest: inverse.map(ParticleEmitterImageBones.flat))
        rigs[layer] = made
        return rig.boxes.isEmpty ? nil : made
    }
}
