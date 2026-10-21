import Metal
import simd

/// The scene pass's seam for model objects (docs/models-plan.md §4.3 M4 → M5). The renderer keeps
/// WE's object loop: it puts each model object in the draw order (scene order, `customsortorder`
/// or `transparentsorting`, §2.4), skips hidden ones, and calls `draw` at the model's place,
/// inside the scene pass, with the depth buffer attached. Everything else about a model (its
/// `.mdl`, materials, pipelines, bones, culling) is the implementation's. Nil on the renderer
/// (`SceneMetalRenderer.modelDrawing`) draws no model, which is where M4 leaves them.
protocol SceneModelDrawing: AnyObject {
    /// A new content: the scene's model objects (`SceneSpatialContent.models`, in scene order).
    /// Drop what belonged to the previous one.
    func setContent(_ models: [SceneModelObject], content: SceneMetalContent)

    /// WE's translucent flag for `transparentsorting` (0x140225241): a model is translucent unless
    /// its meshes' materials blend normal or alpha-to-coverage (then it is opaque).
    func isTranslucent(_ model: SceneModelObject) -> Bool

    /// Encodes `model` into the scene pass. Set the raster state per mesh from its pass
    /// (`SceneRasterState`, through `draw.depth`); the renderer resets its own state after.
    func draw(_ model: SceneModelObject, _ draw: SceneModelDraw, encoder: MTLRenderCommandEncoder,
              commandBuffer: MTLCommandBuffer)

    /// Whether a mesh's pipeline is still compiling off the render thread (the mesh draws nothing
    /// until it lands).
    var hasPendingPipelines: Bool { get }
    /// Compiles finished so far, however they ended: a frame drawn before one landed lacked it.
    var pipelinesLanded: Int { get }
}

/// What a model's draw gets from the renderer.
struct SceneModelDraw {
    /// The object's world matrix this frame (M3's hierarchy with live values; M6's attachments).
    let world: simd_float4x4
    /// The camera it is drawn through: the frame's (`BuiltinFrameContext.camera`), or a
    /// `perspective` model's temporary camera in an orthographic scene.
    let camera: SceneFrameCamera
    /// This frame's built-ins (time, lights, audio…).
    let frame: BuiltinFrameContext
    let values: SceneValueContext
    /// The scene target's format and samples, and its depth buffer (`SceneDepthStates.format`),
    /// which every pipeline drawing in the pass must be made for.
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int
    let depth: SceneDepthStates?
    /// `_rt_MipMappedFrameBuffer`, for `REFLECTION`.
    let mipMappedFrameBuffer: MTLTexture?
    /// An asset texture, materialised by the renderer's cache.
    let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
    /// A layer's image after its effects this frame (`_rt_imageLayerComposite_<id>_a`), by object
    /// id: the layers a model's materials sample (`SceneModelPlan.compositeLayerIDs`), drawn
    /// whether they are visible or not; nil for any other.
    var layerComposite: (String) -> MTLTexture? = { _ in nil }
    /// `_rt_shadowAtlas` this frame (`SceneShadowAtlas`): the maps `SceneShadowPass` drew, or the
    /// cleared stand-in; nil draws no mesh whose material reads it.
    var shadowAtlas: MTLTexture?
    /// `_rt_Reflection` this frame (`ScenePlanarReflection`); nil draws no mesh whose material reads it.
    var planarReflection: MTLTexture?
    /// Drawn into the planar reflection through the mirrored camera, which flips the winding.
    var mirrored = false

    /// The matrices a model's material takes (`BuiltinPassContext.place`): world, camera view,
    /// and the view-projection in the translated shaders' convention.
    var placement: SceneLayerPlacement {
        SceneLayerPlacement(world: world, size: SIMD2(1, 1), camera: camera)
    }
}
