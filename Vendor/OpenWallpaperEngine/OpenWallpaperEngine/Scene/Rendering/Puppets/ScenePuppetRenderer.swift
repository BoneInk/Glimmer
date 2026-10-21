import Metal
import simd

/// Draws puppets' meshes into their albedo targets (`ScenePuppetPlan`). Pipelines compile off the
/// render thread and share the effects' binary archive; until a layer's is ready its target stays
/// transparent (the layer shows nothing rather than its unassembled atlas). A target is redrawn
/// only when what it is drawn from changed: the pose, the albedo texture, or a user-bound constant.
/// Call on the render thread, apart from the compiles.
final class ScenePuppetRenderer {
    private let device: MTLDevice
    private let archive: EffectPipelineArchive?
    private let unpremultiply: MTLComputePipelineState
    /// Lays another image-space texture out like the posed mesh (`warp`).
    private let warpPipeline: MTLRenderPipelineState
    /// `warpPipeline` premultiplied and blended "over", into the scratch target (`warp`'s `blended`).
    private let blendedWarpPipeline: MTLRenderPipelineState
    private let clampSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState
    private let zeroAttributes: MTLBuffer
    /// WE's "morph_<n>" texture stand-in for a `MORPHING` mesh without targets, and the painted
    /// texture of a clipping mask whose texture is missing (nothing painted).
    private let emptyMorphTexture: MTLTexture
    /// A nested mask's coverage multiplied into its parents' (`ScenePuppetClipping`).
    private let coverageCompose: MTLRenderPipelineState
    private let uniformArena: SceneUniformArena
    /// The rigs' texture channels, drawn over the image the mesh samples.
    let channels: ScenePuppetChannelRenderer

    private let compileQueue = DispatchQueue(label: "owe.puppet-pipelines", qos: .userInitiated, attributes: .concurrent)
    /// Owns `pipelines`, `pending` and `failed`, which compile threads write.
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private var landedPipelines = 0

    /// Whether a mesh pipeline is still compiling: a frame drawn now lacks that puppet.
    var hasPendingPipelines: Bool { pipelineLock.withLock { !pending.isEmpty } }
    /// Compiles finished so far, however they ended: a frame drawn before one landed is redrawn.
    var pipelinesLanded: Int { pipelineLock.withLock { landedPipelines } }

    /// The premultiplied draw every puppet shares, grown to the largest image drawn. Render thread only.
    private var scratch: MTLTexture?
    /// WE's `_rt_FullAlphaMask` and `_rt_FullAlphaMaskIntermediate`, the size of the drawing.
    private var coverage: [MTLTexture?] = [nil, nil]
    /// Per layer instance. Render thread only.
    private var layers: [String: LayerState] = [:]
    /// Warped textures by layer id and texture key. Render thread only.
    private var warps: [String: [String: WarpState]] = [:]

    private final class WarpState {
        let target: MTLTexture
        var drawnPose: ScenePuppetPose?
        var drawnSource: ObjectIdentifier?
        var drawnCanvas: ScenePuppetCanvas?
        var drawnMirrored = false

        init(target: MTLTexture) { self.target = target }
    }

    private final class LayerState {
        let plan: ScenePuppetPlan
        let uniforms: ImageMaterialUniforms
        let vertices: MTLBuffer
        let indices: MTLBuffer
        /// The rig's "morph_<n>" texture (`SceneMorphTexture.puppet`); nil without targets.
        let morphTexture: MTLTexture?
        var target: MTLTexture?
        var drawnPose: ScenePuppetPose?
        var drawnSource: ObjectIdentifier?
        var drawnCanvas: ScenePuppetCanvas?
        var drawnMirrored = false
        /// The texture channels' drawing the mesh sampled (`ScenePuppetChannelRenderer`), 0 for the image.
        var drawnChannels: UInt64 = 0
        /// The canvas a layer without effects grows to (`canvas(_:layerID:pose:)`).
        var canvas: ScenePuppetCanvas?
        /// Which drawing `target` holds (`albedoVersion`).
        var version: UInt64 = 0
        /// The clipped parts' and the masks' materials' uniforms (`ScenePuppetClipPlan`).
        let targetUniforms: ImageMaterialUniforms?
        let maskUniforms: ImageMaterialUniforms?
        /// The mask passes of the last drawing (`clippingMaskPasses`).
        var clipPasses = 0

        init?(plan: ScenePuppetPlan, device: MTLDevice) {
            self.plan = plan
            // White, opaque and at brightness 1: the layer's own draw applies its colour, alpha and
            // brightness (and a legacy material's factors for them) to the target once.
            uniforms = ImageMaterialUniforms(layout: plan.material.pass.variant?.uniforms, constants: plan.material.pass.constants,
                                             liveFactors: [:])
            targetUniforms = plan.clipping.map {
                ImageMaterialUniforms(layout: $0.target.pass.variant?.uniforms, constants: $0.target.pass.constants, liveFactors: [:])
            }
            maskUniforms = plan.clipping?.mask.map {
                ImageMaterialUniforms(layout: $0.pass.variant?.uniforms, constants: $0.pass.constants, liveFactors: [:])
            }
            guard let vertices = plan.vertexData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
                  let indices = plan.indexData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            else { return nil }
            self.vertices = vertices
            self.indices = indices
            morphTexture = plan.morphs.flatMap { morphs -> MTLTexture? in
                guard !morphs.targets.isEmpty else { return nil }
                return SceneMorphTexture.makeTexture(SceneMorphTexture.puppet(morphs, meshFlags: plan.meshFlags),
                                                     device: device, label: "morph_puppet")
            }
        }
    }

