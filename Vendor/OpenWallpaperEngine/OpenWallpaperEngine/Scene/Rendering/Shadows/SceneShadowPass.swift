import Metal
import simd

/// Draws the frame's shadow maps into `_rt_shadowAtlas` (docs/models-plan.md §2.10; `wallpaper64.exe`
/// 0x140196530, called from the light packer before the reflection and scene passes).
///
/// - The atlas is cleared to 0 once, then the maps are drawn in batches of views: each point
///   light's six faces as one batch, then the spots and cascades six at a time, in the layout's
///   order (points first).
/// - A batch sets one viewport per view and draws every caster instanced once per view: the
///   material's shadow variant (`ModelMaterialPlan.shadowCaster`, `shadowcaster.vert`) takes
///   `g_ViewportViewProjectionMatrices[gl_InstanceID]` and writes the viewport index.
/// - Casters are the visible model objects with `castshadow` (models default to true) that are
///   opaque (a mesh blending normal or alpha-to-coverage), and of those only their opaque meshes;
///   one is skipped when its box's sphere lies outside every view of the batch.
/// - The state is WE's biased raster state: slope-scaled depth bias −4, no constant bias or clamp,
///   and, by WE's quirk (the biased back-cull state was made with culling off), no culling;
///   `shadowcaster.json`'s depth test and write, reversed (GREATER).
/// - A frame whose commands are exactly the last drawn frame's keeps the atlas as it stands
///   (`Recording`): drawing them again would write the same depth.
///
/// Call on the render thread, apart from the pipeline compiles.
final class SceneShadowPass {
    /// A caster this frame: a visible model object and its world matrix.
    struct Caster {
        let model: SceneModelObject
        let world: simd_float4x4
    }

    /// WE's slope-scaled depth bias (0x1400991bd).
    static let slopeScaledDepthBias: Float = -4
    /// At most this many views per batch (the matrices' array).
    static let viewsPerBatch = 6

    let atlas: SceneShadowAtlas
    private let device: MTLDevice
    private let archive: EffectPipelineArchive?
    private let uniformArena: SceneUniformArena
    private let depthState: MTLDepthStencilState
    private let zeroAttributes: MTLBuffer
    private let clampSampler: MTLSamplerState
    private let repeatSampler: MTLSamplerState
    private let emptyMorphTexture: MTLTexture

    private let compileQueue = DispatchQueue(label: "owe.shadow-pipelines", qos: .userInitiated, attributes: .concurrent)
    /// Owns `pipelines`, `pending` and `failed`, which compile threads write.
    private let pipelineLock = NSLock()
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var pending = Set<String>()
    private var failed = Set<String>()
    private var landedPipelines = 0

    /// Whether a pipeline is still compiling: a frame drawn now lacks that caster's shadow.
    var hasPendingPipelines: Bool { pipelineLock.withLock { !pending.isEmpty } }
    /// Compiles finished so far, however they ended.
    var pipelinesLanded: Int { pipelineLock.withLock { landedPipelines } }

    /// The frame's built-ins and the caster materials' bound constants, shared by the frame's draws.
    private let frameValues = SceneModelFrameValues()
    /// Per object, each mesh's shadow-variant uniforms. Render thread only.
    private var uniforms: [String: [ModelMaterialUniforms?]] = [:]

    /// Diagnostics and tests: batches, caster draws and their indices encoded, and the maps drawn
    /// last frame.
    private(set) var batchesEncoded = 0
    private(set) var casterDraws = 0
    private(set) var casterIndices = 0
    /// Whether a caster draws only into the views that hold it (false draws it into all of its
    /// batch's views, as a comparison for tests).
    var cullsViews = true
    /// The views the casters' draws covered: each draw once per view whose frustum holds it.
    private(set) var casterInstances = 0
    private(set) var lastMapCount = 0
    /// Frames whose atlas was kept as it stood, as they would have drawn exactly the same.
    private(set) var atlasesReused = 0

