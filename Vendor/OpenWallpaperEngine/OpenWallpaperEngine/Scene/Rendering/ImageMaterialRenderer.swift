import Metal
import simd

/// Draws image layers through their own WE material (`ImageMaterialPlan`) into the scene target,
/// the way WE draws an image object: the layer's quad, in scene units, through
/// `g_ModelViewProjectionMatrix`; `g_Texture0` is the layer image (its effects' output when it
/// has any) with the sprite frame in `g_Texture0Rotation/Translation`; the live colour, alpha and
/// brightness feed `g_Color4`, `g_Color`, `g_Alpha`, `g_UserAlpha` and `g_Brightness`; blending
/// comes from the material and `BLENDMODE` reads the scene drawn so far.
///
/// Pipelines compile off the render thread, like effect pipelines, and share their binary
/// archive. `draw` returns false until the pipeline is ready, or when it failed (logged once);
/// the caller then draws the layer natively. Call on the render thread, apart from the compiles.
final class ImageMaterialRenderer {
    private let device: MTLDevice
    private let archive: EffectPipelineArchive?
    private let zeroAttributes: MTLBuffer
    private let clampSampler: MTLSamplerState
    /// `_rt_shadowAtlas`'s comparison sampler (`SceneShadowAtlas.makeSampler`).
    private let shadowSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState
    /// A zero texel: `_alias_lightCookie` without a packed cookie spot (WE's alias is empty, which
    /// D3D reads as zeros).
    private let zeroTexture: MTLTexture
    /// Uniform blocks over 4 KB. Render thread only (see `SceneUniformArena`).
    let uniformArena: SceneUniformArena

    private let compileQueue = DispatchQueue(label: "owe.image-material-pipelines", qos: .userInitiated,
                                             attributes: .concurrent)
    /// Owns `pipelines`, `pending` and `failed`, which compile threads write.
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    /// Pipelines drawn with since the last `trimMemory` that dropped idle ones.
    private var usedPipelines = Set<String>()
    private var pending = Set<String>()

    /// Whether a pipeline is still compiling: a frame drawn now may change when it lands.
    /// Compiles finished so far, however they ended: a frame drawn before one landed is redrawn.
    var pipelinesLanded: Int {
        pipelineLock.withLock { landedPipelines }
    }
    private var landedPipelines = 0

    var hasPendingPipelines: Bool {
        pipelineLock.withLock { !pending.isEmpty }
    }
    private var failed = Set<String>()

    /// Uniform programs per layer instance (script clones share a plan but not a placement), rebuilt
    /// when the layer's plan changes. Render thread only.
    private var programs: [String: Program] = [:]

    /// The bytes of the layers' prelit and base images (diagnostics, test-risks LR10).
    var prelitBytes: Int {
        programs.values.reduce(0) { $0 + ($1.prelit?.allocatedSize ?? 0) + ($1.base?.allocatedSize ?? 0) }
    }

    private final class Program {
        let plan: ImageMaterialPlan
        let uniforms: ImageMaterialUniforms
        /// The prelighting pass's uniforms and its target (`prelight`).
        let prelightUniforms: ImageMaterialUniforms?
        var prelit: MTLTexture?
        /// The base pass (`base`): the material without blending, its uniforms, its target, and what
        /// its target holds (the input, its version and the uniform bytes it was drawn with).
        let basePass: SceneEffectPassPlan
        let baseUniforms: ImageMaterialUniforms
        var base: MTLTexture?
        var baseDrawn: (input: ObjectIdentifier, inputVersion: UInt64, bytes: [UInt8])?
        var baseVersion: UInt64 = 0
        /// Ignored native adjustments have been logged for this layer.
        var reportedIgnoredAdjustments = false

