import Metal
import simd

/// WE's planar reflection, `_rt_Reflection` (docs/models-plan.md §2.11, lighting-plan C2).
///
/// - **Reflective objects:** a model whose material samples `_rt_Reflection` in the variant it
///   draws with (WE: the material pass's flags gather the render-target flags of the textures its
///   compiled shader uses, 0x140151ac2…0x140151c61, and the model builder turns flag 0x1 into
///   object feature 0x8, 0x1402252b9). `generic2`'s `g_Texture2` defaults to `_rt_Reflection`, but
///   only its `REFLECTION` variant samples it, so a `generic2` dome without the combo isn't reflective.
/// - **The target:** made while any model of the scene is reflective (the scene flag 0x1,
///   0x14018b26d), at the scene target's size and format, with its own depth (0x140181c65).
/// - **The pass** (0x140180357…0x1401808ff), after the shadow maps and before the scene pass: with
///   the user's `reflection` setting on, the view is multiplied by diag(1, −1, 1, 1), a mirror
///   across the world plane y = 0 with no offset and no clip plane (geometry below y = 0 lands in
///   the reflection too); the eye and the camera basis are mirrored and the winding flips; the
///   target is cleared to the clear colour and far depth, and the reflected list is drawn. With
///   the setting off the target is only cleared to the clear colour, every frame (0x14018089c).
/// - **The reflected list** (0x1401908f4…0x140190926): objects of the kinds WE's factory lists
///   (models, particle systems, images, sprites and texts; 0x14018ff60 clears the flag for lights,
///   sounds, cameras and shapes) with `reflected` (true unless it is authored as a literal `false`),
///   that aren't reflective. The pass calls each object's own draw (vtable +0x50, the one the scene
///   pass calls; nothing an object draws tells the passes apart: only the object loop reads the
///   main-pass flag, scene+0x468), so a layer or particle system draws through its material, with
///   the frame's built-ins mirrored. Models draw here; the renderer hands in the others' draws
///   (`Object.other`).
///
/// Materials sample it at their own screen position (`generic2`: `clip.xy / w · 0.5 + 0.5`); the
/// target is drawn through the same translated stages as the scene, so that is where the
/// reflection of what lies behind the fragment was drawn. Render thread only.
final class ScenePlanarReflection {
    static let name = "_rt_Reflection"
    /// WE's mirror (the matrix 0x1401844f0 builds at 0x140180477): y negated, in world space.
    static let mirror = simd_float4x4(diagonal: SIMD4(1, -1, 1, 1))

    private let device: MTLDevice
    private let depth: SceneDepthBuffer
    /// This content's target; nil while no model is reflective.
    private(set) var texture: MTLTexture?
    /// Whether each plan samples `_rt_Reflection`, by plan.
    private var reflectivePlans: [ObjectIdentifier: Bool] = [:]
    /// The model objects drawn into the target last frame, in order (tests, diagnostics).
    private(set) var drawnModels: [String] = []
    /// Every object drawn into the target last frame, models included, in order.
    private(set) var drawnObjects: [String] = []
    /// The depth and cull states of the layers and particle systems drawn here: the scene pass's
    /// with the other winding in front (`SceneDepthStates.mirrored`). Nil when they can't be made.
    let mirroredDepthStates: SceneDepthStates?

    init(device: MTLDevice) {
        self.device = device
        depth = SceneDepthBuffer(device: device, transient: true)
        mirroredDepthStates = SceneDepthStates(device: device, mirrored: true)
    }

    var residentBytes: Int { (texture?.allocatedSize ?? 0) + depth.residentBytes }

    /// A new content: its target is made again on its first frame, if it needs one.
    func setContent() {
        reflectivePlans.removeAll()
        release()
    }

    func release() {
        texture = nil
        depth.releaseAll()
        drawnModels.removeAll()
        drawnObjects.removeAll()
    }

    // MARK: - Objects

    /// Whether a model object is reflective: one of its meshes samples `_rt_Reflection`.
    func isReflective(_ model: SceneModelObject) -> Bool {
        guard let plan = model.plan else { return false }
        if let known = reflectivePlans[ObjectIdentifier(plan)] { return known }
        let reflective = Self.isReflective(plan)
        reflectivePlans[ObjectIdentifier(plan)] = reflective
        return reflective
    }

    static func isReflective(_ plan: SceneModelPlan) -> Bool {
        plan.meshes.contains { $0.material.passes.contains { samples($0.pass) } }
    }

    /// Whether a pass's variant samples `_rt_Reflection`.
    static func samples(_ pass: SceneEffectPassPlan) -> Bool {
        pass.textures.values.contains { if case .fbo(name) = $0 { return true } else { return false } }
    }

    /// `reflected`: only a literal `false` turns it off (0x1401908f9: any value that isn't a JSON
    /// bool, a user binding included, leaves it on).
    static func isReflected(_ model: SceneModelObject) -> Bool {
        isReflected(model.renderValues[.reflected])
    }

    static func isReflected(_ value: SceneRawValue?) -> Bool {
        guard case .bool(let flag)? = value else { return true }
        return flag
    }

    /// Whether the content needs the target: one of its models is reflective, visible or not.
    func isNeeded(_ models: [SceneModelObject]) -> Bool {
        models.contains(where: isReflective)
    }

