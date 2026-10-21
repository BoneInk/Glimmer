import Foundation
import Metal
import simd

/// Draws puppets' texture channels (`ScenePuppetChannelPlan`) over their images: per layer, an
/// image-sized target holding the image with the channel quads drawn on it through the channel
/// material, which the puppet's mesh then samples instead of the image (WE's 0x140207740). It is
/// redrawn only when the image, the channel weights or a user-bound constant changed. While the
/// pipeline compiles, or while no channel weighs anything (`drawsAnything`, so the target would
/// be the image), there is no target and the mesh samples the image itself. Render thread only,
/// apart from the compiles.
final class ScenePuppetChannelRenderer {
    /// The target's format: the layer images' (`ScenePuppetRenderer.targetFormat`).
    static let targetFormat: MTLPixelFormat = .rgba8Unorm

    private let device: MTLDevice
    private let archive: EffectPipelineArchive?
    private let copyBase: MTLComputePipelineState
    private let zeroAttributes: MTLBuffer
    private let uniformArena: SceneUniformArena

    private let compileQueue = DispatchQueue(label: "owe.puppet-channel-pipelines", qos: .userInitiated,
                                             attributes: .concurrent)
    /// Owns `pipelines`, `pending` and `failed`, which compile threads write.
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private var landedPipelines = 0

    /// Whether a pipeline is still compiling: a frame drawn now lacks that puppet's texture channels.
    var hasPendingPipelines: Bool { pipelineLock.withLock { !pending.isEmpty } }
    /// Compiles finished so far, however they ended.
    var pipelinesLanded: Int { pipelineLock.withLock { landedPipelines } }

    /// Per layer instance. Render thread only.
    private var layers: [String: LayerState] = [:]
    private var lastVersion: UInt64 = 0

    private final class LayerState {
        let plan: ScenePuppetChannelPlan
        let uniforms: ImageMaterialUniforms
        let vertices: MTLBuffer
        let indices: MTLBuffer
        var target: MTLTexture?
        var drawnBase: ObjectIdentifier?
        var drawnBlendMap: [Float]?
        var version: UInt64 = 0