        init(plan: ImageMaterialPlan) {
            self.plan = plan
            uniforms = ImageMaterialUniforms(layout: plan.pass.variant?.uniforms, constants: plan.pass.constants,
                                             liveFactors: plan.liveFactors)
            basePass = plan.pass.blended("disabled")
            baseUniforms = ImageMaterialUniforms(layout: plan.pass.variant?.uniforms, constants: plan.pass.constants,
                                                 liveFactors: plan.liveFactors)
            prelightUniforms = plan.prelighting.map {
                ImageMaterialUniforms(layout: $0.variant?.uniforms, constants: $0.constants, liveFactors: plan.liveFactors)
            }
        }
    }

    /// Layers drawn through their material, for tests and diagnostics.
    private(set) var drawsEncoded = 0
    /// Prelighting passes encoded (`prelight`), for tests and diagnostics.
    private(set) var prelitDraws = 0
    /// Layer instances holding uniform state, for tests and diagnostics.
    var programCount: Int { programs.count }
    /// Compiled pipelines, shared by every layer drawing the same variant, format and blending.
    var pipelineCount: Int { pipelineLock.withLock { pipelines.count } }

    init?(device: MTLDevice, archive: EffectPipelineArchive?) {
        self.device = device
        self.archive = archive
        uniformArena = SceneUniformArena(device: device)
        guard let zero = device.makeBuffer(length: 64) else { return nil }
        zeroAttributes = zero
        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.sAddressMode = mode
            descriptor.tAddressMode = mode
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat),
              let shadow = SceneShadowAtlas.makeSampler(device: device) else { return nil }
        let zeroDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        zeroDescriptor.usage = .shaderRead
        guard let zeroTexel = device.makeTexture(descriptor: zeroDescriptor) else { return nil }
        zeroTexel.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4),
                          bytesPerRow: 4)
        zeroTexture = zeroTexel
        clampSampler = clamp
        shadowSampler = shadow
        repeatSampler = wrap
    }

    /// Drops per-plan state when the content changes. Compiled pipelines are kept.
    func releaseAll() {
        programs.removeAll()
    }

    /// One layer's draw this frame.
    struct Draw {
        /// The layer instance (its state id); per-layer uniform state is kept under it.
        let layerID: String
        /// World-space quad in scene units (y up), parents, scripts, animation and parallax included.
        let quad: SceneQuadGeometry
        let sceneSize: SIMD2<Float>
        let color: SIMD3<Float>
        let alpha: Float
        let brightness: Float
        /// `g_Texture0`: the layer image, or its effects' output.
        let texture: MTLTexture
        /// The image inside a padded texture (`g_Texture0Resolution.zw`); nil when it fills it.
        let contentSize: SIMD2<Float>?
        /// The sprite frame (or content crop) in `texture`'s UV space.
        let uvOrigin: SIMD2<Float>
        let uvAxisX: SIMD2<Float>
        let uvAxisY: SIMD2<Float>
        /// The scene drawn so far, for materials that blend with it (`BLENDMODE`).
        let sceneSnapshot: MTLTexture?
        /// `_rt_MipMappedFrameBuffer` (`SceneMipMappedFrameBuffer`), for a material that samples it
        /// (`REFLECTION`).
        var mipMappedFrameBuffer: MTLTexture? = nil
        /// `_rt_shadowAtlas` this frame (`SceneShadowAtlas`), for a lit material under a shadowed
        /// light budget (`genericimage4`'s `g_Texture6`).
        var shadowAtlas: MTLTexture? = nil
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// An animated asset texture's sprite frame this frame (`g_TextureNRotation/Translation`
        /// of a slot other than 0, which is the layer's own frame); nil for a still one.
        var assetSprite: ((String, SceneMetalTextureSource) -> BuiltinSpriteFrame?)? = nil
        /// The renderer's own adjustments (legacy material heuristics) are not neutral for this
        /// layer; the material's shader draws it without them. Logged once per layer.
        var ignoredAdjustments = false
        /// The layer drawn through a 3D camera (a perspective scene's, or a `perspective`
        /// layer's): its quad is `size` in object units through the object's world matrix and the
        /// camera (docs/models-plan.md §2.4) instead of `quad`.
        var placement: SceneLayerPlacement? = nil
        /// The depth and cull state the quad draws with where the pass has depth (`draw`'s
        /// `depth`): the material's first pass (`ImageMaterialPlan.raster`), or a text object's.
        var raster: SceneRasterState? = nil
    }

    /// Encodes the layer into `encoder` (a pass of `commandBuffer` on a `pixelFormat` target of
    /// `sampleCount` samples, with `depth`'s depth buffer when it has one). False when the layer
    /// must be drawn another way this frame: the pipeline is compiling or failed, or an input is
    /// missing. Leaves the encoder's pipeline state (and with `depth`, its depth and cull state) changed.
    func draw(_ plan: ImageMaterialPlan, _ draw: Draw, pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
              depth: SceneDepthStates? = nil, encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) -> Bool {
        let depthFormat = depth == nil ? MTLPixelFormat.invalid : SceneDepthStates.format
        guard plan.pass.variant != nil,
              let pipeline = pipeline(for: plan.pass, material: plan.materialPath, pixelFormat: pixelFormat,
                                      sampleCount: sampleCount, depthFormat: depthFormat) else { return false }
        let extent = draw.placement?.size ?? draw.quad.extent
        // A zero-area quad covers no pixels; nothing to draw, and nothing for a fallback to draw either.
        guard extent.x > 0, extent.y > 0, extent.x.isFinite, extent.y.isFinite else { return true }
        guard let textureInfo = textures(of: plan.pass, plan: plan, draw) else { return false }

        let program = program(for: plan, layerID: draw.layerID)
        if draw.ignoredAdjustments, !program.reportedIgnoredAdjustments {
            program.reportedIgnoredAdjustments = true
            OWELog.info(.scene, "Layer \(draw.layerID) draws through \(plan.materialPath); its legacy material adjustments are not applied")
        }
        let uniforms = program.uniforms
        if uniforms.size > 0 {
            let model = draw.placement?.world ?? Self.modelMatrix(draw.quad)
            let viewProjection = draw.placement?.shaderViewProjection ?? Self.sceneViewProjection(draw, depth: depth)
            let rotation = SIMD4<Float>(draw.uvAxisX.x, draw.uvAxisX.y, draw.uvAxisY.x, draw.uvAxisY.y)
            let key = ImageMaterialUniforms.PassKey(
                model: model, viewProjection: viewProjection, color: draw.color, alpha: draw.alpha,
                brightness: draw.brightness, spriteRotation: rotation, spriteTranslation: draw.uvOrigin,
                screen: draw.frame.screenSize,
                textures: textureInfo.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                                  $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) },
                sprites: textureInfo.compactMap(\.sprite))
            uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                var pass = BuiltinPassContext(targetSize: draw.sceneSize)
                pass.modelMatrix = model
                pass.viewProjection = viewProjection
                pass.modelViewProjection = viewProjection * model
                if let placement = draw.placement { pass.place(placement) }
                pass.color = draw.color
                pass.alpha = draw.alpha
                pass.userAlpha = draw.alpha
                pass.brightness = draw.brightness
                for entry in textureInfo {
                    var info = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                    if entry.slot == 0 {
                        info.spriteRotation = rotation
                        info.spriteTranslation = draw.uvOrigin
                    } else if let sprite = entry.sprite {
                        info.spriteRotation = sprite.rotation
                        info.spriteTranslation = sprite.translation
                    }
                    pass.textures[entry.slot] = info
                }
                return pass
            }
        }

        encoder.setRenderPipelineState(pipeline)
        depth?.apply(draw.raster ?? plan.raster, to: encoder)
        var positions = draw.placement?.quadPositions ?? Self.quadPositions(extent: extent)
        var texCoords = plan.usesSpriteSheetUniforms
            ? Self.corners
            : Self.corners.map { draw.uvOrigin + $0.x * draw.uvAxisX + $0.y * draw.uvAxisY }
        encoder.setVertexBytes(&positions, length: MemoryLayout<Float>.stride * positions.count,
                               index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBytes(&texCoords, length: MemoryLayout<SIMD2<Float>>.stride * texCoords.count,
                               index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        for entry in textureInfo {
            encoder.setFragmentTexture(entry.texture, index: entry.slot)
            encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
            encoder.setVertexTexture(entry.texture, index: entry.slot)
            encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
        }
        if uniforms.size > 0 {
            uniforms.bytes.withUnsafeBytes { raw in
                uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        drawsEncoded += 1
        return true
    }


    /// WE's prelighting pass (0x140209540; docs/lighting-plan.md §2.3) for a lit or reflective
    /// layer with effects: `plan.prelighting`, the material with its lighting and `PRELIGHTING`,
    /// draws `draw.texture` texel for texel into a texture of its size, which the layer's effects
    /// then start from. The layer's place in the scene reaches the shader as `g_AltModelMatrix`,
    /// `g_AltNormalModelMatrix` and `g_AltViewProjectionMatrix` (0x14020656b, 0x140207dc3), so each
    /// texel is lit, and reflects the scene, where it lies in the scene, while
    /// `g_ModelViewProjectionMatrix` maps it into the texture. `g_Color4` is white: the layer's
    /// colour, alpha and brightness are applied once, by its own draw after the effects. nil (the
    /// effects take the image unlit) while the pipeline compiles or an input is missing. Encodes its
    /// own render pass. `format` is the frame-buffer class's, which the layer's effect buffers
    /// take (0x1401ea642): RGBA8, or RGBA16F in HDR, where the prepass's overbright must reach the
    /// effects and the bloom.
    func prelight(_ plan: ImageMaterialPlan, _ draw: Draw, format: MTLPixelFormat = .rgba8Unorm,
                  commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let pass = plan.prelighting, let uniforms = program(for: plan, layerID: draw.layerID).prelightUniforms,
              let pipeline = pipeline(for: pass, material: plan.materialPath, pixelFormat: format) else { return nil }
        let program = program(for: plan, layerID: draw.layerID)
        program.prelit = Self.target(program.prelit, like: draw.texture, format: format, device: device)
        guard let target = program.prelit,
              drawIntoTexture(pass, plan: plan, draw, uniforms: uniforms, lit: true, pipeline: pipeline, target: target,
                              commandBuffer: commandBuffer) else { return nil }
        prelitDraws += 1
        return target
    }

    /// WE's base pass for a layer whose effects draw their last pass into the scene (the object's
    /// draw into its first effect buffer, vtable +0xe8 = 0x140207b50, before the effects,
    /// 0x1401e98d6): the layer's own material, without blending, draws `draw.texture` texel for
    /// texel into a texture of its size with the layer's colour, alpha and brightness
    /// (0x140207bd2…0x140207c2a set them as `g_Color4`), which the effects then start from; the
    /// last pass takes them into the scene with the material's blending. The texture is drawn again
    /// only when its input, `inputVersion` or the material's uniforms change, so a chain that doesn't
    /// change keeps its output (`EffectGraphRenderer.StaticChainKey`); `version` counts the draws.
    /// nil while the pipeline compiles or an input is missing. Encodes its own render pass.
    func base(_ plan: ImageMaterialPlan, _ draw: Draw, inputVersion: UInt64, format: MTLPixelFormat = .rgba8Unorm,
              commandBuffer: MTLCommandBuffer) -> (texture: MTLTexture, version: UInt64)? {
        let program = program(for: plan, layerID: draw.layerID)
        guard let pipeline = pipeline(for: program.basePass, material: plan.materialPath, pixelFormat: format) else { return nil }
        let replaced = Self.target(program.base, like: draw.texture, format: format, device: device)
        if replaced !== program.base { program.baseDrawn = nil }
        program.base = replaced
        guard let target = program.base,
              drawIntoTexture(program.basePass, plan: plan, draw, uniforms: program.baseUniforms, lit: false,
                              pipeline: pipeline, target: target, commandBuffer: commandBuffer, skipUnchanged: {
                                  let drawn = (ObjectIdentifier(draw.texture), inputVersion, program.baseUniforms.bytes)
                                  if let last = program.baseDrawn, last.input == drawn.0, last.inputVersion == drawn.1,
                                     last.bytes == drawn.2 { return true }
                                  program.baseDrawn = drawn
                                  program.baseVersion &+= 1
                                  return false
                              }) else { return nil }
        return (target, program.baseVersion)
    }

    /// Whether `plan`'s base pass (`base`) can draw into a `format` texture now; starts its compile.
    func baseIsReady(_ plan: ImageMaterialPlan, layerID: String, format: MTLPixelFormat) -> Bool {
        pipeline(for: program(for: plan, layerID: layerID).basePass, material: plan.materialPath, pixelFormat: format) != nil
    }

    /// `current` when it is a render target like `texture` in `format`, else a new one.
    private static func target(_ current: MTLTexture?, like texture: MTLTexture, format: MTLPixelFormat,
                               device: MTLDevice) -> MTLTexture? {
        if let current, current.width == texture.width, current.height == texture.height, current.pixelFormat == format {
            return current
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Draws `pass` over the whole of `target`, texel for texel from `draw.texture`: the image (its
    /// content, inside a padded texture) is the layer's quad in model space, `extent` wide and tall,
    /// centred, y up. `lit` passes (prelighting) are white and see the layer's place in the scene
    /// through the `g_Alt*` matrices; the others carry the layer's colour, alpha and brightness.
    /// `skipUnchanged`, called once the uniforms are written, keeps the target as it is when true.
    /// False when an input is missing.
    private func drawIntoTexture(_ pass: SceneEffectPassPlan, plan: ImageMaterialPlan, _ draw: Draw,
                                 uniforms: ImageMaterialUniforms, lit: Bool, pipeline: MTLRenderPipelineState,
                                 target: MTLTexture, commandBuffer: MTLCommandBuffer,
                                 skipUnchanged: () -> Bool = { false }) -> Bool {
        let extent = draw.placement?.size ?? draw.quad.extent
        guard extent.x > 0, extent.y > 0, extent.x.isFinite, extent.y.isFinite,
              let textureInfo = textures(of: pass, plan: plan, draw) else { return false }
        let size = SIMD2(Float(target.width), Float(target.height))
        let content = (draw.contentSize ?? size) / size
        var positions = Self.corners.flatMap { uv -> [Float] in
            [(uv.x / content.x - 0.5) * extent.x, (0.5 - uv.y / content.y) * extent.y, 0]
        }
        // Model space onto the whole texture: texture row 0 at GL clip y = −1, as for the scene target.
        let intoTexture = simd_float4x4(columns: (SIMD4(2 * content.x / extent.x, 0, 0, 0),
                                                  SIMD4(0, -2 * content.y / extent.y, 0, 0),
                                                  SIMD4(0, 0, 1, 0),
                                                  SIMD4(content.x - 1, content.y - 1, 0, 1)))
        if uniforms.size > 0 {
            // Where the layer lies: its quad's centre and axes, or through a 3D camera its world
            // matrix moved to the quad's centre.
            let alt = draw.placement?.centredWorld ?? Self.modelMatrix(draw.quad)
            let color = lit ? SIMD3<Float>(repeating: 1) : draw.color
            let alpha: Float = lit ? 1 : draw.alpha
            let brightness: Float = lit ? 1 : draw.brightness
            let key = ImageMaterialUniforms.PassKey(
                model: alt, viewProjection: intoTexture, color: color, alpha: alpha, brightness: brightness,
                spriteRotation: SIMD4(1, 0, 0, 1), spriteTranslation: .zero, screen: draw.frame.screenSize,
                textures: textureInfo.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                                  $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) },
                sprites: textureInfo.compactMap(\.sprite))
            uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                // The buffer's own view-projection, in the scene target's convention.
                let view = Self.viewProjection(sceneSize: size)
                var context = BuiltinPassContext(targetSize: size)
                context.viewProjection = view
                context.modelViewProjection = intoTexture
                context.modelMatrix = view.inverse * intoTexture
                context.altModelMatrix = alt
                context.altViewProjection = draw.placement?.shaderViewProjection
                    ?? Self.viewProjection(sceneSize: draw.sceneSize)
                context.color = color
                context.alpha = alpha
                context.userAlpha = alpha
                context.brightness = brightness
                for entry in textureInfo {
                    var info = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                    if let sprite = entry.sprite, entry.slot != 0 {
                        info.spriteRotation = sprite.rotation
                        info.spriteTranslation = sprite.translation
                    }
                    context.textures[entry.slot] = info
                }
                return context
            }
        }
        if skipUnchanged() { return true }

        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = target
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        var texCoords = Self.corners
        encoder.setVertexBytes(&positions, length: MemoryLayout<Float>.stride * positions.count,
                               index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBytes(&texCoords, length: MemoryLayout<SIMD2<Float>>.stride * texCoords.count,
                               index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        for entry in textureInfo {
            encoder.setFragmentTexture(entry.texture, index: entry.slot)
            encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
            encoder.setVertexTexture(entry.texture, index: entry.slot)
            encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
        }
        if uniforms.size > 0 {
            uniforms.bytes.withUnsafeBytes { raw in
                uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer)
            }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private typealias BoundTexture = (slot: Int, texture: MTLTexture, sampler: MTLSamplerState, contentSize: SIMD2<Float>?,
                                      sprite: BuiltinSpriteFrame?)

    /// The textures `pass` reads for this draw; nil when one isn't there this frame.
    private func textures(of pass: SceneEffectPassPlan, plan: ImageMaterialPlan, _ draw: Draw) -> [BoundTexture]? {
        var textureInfo: [BoundTexture] = []
        for slot in pass.variant?.textureSlots ?? [] {
            // The plan binds every slot the variant reads; one it leaves out is declared but unused.
            guard let input = pass.textures[slot] else { continue }
            let sampler = plan.clampedSlots.contains(slot) ? clampSampler : repeatSampler
            switch input {
            case .current, .previous:
                textureInfo.append((slot, draw.texture, sampler, draw.contentSize, nil))
            case .sceneSnapshot:
                guard let snapshot = draw.sceneSnapshot else { return nil }
                textureInfo.append((slot, snapshot, clampSampler, nil, nil))
            case .mipMappedFrameBuffer:
                guard let target = draw.mipMappedFrameBuffer else { return nil }
                textureInfo.append((slot, target, clampSampler, nil, nil))
            case .asset(let key, let source):
                guard let texture = draw.assetTexture(key, source) else { return nil }
                textureInfo.append((slot, texture, sampler, source.contentSize, draw.assetSprite?(key, source)))
            case .fbo(SceneShadowAtlas.name):
                guard let atlas = draw.shadowAtlas else { return nil }
                textureInfo.append((slot, atlas, shadowSampler, nil, nil))
            case .fbo(SceneLightCookie.name):
                // The last packed cookie spot's texture, else the zero texel.
                if let cookie = draw.frame.lighting.cookie, let texture = draw.assetTexture(cookie.key, cookie.source) {
                    textureInfo.append((slot, texture, clampSampler, cookie.source.contentSize, nil))
                } else {
                    textureInfo.append((slot, zeroTexture, clampSampler, nil, nil))
                }
            case .fbo:
                return nil
            }
        }
        return textureInfo
    }

    /// Whether `sceneFragment`'s per-layer adjustments (legacy material heuristics, music sync) leave
    /// this layer unchanged, i.e. whether the native draw would apply nothing besides the object's
    /// own `brightness`, which the material applies.
    static func nativeAdjustmentsAreIdentity(_ uniform: LayerUniform, brightness: Float) -> Bool {
        uniform.effects.x == brightness
            && uniform.effects.y == 1 && uniform.effects.z == 1 && uniform.effects.w <= 0 && uniform.blur <= 0
            && uniform.colorEffects.x == 0 && uniform.colorEffects.y == 1 && abs(uniform.colorEffects.z) <= 0.0001
            && uniform.transform == SIMD4(0, 0, 0, 1) && uniform.transformScaleY == 1
    }

    // MARK: - Geometry

    /// Triangle-strip corners in texture space (u right, v down the image).
    static let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]

    /// The quad in model space: centred, `extent` wide and tall, y up (v = 0 is the top edge).
    static func quadPositions(extent: SIMD2<Float>) -> [Float] {
        corners.flatMap { corner -> [Float] in
            [(corner.x - 0.5) * extent.x, (0.5 - corner.y) * extent.y, 0]
        }
    }

    /// Maps the model-space quad onto the world quad: its axes (rotation, shear and scale of the
    /// whole parent chain) and its centre.
    static func modelMatrix(_ quad: SceneQuadGeometry) -> simd_float4x4 {
        let extent = quad.extent
        let x = quad.axisX / extent.x
        let y = quad.axisY / extent.y
        return simd_float4x4(columns: (SIMD4(x.x, x.y, 0, 0), SIMD4(y.x, y.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(quad.center.x, quad.center.y, 0, 1)))
    }

    /// Scene units to clip space. The translated vertex stage flips y (GL rows, see `flip_vert_y`
    /// in `Vendor/ShaderToolchain`'s shim), and the scene target keeps the scene's top in its first row, so the
    /// scene's top maps to GL clip y = −1.
    static func viewProjection(sceneSize: SIMD2<Float>) -> simd_float4x4 {
        PassMatrices.ortho(left: 0, right: max(sceneSize.x, 1), bottom: max(sceneSize.y, 1), top: 0)
    }

    /// The view-projection of a layer drawn without a camera placement. In an orthographic scene
    /// whose pass has depth (it has models) it is WE's orthographic projection
    /// (`SceneCamera.orthographic`: z −2000…2000, z = 0 at half depth), whose depth the models
    /// share, so a layer tests against them as in WE; its x and y are `viewProjection`'s.
    static func sceneViewProjection(_ draw: Draw, depth: SceneDepthStates?) -> simd_float4x4 {
        guard depth != nil, !draw.frame.camera.isPerspective else { return viewProjection(sceneSize: draw.sceneSize) }
        return PassMatrices.shaderViewProjection(SceneCamera.orthographic(size: draw.sceneSize))
    }

    // MARK: - Uniforms

    private func program(for plan: ImageMaterialPlan, layerID: String) -> Program {
        if let existing = programs[layerID], existing.plan === plan { return existing }
        let program = Program(plan: plan)
        programs[layerID] = program
        return program
    }

    /// Memory pressure: drops free uniform chunks, and with `dropIdlePipelines` every pipeline not
    /// drawn with since the last trim (they recompile, from the binary archive, if needed again).
    func trimMemory(dropIdlePipelines: Bool) {
        uniformArena.trim()
        guard dropIdlePipelines else { return }
        pipelineLock.withLock {
            pipelines = pipelines.filter { usedPipelines.contains($0.key) }
            usedPipelines.removeAll()
        }
    }

    /// Frees one layer's uniform state (e.g. a removed script clone).
    func releaseLayer(_ layerID: String) {
        programs.removeValue(forKey: layerID)
    }

    // MARK: - Pipelines

    /// A multisampled pipeline's key carries its sample count, and one for a pass with depth its
    /// depth format; a single-sampled one without depth's is unchanged.
    static func pipelineKey(_ pass: SceneEffectPassPlan, pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
                            depthFormat: MTLPixelFormat = .invalid) -> String {
        "image|\(pass.variantKey)|\(pixelFormat.rawValue)|\(pass.blending.lowercased())" + (sampleCount > 1 ? "|x\(sampleCount)" : "")
            + (depthFormat == .invalid ? "" : "|d\(depthFormat.rawValue)")
    }

    /// The ready pipeline, or nil while it compiles (the compile is started here) or after it failed.
    private func pipeline(for pass: SceneEffectPassPlan, material: String, pixelFormat: MTLPixelFormat,
                          sampleCount: Int = 1, depthFormat: MTLPixelFormat = .invalid) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(pass, pixelFormat: pixelFormat, sampleCount: sampleCount, depthFormat: depthFormat)
        let state: (pipeline: MTLRenderPipelineState?, busy: Bool) = pipelineLock.withLock {
            if pipelines[key] != nil { usedPipelines.insert(key) }
            return (pipelines[key], pending.contains(key) || failed.contains(key))
        }
        if let pipeline = state.pipeline { return pipeline }
        if !state.busy, let variant = pass.variant {
            compile(variant, blending: pass.blending, material: material, pixelFormat: pixelFormat,
                    sampleCount: sampleCount, depthFormat: depthFormat, key: key)
        }
        return nil
    }

    /// Blocks until the plan's pipelines (its prelighting pass's too, into `prelitFormat`) compiled
    /// or failed (tests, prewarming). True when they are ready.
    func waitUntilReady(_ plan: ImageMaterialPlan, pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
                        depthFormat: MTLPixelFormat = .invalid, prelitFormat: MTLPixelFormat = .rgba8Unorm,
                        timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let passes = [(plan.pass, pixelFormat, sampleCount, depthFormat)]
            + (plan.prelighting.map { [($0, prelitFormat, 1, MTLPixelFormat.invalid)] } ?? [])
        for (pass, format, samples, depth) in passes {
            let key = Self.pipelineKey(pass, pixelFormat: format, sampleCount: samples, depthFormat: depth)
            while pipeline(for: pass, material: plan.materialPath, pixelFormat: format, sampleCount: samples,
                           depthFormat: depth) == nil {
                if pipelineLock.withLock({ failed.contains(key) }) || Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return true
    }

    /// The image material's blend state for its pass's `blending`: alpha-to-coverage (WE's blend
    /// byte 3) takes coverage from the shader's alpha (`ALPHATOCOVERAGE`) without blending; the
    /// rest blend as `EffectGraphRenderer.blendMode` says.
    static func applyBlending(_ blending: String, to descriptor: MTLRenderPipelineDescriptor) {
        if blending.lowercased() == WEMaterialBlending.alphaToCoverage.rawValue {
            descriptor.isAlphaToCoverageEnabled = true
        } else if let blend = EffectGraphRenderer.blendMode(blending) {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = blend.source
            attachment.sourceAlphaBlendFactor = blend.source
            attachment.destinationRGBBlendFactor = blend.destination
            attachment.destinationAlphaBlendFactor = blend.destination
        }
    }

    private func compile(_ variant: TranslatedShaderVariant, blending: String, material: String, pixelFormat: MTLPixelFormat,
                         sampleCount: Int, depthFormat: MTLPixelFormat, key: String) {
        pipelineLock.withLock { _ = pending.insert(key) }
        let device = self.device
        let archive = self.archive
        compileQueue.async { [weak self] in
            let result: MTLRenderPipelineState?
            do {
                let (vertexLibrary, fragmentLibrary) = try variant.makeLibraries(device: device)
                guard let vertex = vertexLibrary.makeFunction(name: "main0"),
                      let fragment = fragmentLibrary.makeFunction(name: "main0") else {
                    throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
                }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = pixelFormat
                descriptor.rasterSampleCount = sampleCount
                descriptor.depthAttachmentPixelFormat = depthFormat
                Self.applyBlending(blending, to: descriptor)
                descriptor.vertexDescriptor = EffectGraphRenderer.vertexDescriptor(for: vertex)
                result = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: key)
            } catch {
                OWELog.error(.shader, "Image material \(material) can't draw through its shader; the layer draws natively: \(error)")
                result = nil
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pending.remove(key)
                self.landedPipelines &+= 1
                if let result { self.pipelines[key] = result } else { self.failed.insert(key) }
            }
        }
    }
}

private extension SceneEffectPassPlan {
    /// The same pass drawn with `blending`.
    func blended(_ blending: String) -> SceneEffectPassPlan {
        var pass = SceneEffectPassPlan(command: command, variantKey: variantKey, variant: variant, blending: blending,
                                       target: target, textures: textures, constants: constants)
        pass.textureFlags = textureFlags
        pass.materialIndex = materialIndex
        return pass
    }
}