    init?(device: MTLDevice, archive: EffectPipelineArchive?) {
        self.device = device
        self.archive = archive
        atlas = SceneShadowAtlas(device: device)
        uniformArena = SceneUniformArena(device: device)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
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
        guard let state = device.makeDepthStencilState(descriptor: depth), let zero = device.makeBuffer(length: 64),
              let clamp = sampler(.clampToEdge), let wrap = sampler(.repeat),
              let morphTexture = device.makeTexture(descriptor: morph) else { return nil }
        morphTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt16](repeating: 0, count: 4),
                             bytesPerRow: 8)
        depthState = state
        zeroAttributes = zero
        clampSampler = clamp
        repeatSampler = wrap
        emptyMorphTexture = morphTexture
    }

    /// A new content: its objects' uniforms go.
    func setContent() {
        uniforms.removeAll()
        lastDrawn = nil
    }

    /// A model a script destroyed.
    func remove(_ id: String) {
        uniforms.removeValue(forKey: id)
        lastDrawn = nil
    }

    /// Whether a model object casts: its `castshadow`, true unless authored (the model factory
    /// sets flag 0x800, 0x1401901b1); a bound value's fallback, as the content is rebuilt when a
    /// user property changes.
    static func castsShadow(_ model: SceneModelObject) -> Bool {
        guard let value = model.renderValues[.castshadow].flatMap(literal) else { return true }
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text): return !["false", "0", ""].contains(text.lowercased())
        case .object: return true
        }
    }

    private static func literal(_ value: SceneRawValue) -> SceneRawValue? {
        if case .object(let object) = value { return object.value.flatMap(literal) }
        return value
    }

    /// Draws `shadows`' maps with `casters` and returns the atlas the frame's materials read: the
    /// maps, or the cleared stand-in when there are none yet.
    func encode(_ shadows: SceneShadowFrame, casters: [Caster], models: SceneModelRenderer, frame: BuiltinFrameContext,
                values: SceneValueContext, assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?,
                commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        lastMapCount = shadows.maps.count
        guard !shadows.maps.isEmpty else { return atlas.bound(commandBuffer: commandBuffer) }
        guard let texture = atlas.texture(extent: shadows.extent) else { return atlas.bound(commandBuffer: commandBuffer) }
        // Each caster is posed and its meshes' draws prepared once a frame; a batch only culls it
        // against its views and writes their matrices.
        let prepared = casters.compactMap { caster -> PreparedCaster? in
            // A script's `replaceData` re-plans its model (`SceneModelRenderer.currentPlan`).
            guard let plan = caster.model.plan.map({ models.currentPlan($0, objectID: caster.model.id) }), !plan.isTranslucent,
                  plan.meshes.contains(where: { $0.material.shadowCaster != nil }) else { return nil }
            let bones = models.advance(caster.model, plan: plan, frame: frame, values: values)
            return prepare(caster, plan: plan, bones: bones, models: models, frame: frame, values: values,
                           assetTexture: assetTexture)
        }
        var recording = Recording(atlas: texture)
        for batch in Self.batches(shadows.maps) {
            batchesEncoded += 1
            let frustums = batch.views.map(SceneModelCulling.Frustum.init)
            let fixed = batch.views.map { Self.clipFixup * $0 }
            // A caster draws only into the views whose frustum holds it: the variant's
            // `gl_ViewportIndex = gl_InstanceID` pairs view i's matrix with viewport i, so the kept
            // views' viewports and matrices, compacted alike, draw what all six would (the others'
            // triangles are clipped), and the depth test (GREATER, write) doesn't depend on order.
            var subsets: [[Int]: [Float]] = [:]
            for caster in prepared {
                let holding = frustums.indices.filter { frustums[$0].contains(caster.sphere) }
                guard !holding.isEmpty else { continue }
                let kept = cullsViews ? holding : Array(frustums.indices)
                let matrices: [Float]
                if let known = subsets[kept] {
                    matrices = known
                } else {
                    matrices = Self.flatten(kept.map { fixed[$0] })
                    subsets[kept] = matrices
                }
                recording.setViewports(kept.map { batch.viewports[$0] })
                for draw in caster.draws {
                    // A mesh outside every kept view is clipped in all of them.
                    if let sphere = draw.sphere, !kept.contains(where: { frustums[$0].contains(sphere) }) { continue }
                    recording.add(draw, matrices: matrices, instances: kept.count)
                }
            }
        }
        // The atlas already holds exactly these maps: last frame drew the same commands into it.
        if let last = lastDrawn, last.recording.matches(recording), lastDrawStands(last.generation) {
            atlasesReused += 1
            return texture
        }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = SceneShadowAtlas.name
        encoder.setDepthStencilState(depthState)
        encoder.setDepthBias(0, slopeScale: Self.slopeScaledDepthBias, clamp: 0)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(SceneModelRenderer.frontFacing)
        encode(recording, encoder: encoder, commandBuffer: commandBuffer)
        encoder.endEncoding()
        remember(recording, drawnBy: commandBuffer)
        return texture
    }

    /// Matrices as the uniform writer takes them: each one's columns in order.
    static func flatten(_ matrices: [simd_float4x4]) -> [Float] {
        var components: [Float] = []
        components.reserveCapacity(matrices.count * 16)
        for matrix in matrices {
            for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3] {
                components.append(contentsOf: [column.x, column.y, column.z, column.w])
            }
        }
        return components
    }

    /// The translated vertex stages negate y and write z as (z + w) / 2 (`fixup_clipspace`,
    /// `flip_vert_y`), which the scene's depth only compares. The atlas's depth is compared
    /// against WE's own z (`CalculateProjectedCoords`), so the casters' matrices undo both: what
    /// the stage writes is WE's clip position, z included.
    static let clipFixup = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0), SIMD4(0, 0, 2, -1), SIMD4(0, 0, 0, 1)])

    /// A batch of views: their render matrices and viewport rectangles.
    struct Batch: Equatable {
        var views: [simd_float4x4]
        var viewports: [SIMD4<Int>]
    }

    /// The layout's order (points first, then larger maps), each point one batch of its six faces,
    /// the other maps six views at a time (0x1401939ed…0x1401963a2).
    static func batches(_ maps: [SceneShadowMap]) -> [Batch] {
        let order = maps.indices.sorted { a, b in
            let keyA = SceneShadowAtlasLayout.key(.init(size: maps[a].size, isPoint: maps[a].isPoint))
            let keyB = SceneShadowAtlasLayout.key(.init(size: maps[b].size, isPoint: maps[b].isPoint))
            return keyA != keyB ? keyA > keyB : a < b
        }
        var batches: [Batch] = []
        var pending = Batch(views: [], viewports: [])
        for index in order {
            let map = maps[index]
            if map.isPoint {
                batches.append(Batch(views: map.renderViews, viewports: map.viewports))
                continue
            }
            if pending.views.count == viewsPerBatch {
                batches.append(pending)
                pending = Batch(views: [], viewports: [])
            }
            pending.views += map.renderViews
            pending.viewports += map.viewports
        }
        if !pending.views.isEmpty { batches.append(pending) }
        return batches
    }

    // MARK: - Casters

    /// A caster this frame: its bounding sphere and its meshes' draws.
    private struct PreparedCaster {
        let sphere: SceneModelCulling.Sphere
        let draws: [MeshDraw]
    }

    /// One opaque mesh's draw: its pipeline, textures and uniforms (all but the views' matrices).
    private struct MeshDraw {
        let pipeline: MTLRenderPipelineState
        let buffers: SceneModelRenderer.MeshBuffers
        let textures: [BoundTexture]
        let uniforms: ModelMaterialUniforms?
        let indexCount: Int
        let indexType: MTLIndexType
        /// A texture's contents may change while it stays the same object.
        let hasChangingTexture: Bool
        /// The mesh's own sphere (`SceneModelPlan.Mesh.bounds`), nil to follow the caster's.
        var sphere: SceneModelCulling.Sphere? = nil

        /// The same objects and counts (the uniforms are compared as bytes).
        func drawsSame(as other: MeshDraw) -> Bool {
            pipeline === other.pipeline && buffers.vertices === other.buffers.vertices
                && buffers.attributes === other.buffers.attributes
                && buffers.indices === other.buffers.indices && indexCount == other.indexCount && indexType == other.indexType
                && textures.count == other.textures.count
                && zip(textures, other.textures).allSatisfy { $0.slot == $1.slot && $0.texture === $1.texture && $0.sampler === $1.sampler }
        }
    }

    /// The caster's meshes that draw this frame, their uniforms written but for the views.
    private func prepare(_ caster: Caster, plan: SceneModelPlan, bones: [Float]?, models: SceneModelRenderer,
                         frame: BuiltinFrameContext, values: SceneValueContext,
                         assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?) -> PreparedCaster {
        let buffers = models.meshBuffers(plan)
        let meshUniforms = uniforms(for: caster.model.id, plan: plan)
        let placement = SceneLayerPlacement(world: caster.world, size: SIMD2(1, 1), camera: frame.camera)
        var draws: [MeshDraw] = []
        for (index, mesh) in plan.meshes.enumerated() where mesh.material.isOpaque {
            guard let material = mesh.material.shadowCaster, let variant = material.pass.variant,
                  let meshBuffers = buffers[index], let pipeline = pipeline(for: mesh, material: material, variant: variant),
                  let bound = textures(of: material, assetTexture: assetTexture,
                                       morph: models.morphTextures.texture(plan, mesh: mesh.index)) else { continue }
            var program: ModelMaterialUniforms?
            if let uniforms = meshUniforms[index], uniforms.size > 0 {
                let key = ModelMaterialUniforms.PassKey(
                    world: caster.world, view: frame.camera.view, viewProjection: placement.shaderViewProjection,
                    eye: frame.eyePosition, screen: frame.screenSize, target: frame.screenSize,
                    textures: bound.map { SIMD4(Float($0.texture.width), Float($0.texture.height), 0, 0) })
                uniforms.update(key: key, frame: frame, values: values, shared: (frameValues, material)) {
                    var pass = BuiltinPassContext(targetSize: frame.screenSize)
                    pass.place(placement)
                    for entry in bound {
                        pass.textures[entry.slot] = EffectGraphRenderer.textureInfo(for: entry.texture, contentSize: nil)
                    }
                    return pass
                }
                if let bones { uniforms.writeBones(bones) }
                // The caster's `MORPHING` is the source material's; its morph texture and uniforms too.
                if mesh.material.meshCombos.morphing {
                    uniforms.writeMorphs(models.morphUniforms(caster.model.id, plan: plan, mesh: mesh))
                }
                program = uniforms
            }
            // A script's `applyData` may have shortened the triangle list since the plan was made.
            draws.append(MeshDraw(pipeline: pipeline, buffers: meshBuffers, textures: bound, uniforms: program,
                                  indexCount: models.indexCount(of: mesh, in: plan),
                                  indexType: mesh.usesUInt32Indices ? .uint32 : .uint16,
                                  hasChangingTexture: bound.contains { $0.changes },
                                  sphere: mesh.bounds.map { SceneModelCulling.Sphere($0, world: caster.world) }))
        }
        return PreparedCaster(sphere: SceneModelCulling.Sphere(plan.cullBounds, world: caster.world), draws: draws)
    }

    /// Encodes a frame's recorded commands.
    private func encode(_ recording: Recording, encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        for operation in recording.ops {
            switch operation {
            case .viewports(let rects):
                encoder.setViewports(rects.map { rect in
                    MTLViewport(originX: Double(rect.x), originY: Double(rect.y), width: Double(rect.z), height: Double(rect.w),
                                znear: 0, zfar: 1)
                })
            case let .draw(draw, uniforms, instances):
                if let uniforms {
                    recording.uniformBytes.withUnsafeBytes { raw in
                        uniformArena.bind(UnsafeRawBufferPointer(rebasing: raw[uniforms]), index: 0, to: encoder,
                                          commandBuffer: commandBuffer)
                    }
                }
                encoder.setRenderPipelineState(draw.pipeline)
                draw.buffers.bindVertices(to: encoder)
                encoder.setVertexBuffer(zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
                for entry in draw.textures {
                    encoder.setFragmentTexture(entry.texture, index: entry.slot)
                    encoder.setFragmentSamplerState(entry.sampler, index: entry.slot)
                    encoder.setVertexTexture(entry.texture, index: entry.slot)
                    encoder.setVertexSamplerState(entry.sampler, index: entry.slot)
                }
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: draw.indexCount, indexType: draw.indexType,
                                              indexBuffer: draw.buffers.indices, indexBufferOffset: 0, instanceCount: instances)
                casterDraws += 1
                casterIndices += draw.indexCount
                casterInstances += instances
            }
        }
    }

    // MARK: - Reusing the atlas

    /// A frame's shadow commands, recorded before they are encoded, so a frame that would draw
    /// exactly what the atlas already holds draws nothing.
    ///
    /// Two recordings match when they draw the same: the same atlas texture, viewports and
    /// draws, each with the same pipeline, buffers, textures and samplers (the same objects, held
    /// here so none is freed and its address reused) and the same uniform bytes, which carry
    /// everything else a draw reads (the views' matrices, the world, the bones, the morph weights,
    /// the time and every other built-in and bound constant the variant declares). A texture whose
    /// contents can change while it stays the same object (a video frame, a render target) makes
    /// the recording one that never matches.
    private struct Recording {
        enum Operation {
            case viewports([SIMD4<Int>])
            case draw(MeshDraw, uniforms: Range<Int>?, instances: Int)
        }

        let atlas: MTLTexture
        var ops: [Operation] = []
        /// Every draw's uniform block, as bound.
        var uniformBytes: [UInt8] = []
        var hasChangingInput = false

        /// The viewports the last `viewports` operation set.
        private var current: [SIMD4<Int>]?

        init(atlas: MTLTexture) {
            self.atlas = atlas
        }

        /// Sets the viewports the next draws use, unless they're already set.
        mutating func setViewports(_ rects: [SIMD4<Int>]) {
            guard rects != current else { return }
            current = rects
            ops.append(.viewports(rects))
        }

        /// Records `draw` once per view, `matrices` its views' render matrices.
        mutating func add(_ draw: MeshDraw, matrices: [Float], instances: Int) {
            var range: Range<Int>?
            if let program = draw.uniforms {
                program.write(matrices, member: "g_ViewportViewProjectionMatrices")
                let start = uniformBytes.count
                uniformBytes.append(contentsOf: program.bytes)
                range = start..<uniformBytes.count
            }
            hasChangingInput = hasChangingInput || draw.hasChangingTexture
            ops.append(.draw(draw, uniforms: range, instances: instances))
        }

        func matches(_ other: Recording) -> Bool {
            let a = self, b = other
            guard !a.hasChangingInput, !b.hasChangingInput, a.atlas === b.atlas, a.ops.count == b.ops.count,
                  a.uniformBytes == b.uniformBytes else { return false }
            for (x, y) in zip(a.ops, b.ops) {
                switch (x, y) {
                case let (.viewports(p), .viewports(q)):
                    guard p == q else { return false }
                case let (.draw(p, pu, pi), .draw(q, qu, qi)):
                    guard pu == qu, pi == qi, p.drawsSame(as: q) else { return false }
                default:
                    return false
                }
            }
            return true
        }
    }

    /// The last recording encoded, its number and the command buffer that drew it.
    private var lastDrawn: (recording: Recording, generation: Int)?
    private var generation = 0
    private weak var lastDrawBuffer: MTLCommandBuffer?
    /// Owns `finished`, which the command buffers' completion handlers write.
    private let finishLock = NSLock()
    /// The last recording whose command buffer finished, and whether it drew (no GPU error).
    private var finished: (generation: Int, drew: Bool)?

    private func remember(_ recording: Recording, drawnBy commandBuffer: MTLCommandBuffer) {
        generation += 1
        let number = generation
        lastDrawn = recording.hasChangingInput ? nil : (recording, number)
        lastDrawBuffer = commandBuffer
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let drew = buffer.status == .completed
            self.finishLock.withLock { self.finished = (number, drew) }
        }
    }

    /// Whether the atlas holds what recording `number` drew: its command buffer was committed and
    /// hasn't failed. A buffer that was never committed (a frame given up) drew nothing.
    private func lastDrawStands(_ number: Int) -> Bool {
        if let buffer = lastDrawBuffer {
            switch buffer.status {
            case .committed, .scheduled, .completed: return true
            default: return false
            }
        }
        return finishLock.withLock { finished.map { $0.generation == number && $0.drew } ?? false }
    }

    private func uniforms(for id: String, plan: SceneModelPlan) -> [ModelMaterialUniforms?] {
        if let existing = uniforms[id], existing.count == plan.meshes.count { return existing }
        let made = plan.meshes.map { mesh in
            mesh.material.shadowCaster.map { ModelMaterialUniforms(layout: $0.pass.variant?.uniforms, constants: $0.pass.constants) }
        }
        uniforms[id] = made
        return made
    }

    private typealias BoundTexture = (slot: Int, texture: MTLTexture, sampler: MTLSamplerState, changes: Bool)

    /// The shadow variant's textures: the material's by slot, the mesh's morph texture (or the
    /// empty one) for the engine's; nil when one isn't there this frame.
    private func textures(of material: ModelMaterialPlan, assetTexture: (String, SceneMetalTextureSource) -> MTLTexture?,
                          morph: MTLTexture?) -> [BoundTexture]? {
        var bound: [BoundTexture] = []
        for slot in material.pass.variant?.textureSlots ?? [] {
            let sampler = material.clampedSlots.contains(slot) ? clampSampler : repeatSampler
            switch material.pass.textures[slot] {
            case .asset(let key, let source)?:
                guard let texture = assetTexture(key, source) else { return nil }
                bound.append((slot, texture, sampler, Self.contentsMayChange(texture, source: source)))
            case nil:
                bound.append((slot, morph ?? emptyMorphTexture, clampSampler, false))
            default:
                return nil
            }
        }
        return bound
    }

    /// Whether a texture's contents can change while it stays the same object: a video's frames,
    /// or a texture something draws, writes or shares through an IOSurface. Uploaded images and
    /// animation frames are written once.
    static func contentsMayChange(_ texture: MTLTexture, source: SceneMetalTextureSource) -> Bool {
        if case .video = source { return true }
        return !texture.usage.isDisjoint(with: [.renderTarget, .shaderWrite]) || texture.iosurface != nil
    }

    // MARK: - Pipelines

    static func pipelineKey(_ mesh: SceneModelPlan.Mesh, material: ModelMaterialPlan) -> String {
        "shadow|\(material.pass.variantKey)|\(mesh.format.rawValue)|\(material.blending)|d\(SceneShadowAtlas.pixelFormat.rawValue)"
            + (material.customShader ? "|custom" : "")
    }

    /// Blocks until every caster mesh of `plan` compiled or failed (tests). True when all are ready.
    func waitUntilReady(_ plan: SceneModelPlan, timeout: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        for mesh in plan.meshes where mesh.material.isOpaque {
            guard let material = mesh.material.shadowCaster, let variant = material.pass.variant else { continue }
            let key = Self.pipelineKey(mesh, material: material)
            while pipeline(for: mesh, material: material, variant: variant) == nil {
                if pipelineLock.withLock({ failed.contains(key) }) || Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return true
    }

    private func pipeline(for mesh: SceneModelPlan.Mesh, material: ModelMaterialPlan,
                          variant: TranslatedShaderVariant) -> MTLRenderPipelineState? {
        let key = Self.pipelineKey(mesh, material: material)
        let state: (pipeline: MTLRenderPipelineState?, busy: Bool) = pipelineLock.withLock {
            (pipelines[key], pending.contains(key) || failed.contains(key))
        }
        if let pipeline = state.pipeline { return pipeline }
        guard !state.busy else { return nil }
        pipelineLock.withLock { _ = pending.insert(key) }
        let device = self.device, archive = self.archive, format = mesh.format, name = material.materialPath
        let customShader = material.customShader
        compileQueue.async { [weak self] in
            let result: MTLRenderPipelineState?
            do {
                result = try EffectGraphRenderer.makePipeline(Self.pipelineDescriptor(variant, format: format, customShader: customShader,
                                                                                      device: device),
                                                              device: device, archive: archive, key: key)
            } catch let missing as SceneModelMissingInputs {
                OWELog.debug(.shader, "Model material \(name): the mesh casts no shadow: \(missing)")
                result = nil
            } catch {
                OWELog.error(.shader, "Model material \(name) can't draw into the shadow atlas; the mesh casts no shadow: \(error)")
                result = nil
            }
            guard let self else { return }
            self.pipelineLock.withLock {
                self.pending.remove(key)
                self.landedPipelines &+= 1
                if let result { self.pipelines[key] = result } else { self.failed.insert(key) }
            }
        }
        return nil
    }

    /// A shadow variant's pipeline: depth only, the mesh's vertex layout. An alpha-to-coverage
    /// caster discards below half coverage (`shadowcaster.frag`); the atlas has one sample, so
    /// coverage itself would change nothing. A fragment stage that neither discards nor writes
    /// depth (WE's casters without `ALPHATOCOVERAGE`, whose `main` is empty) changes nothing in a
    /// depth-only pass either, so the pipeline has none and the rasteriser writes the depth alone.
    /// A `customShader` caster reading an input the mesh lacks throws `SceneModelMissingInputs`.
    static func pipelineDescriptor(_ variant: TranslatedShaderVariant, format: MDLVertexFormat,
                                   customShader: Bool, device: MTLDevice) throws -> MTLRenderPipelineDescriptor {
        let (vertexLibrary, fragmentLibrary) = try variant.makeLibraries(device: device)
        guard let vertex = vertexLibrary.makeFunction(name: "main0"),
              let fragment = fragmentLibrary.makeFunction(name: "main0") else {
            throw ShaderCompilerError.failed(step: "metal", output: "entry point main0 missing")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragmentAffectsDepth(variant) ? fragment : nil
        descriptor.depthAttachmentPixelFormat = SceneShadowAtlas.pixelFormat
        descriptor.rasterSampleCount = 1
        descriptor.inputPrimitiveTopology = .triangle
        if customShader { try SceneModelMissingInputs.check(vertex, attributes: variant.attributes, format: format) }
        descriptor.vertexDescriptor = SceneModelRenderer.vertexDescriptor(for: vertex, attributes: variant.attributes, format: format)
        return descriptor
    }

    /// Whether a caster's fragment stage can change what a depth-only pass writes: it discards or
    /// writes its own depth.
    static func fragmentAffectsDepth(_ variant: TranslatedShaderVariant) -> Bool {
        variant.fragmentMSL.contains("discard_fragment") || variant.fragmentMSL.contains("[[depth")
    }
}
