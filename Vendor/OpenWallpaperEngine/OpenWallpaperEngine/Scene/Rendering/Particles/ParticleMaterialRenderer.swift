import Metal
import simd

/// Draws particle systems through their Wallpaper Engine material: WE's `genericparticle` /
/// `genericropeparticle` shaders (or a workshop shader in their place) with the material's
/// blending, combos, textures and constants. One instanced draw per system: each record
/// (`ParticleVertexFormat`) is one instance, expanded on the GPU by the emulated geometry
/// stage (`GeometryShaderEmulation`) or WE's no-geometry-shader stream (`ParticleQuadExpansion`).
///
/// A system draws nothing while its pipeline compiles. One whose material has no usable stage
/// (every pipeline failed) keeps the renderer's built-in particle draw, logged once per system.
/// A stage that reads the scene (`_rt_FullFrameBuffer`, refraction) draws with the snapshot the
/// caller takes right before it (`readsSceneSnapshot`, `DrawContext.sceneSnapshot`).
final class ParticleMaterialRenderer {
    /// Vertex buffer slots; buffer 0 is the `WEUniforms` block.
    static let recordBuffer = 30
    static let zeroBuffer = 28

    private let device: MTLDevice
    private let zeroAttributes: MTLBuffer
    /// Uniform blocks over 4 KB. Render thread only (see `SceneUniformArena`).
    let uniformArena: SceneUniformArena
    /// By `.tex` flags that pick a sampler (`clampUVs`, `noInterpolation`).
    private var samplers: [UInt32: MTLSamplerState] = [:]
    /// `_rt_shadowAtlas`'s comparison sampler (`SceneShadowAtlas.makeSampler`).
    private let shadowSampler: MTLSamplerState

    /// Pipelines compile off the render thread. Guarded by `pipelineLock`.
    private let compileQueue = DispatchQueue(label: "owe.particle-pipelines", qos: .userInitiated, attributes: .concurrent)
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    /// Pipelines drawn with since the last `trimMemory` that dropped idle ones.
    private var usedPipelines = Set<String>()
    private var pendingPipelines = Set<String>()

    /// Whether a pipeline is still compiling: a frame drawn now may change when it lands.
    /// Compiles finished so far, however they ended: a frame drawn before one landed is redrawn.
    var pipelinesLanded: Int {
        pipelineLock.withLock { landedPipelines }
    }
    private var landedPipelines = 0

    var hasPendingPipelines: Bool {
        pipelineLock.withLock { !pendingPipelines.isEmpty }
    }
    private var failedPipelines: [String: String] = [:]

    /// Per system, render thread only.
    private var systems: [ObjectIdentifier: SystemState] = [:]
    /// Each stage geometry's index list (`ParticleMaterialPlan.Stage.Geometry.indices`), built
    /// once. Render thread only.
    private var indexBuffers: [ParticleMaterialPlan.Stage.Geometry: (buffer: MTLBuffer, type: MTLIndexType)] = [:]

    private final class SystemState {
        weak var owner: ParticleSystemRuntime?
        /// Uniform blocks the GPU simulation patches (`Simulated.renderVar`), ring-buffered.
        let uniformBlocks: ParticleRecordBuffer
        var programs: [String: UniformProgram] = [:]
        /// Each stage's pipeline key, by pixel format: built once, looked up every frame.
        /// By target format and sample count (`targetKey`).
        var pipelineKeys: [UInt: [String]] = [:]
        /// The particle uniforms' members in each stage's block (`ParticleMaterialUniforms.Members`).
        var members: [String: ParticleMaterialUniforms.Members] = [:]
        /// The uniform block being patched, reused frame to frame.
        var scratch: [UInt8] = []
        /// This frame's draw, set by `prepareSimulated`; `uniforms` is the block the GPU step
        /// patches, when it does.
        var prepared: (stage: ParticleMaterialPlan.Stage, pipeline: MTLRenderPipelineState, uniforms: MTLBuffer?)?
        var reportedFallback = false

        init(owner: ParticleSystemRuntime, device: MTLDevice) {
            self.owner = owner
            uniformBlocks = ParticleRecordBuffer(device: device)
        }
    }