    /// The reflected list among `models` (their indices, in their order): `reflected` and not
    /// reflective.
    func reflectedList(_ models: [SceneModelObject]) -> [Int] {
        models.indices.filter { Self.isReflected(models[$0]) && !isReflective(models[$0]) }
    }

    /// The frame camera mirrored across y = 0: view · mirror, the eye and the basis mirrored.
    static func mirrored(_ camera: SceneFrameCamera) -> SceneFrameCamera {
        var mirrored = camera
        mirrored.view = camera.view * mirror
        mirrored.eye = reflect(camera.eye)
        mirrored.forward = reflect(camera.forward)
        mirrored.up = reflect(camera.up)
        return mirrored
    }

    /// The frame's built-ins as the mirrored pass sees them.
    static func mirrored(_ frame: BuiltinFrameContext) -> BuiltinFrameContext {
        var mirrored = frame
        mirrored.camera = Self.mirrored(frame.camera)
        mirrored.eyePosition = reflect(frame.eyePosition)
        mirrored.viewForward = reflect(frame.viewForward)
        mirrored.viewUp = reflect(frame.viewUp)
        mirrored.viewRight = reflect(frame.viewRight)
        return mirrored
    }

    private static func reflect(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, -v.y, v.z) }

    // MARK: - The pass

    /// One object of the reflected list.
    enum Object {
        /// A model, drawn with its world matrix through `SceneModelDrawing`.
        case model(SceneModelObject, world: simd_float4x4)
        /// A layer or particle system, which the renderer draws through its material into the pass.
        case other(id: String, draw: (MirroredDraw) -> Void)
    }

    /// What a layer or particle system draws into the pass with.
    struct MirroredDraw {
        let encoder: MTLRenderCommandEncoder
        let commandBuffer: MTLCommandBuffer
        /// The frame's built-ins through the mirrored camera (`mirrored(_:)`).
        let frame: BuiltinFrameContext
        /// The target's format; the pass is single-sampled and has `SceneDepthStates.format` depth.
        let pixelFormat: MTLPixelFormat
        /// WE's depth states with the flipped winding (`mirroredDepthStates`).
        let depth: SceneDepthStates
    }

    /// What one frame's pass draws.
    struct Pass {
        /// The scene target's size and format.
        var width: Int
        var height: Int
        var pixelFormat: MTLPixelFormat
        /// `general.clearcolor` (or a script's `thisScene.clearcolor`).
        var clearColor: SIMD3<Float>
        /// The user's `reflection` setting.
        var enabled: Bool
        /// The visible reflected objects in draw order.
        var objects: [Object]
        /// The frame's built-ins, unmirrored.
        var frame: BuiltinFrameContext
        var values: SceneValueContext
        var mipMappedFrameBuffer: MTLTexture?
        var shadowAtlas: MTLTexture?
        var assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        var layerComposite: (String) -> MTLTexture? = { _ in nil }
    }

    /// Draws this frame's reflection and returns `_rt_Reflection`; nil (logged) when the target
    /// can't be made.
    func encode(_ pass: Pass, drawing: any SceneModelDrawing, depthStates: SceneDepthStates,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        drawnModels.removeAll(keepingCapacity: true)
        drawnObjects.removeAll(keepingCapacity: true)
        guard let target = target(width: pass.width, height: pass.height, pixelFormat: pass.pixelFormat) else { return nil }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(pass.clearColor.x), green: Double(pass.clearColor.y),
                                                                  blue: Double(pass.clearColor.z), alpha: 1)
        let drawsObjects = pass.enabled && !pass.objects.isEmpty
        if drawsObjects {
            guard depth.prepare(width: target.width, height: target.height, sampleCount: 1) else { return target }
            depth.attach(to: descriptor, clear: true)
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return target }
        encoder.label = "planar reflection"
        if drawsObjects {
            let frame = Self.mirrored(pass.frame)
            for object in pass.objects {
                switch object {
                case .model(let model, let world):
                    var draw = SceneModelDraw(world: world, camera: frame.camera, frame: frame, values: pass.values,
                                              pixelFormat: target.pixelFormat, sampleCount: 1, depth: depthStates,
                                              mipMappedFrameBuffer: pass.mipMappedFrameBuffer, assetTexture: pass.assetTexture,
                                              layerComposite: pass.layerComposite, shadowAtlas: pass.shadowAtlas)
                    draw.mirrored = true
                    drawing.draw(model, draw, encoder: encoder, commandBuffer: commandBuffer)
                    drawnModels.append(model.id)
                    drawnObjects.append(model.id)
                case .other(let id, let draw):
                    guard let mirroredDepthStates else { continue }
                    draw(MirroredDraw(encoder: encoder, commandBuffer: commandBuffer, frame: frame,
                                      pixelFormat: target.pixelFormat, depth: mirroredDepthStates))
                    drawnObjects.append(id)
                }
            }
        }
        encoder.endEncoding()
        return target
    }

    private func target(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        if let texture, texture.width == width, texture.height == height, texture.pixelFormat == pixelFormat { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: max(width, 1),
                                                                  height: max(height, 1), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Could not allocate the \(width)×\(height) \(Self.name); reflective materials draw nothing")
            texture = nil
            return nil
        }
        made.label = Self.name
        texture = made
        return made
    }
}
