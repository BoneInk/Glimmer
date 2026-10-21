import Metal
import simd

/// What a stage gets once the scene pass has ended.
struct SceneFrameStageContext {
    /// The finished scene target: every object, effect and particle drawn.
    var scene: MTLTexture
    var commandBuffer: MTLCommandBuffer
    /// The scene's size in scene units.
    var sceneSize: SIMD2<Float>
    /// This frame's built-in inputs, the lighting (`BuiltinFrameContext.lighting`) included.
    var frame: BuiltinFrameContext
    var settings: SceneRenderSettings
    /// The scene pass's depth, which `SceneVolumetrics` copies into `_rt_volumetricsBack` as WE
    /// does; nil until the scene pass has a depth buffer (area 6), which reads as the far depth.
    var sceneDepth: MTLTexture? = nil
    /// An asset texture of the content (a light's cookie), from the renderer's texture cache.
    var assetTexture: ((String, SceneMetalTextureSource) -> MTLTexture?)? = nil
    /// This frame's `_rt_shadowAtlas` (`SceneShadowPass`), which a shadow-casting light's volume
    /// reads; nil without one.
    var shadowAtlas: MTLTexture? = nil
}

/// Work WE does on the finished frame before its bloom (docs/lighting-plan.md §2.6 "Frame
/// order", step 4, and the volumetrics' combine of §2.8): it reads or adds to the scene target.
/// `SceneMetalRenderer` runs its stages in order between the scene pass and `ScenePostProcess`.
protocol SceneFrameStage: AnyObject {
    func encode(_ context: SceneFrameStageContext)
    /// The content changed (a new scene or a rebuild): drop state that belonged to the old one.
    func setContent(_ content: SceneMetalContent)
    /// Whether this frame's `encode` may read `SceneFrameStageContext.sceneDepth`, known before
    /// the scene pass ends so the pass stores its depth only when it does.
    func readsSceneDepth(settings: SceneRenderSettings) -> Bool
}

extension SceneFrameStage {
    func readsSceneDepth(settings: SceneRenderSettings) -> Bool { false }
}

enum SceneFrameStages {
    /// The stages of a renderer, in WE's order: the volumetrics, which WE combines within its
    /// object loop, then the `_rt_MipMappedFrameBuffer` copy, which follows that loop.
    static func make(device: MTLDevice) -> [SceneFrameStage] {
        [
            SceneVolumetrics(device: device),
            SceneMipMappedFrameBuffer(device: device),
        ]
    }
}
