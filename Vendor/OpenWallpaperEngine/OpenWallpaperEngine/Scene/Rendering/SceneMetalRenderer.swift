import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

struct PreparedLayer {
    let frames: [RenderTextureFrame]
    let layer: SceneMetalLayer
    /// Where the layer's own transform comes from each frame.
    let motion: SceneObjectMotion
    /// The particle systems to draw before this layer: every system whose authored order is below
    /// this (`SceneRendererScripts.drawOrder`).
    var particleBarrier: Int

    init(frames: [RenderTextureFrame], layer: SceneMetalLayer) {
        self.frames = frames
        self.layer = layer
        motion = SceneObjectMotion(layer: layer)
        particleBarrier = layer.order
    }
}

/// What a visible layer is drawn with this frame: its scripted/animated opacity and colour and
/// its placed quad. Computed once, before effects run, so effects see the same values.
struct LayerDraw {
    let opacity: Float
    let color: SIMD4<Float>
    let brightness: Float
    /// World-space quad, parallax and camera shake included.
    let quad: SceneQuadGeometry
    let musicSyncLevel: Double
    /// The layer drawn through a 3D camera (a perspective scene's, or a `perspective` layer's in an
    /// orthographic scene, docs/models-plan.md §2.4); nil draws `quad` in the scene's plane.
    var placement: SceneLayerPlacement? = nil
    /// The layer's object transform (parents included), before the camera: `g_LayerModelMatrix`.
    var world = SceneAffineTransform.identity
}

/// Frame-wide camera motion applied to every layer.
struct CameraMotion {
    /// This frame's parallax and `cameraparallaxamount` (times the app's amount), when objects
    /// are displaced: parallax on in an orthographic scene.
    let parallax: (state: SceneCameraParallax, amount: Float)?
    /// How far camera shake moved the camera, where the renderer moves the scene the other way
    /// instead: an orthographic scene, whose layers aren't drawn through the camera.
    let shake: SIMD2<Float>
    /// The shake a perspective scene's camera carries (`SceneCameraRigInput.shake`); zero in an
    /// orthographic scene.
    var cameraShake = SIMD3<Float>.zero
    let audioLevel: Double
}

struct RenderTextureFrame {
    let texture: MTLTexture
    let duration: Float
    let uvOrigin: SIMD2<Float>
    let uvAxisX: SIMD2<Float>
    let uvAxisY: SIMD2<Float>
    /// Text only: the glyphs' coverage, which WE's `font` material samples; nil for colour glyphs.
    var coverage: MTLTexture? = nil
    /// Text only: the block's centre from the object's origin, unscaled (`SceneTextLayout.boxCenter`).
    var textCenter = SIMD2<Float>.zero
}

