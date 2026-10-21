import simd

/// What the renderer drew, recorded while a probe is attached (`SceneMetalRenderer.drawProbe`;
/// tests and diagnostics, docs/timeline-plan.md T6): each drawn layer's opacity, colour and own
/// transform, each animated layer's sprite frame, what the GPU got for animated material
/// constants, and the frame's lighting. Without a probe the renderer records nothing. Render thread only.
final class SceneDrawProbe {
    struct Layer: Equatable {
        var opacity: Float
        var color: SIMD4<Float>
        var brightness: Float
        /// The layer's own origin, scale and `angles.z` before music sync and parallax.
        var local: SceneLocalTransform
    }

    /// Frames drawn since the probe was attached.
    private(set) var frames = 0
    /// This frame's drawn (visible) layers, by id.
    private(set) var layers: [String: Layer] = [:]
    /// This frame's sprite frame of each animated layer asked for one, by id.
    private(set) var spriteFrames: [Int: Int32] = [:]
    /// The last value written to each animated material constant's uniform, by site, as the
    /// uniform block holds it (script writes included). A chain reused as is keeps its last one.
    private(set) var constants: [SceneAnimationSite: [Float]] = [:]
    /// This frame's lighting: the scene colours and the packed light arrays.
    private(set) var lighting: SceneFrameLighting?

    func beginFrame() {
        frames += 1
        layers.removeAll(keepingCapacity: true)
        spriteFrames.removeAll(keepingCapacity: true)
    }

    func record(layer id: String, _ layer: Layer) { layers[id] = layer }

    func record(spriteFrame: Int32, object id: Int) { spriteFrames[id] = spriteFrame }

    func record(constant site: SceneAnimationSite, value: [Float]) { constants[site] = value }

    func record(lighting: SceneFrameLighting) { self.lighting = lighting }
}