    /// Mesh draws encoded, for tests and diagnostics.
    private(set) var drawsEncoded = 0
    /// The last version handed to a layer's image; versions are unique across layers and loads.
    private var lastVersion: UInt64 = 0
    /// Bytes of the albedo targets and the scratch (diagnostics).
    var allocatedBytes: Int {
        layers.values.reduce((scratch?.allocatedSize ?? 0) + coverage.reduce(0) { $0 + ($1?.allocatedSize ?? 0) }) { $0 + ($1.target?.allocatedSize ?? 0) } + channels.allocatedBytes
            + warps.values.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.target.allocatedSize } }
    }

    static let scratchFormat: MTLPixelFormat = .rgba16Float
    /// The albedo target's format: the layer images' (8-bit, not sRGB-encoded; `SceneTextureUpload`).
    static let targetFormat: MTLPixelFormat = .rgba8Unorm

    init?(device: MTLDevice, archive: EffectPipelineArchive?) {
        self.device = device
        self.archive = archive
        uniformArena = SceneUniformArena(device: device)
        do {
            guard let library = SceneMetalLibrary.make(device: device),
                  let function = library.makeFunction(name: "scenePuppetUnpremultiply"),
                  let warpVertex = library.makeFunction(name: "scenePuppetWarpVertex"),
                  let warpFragment = library.makeFunction(name: "scenePuppetWarpFragment"),
                  let blendedFragment = library.makeFunction(name: "scenePuppetWarpPremultipliedFragment"),
                  let channels = ScenePuppetChannelRenderer(device: device, library: library, archive: archive) else { return nil }
            self.channels = channels
            unpremultiply = try device.makeComputePipelineState(function: function)
            let warp = MTLRenderPipelineDescriptor()
            warp.vertexFunction = warpVertex
            warp.fragmentFunction = warpFragment
            warp.colorAttachments[0].pixelFormat = Self.warpFormat
            warpPipeline = try device.makeRenderPipelineState(descriptor: warp)
            warp.fragmentFunction = blendedFragment
            warp.colorAttachments[0].pixelFormat = Self.scratchFormat
            let attachment = warp.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendedWarpPipeline = try device.makeRenderPipelineState(descriptor: warp)
            guard let composeVertex = library.makeFunction(name: "scenePuppetCoverageVertex"),
                  let composeFragment = library.makeFunction(name: "scenePuppetCoverageFragment") else { return nil }
            let compose = MTLRenderPipelineDescriptor()
            compose.vertexFunction = composeVertex
            compose.fragmentFunction = composeFragment
            compose.colorAttachments[0].pixelFormat = Self.coverageFormat
            // The intersection of nested masks: the coverage so far times this mask's [I: WE's
            // compose blend state, 0x14020da40].
            compose.colorAttachments[0].isBlendingEnabled = true
            compose.colorAttachments[0].sourceRGBBlendFactor = .zero
            compose.colorAttachments[0].destinationRGBBlendFactor = .sourceColor
            compose.colorAttachments[0].sourceAlphaBlendFactor = .zero
            compose.colorAttachments[0].destinationAlphaBlendFactor = .one
            coverageCompose = try device.makeRenderPipelineState(descriptor: compose)
        } catch {
            OWELog.error(.scene, "The puppet albedo pipeline failed: \(error)")
            return nil
        }
        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.sAddressMode = mode
            descriptor.tAddressMode = mode
            return device.makeSamplerState(descriptor: descriptor)
        }
        let morph = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        morph.usage = .shaderRead
        guard let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat),
              let zero = device.makeBuffer(length: 64), let morphTexture = device.makeTexture(descriptor: morph) else { return nil }
        morphTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt16](repeating: 0, count: 4),
                             bytesPerRow: 8)
        clampSampler = clamp
        repeatSampler = wrap
        zeroAttributes = zero
        emptyMorphTexture = morphTexture
    }

    /// Whether the layer's mesh has been drawn into its image (the pipeline was ready).
    func hasDrawn(_ layerID: String) -> Bool { layers[layerID]?.drawnPose != nil }
    /// Whether `warp` has laid `key`'s texture out for the layer (tests, diagnostics).
    func hasLaidOut(_ layerID: String, key: String) -> Bool { warps[layerID]?[key]?.drawnPose != nil }

    /// Which drawing the layer's image holds: a new value each time `albedo` redraws it. The image
    /// is redrawn into the same texture, so caches keyed by the texture (a layer's kept effect
    /// output, its base pass) also key on this, or they keep the pose they were made from.
    func albedoVersion(_ layerID: String) -> UInt64 { layers[layerID]?.version ?? 0 }

    /// Drops per-layer state when the content changes. Compiled pipelines are kept.
    func releaseAll() {
        layers.removeAll()
        warps.removeAll()
        scratch = nil
        coverage = [nil, nil]
        channels.releaseAll()
    }

    /// Frees one layer's state (e.g. a removed script clone).
    func releaseLayer(_ layerID: String) {
        layers.removeValue(forKey: layerID)
        warps.removeValue(forKey: layerID)
        channels.releaseLayer(layerID)
    }

    /// Memory pressure: the scratch is remade by the next draw that needs it.
    func trimMemory() {
        scratch = nil
        coverage = [nil, nil]
        uniformArena.trim()
        channels.trimMemory()
    }

    /// What a puppet's draw needs this frame.
    struct Draw {
        let layerID: String
        /// The layer image (the material's `textures[0]`), as uploaded.
        let source: MTLTexture
        let pose: ScenePuppetPose
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// What of the mesh's space the target covers; nil for the image's rect.
        var canvas: ScenePuppetCanvas? = nil
        /// Whether the layer shows its image mirrored (`isMirrored`), which flips the mesh's winding.
        var mirrored = false
    }

    /// The winding of the mesh's front faces as it is drawn into the layer's image. WE draws the
    /// mesh in the scene through the object's world, with D3D's `FrontCounterClockwise = FALSE`
    /// and no compensation for a mirroring world (WE 2.8's capture, docs/models-plan.md §5.17: a
    /// `cullmode` "normal" puppet draws at scale 1 1 1 and disappears at −1 1 1). That is a
    /// `.mdl`'s counter-clockwise winding in clip space (`SceneModelRenderer.frontFacing`), and
    /// WE's editor winds a rig's triangles counter-clockwise in its image (y up: the rope and the
    /// library's rigs). Into the image, the mesh keeps that winding in clip space (the projection's
    /// row flip and the stage's y negation cancel), so the same winding is in front; the layer
    /// then mirrors the image, so a mirrored layer culls the other winding.
    static func frontFacing(mirrored: Bool) -> MTLWinding {
        mirrored ? .clockwise : SceneModelRenderer.frontFacing
    }

    /// Whether a layer whose world maps its image's x and y axes to `axisX` and `axisY` on screen
    /// (y up) shows the image mirrored: a negative scale, or a tilt past a quarter turn.
    static func isMirrored(axisX: SIMD2<Float>, axisY: SIMD2<Float>) -> Bool {
        axisX.x * axisY.y - axisX.y * axisY.x < 0
    }

    /// The same through a 3D camera: the image's axes projected at its origin, `world` mapping the
    /// image's plane into the scene and `viewProjection` the scene to clip space (y up). Behind the
    /// camera (w ≤ 0) it isn't mirrored.
    static func isMirrored(world: simd_float4x4, viewProjection: simd_float4x4) -> Bool {
        let clip = viewProjection * world
        func screen(_ point: SIMD4<Float>) -> SIMD2<Float>? {
            let p = clip * point
            guard p.w > 0 else { return nil }
            return SIMD2(p.x, p.y) / p.w
        }
        guard let origin = screen(SIMD4(0, 0, 0, 1)), let x = screen(SIMD4(1, 0, 0, 1)),
              let y = screen(SIMD4(0, 1, 0, 1)) else { return false }
        return isMirrored(axisX: x - origin, axisY: y - origin)
    }

    /// The canvas of a puppet layer without effects posed by `pose`: its image grown to cover the
    /// posed mesh, never shrinking while the layer lives (`ScenePuppetCanvas.covering`).
    func canvas(_ plan: ScenePuppetPlan, layerID: String, pose: ScenePuppetPose) -> ScenePuppetCanvas {
        guard let state = layerState(plan, layerID: layerID) else { return .image(plan.imageSize) }
        let canvas = ScenePuppetCanvas.covering(plan.posedBounds(pose), imageSize: plan.imageSize, current: state.canvas)
        state.canvas = canvas
        return canvas
    }

    /// Makes the layer's state without drawing its image, for a layer whose effects read its
    /// texture as stored (`warp` lays their output out). False when it can't be made.
    @discardableResult
    func prepareLayer(_ plan: ScenePuppetPlan, layerID: String) -> Bool { layerState(plan, layerID: layerID) != nil }

    private func layerState(_ plan: ScenePuppetPlan, layerID: String) -> LayerState? {
        if let existing = layers[layerID], existing.plan === plan { return existing }
        guard let made = LayerState(plan: plan, device: device) else { return nil }
        layers[layerID] = made
        return made
    }

    /// The layer's albedo target this frame, in `draw.source`'s texture layout (same size, the
    /// image in its top-left content texels), redrawn into `commandBuffer` when needed. Encodes its
    /// own passes, so call it outside any open render pass. nil when no target can be made.
    func albedo(_ plan: ScenePuppetPlan, _ draw: Draw, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let state = layerState(plan, layerID: draw.layerID) else { return nil }
        let size = SIMD2(draw.source.width, draw.source.height)
        if state.target.map({ SIMD2($0.width, $0.height) }) != size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.targetFormat, width: size.x,
                                                                      height: size.y, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            state.target = device.makeTexture(descriptor: descriptor)
            state.drawnPose = nil
        }
        guard let target = state.target else { return nil }
        // The texture channels drawn over the image, which the mesh then samples (0x140207740).
        let channeled = plan.channels.flatMap { channelPlan in
            channels.composite(channelPlan, ScenePuppetChannelRenderer.Draw(
                layerID: draw.layerID, image: draw.source, contentPixels: plan.contentPixels, imageSize: plan.imageSize,
                blendMap: draw.pose.blendMap, frame: draw.frame, values: draw.values, assetTexture: draw.assetTexture),
                commandBuffer: commandBuffer)
        }
        let source = ObjectIdentifier(draw.source)
        let unchanged = state.drawnPose == draw.pose && state.drawnSource == source && state.drawnCanvas == draw.canvas
            && state.drawnMirrored == draw.mirrored && state.drawnChannels == (channeled?.version ?? 0)
            && plan.material.pass.constants.dynamic.isEmpty
        if unchanged { return target }

        let content = simd_min(plan.contentPixels, size)
        guard let scratch = scratchTexture(covering: content) else { return nil }
        let drawn = encodeMesh(plan, state: state, draw, image: channeled?.texture ?? draw.source, into: scratch,
                               content: content, commandBuffer: commandBuffer)
        lastVersion &+= 1
        state.version = lastVersion
        guard let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }
        compute.setComputePipelineState(unpremultiply)
        compute.setTexture(scratch, index: 0)
        compute.setTexture(target, index: 1)
        // Nothing drawn yet (compiling): the target is cleared, the layer transparent.
        var extent = drawn ? SIMD2(UInt32(content.x), UInt32(content.y)) : .zero
        compute.setBytes(&extent, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        compute.dispatchThreadgroups(MTLSize(width: (size.x + 15) / 16, height: (size.y + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
        compute.endEncoding()
        if drawn {
            state.drawnPose = draw.pose
            state.drawnSource = source
            state.drawnCanvas = draw.canvas
            state.drawnMirrored = draw.mirrored
            state.drawnChannels = channeled?.version ?? 0
        }
        return target
    }

    /// A warped texture's format: float, so sampling it returns what sampling the source did.
    static let warpFormat: MTLPixelFormat = .rgba16Float

    /// `texture` (an image-space texture of the layer's material other than its image: a normal
    /// map, a PBR mask) laid out like the posed mesh, in `texture`'s own layout (its image in the
    /// top-left `contentSize` texels), redrawn only when the pose or the texture changed. For a
    /// lit puppet without effects, WE draws the mesh in the scene through the layer's material, so
    /// every texture is sampled at the mesh's coordinates (0x14020a5d2, docs/models-plan.md §2.13);
    /// the layer's quad drawn with its image and these textures laid out through the mesh is that
    /// draw for a flat layer. The coordinates are the mesh's, scaled to the image's share of its
    /// padded texture, for every texture, as WE's copy of the mesh has them. nil when the mesh
    /// has no plain position, blend indices, weights or texture coordinate. `redraw`: `texture`'s
    /// contents change from frame to frame (a puppet's effect output), so it is laid out again.
    /// `blended`: the triangles composite over each other as the layer's material draws them
    /// (`applyBlending`): the image a translucent puppet's effects made, whose parts overlap (a
    /// strand of hair over a face the texture leaves empty under it). Otherwise later triangles
    /// replace earlier ones, as data textures (normal maps, masks) want. `mirrored`: the layer
    /// mirrors its image (`Draw.mirrored`). `fades`: the parts fade by the pose's `bonesAlpha`
    /// when the material has `SKINNING_ALPHA`, for output that didn't come through the mesh's own
    /// draw (a rig whose effects run on its texture). The triangles draw in the pose's
    /// `drawRanges` order.
    func warp(_ plan: ScenePuppetPlan, layerID: String, key: String, texture: MTLTexture, contentSize: SIMD2<Float>?,
              pose: ScenePuppetPose, canvas: ScenePuppetCanvas? = nil, redraw: Bool = false, blended: Bool = false,
              mirrored: Bool = false, fades: Bool = false, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let state = layers[layerID], state.plan === plan else { return nil }
        let format = plan.format
        guard let position = MDLVertexAttribute.named("a_Position").flatMap(format.offset(of:)),
              let indices = MDLVertexAttribute.named("a_BlendIndices").flatMap(format.offset(of:)),
              let weights = MDLVertexAttribute.named("a_BlendWeights").flatMap(format.offset(of:)),
              let texCoord = MDLVertexAttribute.all[7...9].lazy.compactMap(format.offset(of:)).first else { return nil }
        let warp: WarpState
        if let existing = warps[layerID]?[key], existing.target.width == texture.width,
           existing.target.height == texture.height {
            warp = existing
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.warpFormat, width: texture.width,
                                                                      height: texture.height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
            warp = WarpState(target: target)
            warps[layerID, default: [:]][key] = warp
        }
        let source = ObjectIdentifier(texture)
        if !redraw, warp.drawnPose == pose, warp.drawnSource == source, warp.drawnCanvas == canvas,
           warp.drawnMirrored == mirrored { return warp.target }

        let blends = blended && EffectGraphRenderer.blendMode(plan.material.pass.blending) != nil
        let content = contentSize.map { SIMD2(Int(saturating: $0.x.rounded()), Int(saturating: $0.y.rounded())) } ?? SIMD2(texture.width, texture.height)
        let extent = SIMD2(min(content.x, texture.width), min(content.y, texture.height))
        let scratch = blends ? scratchTexture(covering: extent) : nil
        if blends, scratch == nil { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = scratch ?? warp.target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        struct Uniforms {
            var projection: simd_float4x4
            var uvScale: SIMD2<Float>
            var positionOffset, indicesOffset, weightsOffset, texCoordOffset, stride, boneCount, alphaCount: UInt32
        }
        var uniforms = Uniforms(projection: (canvas ?? .image(plan.imageSize)).projection, uvScale: SIMD2(1, 1),
                                positionOffset: UInt32(position), indicesOffset: UInt32(indices),
                                weightsOffset: UInt32(weights), texCoordOffset: UInt32(texCoord),
                                stride: UInt32(format.stride), boneCount: UInt32(pose.bones.count),
                                alphaCount: fades && plan.combos.skinningAlpha ? UInt32(pose.bonesAlpha.count) : 0)
        let bones = pose.bones.isEmpty ? [matrix_identity_float4x4] : pose.bones
        encoder.setRenderPipelineState(blends ? blendedWarpPipeline : warpPipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(extent.x), height: Double(extent.y),
                                        znear: 0, zfar: 1))
        encoder.setCullMode(plan.material.cullsBackFaces ? .back : .none)
        encoder.setFrontFacing(Self.frontFacing(mirrored: mirrored))
        encoder.setVertexBuffer(state.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        guard let palette = bones.withUnsafeBytes({ uniformArena.allocate($0, for: commandBuffer) }) else {
            encoder.endEncoding()
            return nil
        }
        encoder.setVertexBuffer(palette.buffer, offset: palette.offset, index: 2)
        let alphas = pose.bonesAlpha.isEmpty ? [Float(1)] : pose.bonesAlpha
        guard let alphaBuffer = alphas.withUnsafeBytes({ uniformArena.allocate($0, for: commandBuffer) }) else {
            encoder.endEncoding()
            return nil
        }
        encoder.setVertexBuffer(alphaBuffer.buffer, offset: alphaBuffer.offset, index: 3)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(clampSampler, index: 0)
        Self.drawMesh(plan, ranges: Self.visibleRanges(plan, pose: pose), indices: state.indices, encoder: encoder)
        encoder.endEncoding()
        if let scratch {
            guard let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }
            compute.setComputePipelineState(unpremultiply)
            compute.setTexture(scratch, index: 0)
            compute.setTexture(warp.target, index: 1)
            var bounds = SIMD2(UInt32(extent.x), UInt32(extent.y))
            compute.setBytes(&bounds, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
            compute.dispatchThreadgroups(MTLSize(width: (warp.target.width + 15) / 16, height: (warp.target.height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            compute.endEncoding()
        }
        warp.drawnPose = pose
        warp.drawnSource = source
        warp.drawnCanvas = canvas
        warp.drawnMirrored = mirrored
        return warp.target
    }

    /// The mesh into `scratch`'s top-left `content` texels, premultiplied, cleared to 0 first.
    /// False while a pipeline compiles or failed, or an input is missing.
    /// `image`: what the mesh samples as the layer image, `draw.source` or it with the texture
    /// channels drawn on it. A rig with clipping masks draws in their steps (`ScenePuppetClipping`).
    private func encodeMesh(_ plan: ScenePuppetPlan, state: LayerState, _ draw: Draw, image: MTLTexture,
                            into scratch: MTLTexture, content: SIMD2<Int>, commandBuffer: MTLCommandBuffer) -> Bool {
        let pipeline = self.pipeline(plan.material, format: plan.format, blend: .material(plan.material.pass.blending),
                                     pixelFormat: Self.scratchFormat)
        let bound = pipeline == nil ? nil : textures(of: plan.material, plan: plan, draw, image: image, morph: state.morphTexture)
        let steps = plan.clipping.map { $0.layout.steps(order: $0.layout.order(draw.pose.drawRanges)) }
        let clipped = Self.clippedDraws(plan, steps: steps, pipeline: { self.pipeline($0, format: plan.format, blend: $1, pixelFormat: $2) })
        guard var encoder = Self.scratchEncoder(scratch, clear: true, commandBuffer: commandBuffer) else { return false }
        guard let pipeline, let bound, let clipped else {
            encoder.endEncoding()
            return false
        }

        // Identity model and view; orthographic over the image's pixels (WE's z range ±1000), the
        // image's top on the target's first row like every layer image.
        let projection = (draw.canvas ?? .image(plan.imageSize)).projection
        let bytes = uniformBytes(state.uniforms, material: plan.material, bound: bound, draw, projection: projection, content: content)
        bindMesh(encoder, plan: plan, state: state, draw, pipeline: pipeline, bound: bound, bytes: bytes, content: content,
                 commandBuffer: commandBuffer)
        guard let clip = plan.clipping, let steps else {
            Self.drawMesh(plan, ranges: draw.pose.drawRanges, indices: state.indices, encoder: encoder)
            encoder.endEncoding()
            drawsEncoded += 1
            return true
        }

        let targetBound = textures(of: clip.target, plan: plan, draw, image: image, morph: state.morphTexture)
        guard let targetBound, let targetUniforms = state.targetUniforms else {
            encoder.endEncoding()
            return false
        }
        let targetBytes = uniformBytes(targetUniforms, material: clip.target, bound: targetBound, draw, projection: projection,
                                       content: content)
        var boundMain = true
        state.clipPasses = 0
        for step in steps {
            switch step {
            case .draw(let ranges):
                if !boundMain {
                    bindMesh(encoder, plan: plan, state: state, draw, pipeline: pipeline, bound: bound, bytes: bytes,
                             content: content, commandBuffer: commandBuffer)
                    boundMain = true
                }
                Self.drawMesh(plan, ranges: clip.layout.drawRanges(ranges), indices: state.indices, encoder: encoder)
            case let .clip(layers, parts, additive):
                state.clipPasses += 1
                var partBound = targetBound
                if clip.mask != nil {
                    // The coverage is drawn into its own targets, between the scratch's passes.
                    encoder.endEncoding()
                    guard let coverage = encodeCoverage(plan, clip: clip, layers: layers, state: state, draw, image: image,
                                                        projection: projection, content: content, commandBuffer: commandBuffer),
                          let next = Self.scratchEncoder(scratch, clear: false, commandBuffer: commandBuffer) else { return false }
                    encoder = next
                    partBound.append((ImagePuppetCombos.clippingMaskSlot, coverage, clampSampler, nil))
                }
                guard let partPipeline = clipped[additive] else { continue }
                bindMesh(encoder, plan: plan, state: state, draw, pipeline: partPipeline, bound: partBound, bytes: targetBytes,
                         content: content, commandBuffer: commandBuffer)
                boundMain = false
                Self.drawMesh(plan, ranges: clip.layout.drawRanges(parts), indices: state.indices, encoder: encoder)
            }
        }
        encoder.endEncoding()
        drawsEncoded += 1
        return true
    }

    /// The pipelines `steps` draws its clipped parts with, by whether they're additive, and the
    /// mask pipeline when the plan draws the coverage; nil while one compiles or failed.
    private static func clippedDraws(_ plan: ScenePuppetPlan, steps: [ScenePuppetClipping.Step]?,
                                     pipeline: (ImageMaterialPlan, MeshBlend, MTLPixelFormat) -> MTLRenderPipelineState?)
        -> [Bool: MTLRenderPipelineState]? {
        guard let clip = plan.clipping, let steps else { return [:] }
        var out: [Bool: MTLRenderPipelineState] = [:]
        var drawsCoverage = false
        for case let .clip(_, _, additive) in steps {
            drawsCoverage = true
            guard out[additive] == nil else { continue }
            // The record's +0x40 replaces the material's blending for the clipped draw (0x140208b8f).
            guard let made = pipeline(clip.target, additive ? .additive : .material("translucent"), scratchFormat) else { return nil }
            out[additive] = made
        }
        if drawsCoverage, let mask = clip.mask, pipeline(mask, .coverage, coverageFormat) == nil { return nil }
        return out
    }

    /// A render pass into `scratch`, cleared to 0 or keeping what it holds.
    private static func scratchEncoder(_ scratch: MTLTexture, clear: Bool, commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = scratch
        renderPass.colorAttachments[0].loadAction = clear ? .clear : .load
        renderPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPass.colorAttachments[0].storeAction = .store
        return commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
    }

    /// `material`'s uniforms for this drawing, the pose's palette written in.
    private func uniformBytes(_ uniforms: ImageMaterialUniforms, material: ImageMaterialPlan, bound: [BoundTexture], _ draw: Draw,
                              projection: simd_float4x4, content: SIMD2<Int>) -> [UInt8] {
        if uniforms.size > 0 {
            let key = ImageMaterialUniforms.PassKey(
                model: matrix_identity_float4x4, viewProjection: projection, color: SIMD3(repeating: 1), alpha: 1,
                brightness: 1, spriteRotation: SIMD4(1, 0, 0, 1), spriteTranslation: .zero, screen: draw.frame.screenSize,
                textures: bound.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                            $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) })
            uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                var context = BuiltinPassContext(targetSize: SIMD2(Float(content.x), Float(content.y)))
                context.viewProjection = projection
                context.modelViewProjection = projection
                for entry in bound {
                    context.textures[entry.slot] = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                }
                return context
            }
        }
        var bytes = uniforms.bytes
        if let layout = material.pass.variant?.uniforms {
            Self.writePose(draw.pose, layout: layout, into: &bytes)
        }
        return bytes
    }

    /// Sets up `encoder` to draw the mesh through `pipeline` into `content` texels.
    private func bindMesh(_ encoder: MTLRenderCommandEncoder, plan: ScenePuppetPlan, state: LayerState, _ draw: Draw,
                          pipeline: MTLRenderPipelineState, bound: [BoundTexture], bytes: [UInt8], content: SIMD2<Int>,
                          commandBuffer: MTLCommandBuffer) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(content.x), height: Double(content.y),
                                        znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: content.x, height: content.y))
        encoder.setCullMode(plan.material.cullsBackFaces ? .back : .none)
        // WE's front faces (`frontFacing(mirrored:)`): the editor's counter-clockwise rig faces
        // the viewer; the other winding when the layer mirrors the image.
        encoder.setFrontFacing(Self.frontFacing(mirrored: draw.mirrored))
        encoder.setVertexBuffer(state.vertices, offset: 0, index: Self.meshBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        for entry in bound {
            encoder.setFragmentTexture(entry.texture, index: entry.slot)
            encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
            encoder.setVertexTexture(entry.texture, index: entry.slot)
            encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
        }
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer) }
        }
    }

    /// WE's `_rt_FullAlphaMask` for a clipped draw (0x14020d6a0): each layer's mask drawn through
    /// its ranges with `clippingmaskimage4` into a target cleared to 0, or to 1 and with
    /// `g_RenderVar0.x` = 1 for an inverted mask; a nested mask's layers after the first drawn into
    /// the intermediate target and multiplied in. nil when a target can't be made.
    private func encodeCoverage(_ plan: ScenePuppetPlan, clip: ScenePuppetClipPlan, layers: [ScenePuppetClipping.Layer],
                                state: LayerState, _ draw: Draw, image: MTLTexture, projection: simd_float4x4,
                                content: SIMD2<Int>, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let material = clip.mask, let uniforms = state.maskUniforms,
              let pipeline = pipeline(material, format: plan.format, blend: .coverage, pixelFormat: Self.coverageFormat),
              let base = textures(of: material, plan: plan, draw, image: image, morph: state.morphTexture),
              let first = coverageTexture(0, content: content) else { return nil }
        for (index, layer) in layers.enumerated() {
            guard let target = index == 0 ? first : coverageTexture(1, content: content) else { return nil }
            let mask = clip.layout.masks[layer.mask]
            let inverted: Float = mask.flags.contains(.invert) ? 1 : 0
            let painted = layer.mask < clip.maskTextures.count ? clip.maskTextures[layer.mask].flatMap { draw.assetTexture($0.key, $0.source) } : nil
            var bound = base
            bound.append((ImagePuppetCombos.clippingMaskTextureSlot, painted ?? emptyMorphTexture, clampSampler, nil))
            var bytes = uniformBytes(uniforms, material: material, bound: bound, draw, projection: projection, content: content)
            if let member = material.pass.variant?.uniforms?.members["g_RenderVar0"] {
                UniformWriter.write([inverted, 0, 0, 0], member: member, into: &bytes)
            }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(inverted), green: Double(inverted),
                                                               blue: Double(inverted), alpha: Double(inverted))
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
            bindMesh(encoder, plan: plan, state: state, draw, pipeline: pipeline, bound: bound, bytes: bytes, content: content,
                     commandBuffer: commandBuffer)
            Self.drawMesh(plan, ranges: clip.layout.drawRanges(layer.ranges), indices: state.indices, encoder: encoder)
            encoder.endEncoding()
            guard index > 0 else { continue }
            let compose = MTLRenderPassDescriptor()
            compose.colorAttachments[0].texture = first
            compose.colorAttachments[0].loadAction = .load
            compose.colorAttachments[0].storeAction = .store
            guard let composer = commandBuffer.makeRenderCommandEncoder(descriptor: compose) else { return nil }
            composer.setRenderPipelineState(coverageCompose)
            composer.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(content.x), height: Double(content.y),
                                             znear: 0, zfar: 1))
            composer.setFragmentTexture(target, index: 0)
            composer.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            composer.endEncoding()
        }
        return first
    }

    /// The coverage's format: its red channel is all the clipped draw reads.
    static let coverageFormat: MTLPixelFormat = .r8Unorm

    /// Coverage target `index` (0 the mask, 1 the intermediate), exactly `content` texels: the
    /// clipped draw samples it over its viewport (`CLIPPINGUVS`).
    private func coverageTexture(_ index: Int, content: SIMD2<Int>) -> MTLTexture? {
        if let existing = coverage[index], existing.width == content.x, existing.height == content.y { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.coverageFormat, width: content.x,
                                                                  height: content.y, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        coverage[index] = device.makeTexture(descriptor: descriptor)
        return coverage[index]
    }

    /// The mask passes the layer's last drawing made (the editor's "Clipping mask passes").
    func clippingMaskPasses(_ layerID: String) -> Int { layers[layerID]?.clipPasses ?? 0 }

    /// The ranges the pose draws in the layer's image: its `drawRanges`, or with clipping masks
    /// every part their steps draw (without "Hide mask geometry"'s), clipped ones unclipped.
    static func visibleRanges(_ plan: ScenePuppetPlan, pose: ScenePuppetPose) -> [ScenePuppetDrawOrder.Range]? {
        guard let clip = plan.clipping else { return pose.drawRanges }
        return clip.layout.visibleRanges(order: clip.layout.order(pose.drawRanges))
    }

    /// The mesh's triangles: the index buffer as it is, or its `ranges` in their order
    /// (`ScenePuppetDrawOrder`), later ranges over earlier ones.
    static func drawMesh(_ plan: ScenePuppetPlan, ranges: [ScenePuppetDrawOrder.Range]?, indices: MTLBuffer,
                         encoder: MTLRenderCommandEncoder) {
        let type: MTLIndexType = plan.usesUInt32Indices ? .uint32 : .uint16
        guard let ranges else {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: plan.indexCount, indexType: type,
                                          indexBuffer: indices, indexBufferOffset: 0)
            return
        }
        let size = plan.usesUInt32Indices ? 4 : 2
        for range in ranges where range.indexCount > 0 && range.firstIndex + range.indexCount <= plan.indexCount {
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: range.indexCount, indexType: type,
                                          indexBuffer: indices, indexBufferOffset: range.firstIndex * size)
        }
    }

    /// `g_Bones`, `g_BonesAlpha` and the morph uniforms (zero without targets: none applies).
    static func writePose(_ pose: ScenePuppetPose, layout: UniformLayout, into bytes: inout [UInt8]) {
        pose.morph?.write(into: &bytes, layout: layout)
        if let member = layout.members["g_Bones"] {
            UniformWriter.write(pose.boneComponents, member: member, into: &bytes)
        }
        if let member = layout.members["g_BonesAlpha"] {
            UniformWriter.write(pose.bonesAlpha, member: member, into: &bytes)
        }
    }

    private typealias BoundTexture = (slot: Int, texture: MTLTexture, sampler: MTLSamplerState, contentSize: SIMD2<Float>?)

    /// The textures `material`'s mesh pass reads; nil when one isn't there this frame. The slots
    /// the engine fills (the coverage, a mask's texture) are left to the caller.
    private func textures(of material: ImageMaterialPlan, plan: ScenePuppetPlan, _ draw: Draw, image: MTLTexture,
                          morph: MTLTexture?) -> [BoundTexture]? {
        var bound: [BoundTexture] = []
        let pass = material.pass
        for slot in pass.variant?.textureSlots ?? [] {
            let sampler = material.clampedSlots.contains(slot) ? clampSampler : repeatSampler
            guard let input = pass.textures[slot] else {
                if plan.combos.morphing, slot == ImagePuppetCombos.morphSlot {
                    bound.append((slot, morph ?? emptyMorphTexture, clampSampler, nil))
                }
                continue
            }
            switch input {
            case .current, .previous:
                let content = SIMD2(Float(plan.contentPixels.x), Float(plan.contentPixels.y))
                let whole = SIMD2(Float(image.width), Float(image.height))
                bound.append((slot, image, sampler, content == whole ? nil : content))
            case .asset(let key, let source):
                guard let texture = draw.assetTexture(key, source) else { return nil }
                bound.append((slot, texture, sampler, source.contentSize))
            case .sceneSnapshot, .mipMappedFrameBuffer, .fbo:
                // Only a lit or blended pass reads the scene; the mesh pass is neither.
                return nil
            }
        }
        return bound
    }

    private func scratchTexture(covering content: SIMD2<Int>) -> MTLTexture? {
        if let scratch, scratch.width >= content.x, scratch.height >= content.y { return scratch }
        let width = max(content.x, scratch?.width ?? 0), height = max(content.y, scratch?.height ?? 0)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.scratchFormat, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        scratch = device.makeTexture(descriptor: descriptor)
        return scratch
    }

    // MARK: - Pipelines

    /// The mesh's interleaved vertices.
    static let meshBuffer = EffectGraphRenderer.positionBuffer

    /// How a mesh pipeline blends.
    enum MeshBlend: Hashable {
        /// The material's blending (`applyBlending`).
        case material(String)
        /// Added over the parts before (a clipping mask's "Additive blending").
        case additive
        /// A clipping mask's coverage: `clippingmaskimage4`'s translucent, straight alpha.
        case coverage

        var key: String {
            switch self {
            case .material(let blending): blending.lowercased()
            case .additive: "clip-additive"
            case .coverage: "clip-coverage"
            }
        }
    }

    static func pipelineKey(_ plan: ScenePuppetPlan) -> String {
        pipelineKey(plan.material, format: plan.format, blend: .material(plan.material.pass.blending), pixelFormat: scratchFormat)
    }

    static func pipelineKey(_ material: ImageMaterialPlan, format: MDLVertexFormat, blend: MeshBlend,
                            pixelFormat: MTLPixelFormat) -> String {
        let base = "puppet|\(material.pass.variantKey)|\(format.rawValue)|\(blend.key)"
        return pixelFormat == scratchFormat ? base : "\(base)|\(pixelFormat.rawValue)"
    }

    /// Blocks until the plan's pipelines compiled or failed (tests, prewarming): its mesh's and,
    /// with clipping masks, the clipped parts' and the masks'. True when they are ready.
    func waitUntilReady(_ plan: ScenePuppetPlan, timeout: TimeInterval = 60) -> Bool {
        var wanted: [(ImageMaterialPlan, MeshBlend, MTLPixelFormat)] = [(plan.material, .material(plan.material.pass.blending), Self.scratchFormat)]
        if let clip = plan.clipping {
            wanted += [(clip.target, .material("translucent"), Self.scratchFormat), (clip.target, .additive, Self.scratchFormat)]
            if let mask = clip.mask { wanted.append((mask, .coverage, Self.coverageFormat)) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        for (material, blend, pixelFormat) in wanted {
            let key = Self.pipelineKey(material, format: plan.format, blend: blend, pixelFormat: pixelFormat)
            while pipeline(material, format: plan.format, blend: blend, pixelFormat: pixelFormat) == nil {
                if pipelineLock.withLock({ failed.contains(key) }) || Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return true
    }

    private func pipeline(_ material: ImageMaterialPlan, format: MDLVertexFormat, blend: MeshBlend,
                          pixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(material, format: format, blend: blend, pixelFormat: pixelFormat)
        let state: (pipeline: MTLRenderPipelineState?, busy: Bool) = pipelineLock.withLock {
            (pipelines[key], pending.contains(key) || failed.contains(key))
        }
        if let pipeline = state.pipeline { return pipeline }
        if !state.busy, let variant = material.pass.variant {
            compile(variant, key: key, format: format, blend: blend, pixelFormat: pixelFormat, materialPath: material.materialPath)
        }
        return nil
    }

    private func compile(_ variant: TranslatedShaderVariant, key: String, format: MDLVertexFormat, blend: MeshBlend,
                         pixelFormat: MTLPixelFormat, materialPath material: String) {
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
                Self.applyBlending(blend, to: descriptor.colorAttachments[0])
                descriptor.vertexDescriptor = Self.vertexDescriptor(for: vertex, attributes: variant.attributes, format: format)
                result = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: key)
            } catch {
                OWELog.error(.shader, "Puppet mesh material \(material) can't draw through its shader; the layer shows nothing: \(error)")
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

    /// Triangles over each other: premultiplied "over" (WE's translucent and additive draws
    /// composite over the ones before them), unblended for `normal`, which replaces.
    static func applyBlending(_ blending: String, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        guard EffectGraphRenderer.blendMode(blending) != nil else { return }
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }

    /// `blend` on `attachment`. A clipping mask's additive parts add their premultiplied colour
    /// to the parts before them and cover them as "over" does [I: the alpha]; its coverage blends
    /// translucent as `clippingmaskimage4.json` says, straight alpha into a target of its own.
    static func applyBlending(_ blend: MeshBlend, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch blend {
        case .material(let blending):
            applyBlending(blending, to: attachment)
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .coverage:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }

    /// The mesh's interleaved attributes at the locations the translated stage reads them from
    /// (`HLSLLinkage.attributeLocations`); an input the mesh lacks reads zeros, as WE's input
    /// layout leaves it (docs/models-plan.md §5, open point 11).
    static func vertexDescriptor(for function: MTLFunction, attributes: [String: Int],
                                 format: MDLVertexFormat) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        let names = Dictionary(attributes.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        var usesZero = false, usesMesh = false
        for input in function.vertexAttributes ?? [] where input.isActive {
            let element = descriptor.attributes[input.attributeIndex]!
            let isInteger = [.uint, .uint2, .uint3, .uint4, .int, .int2, .int3, .int4].contains(input.attributeType)
            if let name = names[input.attributeIndex], let attribute = MDLVertexAttribute.named(name),
               let offset = format.offset(of: attribute) {
                element.format = vertexFormat(attribute)
                element.offset = offset
                element.bufferIndex = meshBuffer
                usesMesh = true
            } else {
                element.format = isInteger ? .uint4 : .float4
                element.offset = 0
                element.bufferIndex = EffectGraphRenderer.zeroBuffer
                usesZero = true
            }
        }
        // Metal refuses a layout no attribute reads, so it is set only when one does.
        if usesMesh { descriptor.layouts[meshBuffer].stride = format.stride }
        if usesZero {
            descriptor.layouts[EffectGraphRenderer.zeroBuffer].stride = 16
            descriptor.layouts[EffectGraphRenderer.zeroBuffer].stepFunction = .constant
            descriptor.layouts[EffectGraphRenderer.zeroBuffer].stepRate = 0
        }
        return descriptor
    }

    static func vertexFormat(_ attribute: MDLVertexAttribute) -> MTLVertexFormat {
        switch (attribute.componentType, attribute.components) {
        case (.uint32, _): return .uint4
        case (.float32, 2): return .float2
        case (.float32, 3): return .float3
        default: return .float4
        }
    }
}