final class SceneMetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    /// The drawables' format, which the layer and copy pipelines draw in.
    let pixelFormat: MTLPixelFormat
    let commandQueue: MTLCommandQueue
    /// The scene pass's own pipelines, in the scene target's format (`SceneLayerPipelines`).
    let layerPipelines: SceneLayerPipelines
    var renderPipeline: MTLRenderPipelineState { scenePassPipelines.normal }
    var additiveRenderPipeline: MTLRenderPipelineState { scenePassPipelines.additive }
    /// The layer pipelines for the scene target's format, this frame's sample count and depth.
    var scenePassPipelines: SceneLayerPipelines.Pipelines {
        // The drawable's when the scene draws straight into it (S2).
        guard let format = (sceneRenderTarget ?? lastDrawableScene)?.pixelFormat else { return layerPipelines.pipelines(for: nil) }
        return layerPipelines.pipelines(for: format, sampleCount: sceneSampleCount, depthFormat: sceneDepthFormat)
            ?? layerPipelines.pipelines(for: format)
    }
    /// An unblended copy in the drawables' format: a shared frame onto a display (`present(in:)`).
    let copyPipeline: MTLRenderPipelineState
    /// Everything after the scene pass, up to the drawable (bloom and the composite).
    let postProcess: ScenePostProcess
    /// WE's work on the finished frame before its bloom (`SceneFrameStages`).
    let frameStages: [SceneFrameStage]
    /// The stage that keeps `_rt_MipMappedFrameBuffer` (internal for tests and diagnostics), and
    /// its target for this frame's draws.
    let mipMappedFrameBuffer: SceneMipMappedFrameBuffer?
    var mipMappedTarget: MTLTexture?
    /// The volumetrics stage (tests and diagnostics).
    var volumetrics: SceneVolumetrics? { frameStages.lazy.compactMap { $0 as? SceneVolumetrics }.first }
    let dxtDecodePipeline: MTLComputePipelineState
    let textureLoader: MTKTextureLoader
    let renderTargetPool: SceneRenderTargetPool
    /// This frame's scene snapshot target (`sceneSnapshot`), leased on first use, and which part
    /// of it matches the scene drawn so far.
    var sceneCopy: MTLTexture?
    /// This frame's scene snapshot goes into `_rt_MipMappedFrameBuffer`'s level 0
    /// (`SceneMipMappedFrameBuffer.snapshotCanShare`).
    var snapshotSharesMipMappedTarget = false
    var snapshotTracker = SceneSnapshotTracker()
    /// Trims rebuildable memory when the system asks (`trimMemory`).
    private var memoryPressure: SceneMemoryPressure?
    /// Runs authored effects through Wallpaper Engine's own shaders.
    lazy var effectGraph = EffectGraphRenderer(device: device, pipelineArchiveDirectory: pipelineArchiveDirectory)
    /// Where the effect pipeline archive lives (`EffectGraphRenderer`); nil keeps none.
    private let pipelineArchiveDirectory: URL?
    /// How much larger full detail (at least the authored size) would draw this frame's scene
    /// target: 1 unless Render Resolution draws the scene smaller than authored or Upscaling draws
    /// it at the render scale. The size effects on scene regions, and the bloom, stand for.
    var fullDetailScale: Float = 1
    /// This frame is drawn below its target size (`GSUpscaling`) and the final composite scales
    /// it up, so it can't be drawn straight into the output.
    var drawsAtRenderScale = false
    /// Bumped for every prelit image an effect chain starts from (`runEffects`).
    var prelitVersion: UInt64 = 0
    /// Times the effect passes when set (profiling; `EffectPassTimer`).
    var effectPassTimer: EffectPassTimer? {
        get { effectGraph?.passTimer }
        set { effectGraph?.passTimer = newValue }
    }
    /// Draws particle systems through their WE material.
    lazy var particleMaterials = ParticleMaterialRenderer(device: device)
    /// Draws image layers through their own WE material.
    lazy var imageMaterials = ImageMaterialRenderer(device: device, archive: effectGraph?.pipelineArchive)
    /// Draws Puppet Warp layers' meshes into their images (`ScenePuppetRenderer`).
    lazy var puppets: ScenePuppetRenderer? = {
        self.puppetsMade = true
        return ScenePuppetRenderer(device: self.device, archive: self.effectGraph?.pipelineArchive)
    }()
    /// Whether `puppets` was made: the pipeline checks ask it only then, so a scene without a
    /// puppet never makes it.
    var puppetsMade = false
    /// Puppet layers' images this frame, by layer id: what `textureFrame(for:)` hands out for them.
    var puppetAlbedos: [String: MTLTexture] = [:]
    /// Puppet layers' skeletons in motion, by layer id (`ScenePuppetAnimator`).
    var puppetAnimators: [String: ScenePuppetAnimator] = [:]
    /// A puppet without effects: its material's other textures laid out like its posed mesh, by
    /// layer id and texture key (`ScenePuppetRenderer.warp`).
    var puppetWarps: [String: [String: MTLTexture]] = [:]
    /// A puppet without effects: what of its mesh's space its image covers, which its quad grows
    /// to (`ScenePuppetCanvas`), by layer id.
    var puppetCanvases: [String: ScenePuppetCanvas] = [:]
    /// Asset textures used by effect passes, materialised once per content.
    var effectAssetTextures: [String: MTLTexture] = [:]
    /// Each decoded image's upload, by the image: layers, clones, particle systems and effect
    /// assets that load the same image (the loader hands them one `NSImage`) share one texture.
    /// Keyed weakly by the image itself, so an entry goes with the last copy of the image and the
    /// renderer never keeps the pixels alive; cleared with the content.
    let uploadedImages = NSMapTable<NSImage, UploadedFrames>(
        keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    final class UploadedFrames {
        let frames: [RenderTextureFrame]
        init(_ frames: [RenderTextureFrame]) { self.frames = frames }
    }
    let uploadedImagesLock = NSLock()
    /// Particle textures with their mip chains (`ParticleTextureMipmaps`), by the uploaded texture
    /// they were made from, which each entry holds so its identifier isn't reused. Under
    /// `uploadedImagesLock`; cleared with the content.
    var particleMipmaps: [ObjectIdentifier: (source: MTLTexture, chained: MTLTexture)] = [:]
    /// Animated asset textures' sprite frames, by the same key.
    var effectAssetFrames: [String: [RenderTextureFrame]] = [:]
    /// Textureless layers' effect inputs (`solidEffectInput`), by layer id; once per content.
    var solidEffectInputs: [String: MTLTexture] = [:]
    /// Solid layers' base passes for a last pass drawn into the scene (`solidSceneBase`), by layer
    /// id: the fill with the alpha it was made with, and its fill's count for `inputVersion`.
    var solidSceneBases: [String: (texture: MTLTexture, alpha: Float, version: UInt64)] = [:]
    var solidSceneBaseFills: UInt64 = 0
    /// The media system textures, while the content has a layer that shows one.
    var mediaTextures: SceneMediaTextures?
    /// Scene-input layers drawn through a 3D camera get the scene under them through this.
    lazy var regionProjection = SceneRegionProjection(device: device)
    /// Scene time since the content loaded, speed applied; drives animations, `g_Time`,
    /// particles and scripts alike.
    var clock = SceneClock()
    /// Test harnesses: while true the scene clock stands still (`SceneClock.hold`). The app never sets it.
    var holdsClock = false
    /// The frame being rendered only redraws the scene as it stands (`redrawShared`).
    var redrawing = false
    /// The renderer draws the live screen saver (`ScreenSaverLiveScene`): scripts see
    /// `engine.isScreensaver()` true. Set before the first frame.
    var rendersScreenSaver = false
    /// The renderer draws the Wallpaper Editor's canvas: scripts see `engine.isRunningInEditor()`
    /// true, as in Wallpaper Engine's editor. Set before the first frame.
    var runsInEditor = false
    /// While true the scene's clock text layers (`SceneClockLayers`) draw nothing: set for the
    /// Live Photo export (iOS draws its own clock) and while capturing the loading snapshot the
    /// lock screen shows.
    var hidesClockLayers = false
    /// While true the layers a still leaves out draw nothing: every text layer and the clock hands
    /// (`SceneClockLayers.stillIDs`), so a picture shown later never shows the time it was taken.
    /// Set only around a still's frame (`captureStill`).
    var hidesStillLayers = false
    /// The pointer every frame sees instead of the mouse, normalised over the scene with y up
    /// (`g_PointerPosition`; the centre is 0.5, 0.5); nil follows the mouse. A picture that is
    /// previewed and rendered (the iPhone & iPad Export) holds it fixed in both, so the camera and
    /// depth parallax, the cursor uniforms and the scripts' cursor are the same in each.
    var fixedPointer: SIMD2<Float>?
    /// The fixed pointer the camera parallax last reached: a new one is reached at once, not over
    /// `cameraparallaxdelay`, so a render starts where its preview has settled.
    var parallaxSettledPointer: SIMD2<Float>?
    /// The current content's clock text layers.
    var clockLayerIDs: Set<String> = []
    /// The current content's layers a still leaves out (`hidesStillLayers`): its text layers and
    /// clock hands. Layers scripts make later are left out by kind (`hiddenFromFrame`).
    var stillLayerIDs: Set<String> = []
    /// The frames drawn (`BuiltinFrameContext.serial`).
    var frameSerial: UInt64 = 0
    /// The wall clock `clock` follows (tests step it).
    var wallTime: () -> CFTimeInterval = { CACurrentMediaTime() }
    /// The playback rate `clock` runs at, when set (tests); otherwise the Animation Speed of this
    /// instance's own property store (`ScenePlaybackSpeed`), WE's `rate`.
    var playbackRate: (() -> Double)?
    /// Advances the audio spectrum by one frame at a playback rate: this renderer's own smoothing
    /// of the app's capture, made on the first frame (tests feed their own). Each renderer steps
    /// its own, so several scenes don't step one another's and a web page's never depends on them.
    var audioSpectrumFrame: (Double) -> AudioSpectrumSnapshot = {
        var clock: AudioSpectrumClock?
        return { (playbackRate: Double) -> AudioSpectrumSnapshot in
            let current: AudioSpectrumClock = clock ?? WallpaperServices.shared.makeAudioSpectrumClock(publishes: true)
            clock = current
            return current.advanceFrame(playbackRate: playbackRate)
        }
    }()
    /// The wallpaper is paused (the app's pause, or every display it shows on): the clock eases to
    /// a stop as WE's does (`SceneClock.paused`), and `onPlaybackStopped` fires on each frame drawn
    /// once it stood still, so the displays can stop drawing.
    var pausesPlayback = false
    var onPlaybackStopped: (() -> Void)?
    /// Runs `block` on the thread that owns this renderer's state (thread boundary): content and
    /// script objects prepared in the background land through it. The main queue by default, for a
    /// renderer drawn by its view's own timer; a scene instance's renderer uses its render thread.
    /// A render loop owns this renderer (`SceneRenderLoop`): a frame anywhere but its render
    /// thread is a thread-guard hit. Without one (tests, prewarm) the thread drawing it counts as
    /// the render thread while it draws. Set once, before the first frame.
    var drawsOnRenderThreadOnly = false
    var performOnRenderThread: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// The paused clock has eased to a stop.
    var hasStoppedPlayback: Bool { clock.hasStopped }
    /// A script's fog on/off switch was reported (`frameLighting`).
    var loggedFogToggle = false

    /// Scene seconds since the content loaded, rate applied (`g_Time`).
    var sceneTime: Double { clock.time }
    /// Mixed into the seed of every particle system the next content prepares. 0 replays a
    /// wallpaper's particles the same way each time; another value draws another random outcome
    /// (tests average a system of a few particles over several).
    var particleSeed: UInt32 = 0
    /// The wallpaper instance's timelines and texture clocks (docs/timeline-plan.md §2), advanced
    /// once per frame by `clock`'s delta, before the scripts run.
    let timelines = SceneRendererAnimations()
    /// The instance's `SceneAnimationSet`; nil without a scene document.
    var animations: SceneAnimationSet? { timelines.set }
    /// Records what each frame draws while set (tests and diagnostics, `SceneDrawProbe`).
    var drawProbe: SceneDrawProbe?
    let contentQueue = DispatchQueue(label: "SceneMetalRenderer.content", qos: .userInitiated)
    let contentGenerationLock = NSLock()
    var contentGeneration = 0
    var sceneSize = SIMD2<Float>(1920, 1080)
    var layers: [PreparedLayer] = [] {
        didSet { layerCompositeOrder = nil }
    }
    /// Which layers other layers' effects sample, and the order that prepares them first; made
    /// again whenever `layers` changes.
    var layerCompositeOrder: SceneLayerCompositeOrder?

    var particleSystems: [ParticleSystemRuntime] = [] {
        didSet { emitterImages.noteSystems(particleSystems) }
    }
    /// `layerimage` emitters' rigged layers and resampling (`SceneEmitterImages`).
    lazy var emitterImages = SceneEmitterImages(device: device, queue: commandQueue) { [weak self] block in
        self?.performOnRenderThread(block)
    }
    /// Steps particle systems on the GPU; nil when it couldn't be made (logged), and then no
    /// particle system draws.
    let particleSimulator: ParticleGPUSimulator?
    /// This frame's GPU steps, reused across frames.
    var particleRequests: [ParticleGPUSimulator.Request] = []
    /// The wallpaper instance's scripts and what their last frame left.
    let scripts: SceneRendererScripts
    /// The scene's sound layers; the view sets their gain (`sounds.setTargetGain`).
    let sounds: SceneSoundLayers
    /// Particle systems and sounds scripts created, by object id, kept across content rebuilds
    /// like `scriptLayers`.
    var scriptParticles: [String: (systems: [ParticleSystemRuntime], motion: SceneObjectMotion)] = [:]
    var scriptSounds: [Int: SceneSoundContent] = [:]
    /// Layers scripts created (`thisScene.createLayer`), kept across content rebuilds, by id, with
    /// their base `visible`.
    var scriptLayers: [String: (entry: PreparedLayer, visible: Bool)] = [:]
    /// Model objects scripts created, by id: the model, its 3D node and its motion.
    var scriptModels: [String: ScriptModel] = [:]
    typealias ScriptModel = (model: SceneModelObject, node: SceneTransformHierarchy3D.Node, motion: SceneObjectMotion)
    /// Layers scripts destroyed while they were still being built.
    var destroyedScriptLayers = Set<String>()
    /// Parents scripts set (`ILayer.setParent`), by object id, kept across content rebuilds like
    /// `scriptLayers`: the parent's id (nil: a root) and the attachment it hangs from.
    var scriptParents: [String: (parent: String?, attachment: String?)] = [:]
    /// `emitParticles` counts waiting for their system's next step, by object id.
    var pendingEmits: [String: Int] = [:]
    /// How many particle systems are drawn (tests, diagnostics).
    var particleSystemCount: Int { particleSystems.lazy.filter { $0.simulation == nil }.count }
    /// Layers drawn through their material, and prelighting passes run (tests, diagnostics).
    var imageMaterialDraws: Int { imageMaterials?.drawsEncoded ?? 0 }
    var imageMaterialPrelitDraws: Int { imageMaterials?.prelitDraws ?? 0 }
    /// Per layer id, the draws of a layer with a material plan that fell back to the native draw
    /// (its pipeline compiling or failed, or an input missing) (tests, diagnostics).
    var imageMaterialFallbacks: [String: Int] = [:]
    /// Puppet meshes drawn into their images (tests, diagnostics).
    var puppetMeshDraws: Int { puppets?.drawsEncoded ?? 0 }
    /// A puppet layer's image once its mesh has been drawn, and the texture the mesh samples (tests,
    /// diagnostics).
    func puppetImage(ofLayer id: String) -> (source: MTLTexture, image: MTLTexture)? {
        guard puppets?.hasDrawn(id) == true, let image = puppetAlbedos[id],
              let source = layers.first(where: { $0.layer.id == id })?.frames.first?.texture else { return nil }
        return (source, image)
    }
    /// Whether the posed mesh has laid a puppet layer's effect output out (tests, diagnostics). A
    /// rig that rearranges an atlas runs its effects on its texture and draws no image of its own.
    func puppetLaidOutEffects(ofLayer id: String) -> Bool { puppets?.hasLaidOut(id, key: "_effects") == true }
    /// A puppet layer's pose as its image was last drawn (tests, diagnostics).
    func puppetPose(ofLayer id: String) -> ScenePuppetPose? { puppetAnimators[id]?.pose }
    /// The pose `puppetImage(ofLayer:)` holds: the bind pose for a layer with effects, which the
    /// posed mesh lays out after them (`posedEffectOutput`); the layer's pose otherwise.
    func puppetImagePose(ofLayer id: String) -> ScenePuppetPose? {
        guard let pose = puppetPose(ofLayer: id) else { return nil }
        return puppetHasEffects(id) ? .bind(boneCount: pose.bones.count) : pose
    }
    /// What of a puppet's mesh space `puppetImage(ofLayer:)` covers, when not the image's rect
    /// (tests, diagnostics): a layer with effects draws its bind pose into the image's rect, and
    /// only the posed layout of their output covers the canvas.
    func puppetCanvas(ofLayer id: String) -> ScenePuppetCanvas? { puppetHasEffects(id) ? nil : puppetCanvases[id] }
    private func puppetHasEffects(_ id: String) -> Bool {
        layers.first { $0.layer.id == id }.map { !$0.layer.weEffects.isEmpty } ?? false
    }
    /// Effect passes encoded so far, for tests.
    var effectPassesEncoded: Int { effectGraph?.passesEncoded ?? 0 }
    /// Whether an effect pipeline is still compiling (shader prewarm waits for them).
    var hasPendingEffectPipelines: Bool { effectGraph?.hasPendingPipelines ?? false }

    /// One live particle as the last committed step left it (tests, diagnostics).
    struct ParticleSample {
        var age: Float
        var lifetime: Float
        var size: Float
        var alpha: Float
        var color: SIMD4<Float>
    }

    /// Every particle system's particles by scene object (a child under its family root's id),
    /// read back from the GPU state (none before a system's first step). Blocks until the GPU is done.
    func particleSamples() -> [(objectID: String?, particles: [ParticleSample])] {
        particleSystems.map { system in
            let states = particleSimulator?.snapshot(system, queue: commandQueue) ?? []
            return (particleObjectID(system), states.map {
                ParticleSample(age: $0.life.x, lifetime: $0.life.y, size: $0.life.z, alpha: $0.alphaRotation.x,
                               color: $0.color)
            })
        }
    }
    /// The last frame's scene target, before the post-process (tests, diagnostics).
    var lastSceneTarget: MTLTexture? { sceneRenderTarget ?? lastDrawableScene }
    /// The drawable the last frame drew its scene straight into (S2), not held.
    weak var lastDrawableScene: MTLTexture?
    /// The bytes of the frame's own targets, by holder (diagnostics, test-risks LR10); the effect
    /// graph's layer and bloom buffers aren't among them.
    var frameTargetBytes: [String: Int] {
        ["scene target": sceneRenderTarget?.allocatedSize ?? 0,
         "mip-mapped frame buffer": mipMappedFrameBuffer?.texture?.allocatedSize ?? 0,
         "target pool (snapshots, regions)": renderTargetPool.residentBytes,
         "volumetrics": volumetrics?.residentBytes ?? 0,
         "prelit images": imageMaterials?.prelitBytes ?? 0,
         "puppet images": puppets?.allocatedBytes ?? 0,
         "scene depth": depthBuffer.residentBytes,
         "planar reflection": planarReflection?.residentBytes ?? 0]
    }
    /// A drawn layer's effect plans (tests, diagnostics).
    func effectPlans(ofLayer id: String) -> [SceneEffectPlan] {
        layers.first { $0.layer.id == id }?.layer.weEffects ?? []
    }
    /// Script-created layers still being built (tests wait for them).
    var pendingScriptLayers = 0
    /// Rebuilt objects (`replaceObjects`) being prepared.
    var pendingReplacements = 0
    /// The last `setContent` has been applied (its layers and scripts are in place).
    var hasContent = false
    /// A frame of the content has been drawn with every pass in it: none waited on a pipeline
    /// still compiling, a script layer being built or text being rasterised. The first frames
    /// after `hasContent` draw what is ready and skip the rest, so they can show a darker or
    /// partial scene; a loading picture stays over the scene until this is set.
    var hasCompleteFrame = false
    /// Which object each authored scene index is, for the draw order scripts set.
    var objectIDs: [Int] = []
    var camera = SceneCameraEffects()
    /// The content's `general`, to resolve `camera` again when a user property bound to it
    /// changes (`refreshCamera()`); nil keeps the content's.
    var cameraGeneral: WESceneGeneral?
    /// `general.clearcolor` (`SceneMetalContent.clearColor`); a script's `thisScene.clearcolor` wins.
    var clearColor = SceneGeneralDefaults.clearColor
    /// `general.clearenabled` (`SceneMetalContent.clearEnabled`); a script's `thisScene.clearenabled` wins.
    var clearEnabled = true
    /// This frame keeps the last frame's scene (`clearenabled` off): its own scene target, loaded
    /// instead of cleared, and the pass's samples and depth stored.
    var keepsScene = false
    /// The scene targets (colour, samples, depth) the last frame that kept its scene drew into:
    /// a frame loads them only while they are the same textures; new ones start cleared.
    var keptSceneTargets: [ObjectIdentifier?] = []
    /// WE's parallax camera position, eased across frames (`SceneCameraParallax`).
    var cameraParallax = SceneCameraParallax(sceneSize: SIMD2<Float>(1920, 1080))
    /// Whose user properties this renderer's frames read (see `SceneMetalContent.wallpaperKey`).
    var wallpaperKey = ""
    /// What the objects' and effects' visibility follows (`SceneMetalContent.userVisibility`).
    var userVisibility = SceneUserVisibility()
    /// Each object's binding revision (`SceneBindingRevisions`), bumped by property changes.
    var bindingRevisions = SceneBindingRevisions()
    /// Layers' base values (`baseValues`) by layer id, per binding revision.
    var baseValueCaches: [String: SceneBindingCache<SceneLayerBaseValues>] = [:]
    /// The Wallpaper Editor's live edits over the built content (`SceneEditorLive`).
    var editorLive = SceneEditorLive()
    /// `editorLive`'s revision the frame analysis last saw: a live edit redraws an idle scene.
    var analysedEditorRevision = 0
    /// A perspective scene's camera as the last frame drew it, for the Wallpaper Editor's 3D gizmo.
    /// Its lock owns it alone, so the main thread reads it (`lastPerspectiveCamera`) while the
    /// render thread draws.
    let perspectiveCameraLock = NSLock()
    var perspectiveCamera: SceneFrameCamera?
    var lastPerspectiveCamera: SceneFrameCamera? { perspectiveCameraLock.withLock { perspectiveCamera } }
    /// The puppets' posed hit boxes, for the Wallpaper Editor's Show Hitboxes (its own lock).
    let puppetHitBoxes = ScenePuppetHitBoxFeed()
    var placement: WallpaperPlacement = .fill
    /// Drawable pixels per view point (the backing scale), refreshed every frame.
    var drawablePixelsPerPoint: Float = 1
    /// Last frame's normalised pointer, for `g_PointerPositionLast`; nil until the first frame.
    var lastPointer: SIMD2<Float>?
    /// Where the cursor was last seen on this renderer's display.
    var cursorTracker = SceneCursorTracker()
    var bloom = SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3<Float>(repeating: 1))
    /// The scene's lighting settings and light objects (`SceneMetalContent.lighting`).
    var lighting = SceneLightingContent()
    /// Where each frame's camera comes from (`SceneCameraRigs.make(for:)`).
    var cameraRig: any SceneCameraRig = SceneOrthographicCameraRig()
    /// Every object's authored 3D transform (`SceneSpatialContent.transforms`), for the rig's live values.
    var cameraTransforms = SceneTransformHierarchy3D.empty
    /// The content's 3D side (`SceneSpatialContent`): projection, draw order, the 3D hierarchies,
    /// model objects and the objects' `sortorder`/`depthtest`.
    var spatial = SceneSpatialContent()
    /// Draws model objects at their place in the object loop (docs/models-plan.md M5); nil draws none.
    var modelDrawing: (any SceneModelDrawing)?
    /// Draws the frame's shadow maps into `_rt_shadowAtlas` (docs/models-plan.md §2.10).
    private(set) var shadowPass: SceneShadowPass?
    /// This frame's `_rt_shadowAtlas` (`drawShadows`).
    var frameShadowAtlas: MTLTexture?
    /// Draws `_rt_Reflection` (docs/models-plan.md §2.11), and this frame's (`drawReflection`).
    private(set) var planarReflection: ScenePlanarReflection?
    var frameReflection: MTLTexture?
    /// WE's depth-stencil states and this frame's depth buffer (docs/models-plan.md §2.4): a
    /// perspective scene's pass has one.
    lazy var depthStates = SceneDepthStates(device: device)
    lazy var depthBuffer = SceneDepthBuffer(device: device)
    /// The content is a perspective scene (`SceneCameraEffects.orthographic`, from `general`'s
    /// projection): its objects draw through the frame camera. A content made without a scene
    /// document (a preview, tests) is orthographic.
    var isPerspective: Bool { !camera.orthographic }
    /// This frame's depth attachment format (`.invalid`: the pass has none).
    var sceneDepthFormat = MTLPixelFormat.invalid
    /// The depth states for this frame's draws; nil when the pass has no depth.
    var frameDepth: SceneDepthStates? { sceneDepthFormat == .invalid ? nil : depthStates }
    /// Each object's own 3D transform this frame (`live3D`), evaluated once.
    var frameLocals3D: [String: SceneLocalTransform3D] = [:]
    /// This frame's orthographic zoom (`orthographicZoom()`), taken with the transforms.
    var frameZoom = SceneOrthographicZoom.none
    /// `collisionmodel` targets already reported as not collidable (`particleCapsules`).
    var reportedCollisionTargets = Set<String>()
    /// The user's quality settings (post-processing, reflection, shadows, volumetrics); the view sets them.
    var renderSettings = SceneRenderSettings()
    /// The target follows a live-resizing window (the editors' previews): its pixels per unit are
    /// quantised so a resize doesn't reallocate it every frame (`SceneRenderResolution`). Off, the
    /// target is exactly the size Render Resolution asks for. Set before the first frame.
    var followsLiveResize = false
    var sceneRenderTarget: MTLTexture?
    /// The scene pass's multisampled target with WE's MSAA setting, resolved into `sceneRenderTarget`
    /// at the end of every stretch of the pass (WE's `_rt_FullFrameBufferMultiSampled`).
    var sceneMultisampleTarget: MTLTexture?
    /// This frame's scene-pass samples per pixel (1 without MSAA).
    var sceneSampleCount = 1
    /// This frame's prelit images (`prelit`), by layer id.
    var prelitImages: [String: MTLTexture] = [:]
    /// Animated layers' current frames, cut out of their atlases for their effects (`effectInput`).
    lazy var spriteFrameInputs = SceneSpriteFrameInputs(device: device)
    /// This frame's cut-out frame versions (`SceneSpriteFrameInputs.Input.version`), by layer id.
    var spriteFrameVersions: [String: UInt64] = [:]
    /// A shared scene's finished frame, the scene target's size (`sharedFrame`).
    var sharedFrameTarget: MTLTexture?
    var sceneRenderTargetSize = SIMD2<Int>.zero
    /// Whether the drawable's size has settled, for an exactly sized scene target (S1).
    /// Render-target pixels per scene unit this frame (see `SceneRenderResolution`).
    var renderPixelsPerUnit: Float = 1
    /// Rendered text, by string and style. Capped at 128 entries and 32 MB of rasters not drawn this
    /// frame: a clock with seconds never reuses its old strings, and at 128 entries of ~1.5 MB (a
    /// 1000x300 px raster plus its coverage) it held ~190 MB, 300 MB or more on Retina/5K. 32 MB
    /// still keeps 20 such rasters (and the full 128 small labels) for scripts that cycle or toggle
    /// strings; every string a frame draws stays regardless (`beginGeneration`).
    var textFrameCache = SceneLRUCache<String, SceneTextRasterResult>(
        capacity: 128, costLimit: SceneMetalRenderer.textCacheByteBudget)
    static let textCacheByteBudget = 32 << 20
    /// Rasterises changed strings off the render thread (`SceneTextRasterQueue`).
    let textRaster: SceneTextRasterQueue
    /// Changed strings still rasterising or waiting for a frame to take them (for tests).
    var pendingTextRasters: Int { textRaster.inFlight }
    /// Each text layer's raster scale: quantised and retained while it animates, exact once it
    /// settles (`SceneTextRasterScale.Tracker`).
    var textRasterScales: [String: SceneTextRasterScale.Tracker] = [:]
    /// Parent graph of the current content; layer origins are relative to their parents.
    var transforms = SceneTransformHierarchy.empty
    /// Each layer's local transform, evaluated once per frame so a parent's scripts run once
    /// however many children read it.
    var frameLocals: [String: SceneLocalTransform] = [:]
    var layerIndexByStateId: [String: Int] = [:]
    /// Objects that aren't drawn layers (groups, particle systems), by id: their live transform.
    var objectMotions: [String: SceneObjectMotion] = [:]
    /// The most recently committed frame, so state a removal frees can wait for it.
    var lastCommandBuffer: MTLCommandBuffer?
    /// A shared scene's latest finished frame (`renderShared`), which its displays present.
    var sharedFrame: MTLTexture?
    /// The last `present(in:)`'s command buffer (tests and benchmarks).
    var lastPresentCommandBuffer: MTLCommandBuffer?
    /// Counts this renderer's frames while the Wallpaper Editor's stats overlay shows them; nil,
    /// counting nothing, the rest of the time (`SceneFrameStatsRecorder`).
    var frameStats: SceneFrameStatsRecorder?
    /// The CPU time of the frame's particle step and its light objects, for `frameStats`.
    var particleStepMilliseconds = 0.0
    var lastLightCount = 0
    /// A screen's EDR headroom (tests set their own); a view without a window has none.
    var displayHeadroom: (NSScreen?) -> SceneDisplayHeadroom = { SceneDisplayHeadroom(screen: $0) }

    /// `view`'s screen's headroom: from its main-thread snapshot when a render thread draws it.
    func viewHeadroom(_ view: MTKView) -> SceneDisplayHeadroom {
        SceneViewSnapshots.snapshot(of: view)?.headroom ?? displayHeadroom(view.window?.screen)
    }
    /// How the last frame reached the display (`SceneDisplayOutput`).
    var displayOutput = SceneDisplayOutput.standard
    /// The headroom of each view a shared frame was presented on since the last one was drawn.
    var sharedHeadrooms: [ObjectIdentifier: SceneDisplayHeadroom] = [:]
    /// Destroyed script layers' ids, freed once the frame that last drew them completes.
    var deferredReleases = SceneDeferredReleases()
    /// Where the cursor was last seen on this display, in display pixels from the top-left.
    var lastCursorScreenPixels = SIMD2<Double>(repeating: 0)
    /// This renderer's view of the desktop's left clicks.
    var clickReader = DesktopClickReader()
    /// The last drawn frame's camera motion and text sizes (by layer id), for the next script frame.
    var lastCameraMotion: CameraMotion?
    /// The last drawn frame's camera, for the next script frame's cursor ray.
    var lastFrameCamera: SceneFrameCamera?
    /// Per-layer dependencies, coverage, class and this frame's dirty state
    /// (efficiency-plan-2d notes WP1-A); built with the content, off the main thread.
    var layerAnalysis: SceneLayerAnalysis?
    /// Keeps system audio capture on while the content reacts to audio (`needsAudio`).
    var audioCaptureLease: AudioCaptureLease?
    /// Adaptive rate and idle skipping (`FramePacing`, WP2-C): the instance sets its limits and
    /// ticks the displays at its rate; an idle frame returns before anything is encoded.
    var framePacing = FramePacing()
    /// Bumped when a video layer has a new frame (`SceneLayerFrameInputs.videoRevision`).
    var videoRevision: UInt64 = 0
    var analysedTime: Double = 0
    /// Off with `OWE_IDLE_SKIP=0` (comparisons, Debug builds): every frame is drawn, the rate still adapts.
    #if DEBUG
    var skipsIdleFrames = ProcessInfo.processInfo.environment["OWE_IDLE_SKIP"] != "0"
    #else
    var skipsIdleFrames = true
    #endif
    /// Frames encoded so far: a shared scene's displays present only a new one.
    var encodedFrames: UInt64 = 0
    var pacedParallax = SIMD2<Float>(0.5, 0.5)
    /// What the analysis last saw of the frame's shape: a change marks every layer dirty.
    var analysedShape: (layers: Int, target: SIMD2<Float>) = (0, .zero)
    /// A pipeline was compiling last frame: the frame after one lands changes too.
    var analysedWarmUp = true
    /// `pipelinesLanded` as the last analysed frame saw it.
    var analysedLanded = 0
    /// `scripts.userVisibilityRevision` the analysis last saw.
    var analysedUserVisibility = 0
    /// The blur-like buffer divisor (1, 2, 4) over the slider's (`OWE_BLUR_DIVISOR` for comparisons, Debug
    /// builds).
    #if DEBUG
    var blurDivisorOverride = ProcessInfo.processInfo.environment["OWE_BLUR_DIVISOR"].flatMap(Int.init)
    #else
    var blurDivisorOverride: Int? = nil
    #endif
    func effectResolution(of layerID: String) -> EffectResolutionPolicy {
        let divisor = blurDivisorOverride ?? framePacing.limits.policy.blurResolutionDivisor
        guard divisor > 1 else { return .full }
        let layer = layerAnalysis.flatMap { analysis in analysis.index(of: layerID).map { analysis.layers[$0] } }
        let sharp = layer.map { $0.contentClass == .text || ($0.contentClass == .lineArt && $0.classifiedFromPixels) } ?? false
        return EffectResolutionPolicy(divisor: divisor, sharpContent: sharp)
    }
    var lastTextSizes: [String: SIMD2<Float>] = [:]
    /// Told how long each frame took on the CPU, including the wait for a drawable.
    var frameTimeObserver: ((CFTimeInterval) -> Void)?

    /// A renderer that draws into `view` itself (`draw(in:)`). `scriptServices` runs the scenes'
    /// SceneScripts (nil runs none); `screenID` names the display whose script storage they use.
    convenience init?(view: MTKView, scriptServices: SceneScriptServices? = nil,
                      screenID: String = "", pipelineArchiveDirectory: URL? = EffectPipelineArchive.defaultDirectory) {
        self.init(pixelFormat: view.colorPixelFormat,
                  scriptServices: scriptServices, screenID: screenID, pipelineArchiveDirectory: pipelineArchiveDirectory)
        configure(view)
        // Drawn by the view's own timer, on the main thread.
        view.isPaused = false
        view.delegate = self
    }

    /// A renderer for drawables of `pixelFormat`. A shared scene's displays each show its frames
    /// through their own view (`configure`, `renderShared`, `present(in:)`).
    init?(pixelFormat: MTLPixelFormat,
          scriptServices: SceneScriptServices? = nil, screenID: String = "",
          pipelineArchiveDirectory: URL? = EffectPipelineArchive.defaultDirectory) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = SceneMetalLibrary.make(device: device),
              let vertex = library.makeFunction(name: "sceneVertex"),
              let fragment = library.makeFunction(name: "sceneFragment"),
              let placedVertex = library.makeFunction(name: "sceneVertex3D"),
              let copyFragment = library.makeFunction(name: "sceneCopyFragment"),
              let decode = library.makeFunction(name: "decodeDXT"),
              let decodePipeline = OWELog.attempt(.scene, "The DXT decode pipeline can't be made", {
                  try device.makeComputePipelineState(function: decode)
              }) else {
            return nil
        }

        let descriptor = SceneLayerPipelines.layerDescriptor(vertex: vertex, fragment: fragment, format: pixelFormat)
        let layerPipelines: SceneLayerPipelines
        do {
            // The drawable's format, and the HDR scene target's (docs/lighting-plan.md §2.6).
            layerPipelines = try SceneLayerPipelines(device: device, vertex: vertex, fragment: fragment,
                                                     copyFragment: copyFragment, placedVertex: placedVertex,
                                                     formats: [pixelFormat, .rgba16Float])
        } catch {
            OWELog.error(.scene, "The scene pipelines can't be made: \(error)")
            return nil
        }

        guard let postProcess = ScenePostProcess(device: device, layerDescriptor: descriptor) else {
            return nil
        }

        do {
            particleSimulator = try ParticleGPUSimulator(device: device)
        } catch {
            OWELog.error(.scene, "The GPU particle simulation can't be made, so no particle system draws: \(error)")
            particleSimulator = nil
        }
        self.device = device
        self.pipelineArchiveDirectory = pipelineArchiveDirectory
        self.pixelFormat = pixelFormat
        self.copyPipeline = layerPipelines.pipelines(for: pixelFormat).copy
        self.postProcess = postProcess
        let frameStages = SceneFrameStages.make(device: device)
        self.frameStages = frameStages
        self.mipMappedFrameBuffer = frameStages.lazy.compactMap { $0 as? SceneMipMappedFrameBuffer }.first
        self.commandQueue = commandQueue
        self.layerPipelines = layerPipelines
        self.dxtDecodePipeline = decodePipeline
        self.textureLoader = MTKTextureLoader(device: device)
        self.textRaster = SceneTextRasterQueue(device: device, loader: textureLoader)
        self.renderTargetPool = SceneRenderTargetPool(device: device)
        scripts = SceneRendererScripts(services: scriptServices, screenID: screenID)
        sounds = SceneSoundLayers(label: screenID.isEmpty ? "sounds" : "sounds \(screenID)")
        super.init()
        // Created objects are built on the script thread, so they draw in the frame that made them.
        scripts.prepareCreated = { [weak self] created, id in self?.prepare(created, id: String(id)) }
        modelDrawing = SceneModelRenderer(device: device, archive: effectGraph?.pipelineArchive)
        shadowPass = SceneShadowPass(device: device, archive: effectGraph?.pipelineArchive)
        planarReflection = ScenePlanarReflection(device: device)
        memoryPressure = SceneMemoryPressure { [weak self] level in self?.trimMemory(level) }
        sounds.locate = { [weak self] id in self?.soundWorldPosition(id) }
    }

    /// Sets `view` up to show this renderer's frames, on its device. It leaves the view's own timer
    /// as it is: a scene instance's view stays paused, drawn only by its link on the render thread
    /// (`SceneRenderLoop`). Its delegate is whoever draws it: this renderer, or a shared scene's presenter.
    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = pixelFormat
        view.framebufferOnly = false
        // The composite never wrote the drawable's alpha; a scene drawn straight into it (S2)
        // does, and the desktop shows colour only.
        view.layer?.isOpaque = true
        view.enableSetNeedsDisplay = false
    }

    /// Drops what can be rebuilt under memory pressure: free pooled targets, cached text other than
    /// the layers' current strings, spare effect targets and free uniform chunks; when critical,
    /// also effect asset textures and pipelines idle since the last critical trim. Leased and
    /// persistent targets, layers' own targets and anything the current frame uses stay.
    func trimMemory(_ level: SceneMemoryPressure.Level) {
        let before = renderTargetPool.residentBytes
        renderTargetPool.removeAll()
        textFrameCache.trim(to: layers.filter { $0.layer.text != nil }.count)
        effectGraph?.trimMemory(dropIdlePipelines: level == .critical)
        imageMaterials?.trimMemory(dropIdlePipelines: level == .critical)
        puppets?.trimMemory()
        particleMaterials?.trimMemory(dropIdlePipelines: level == .critical)
        if level == .critical {
            effectAssetTextures.removeAll()
            effectAssetFrames.removeAll()
            solidEffectInputs.removeAll()
            solidSceneBases.removeAll()
            clearUploadedImages()
        }
        OWELog.info(.scene, "Memory pressure (\(level)): freed \((before - renderTargetPool.residentBytes) >> 20) MB of pooled targets")
    }

    /// User properties `names` changed: the scripts get `applyUserProperties`. With
    /// `applyVisibility` (while the user edits properties) objects and effects follow their
    /// user-bound `visible` at once, without a content rebuild (`SceneLiveBindingSites`).
    /// User properties `names` changed: the scripts get them (`applyUserProperties`), the owners of
    /// the bindings that read them (`UserPropertyBindingTable.changes(for:)`) move to a new binding
    /// revision, which every cache baking a bound value keys on, and the visibility is taken again.
    /// Structural changes arrive separately, as rebuilt objects (`replaceObjects`).
    func userPropertiesDidChange(_ names: Set<String>, owners: Set<UserPropertyBindingOwner>) {
        scripts.userPropertiesDidChange(names)
        guard !owners.isEmpty else { return }
        if owners.contains(.scene) { refreshCamera() }
        bindingRevisions.bump(owners)
        refreshParticleRevisions()
        applyUserVisibility()
        framePacing.wake(.interactive, at: wallTime())
    }

    /// Resolves `general.camera…` against the current user properties: a property bound to
    /// them applies from the next frame, without a content rebuild (`cameraMotion`).
    private func refreshCamera() {
        guard let cameraGeneral else { return }
        camera = SceneCameraEffects(cameraGeneral, in: LiveSceneValueContext(wallpaper: wallpaperKey))
    }

    /// Resolves the content's visibility against the current user properties (`SceneUserVisibility`).
    func applyUserVisibility() {
        guard !userVisibility.sites.isEmpty else { return }
        let key = wallpaperKey
        let resolved = userVisibility.resolve { WallpaperServices.shared.userPropertyString($0, wallpaper: key) }
        scripts.applyUserVisibility(objects: resolved.objects, effects: resolved.effects)
    }

    /// The Wallpaper Editor's edits since the content was built, drawn from the next frame; nil or
    /// empty draws the content as built.
    func setEditorLiveValues(_ values: SceneEditLiveValues?) {
        let next = SceneEditorLive(values ?? SceneEditLiveValues(), revision: editorLive.revision &+ 1)
        guard !(next.isEmpty && editorLive.isEmpty) else { return }
        editorLive = next
        frameLocals.removeAll(keepingCapacity: true)
        framePacing.wake(.interactive, at: wallTime())
    }

    /// Drops every prepared layer, releasing any video stream those layers hold.
    func releaseContent() {
        setContent(nil)
    }

    /// Whether this frame leaves `layer` out: a clock layer while `hidesClockLayers`, a text layer
    /// or clock hand while `hidesStillLayers`.
    func hiddenFromFrame(_ layer: SceneMetalLayer) -> Bool {
        (hidesClockLayers && clockLayerIDs.contains(layer.id))
            || (hidesStillLayers && (layer.text != nil || stillLayerIDs.contains(layer.id)))
    }

    /// Off with `OWE_COMPOSITE_SKIP=0` (comparisons, Debug builds): the composite always runs.
    #if DEBUG
    var skipsIdentityComposite = ProcessInfo.processInfo.environment["OWE_COMPOSITE_SKIP"] != "0"
    #else
    var skipsIdentityComposite = true
    #endif
    /// Frames drawn straight into their output, the composite skipped (tests, diagnostics).
    var compositesSkipped = 0
    /// Off with `OWE_NATIVE_DETAIL=0` (comparisons, Debug builds): every layer draws in the scene pass.
    #if DEBUG
    var promotesDetailLayers = ProcessInfo.processInfo.environment["OWE_NATIVE_DETAIL"] != "0"
    #else
    var promotesDetailLayers = true
    #endif
    /// Layers the last frame drew at the output's backing pixels (`SceneNativeDetailLayers`).
    var promotedDetailLayers = 0

    /// A 1 × 1 opaque white texture, for quads drawn in a flat colour.
    lazy var solidWhiteTexture: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        return texture
    }()
    /// This frame's images of the layers models and other layers sample, by layer id.
    var layerComposites: [String: MTLTexture] = [:]
}