    /// What the GPU simulation writes for a system drawn through its material.
    struct Simulated {
        let format: ParticleVertexFormat
        /// Vertices per instance of the stage's draw.
        let vertexCount: Int
        /// The uniform block and byte offset of `g_RenderVar0`, which holds the rope's point
        /// count: only the GPU knows it this frame.
        let renderVar: (buffer: MTLBuffer, offset: Int)?
    }

    /// Counters for tests and diagnostics.
    private(set) var drawsEncoded = 0
    /// Systems logged as falling back to the built-in draw; each is reported once.
    private(set) var fallbacksReported = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let zero = device.makeBuffer(length: 64), let shadow = SceneShadowAtlas.makeSampler(device: device) else { return nil }
        zeroAttributes = zero
        shadowSampler = shadow
        uniformArena = SceneUniformArena(device: device)
    }

    /// WE's sampler for a texture: clamp with `clampUVs`, else repeat; nearest with
    /// `noInterpolation`, else bilinear.
    private func sampler(for flags: TEXFlags) -> MTLSamplerState? {
        let key = flags.intersection([.clampUVs, .noInterpolation]).rawValue
        if let sampler = samplers[key] { return sampler }
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = flags.contains(.noInterpolation) ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.mipFilter = flags.contains(.noInterpolation) ? .nearest : .linear
        let address: MTLSamplerAddressMode = flags.contains(.clampUVs) ? .clampToEdge : .repeat
        descriptor.sAddressMode = address
        descriptor.tAddressMode = address
        let sampler = device.makeSamplerState(descriptor: descriptor)
        samplers[key] = sampler
        return sampler
    }

    /// Forgets every system (the scene changed). Compiled pipelines are kept.
    func releaseAll() {
        systems.removeAll()
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

    /// Compiled pipelines, for tests and diagnostics.
    var pipelineCount: Int { pipelineLock.withLock { pipelines.count } }

    // MARK: - Frame

    /// Picks `system`'s stage for a draw whose records the GPU simulation writes this frame.
    /// Nil means the system can't draw through its material; the caller draws it the built-in way.
    /// While its pipeline
    /// compiles, the simulation writes the compiling stage's records and `draw` draws nothing.
    func prepareSimulated(_ system: ParticleSystemRuntime, pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
                          depthFormat: MTLPixelFormat = .invalid) -> Simulated? {
        guard let plan = system.configuration.material else { return nil }
        let state = state(for: system)
        state.prepared = nil
        let ready: (stage: ParticleMaterialPlan.Stage, pipeline: MTLRenderPipelineState)
        switch readiness(plan, pixelFormat: pixelFormat, sampleCount: sampleCount, depthFormat: depthFormat, state: state) {
        case .unavailable: return nil
        case .compiling(let stage):
            return Simulated(format: plan.format, vertexCount: Self.vertexCount(stage), renderVar: nil)
        case .ready(let stage, let pipeline): ready = (stage, pipeline)
        }
        var renderVar: (buffer: MTLBuffer, offset: Int)?
        var uniforms: MTLBuffer?
        if plan.format == .rope, system.configuration.rendererName != "ropetrail",
           let member = ready.stage.variant.uniforms?.members["g_RenderVar0"] {
            let program = self.program(for: ready.stage, state: state)
            guard let block = state.uniformBlocks.next(bytes: program.size) else { return nil }
            uniforms = block
            renderVar = (block, member.offset)
        }
        state.prepared = (ready.stage, ready.pipeline, uniforms)
        return Simulated(format: plan.format, vertexCount: Self.vertexCount(ready.stage), renderVar: renderVar)
    }

    /// Indices each instance of `stage`'s draw lists.
    private static func vertexCount(_ stage: ParticleMaterialPlan.Stage) -> Int {
        switch stage.geometry {
        case .emulated(let count, _): return count
        case .expandedQuads: return ParticleQuadExpansion.verticesPerInstance
        }
    }

    /// `geometry`'s index list, 16-bit when its vertex ids fit.
    private func indexBuffer(for geometry: ParticleMaterialPlan.Stage.Geometry) -> (buffer: MTLBuffer, type: MTLIndexType)? {
        if let known = indexBuffers[geometry] { return known }
        let indices = geometry.indices
        let buffer: MTLBuffer?
        let type: MTLIndexType
        if (indices.max() ?? 0) <= UInt32(UInt16.max) {
            let narrow = indices.map { UInt16($0) }
            buffer = device.makeBuffer(bytes: narrow, length: max(narrow.count, 1) * 2, options: .storageModeShared)
            type = .uint16
        } else {
            buffer = device.makeBuffer(bytes: indices, length: max(indices.count, 1) * 4, options: .storageModeShared)
            type = .uint32
        }
        guard let buffer else { return nil }
        buffer.label = "Particle material indices"
        indexBuffers[geometry] = (buffer, type)
        return (buffer, type)
    }

    /// `stage`'s uniforms. The planar reflection's draw has its own (`reflected`): a program writes
    /// its pass values only when they change, so the two passes' cameras mustn't share one.
    private func program(for stage: ParticleMaterialPlan.Stage, state: SystemState, reflected: Bool = false) -> UniformProgram {
        let key = reflected ? "reflection|" + stage.variantKey : stage.variantKey
        if let program = state.programs[key] { return program }
        let program = UniformProgram(layout: stage.variant.uniforms, constants: stage.constants)
        state.programs[key] = program
        return program
    }

    struct DrawContext {
        let sceneSize: SIMD2<Float>
        let frame: BuiltinFrameContext
        let values: SceneValueContext
        /// Texture for an asset input, materialised by the renderer.
        let assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?
        /// The scene drawn so far (`_rt_FullFrameBuffer`), for a system that reads it.
        var sceneSnapshot: MTLTexture?
        /// `_rt_MipMappedFrameBuffer` (`SceneMipMappedFrameBuffer`), for a system that samples it.
        var mipMappedFrameBuffer: MTLTexture? = nil
        /// `_rt_shadowAtlas` this frame (`SceneShadowAtlas`: the maps `SceneShadowPass` drew, or the
        /// cleared stand-in), for a lit particle material under a shadowed light (`genericparticle`'s
        /// `g_Texture4`).
        var shadowAtlas: MTLTexture? = nil
        /// The pass's depth buffer, when it has one: the system draws with its material's
        /// `SceneRasterState` (docs/models-plan.md §2.4).
        var depth: SceneDepthStates? = nil
        /// The system drawn through a 3D camera (a perspective scene's, or a `perspective` system's
        /// temporary one); nil draws it through the orthographic scene view.
        var placement: ParticleMaterialUniforms.Placement? = nil
    }

    /// Whether `system`'s draw this frame reads the scene drawn so far, which the caller then
    /// snapshots right before it and passes in `DrawContext.sceneSnapshot`.
    func readsSceneSnapshot(_ system: ParticleSystemRuntime) -> Bool {
        guard let state = systems[ObjectIdentifier(system)], state.owner === system else { return false }
        return state.prepared?.stage.readsSceneSnapshot ?? false
    }

    /// Encodes the draw `prepareSimulated` set up for `system` this frame.
    func draw(_ system: ParticleSystemRuntime, encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer,
              context: DrawContext) {
        guard let plan = system.configuration.material,
              let state = systems[ObjectIdentifier(system)], state.owner === system,
              let prepared = state.prepared else { return }
        state.prepared = nil
        encode(system, plan: plan, state: state, prepared: prepared, pipeline: prepared.pipeline, reflected: false,
               encoder: encoder, commandBuffer: commandBuffer, context: context)
    }

    /// Encodes the draw `prepareSimulated` set up for `system` this frame into another pass as well, before
    /// `draw` encodes it into the scene pass: the planar reflection's (docs/models-plan.md §2.11),
    /// a `pixelFormat` target of `sampleCount` samples with `depthFormat` depth. The same stage and
    /// records draw through a pipeline for that target, and the uniforms, `context`'s camera
    /// included, go through the arena (the GPU step patches only the scene draw's block, so a
    /// GPU-simulated rope keeps its material's `g_RenderVar0` here). Nothing is drawn while that
    /// pipeline compiles or the system has no draw this frame; false then.
    @discardableResult
    func draw(_ system: ParticleSystemRuntime, alsoInto pixelFormat: MTLPixelFormat, sampleCount: Int,
              depthFormat: MTLPixelFormat, encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer,
              context: DrawContext) -> Bool {
        guard let plan = system.configuration.material,
              let state = systems[ObjectIdentifier(system)], state.owner === system,
              let prepared = state.prepared,
              case .ready(let stage, let pipeline) = readiness(plan, pixelFormat: pixelFormat, sampleCount: sampleCount,
                                                               depthFormat: depthFormat, state: state),
              stage.variantKey == prepared.stage.variantKey else { return false }
        encode(system, plan: plan, state: state, prepared: prepared, pipeline: pipeline, reflected: true,
               encoder: encoder, commandBuffer: commandBuffer, context: context)
        return true
    }

    /// Encodes `prepared` through `pipeline`; `reflected` for the planar reflection's draw, whose
    /// uniforms have their own program and go through the arena, not the block the GPU step patches.
    private func encode(_ system: ParticleSystemRuntime, plan: ParticleMaterialPlan, state: SystemState,
                        prepared: (stage: ParticleMaterialPlan.Stage, pipeline: MTLRenderPipelineState, uniforms: MTLBuffer?),
                        pipeline: MTLRenderPipelineState, reflected: Bool, encoder: MTLRenderCommandEncoder,
                        commandBuffer: MTLCommandBuffer, context: DrawContext) {
        // The records the GPU simulation wrote (`ParticleGPUSystem.records`), drawn indirectly.
        guard let gpu = system.gpu, gpu.isReady, let recordBuffer = gpu.records, gpu.recordKind?.isFallback == false else { return }
        let stage = prepared.stage
        encoder.setRenderPipelineState(pipeline)
        // WE's particle vertices (`genericparticle`'s strip, the emulation keeps its winding) face
        // the camera counter-clockwise in clip space, as a model's front faces do.
        context.depth?.apply(plan.raster, to: encoder, front: SceneModelRenderer.frontFacing)
        encoder.setVertexBuffer(recordBuffer, offset: 0, index: Self.recordBuffer)
        encoder.setVertexBuffer(zeroAttributes, offset: 0, index: Self.zeroBuffer)

        var textures: [Int: BuiltinTextureInfo] = [:]
        for slot in stage.variant.textureSlots {
            let texture: MTLTexture
            let flags: TEXFlags
            var contentSize: SIMD2<Float>?
            switch stage.textures[slot] {
            case .asset(let key, let source)?:
                // Texture 0 is the one the system already loaded.
                guard let asset = slot == 0 ? system.texture : context.assetTexture(key, source) else { continue }
                texture = asset
                flags = plan.textureFlags[slot] ?? []
                contentSize = source.contentSize
            case .sceneSnapshot?:
                // Without the scene there is nothing to refract; the caller always passes it
                // when `readsSceneSnapshot` (only a failed allocation leaves it out).
                guard let snapshot = context.sceneSnapshot else { return }
                texture = snapshot
                flags = .clampUVs
            case .mipMappedFrameBuffer?:
                guard let target = context.mipMappedFrameBuffer else { return }
                texture = target
                flags = .clampUVs
            case .fbo(SceneShadowAtlas.name)?:
                guard let atlas = context.shadowAtlas else { return }
                texture = atlas
                flags = []
            default:
                continue
            }
            // The atlas takes WE's comparison sampler (`SceneShadowAtlas.makeSampler`).
            let sampler = texture === context.shadowAtlas ? shadowSampler : sampler(for: flags)
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(sampler, index: slot)
            encoder.setVertexTexture(texture, index: slot)
            encoder.setVertexSamplerState(sampler, index: slot)
            textures[slot] = EffectGraphRenderer.textureInfo(for: texture, contentSize: contentSize)
        }

        let program = self.program(for: stage, state: state, reflected: reflected)
        if program.size > 0, let layout = stage.variant.uniforms {
            let uniforms = ParticleMaterialUniforms(plan: plan, system: system, sceneSize: context.sceneSize,
                                                    texture0: textures[0], placement: context.placement,
                                                    orthographicDepth: context.depth != nil)
            var pass = BuiltinPassContext(targetSize: context.sceneSize)
            pass.modelViewProjection = uniforms.modelViewProjection
            pass.modelMatrix = uniforms.modelMatrix
            pass.viewMatrix = uniforms.viewMatrix
            pass.viewProjection = uniforms.viewProjection
            pass.textures = textures
            pass.renderVars = uniforms.renderVars
            program.update(frame: uniforms.frame(from: context.frame), pass: pass, values: context.values)
            let members: ParticleMaterialUniforms.Members
            if let known = state.members[stage.variantKey] {
                members = known
            } else {
                members = ParticleMaterialUniforms.Members(layout)
                state.members[stage.variantKey] = members
            }
            // Patched in a block reused frame to frame: no copy of the program's bytes to allocate.
            state.scratch.removeAll(keepingCapacity: true)
            state.scratch.append(contentsOf: program.bytes)
            uniforms.patch(&state.scratch, members: members)
            state.scratch.withUnsafeBytes { raw in
                if !reflected, let block = prepared.uniforms, block.length >= raw.count {
                    // The simulation's step, which runs before this draw, patches the block.
                    block.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                    encoder.setVertexBuffer(block, offset: 0, index: 0)
                    encoder.setFragmentBuffer(block, offset: 0, index: 0)
                } else {
                    uniformArena.bind(raw, index: 0, to: encoder, commandBuffer: commandBuffer)
                }
            }
        }
        guard let indices = indexBuffer(for: stage.geometry) else { return }
        // `ParticleGPUSimulator` wrote the arguments: the stage's index count and the records.
        encoder.drawIndexedPrimitives(type: .triangle, indexType: indices.type, indexBuffer: indices.buffer,
                                      indexBufferOffset: 0, indirectBuffer: gpu.control,
                                      indirectBufferOffset: ParticleGPUSystem.Control.materialDrawOffset)
        drawsEncoded += 1
    }

    // MARK: - Stages and pipelines

    private func state(for system: ParticleSystemRuntime) -> SystemState {
        let id = ObjectIdentifier(system)
        if let state = systems[id], state.owner === system { return state }
        let state = SystemState(owner: system, device: device)
        systems[id] = state
        return state
    }

    private enum Readiness {
        /// The first stage whose pipeline built.
        case ready(ParticleMaterialPlan.Stage, MTLRenderPipelineState)
        /// This stage, which comes before any that built, is still compiling.
        case compiling(ParticleMaterialPlan.Stage)
        /// Every stage failed (logged once).
        case unavailable
    }

    private func readiness(_ plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat, sampleCount: Int,
                           depthFormat: MTLPixelFormat, state: SystemState) -> Readiness {
        var reasons: [String] = []
        let keys: [String]
        let target = (pixelFormat.rawValue &* 16 &+ UInt(max(sampleCount, 1))) &* 1024 &+ depthFormat.rawValue
        if let known = state.pipelineKeys[target] {
            keys = known
        } else {
            keys = plan.stages.map {
                Self.pipelineKey($0, plan: plan, pixelFormat: pixelFormat, sampleCount: sampleCount, depthFormat: depthFormat)
            }
            state.pipelineKeys[target] = keys
        }
        for (stage, key) in zip(plan.stages, keys) {
            let status: (pipeline: MTLRenderPipelineState?, pending: Bool, failure: String?) = pipelineLock.withLock {
                if pipelines[key] != nil { usedPipelines.insert(key) }
                return (pipelines[key], pendingPipelines.contains(key), failedPipelines[key])
            }
            if let pipeline = status.pipeline { return .ready(stage, pipeline) }
            if status.pending { return .compiling(stage) }
            if let failure = status.failure {
                reasons.append("\(stage.geometry): \(failure)")
                continue
            }
            compile(stage, plan: plan, pixelFormat: pixelFormat, sampleCount: sampleCount, depthFormat: depthFormat, key: key)
            return .compiling(stage)
        }
        if !state.reportedFallback {
            state.reportedFallback = true
            fallbacksReported += 1
            OWELog.error(.scene, "Particle material \(plan.materialPath) (\(plan.shader)) can't render; "
                         + "using the built-in particle draw: \(reasons.joined(separator: "; "))")
        }
        return .unavailable
    }

    /// A multisampled pipeline's key carries its sample count, and one for a pass with depth its
    /// depth format; a single-sampled one without depth's is unchanged.
    private static func pipelineKey(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan,
                                     pixelFormat: MTLPixelFormat, sampleCount: Int = 1,
                                     depthFormat: MTLPixelFormat = .invalid) -> String {
        "\(stage.variantKey)|\(plan.format)|\(plan.blending)|\(pixelFormat.rawValue)" + (sampleCount > 1 ? "|x\(sampleCount)" : "")
            + (depthFormat == .invalid ? "" : "|d\(depthFormat.rawValue)")
    }

    private func compile(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan,
                         pixelFormat: MTLPixelFormat, sampleCount: Int = 1, depthFormat: MTLPixelFormat = .invalid,
                         key: String) {
        pipelineLock.withLock { _ = pendingPipelines.insert(key) }
        let device = self.device
        let format = plan.format
        let blending = plan.blending
        compileQueue.async { [weak self] in
            var failure: String?
            var pipeline: MTLRenderPipelineState?
            do {
                pipeline = try OWEPhaseTiming.measure(.pipeline) {
                    try Self.makePipeline(stage, format: format, blending: blending, pixelFormat: pixelFormat,
                                          sampleCount: sampleCount, depthFormat: depthFormat, device: device)
                }
            } catch {
                failure = "\(error)"
                OWELog.error(.shader, "Particle pipeline failed (\(plan.materialPath), \(stage.geometry)): \(error)")
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pendingPipelines.remove(key)
                self.landedPipelines &+= 1
                if let pipeline { self.pipelines[key] = pipeline } else { self.failedPipelines[key] = failure ?? "unknown" }
            }
        }
    }

    /// Blocks until every stage of `plan` has a pipeline or failed (tests, prewarming).
    func waitUntilCompiled(_ plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat, timeout: TimeInterval = 60) -> Bool {
        let keys = plan.stages.map { Self.pipelineKey($0, plan: plan, pixelFormat: pixelFormat) }
        for (stage, key) in zip(plan.stages, keys) {
            let known = pipelineLock.withLock { pipelines[key] != nil || pendingPipelines.contains(key) || failedPipelines[key] != nil }
            if !known { compile(stage, plan: plan, pixelFormat: pixelFormat, key: key) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while pipelineLock.withLock({ keys.contains { pendingPipelines.contains($0) } }) {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }

    /// Failure reason of a stage's pipeline, for tests and diagnostics.
    func pipelineFailure(_ stage: ParticleMaterialPlan.Stage, plan: ParticleMaterialPlan, pixelFormat: MTLPixelFormat) -> String? {
        let key = Self.pipelineKey(stage, plan: plan, pixelFormat: pixelFormat)
        return pipelineLock.withLock { failedPipelines[key] }
    }

    static func makePipeline(_ stage: ParticleMaterialPlan.Stage, format: ParticleVertexFormat, blending: String,
                             pixelFormat: MTLPixelFormat, sampleCount: Int = 1, depthFormat: MTLPixelFormat = .invalid,
                             device: MTLDevice) throws -> MTLRenderPipelineState {
        let vertexLibrary = try device.makeLibrary(source: stage.variant.vertexMSL, options: nil)
        let fragmentLibrary = try device.makeLibrary(source: stage.variant.fragmentMSL, options: nil)
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
        if let blend = EffectGraphRenderer.blendMode(blending) {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = blend.source
            attachment.sourceAlphaBlendFactor = blend.source
            attachment.destinationRGBBlendFactor = blend.destination
            attachment.destinationAlphaBlendFactor = blend.destination
        }
        descriptor.vertexDescriptor = vertexDescriptor(for: vertex, attributes: stage.variant.attributes, format: format)
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Every attribute the stage reads comes from the instance's record, stepping once per
    /// instance; one the format lacks reads zero.
    static func vertexDescriptor(for function: MTLFunction, attributes: [String: Int],
                                 format: ParticleVertexFormat) -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        var usesZero = false
        var usesRecord = false
        for attribute in function.vertexAttributes ?? [] where attribute.isActive {
            let index = attribute.attributeIndex
            let element = descriptor.attributes[index]!
            let offset = attributes.filter { $0.value == index }.keys.sorted()
                .lazy.compactMap { format.recordOffset(ofAttribute: $0) }.first
            element.format = vertexFormat(attribute.attributeType)
            if let offset {
                element.offset = offset
                element.bufferIndex = recordBuffer
                usesRecord = true
            } else {
                element.offset = 0
                element.bufferIndex = zeroBuffer
                usesZero = true
            }
        }
        if usesRecord {
            descriptor.layouts[recordBuffer].stride = format.stride
            descriptor.layouts[recordBuffer].stepFunction = .perInstance
            descriptor.layouts[recordBuffer].stepRate = 1
        }
        if usesZero {
            descriptor.layouts[zeroBuffer].stride = 16
            descriptor.layouts[zeroBuffer].stepFunction = .constant
            descriptor.layouts[zeroBuffer].stepRate = 0
        }
        return descriptor
    }

    private static func vertexFormat(_ type: MTLDataType) -> MTLVertexFormat {
        switch type {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        default: return .float4
        }
    }
}