        init?(plan: ScenePuppetChannelPlan, device: MTLDevice) {
            self.plan = plan
            uniforms = ImageMaterialUniforms(layout: plan.material.pass.variant?.uniforms,
                                             constants: plan.material.pass.constants, liveFactors: [:])
            guard let vertices = plan.vertexData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }),
                  let indices = plan.indexData.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) })
            else { return nil }
            self.vertices = vertices
            self.indices = indices
        }
    }

    /// Channel draws encoded, for tests and diagnostics.
    private(set) var drawsEncoded = 0

    var allocatedBytes: Int { layers.values.reduce(0) { $0 + ($1.target?.allocatedSize ?? 0) } }

    init?(device: MTLDevice, library: MTLLibrary, archive: EffectPipelineArchive?) {
        self.device = device
        self.archive = archive
        uniformArena = SceneUniformArena(device: device)
        do {
            guard let function = library.makeFunction(name: "scenePuppetChannelBase") else { return nil }
            copyBase = try device.makeComputePipelineState(function: function)
        } catch {
            OWELog.error(.scene, "The puppet texture-channel pipeline failed: \(error)")
            return nil
        }
        guard let zero = device.makeBuffer(length: 64) else { return nil }
        zeroAttributes = zero
    }

    func releaseAll() { layers.removeAll() }
    func releaseLayer(_ layerID: String) { layers.removeValue(forKey: layerID) }
    func trimMemory() { uniformArena.trim() }

    /// What the channels draw over this frame.
    struct Draw {
        let layerID: String
        /// The puppet's image as uploaded (the mesh pass's `g_Texture0`).
        let image: MTLTexture
        /// The image's texels inside `image`, from its top-left corner.
        let contentPixels: SIMD2<Int>
        /// The image in the quads' units: its full-resolution pixels.
        let imageSize: SIMD2<Float>
        /// The channel weights (`ScenePuppetPose.blendMap`).
        let blendMap: [Float]
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
    }

    /// The image with the channels drawn on it, in the image's texture layout, and which drawing
    /// it holds (a new version each redraw); nil when the mesh should sample the image itself.
    /// Encodes its own passes, so call it outside any open render pass.
    func composite(_ plan: ScenePuppetChannelPlan, _ draw: Draw,
                   commandBuffer: MTLCommandBuffer) -> (texture: MTLTexture, version: UInt64)? {
        guard plan.drawsAnything(blendMap: draw.blendMap) else { return nil }
        guard let state = layerState(plan, layerID: draw.layerID), let pipeline = pipeline(for: plan) else { return nil }
        let size = SIMD2(draw.image.width, draw.image.height)
        if state.target.map({ SIMD2($0.width, $0.height) }) != size {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.targetFormat, width: size.x,
                                                                      height: size.y, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            state.target = device.makeTexture(descriptor: descriptor)
            state.drawnBase = nil
        }
        guard let target = state.target else { return nil }
        let base = ObjectIdentifier(draw.image)
        if state.drawnBase == base, state.drawnBlendMap == draw.blendMap, plan.material.pass.constants.dynamic.isEmpty {
            return (target, state.version)
        }
        guard let bound = textures(of: plan, draw) else { return nil }

        guard let compute = commandBuffer.makeComputeCommandEncoder() else { return nil }
        compute.setComputePipelineState(copyBase)
        compute.setTexture(draw.image, index: 0)
        compute.setTexture(target, index: 1)
        compute.dispatchThreadgroups(MTLSize(width: (size.x + 15) / 16, height: (size.y + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        defer { encoder.endEncoding() }
        let content = simd_min(draw.contentPixels, size)
        // The quads are in the image's pixels from its bottom-left corner, y up; its top row is
        // the target's first, as the mesh pass lays the image out.
        let projection = ScenePuppetCanvas(min: .zero, max: draw.imageSize).projection
        var bytes: [UInt8] = []
        if state.uniforms.size > 0 {
            let key = ImageMaterialUniforms.PassKey(
                model: matrix_identity_float4x4, viewProjection: projection, color: SIMD3(repeating: 1), alpha: 1,
                brightness: 1, spriteRotation: SIMD4(1, 0, 0, 1), spriteTranslation: .zero, screen: draw.frame.screenSize,
                textures: bound.map { SIMD4(Float($0.texture.width), Float($0.texture.height),
                                            $0.contentSize?.x ?? 0, $0.contentSize?.y ?? 0) })
            state.uniforms.update(key: key, frame: draw.frame, values: draw.values) {
                var context = BuiltinPassContext(targetSize: SIMD2(Float(content.x), Float(content.y)))
                context.viewProjection = projection
                context.modelViewProjection = projection
                for entry in bound {
                    context.textures[entry.slot] = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: entry.contentSize)
                }
                return context
            }
            bytes = state.uniforms.bytes
            if let member = plan.material.pass.variant?.uniforms?.members["g_BlendMap"] {
                UniformWriter.write(plan.blendMapComponents(draw.blendMap), member: member, into: &bytes)
            }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(content.x), height: Double(content.y),
                                        znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: content.x, height: content.y))
        encoder.setCullMode(plan.material.cullsBackFaces ? .back : .none)
        encoder.setFrontFacing(ScenePuppetRenderer.frontFacing(mirrored: false))
        encoder.setVertexBuffer(state.vertices, offset: 0, index: ScenePuppetRenderer.meshBuffer)
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
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: plan.indexCount,
                                      indexType: plan.usesUInt32Indices ? .uint32 : .uint16,
                                      indexBuffer: state.indices, indexBufferOffset: 0)
        drawsEncoded += 1
        lastVersion &+= 1
        state.version = lastVersion
        state.drawnBase = base
        state.drawnBlendMap = draw.blendMap
        return (target, state.version)
    }

    private func layerState(_ plan: ScenePuppetChannelPlan, layerID: String) -> LayerState? {
        if let existing = layers[layerID], existing.plan === plan { return existing }
        guard let made = LayerState(plan: plan, device: device) else { return nil }
        layers[layerID] = made
        return made
    }

    private typealias BoundTexture = (slot: Int, texture: MTLTexture, sampler: MTLSamplerState, contentSize: SIMD2<Float>?)

    /// The material's textures (the atlas, the base image); nil when one isn't there this frame.
    private func textures(of plan: ScenePuppetChannelPlan, _ draw: Draw) -> [BoundTexture]? {
        var bound: [BoundTexture] = []
        let pass = plan.material.pass
        for slot in pass.variant?.textureSlots ?? [] {
            guard let input = pass.textures[slot] else { continue }
            let clamps = plan.material.clampedSlots.contains(slot)
            guard let sampler = clamps ? clampSampler : repeatSampler else { return nil }
            switch input {
            case .asset(let key, let source):
                guard let texture = draw.assetTexture(key, source) else { return nil }
                bound.append((slot, texture, sampler, source.contentSize))
            case .current, .previous:
                let content = SIMD2(Float(draw.contentPixels.x), Float(draw.contentPixels.y))
                bound.append((slot, draw.image, sampler, content))
            case .sceneSnapshot, .mipMappedFrameBuffer, .fbo:
                return nil
            }
        }
        return bound
    }

    private lazy var clampSampler: MTLSamplerState? = sampler(.clampToEdge)
    private lazy var repeatSampler: MTLSamplerState? = sampler(.repeat)

    private func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = mode
        descriptor.tAddressMode = mode
        return device.makeSamplerState(descriptor: descriptor)
    }

    // MARK: - Pipelines

    static func pipelineKey(_ plan: ScenePuppetChannelPlan) -> String {
        "puppet-channels|\(plan.material.pass.variantKey)|\(plan.format.rawValue)|\(plan.material.writesAlpha)"
    }

    /// Blocks until the plan's pipeline compiled or failed (tests, prewarming). True when it is ready.
    func waitUntilReady(_ plan: ScenePuppetChannelPlan, timeout: TimeInterval = 60) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let key = Self.pipelineKey(plan)
        while pipeline(for: plan) == nil {
            if pipelineLock.withLock({ failed.contains(key) }) || Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    private func pipeline(for plan: ScenePuppetChannelPlan) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(plan)
        let state: (pipeline: MTLRenderPipelineState?, busy: Bool) = pipelineLock.withLock {
            (pipelines[key], pending.contains(key) || failed.contains(key))
        }
        if let pipeline = state.pipeline { return pipeline }
        if !state.busy, let variant = plan.material.pass.variant {
            compile(variant, plan: plan, key: key)
        }
        return nil
    }

    private func compile(_ variant: TranslatedShaderVariant, plan: ScenePuppetChannelPlan, key: String) {
        pipelineLock.withLock { _ = pending.insert(key) }
        let device = self.device
        let archive = self.archive
        let format = plan.format
        let writesAlpha = plan.material.writesAlpha
        let material = plan.material.materialPath
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
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = Self.targetFormat
                // Blended over the image whatever the material's `blending` ("normal" in WE's
                // editor output): WE's capture at weight 0, where every fragment has alpha 0,
                // leaves the target identical to the image.
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                if !writesAlpha { attachment.writeMask = [.red, .green, .blue] }
                descriptor.vertexDescriptor = ScenePuppetRenderer.vertexDescriptor(for: vertex, attributes: variant.attributes,
                                                                                   format: format)
                result = try EffectGraphRenderer.makePipeline(descriptor, device: device, archive: archive, key: key)
            } catch {
                OWELog.error(.shader, "Puppet texture-channel material \(material) can't draw through its shader; "
                             + "the puppet draws without its channels: \(error)")
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
