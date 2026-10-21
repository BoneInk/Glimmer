import Metal
import os

/// Runs particle systems on the GPU (`ParticleSimulation.metal`): one compute pass per frame
/// steps every system and writes its draw records and indirect draw arguments, so neither the
/// particles nor their count come back to the CPU. The CPU only evaluates the frame's inputs
/// (`ParticleFrameInputs`).
final class ParticleGPUSimulator {
    /// One system's step this frame.
    struct Request {
        let system: ParticleSystemRuntime
        let inputs: ParticleFrameInputs
        /// What the step writes records for.
        let kind: ParticleGPUDrawKind
        /// The material draw's indices per instance (ignored for the built-in draw).
        var materialVertexCount = 0
        /// A rope material's uniform block: the step writes `g_RenderVar0` (the point count) at
        /// this byte offset.
        var renderVar: (buffer: MTLBuffer, offset: Int)?
        /// False for a step nothing draws (a pre-simulation step before the frame's own): it skips
        /// the draw arguments, the trail scan and the records, which the drawn step rewrites.
        var writesRecords = true
    }

    static let threadgroupSize = 256

    /// Frames encoded, and the latest one whose command buffer has completed (its control words,
    /// `completedCount` among them, are final).
    private var serial: UInt64 = 0
    private let completedSerial = OSAllocatedUnfairLock(initialState: UInt64(0))

    private let device: MTLDevice
    private let age, begin, emit, simulate, scanBlocks, scanBlockSums, compact, finish: MTLComputePipelineState
    private let emitSerial, simulateSerial: MTLComputePipelineState
    private let eventMark, eventScatter, instanceStep, linkPoints: MTLComputePipelineState
    private let boidsMark, boidsScatter, ropeSort: MTLComputePipelineState
    /// A renderer after a system's first takes the system's step counters (`particleFollowControl`).
    private let followControl: MTLComputePipelineState
    /// Compactions that also write sprite records, by draw kind.
    private let compactWriters: [ParticleGPUDrawKind: MTLComputePipelineState]
    private let writers: [ParticleGPUDrawKind: MTLComputePipelineState]
    /// Bound as the linked points of a system that isn't linked: the kernels never read it, but
    /// Metal checks the binding holds one `LinkedPoints`. Zeroed.
    let unlinkedPoints: MTLBuffer

    init(device: MTLDevice) throws {
        let library = try SceneMetalLibrary.load(device: device)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw ShaderCompilerError.failed(step: "metal", output: "kernel \(name) missing")
            }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        let unlinkedLength = MemoryLayout<ParticleGPULinkedPoints>.stride
        guard let unlinked = device.makeBuffer(length: unlinkedLength, options: .storageModeShared) else {
            throw ShaderCompilerError.failed(step: "metal", output: "could not allocate the unlinked points buffer")
        }
        memset(unlinked.contents(), 0, unlinkedLength)
        unlinked.label = "OWE particle unlinked points"
        unlinkedPoints = unlinked
        age = try pipeline("particleAge")
        begin = try pipeline("particleBegin")
        emit = try pipeline("particleEmit")
        simulate = try pipeline("particleSimulate")
        emitSerial = try pipeline("particleEmitSerial")
        simulateSerial = try pipeline("particleSimulateSerial")
        scanBlocks = try pipeline("particleScanBlocks")
        scanBlockSums = try pipeline("particleScanBlockSums")
        compact = try pipeline("particleCompact")
        finish = try pipeline("particleFinish")
        eventMark = try pipeline("particleEventMark")
        eventScatter = try pipeline("particleEventScatter")
        instanceStep = try pipeline("particleInstanceStep")
        linkPoints = try pipeline("particleLinkPoints")
        boidsMark = try pipeline("particleBoidsMark")
        boidsScatter = try pipeline("particleBoidsScatter")
        ropeSort = try pipeline("particleRopeOrder")
        followControl = try pipeline("particleFollowControl")
        let compactFallback = try pipeline("particleCompactFallbackSprites")
        compactWriters = [.sprite: try pipeline("particleCompactSprites"), .fallbackSprite: compactFallback,
                          .fallbackSpriteTrail: compactFallback]
        let sprites = try pipeline("particleWriteFallbackSprites")
        writers = [
            .sprite: try pipeline("particleWriteSprites"),
            .rope: try pipeline("particleWriteRope"),
            .ropeTrail: try pipeline("particleWriteRopeTrails"),
            .fallbackSprite: sprites,
            .fallbackSpriteTrail: sprites,
            .fallbackRope: try pipeline("particleWriteFallbackRope"),
            .fallbackRopeTrail: try pipeline("particleWriteFallbackRopeTrails"),
        ]
    }

    /// The system's GPU state, made on first use. Nil when its buffers can't be allocated.
    func state(for system: ParticleSystemRuntime) -> ParticleGPUSystem? {
        if let gpu = system.gpu {
            gpu.updateImagePoints(system)
            return gpu
        }
        system.gpu = ParticleGPUSystem(device: device, configuration: system.configuration, seed: system.seed,
                                       images: system.emitterImages)
        system.gpu?.updateImagePoints(system)
        return system.gpu
    }

    /// Encodes every request's step into `commandBuffer`. Systems whose buffers can't grow are
    /// skipped (logged) and draw nothing this frame.
    func encode(_ requests: [Request], sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>,
                commandBuffer: MTLCommandBuffer) {
        guard !requests.isEmpty else { return }
        let requests = skippingEmpty(requests, commandBuffer: commandBuffer)
        guard !requests.isEmpty else { return }
        var blit: MTLBlitCommandEncoder?
        for request in requests {
            guard let gpu = state(for: request.system) else { continue }
            if let simulation = request.system.simulation {
                // A renderer after the system's first steps nothing: it draws that system's
                // particles, whose step comes before it.
                gpu.isReady = simulation.gpu.map(gpu.follow) ?? false
                continue
            }
            gpu.isReady = gpu.reserve(for: request.inputs) {
                if blit == nil { blit = commandBuffer.makeBlitCommandEncoder() }
                return blit
            }
            // An instanced or linked system steps from its parent's step, encoded just before it.
            let configuration = request.system.configuration
            if gpu.isReady, configuration.isInstanced || configuration.link?.controlPointStart != nil {
                let parent = request.system.parent?.gpu
                gpu.isReady = parent?.isReady == true
                if let parent, gpu.isReady, request.system.configuration.link?.kind != .static {
                    gpu.isReady = gpu.reserveEvents(parentCapacity: parent.capacity)
                }
            }
            if !gpu.isReady, !gpu.reportedFailure {
                gpu.reportedFailure = true
                OWELog.error(.scene, "Particle system can't grow its GPU buffers past \(gpu.capacity) particles; skipped")
            }
        }
        blit?.endEncoding()
        // Every system's steps go stage by stage, all systems of a wave at once: dispatches of one
        // stage run concurrently and one barrier separates the stages, instead of each small
        // system's dozen dispatches running one after another. A system's next request and a
        // child's first run a wave after their parent's (they read its particles and events).
        var plans: [[StepPlan]] = []
        var lastWave: [ObjectIdentifier: Int] = [:]
        for request in requests {
            guard let gpu = request.system.gpu, gpu.isReady,
                  let plan = StepPlan(request, gpu: gpu, sceneSize: sceneSize, targetSize: targetSize,
                                         compactWriters: compactWriters, unlinkedPoints: unlinkedPoints) else { continue }
            // A renderer after a system's first draws in the wave after that system's step, and
            // each further renderer after the one before (they share its scratch buffers).
            let key = ObjectIdentifier(request.system.simulation ?? request.system)
            let own = lastWave[key].map { $0 + 1 } ?? 0
            let parent = request.system.parent.flatMap { lastWave[ObjectIdentifier($0)] }.map { $0 + 1 } ?? 0
            let wave = max(own, parent)
            lastWave[key] = wave
            while plans.count <= wave { plans.append([]) }
            plans[wave].append(plan)
        }
        guard !plans.isEmpty, let encoder = commandBuffer.makeComputeCommandEncoder(dispatchType: .concurrent) else { return }
        encoder.label = "Particle simulation"
        for wave in plans {
            for stage in Stage.allCases {
                var encoded = false
                for plan in wave where encode(stage, plan, encoder: encoder) { encoded = true }
                if encoded { encoder.memoryBarrier(scope: .buffers) }
            }
        }
        encoder.endEncoding()
    }

    /// Drops the steps of systems that are provably empty: nothing alive when a frame at or after
    /// their last step that could hold or add particles completed, and this step adds none (every
    /// emitter at rate 0 with no burst, no clear). Their last step wrote zero draw arguments, so
    /// they stay drawn as empty. A child (spawned by its parent's events) or a parent (its events
    /// feed children) always steps. Any emission wakes the system the same frame.
    private func skippingEmpty(_ requests: [Request], commandBuffer: MTLCommandBuffer) -> [Request] {
        serial &+= 1
        let frame = serial
        let completed = completedSerial.withLock { $0 }
        commandBuffer.addCompletedHandler { [completedSerial] _ in
            completedSerial.withLock { $0 = max($0, frame) }
        }
        let parents = Set(requests.compactMap { $0.system.parent.map(ObjectIdentifier.init) })
        return requests.filter { request in
            let system = request.system
            guard let gpu = system.gpu, system.parent == nil, system.simulation == nil, !system.configuration.isInstanced,
                  !parents.contains(ObjectIdentifier(system)) else { return true }
            let adds = request.inputs.clears || request.inputs.emitters.contains { $0.rate > 0 || $0.burst > 0 }
            guard !adds, let live = gpu.lastLiveSerial else {
                gpu.lastLiveSerial = frame
                return true
            }
            return !(gpu.isReady && live <= completed && gpu.completedCount == 0)
        }
    }

    /// The dispatches of a system's step, in order; each reads what the ones before it wrote.
    private enum Stage: CaseIterable {
        case linkPoints, age, eventMark, eventScanBlocks, eventScanSums, eventScatter, begin, emit
        case boidsMark, boidsScanBlocks, boidsScanSums, boidsScatter, simulate
        case scanBlocks, scanSums, compact, follow, trailScanBlocks, trailScanSums, finish, ropeOrder, write
    }

    /// One request's step: its buffers and frame, captured when the frame is encoded. A class, so
    /// the stages share it rather than copy it.
    private final class StepPlan {
        let request: Request
        let gpu: ParticleGPUSystem
        let parent: ParticleGPUSystem?
        /// For a renderer after a system's first: that system's state, whose particles, trail
        /// history and scratch the step reads; it only writes its own control block and records.
        let simulation: ParticleGPUSystem?
        var frame: ParticleGPUFrame
        let isInstanced: Bool
        /// An instanced child of an event (`eventfollow`, `eventspawn`, `eventdeath`).
        let isEventChild: Bool
        let particles, stepped, alive, offsets, blockSums, records: MTLBuffer
        let history, nextHistory, trailCounts, instances, linked: MTLBuffer
        /// The initializers, then the operators (`ParticleProgramOp`).
        let program: [ParticleProgramOp]
        let steps: [ParticleGPUEmitterStep]
        /// Every rigged layer image's bones this step (`ParticleGPUEmitterStep.bones`).
        let bones: [ParticleGPUImageBone]
        let trails: Bool
        /// Spawns and steps in one thread (`ParticleGPUSystem.writesControlPoints`).
        let serialPoints: MTLBuffer?
        /// The boids slice's list, for a parallel step with a boids operator.
        let boidsMembers: MTLBuffer?
        /// The compaction that also writes the step's sprite records (no `.write` stage).
        let compactWriter: MTLComputePipelineState?
        /// An instanced `rope`'s strand order (`particleRopeOrder`); nil otherwise.
        let ropeOrder: MTLBuffer?

        init?(_ request: Request, gpu: ParticleGPUSystem, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>,
              compactWriters: [ParticleGPUDrawKind: MTLComputePipelineState], unlinkedPoints: MTLBuffer) {
            let configuration = request.system.configuration
            let subdivision = max(configuration.ropeSubdivision, 1)
            let followed: ParticleGPUSystem?
            if let system = request.system.simulation {
                guard let state = system.gpu else { return nil }
                followed = state
            } else {
                followed = nil
            }
            let source = followed ?? gpu
            guard let particles = source.particles, let stepped = source.stepped, let alive = source.alive,
                  let offsets = source.offsets, let blockSums = source.blockSums,
                  let records = gpu.recordBuffer(for: request.kind, subdivision: subdivision) else { return nil }
            simulation = followed
            parent = followed == nil ? request.system.parent?.gpu : nil
            if configuration.isInstanced, followed == nil, parent == nil { return nil }
            isInstanced = configuration.isInstanced
            isEventChild = configuration.isInstanced && configuration.link?.kind != .static
            self.request = request
            self.gpu = gpu
            frame = ParticleGPUFrame(request.inputs, sceneSize: sceneSize, targetSize: targetSize, kind: request.kind,
                                     materialVertexCount: request.materialVertexCount,
                                     renderVarOffset: request.renderVar?.offset)
            frame.emission.y = UInt32(gpu.emitterCount)
            let ropeUV = configuration.ropeUV
            frame.rope = SIMD4(ropeUV.rate * request.inputs.ropeRateScale, ropeUV.lifetime * request.inputs.ropeLifetimeScale,
                               Float(request.inputs.frameRateLimit), ropeUV.inverseScale)
            self.particles = particles
            self.stepped = stepped
            self.alive = alive
            self.offsets = offsets
            self.blockSums = blockSums
            self.records = records
            // Buffers a system without trails never touches still need a binding.
            if followed != nil {
                // The system's live trails: its step this frame, encoded before, already swapped them in.
                let live = source.history[source.historyIndex] ?? gpu.control
                history = live
                nextHistory = live
            } else {
                history = gpu.history[gpu.historyIndex] ?? gpu.control
                nextHistory = gpu.history[gpu.historyIndex ^ 1] ?? gpu.control
                gpu.toggleHistory()
            }
            trailCounts = source.trailCounts ?? gpu.control
            instances = gpu.instances ?? gpu.control
            linked = gpu.linkedPoints ?? unlinkedPoints
            program = request.inputs.initializers + request.inputs.operators
            var bones: [ParticleGPUImageBone] = []
            var steps = request.inputs.emitters.prefix(gpu.emitterCount).map { step -> ParticleGPUEmitterStep in
                defer { bones += step.bones.map(ParticleGPUImageBone.init) }
                return ParticleGPUEmitterStep(step, firstBone: bones.count)
            }
            while steps.count < max(gpu.emitterCount, 1) { steps.append(ParticleGPUEmitterStep(ParticleEmitterStep())) }
            self.steps = steps
            self.bones = bones
            trails = request.kind == .ropeTrail || request.kind == .fallbackRopeTrail
            serialPoints = gpu.writesControlPoints ? gpu.pointStates : nil
            let boids = request.inputs.operators.contains { $0.header.x == ParticleOperatorKind.boids.rawValue }
            boidsMembers = boids && serialPoints == nil && followed == nil ? gpu.boidsMembers() : nil
            // Sprites have no trail history to move; a step nothing draws writes no records. A
            // renderer after the first has no compaction and writes its records itself.
            compactWriter = request.writesRecords && !gpu.tracksHistory && followed == nil
                ? compactWriters[request.kind] : nil
            let rope = request.kind == .rope || request.kind == .fallbackRope
            ropeOrder = rope && configuration.isInstanced && request.writesRecords ? gpu.ropeOrder() : nil
        }
    }

    /// Encodes `plan`'s dispatch for `stage`; false when the stage has none for it.
    private func encode(_ stage: Stage, _ plan: StepPlan, encoder: MTLComputeCommandEncoder) -> Bool {
        let gpu = plan.gpu, control = gpu.control
        let frameLength = MemoryLayout<ParticleGPUFrame>.stride
        let group = MTLSize(width: Self.threadgroupSize, height: 1, depth: 1)
        let single = MTLSize(width: 1, height: 1, depth: 1)
        func perParticle() {
            encoder.dispatchThreadgroups(indirectBuffer: control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                         threadsPerThreadgroup: group)
        }
        switch stage {
        case .follow, .trailScanBlocks, .trailScanSums, .finish, .ropeOrder, .write:
            guard plan.request.writesRecords else { return false }
        default:
            // A renderer after a system's first only draws what that system's step left.
            guard plan.simulation == nil else { return false }
        }
        switch stage {
        case .linkPoints:
            guard let linkedPoints = gpu.linkedPoints, let parent = plan.parent, let parentParticles = parent.particles else {
                return false
            }
            var slots = UInt32(gpu.slots)
            encoder.setComputePipelineState(linkPoints)
            encoder.setBuffer(parentParticles, offset: 0, index: 0)
            encoder.setBuffer(parent.control, offset: 0, index: 1)
            encoder.setBuffer(linkedPoints, offset: 0, index: 2)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
            encoder.setBytes(&slots, length: 4, index: 4)
            encoder.dispatchThreads(MTLSize(width: gpu.slots, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(gpu.slots, 64), height: 1, depth: 1))
        case .age:
            // WE's order: every particle ages first and those past their lifetime die (0x140236d91).
            encoder.setComputePipelineState(age)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.alive, offset: 0, index: 1)
            encoder.setBuffer(control, offset: 0, index: 2)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
            encoder.setBytes(&plan.frame, length: frameLength, index: 4)
            encoder.setBuffer(plan.instances, offset: 0, index: 5)
            perParticle()
        case .eventMark, .eventScanBlocks, .eventScanSums, .eventScatter:
            guard plan.isEventChild, let parent = plan.parent, let parentStepped = parent.stepped, let parentAlive = parent.alive,
                  let flags = gpu.eventFlags, let offsets = gpu.eventOffsets, let blockSums = gpu.eventBlockSums,
                  let events = gpu.events else { return false }
            let perParentParticle = {
                encoder.dispatchThreadgroups(indirectBuffer: parent.control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                             threadsPerThreadgroup: group)
            }
            switch stage {
            case .eventMark:
                encoder.setComputePipelineState(eventMark)
                encoder.setBuffer(parentStepped, offset: 0, index: 0)
                encoder.setBuffer(parentAlive, offset: 0, index: 1)
                encoder.setBuffer(parent.control, offset: 0, index: 2)
                encoder.setBuffer(flags, offset: 0, index: 3)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 4)
                perParentParticle()
            case .eventScanBlocks:
                scanBlocks(flags, count: ParticleGPUSystem.Control.total, offsets: offsets, blockSums: blockSums,
                           control: parent.control, encoder: encoder)
            case .eventScanSums:
                scanSums(count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.eventTotal, blockSums: blockSums,
                         control: parent.control, totals: control, encoder: encoder)
            default:
                encoder.setComputePipelineState(eventScatter)
                encoder.setBuffer(flags, offset: 0, index: 0)
                encoder.setBuffer(offsets, offset: 0, index: 1)
                encoder.setBuffer(blockSums, offset: 0, index: 2)
                encoder.setBuffer(parent.control, offset: 0, index: 3)
                encoder.setBuffer(events, offset: 0, index: 4)
                perParentParticle()
            }
        case .begin:
            if plan.isInstanced {
                guard let parent = plan.parent, let instances = gpu.instances, let parentStepped = parent.stepped,
                      let parentParticles = parent.particles else { return false }
                encoder.setComputePipelineState(instanceStep)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(instances, offset: 0, index: 1)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
                encoder.setBytes(&plan.frame, length: frameLength, index: 3)
                encoder.setBuffer(parentStepped, offset: 0, index: 4)
                encoder.setBuffer(parentParticles, offset: 0, index: 5)
                encoder.setBuffer(parent.control, offset: 0, index: 6)
                encoder.setBuffer(gpu.events ?? control, offset: 0, index: 7)
                encoder.setBuffer(parent.instances ?? control, offset: 0, index: 8)
                encoder.setBuffer(gpu.emitterParameters, offset: 0, index: 9)
                bindEmitterSteps(plan.steps, index: 10, encoder: encoder)
                encoder.setBuffer(gpu.emitterStates, offset: 0, index: 11)
            } else {
                encoder.setComputePipelineState(begin)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 1)
                encoder.setBytes(&plan.frame, length: frameLength, index: 2)
                bindEmitterSteps(plan.steps, index: 3, encoder: encoder)
                encoder.setBuffer(gpu.emitterStates, offset: 0, index: 4)
            }
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        case .emit:
            // A program that writes control points spawns and steps in one thread, in WE's order.
            encoder.setComputePipelineState(plan.serialPoints == nil ? emit : emitSerial)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(control, offset: 0, index: 1)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
            encoder.setBytes(&plan.frame, length: frameLength, index: 3)
            encoder.setBuffer(plan.instances, offset: 0, index: 4)
            encoder.setBuffer(plan.linked, offset: 0, index: 5)
            bindProgram(plan.program, index: 6, fallback: control, encoder: encoder)
            encoder.setBuffer(gpu.emitterParameters, offset: 0, index: 7)
            encoder.setBuffer(gpu.emitterStates, offset: 0, index: 8)
            bindEmitterSteps(plan.steps, index: 10, encoder: encoder)
            encoder.setBuffer(gpu.imagePoints ?? control, offset: 0, index: 11)
            bindRecords(plan.bones, index: 12, fallback: control, encoder: encoder)
            if let serialPoints = plan.serialPoints {
                encoder.setBuffer(serialPoints, offset: 0, index: 9)
                encoder.dispatchThreads(single, threadsPerThreadgroup: single)
            } else {
                perParticle()
            }
        case .boidsMark, .boidsScanBlocks, .boidsScanSums, .boidsScatter:
            guard let members = plan.boidsMembers else { return false }
            switch stage {
            case .boidsMark:
                encoder.setComputePipelineState(boidsMark)
                encoder.setBuffer(plan.particles, offset: 0, index: 0)
                encoder.setBuffer(plan.alive, offset: 0, index: 1)
                encoder.setBuffer(control, offset: 0, index: 2)
                encoder.setBytes(&plan.frame, length: frameLength, index: 3)
                encoder.setBuffer(plan.offsets, offset: 0, index: 4)
                perParticle()
            case .boidsScanBlocks:
                // In place: each thread reads its own flag before writing its offset.
                scanBlocks(plan.offsets, count: ParticleGPUSystem.Control.total, offsets: plan.offsets, blockSums: plan.blockSums,
                           control: control, encoder: encoder)
            case .boidsScanSums:
                scanSums(count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.boidsTotal,
                         blockSums: plan.blockSums, control: control, totals: control, encoder: encoder)
            default:
                encoder.setComputePipelineState(boidsScatter)
                encoder.setBuffer(plan.particles, offset: 0, index: 0)
                encoder.setBuffer(plan.alive, offset: 0, index: 1)
                encoder.setBuffer(control, offset: 0, index: 2)
                encoder.setBytes(&plan.frame, length: frameLength, index: 3)
                encoder.setBuffer(plan.offsets, offset: 0, index: 4)
                encoder.setBuffer(plan.blockSums, offset: 0, index: 5)
                encoder.setBuffer(members, offset: 0, index: 6)
                perParticle()
            }
        case .simulate:
            encoder.setComputePipelineState(plan.serialPoints == nil ? simulate : simulateSerial)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.stepped, offset: 0, index: 1)
            encoder.setBuffer(plan.alive, offset: 0, index: 2)
            encoder.setBuffer(plan.history, offset: 0, index: 3)
            encoder.setBuffer(control, offset: 0, index: 4)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 5)
            encoder.setBytes(&plan.frame, length: frameLength, index: 6)
            encoder.setBuffer(plan.instances, offset: 0, index: 7)
            let collisions = plan.request.inputs.collisions
            let collisionBytes = collisions.count * MemoryLayout<ParticleCollisionPlacement>.stride
            if collisions.isEmpty {
                encoder.setBuffer(control, offset: 0, index: 8)
            } else if collisionBytes <= 4096 {
                collisions.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: collisionBytes, index: 8) }
            } else if let buffer = device.makeBuffer(bytes: collisions, length: collisionBytes, options: .storageModeShared) {
                encoder.setBuffer(buffer, offset: 0, index: 8)
            } else {
                encoder.setBuffer(control, offset: 0, index: 8)
            }
            encoder.setBuffer(plan.linked, offset: 0, index: 9)
            bindProgram(plan.program, index: 10, fallback: control, encoder: encoder)
            if let serialPoints = plan.serialPoints, let serialStates = gpu.serialStates {
                encoder.setBuffer(serialPoints, offset: 0, index: 11)
                encoder.setBuffer(serialStates, offset: 0, index: 12)
                encoder.dispatchThreads(single, threadsPerThreadgroup: single)
            } else {
                var listsBoids: UInt32 = plan.boidsMembers == nil ? 0 : 1
                encoder.setBuffer(plan.boidsMembers ?? control, offset: 0, index: 11)
                encoder.setBytes(&listsBoids, length: 4, index: 12)
                perParticle()
            }
        case .scanBlocks:
            scanBlocks(plan.alive, count: ParticleGPUSystem.Control.total, offsets: plan.offsets, blockSums: plan.blockSums,
                       control: control, encoder: encoder)
        case .scanSums:
            scanSums(count: ParticleGPUSystem.Control.total, into: ParticleGPUSystem.Control.count, blockSums: plan.blockSums,
                     control: control, totals: control, encoder: encoder)
        case .compact:
            if let compactWriter = plan.compactWriter {
                encoder.setComputePipelineState(compactWriter)
                encoder.setBuffer(plan.stepped, offset: 0, index: 0)
                encoder.setBuffer(plan.particles, offset: 0, index: 1)
                encoder.setBuffer(plan.alive, offset: 0, index: 2)
                encoder.setBuffer(plan.offsets, offset: 0, index: 3)
                encoder.setBuffer(plan.blockSums, offset: 0, index: 4)
                encoder.setBuffer(control, offset: 0, index: 5)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 6)
                encoder.setBytes(&plan.frame, length: frameLength, index: 7)
                encoder.setBuffer(plan.records, offset: 0, index: 8)
                perParticle()
                return true
            }
            encoder.setComputePipelineState(compact)
            encoder.setBuffer(plan.stepped, offset: 0, index: 0)
            encoder.setBuffer(plan.particles, offset: 0, index: 1)
            encoder.setBuffer(plan.alive, offset: 0, index: 2)
            encoder.setBuffer(plan.offsets, offset: 0, index: 3)
            encoder.setBuffer(plan.blockSums, offset: 0, index: 4)
            encoder.setBuffer(plan.history, offset: 0, index: 5)
            encoder.setBuffer(plan.nextHistory, offset: 0, index: 6)
            encoder.setBuffer(plan.trailCounts, offset: 0, index: 7)
            encoder.setBuffer(control, offset: 0, index: 8)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 9)
            perParticle()
        case .follow:
            guard let simulation = plan.simulation else { return false }
            let words = MTLSize(width: ParticleGPUSystem.Control.materialDrawOffset / 4, height: 1, depth: 1)
            encoder.setComputePipelineState(followControl)
            encoder.setBuffer(simulation.control, offset: 0, index: 0)
            encoder.setBuffer(control, offset: 0, index: 1)
            encoder.dispatchThreads(words, threadsPerThreadgroup: words)
        case .trailScanBlocks:
            guard plan.trails else { return false }
            scanBlocks(plan.trailCounts, count: ParticleGPUSystem.Control.count, offsets: plan.offsets, blockSums: plan.blockSums,
                       control: control, encoder: encoder)
        case .trailScanSums:
            guard plan.trails else { return false }
            scanSums(count: ParticleGPUSystem.Control.count, into: ParticleGPUSystem.Control.trailTotal, blockSums: plan.blockSums,
                     control: control, totals: control, encoder: encoder)
        case .finish:
            encoder.setComputePipelineState(finish)
            encoder.setBuffer(control, offset: 0, index: 0)
            encoder.setBuffer(plan.request.renderVar?.buffer ?? control, offset: 0, index: 1)
            encoder.setBuffer(gpu.parameters, offset: 0, index: 2)
            encoder.setBytes(&plan.frame, length: frameLength, index: 3)
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        case .ropeOrder:
            guard let order = plan.ropeOrder else { return false }
            var sizes = gpu.ropeOrderSizes
            encoder.setComputePipelineState(ropeSort)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(order, offset: 0, index: 1)
            encoder.setBuffer(control, offset: 0, index: 2)
            encoder.setBytes(&sizes, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            encoder.dispatchThreads(single, threadsPerThreadgroup: single)
        case .write:
            guard plan.compactWriter == nil, let writer = writers[plan.request.kind] else { return false }
            encoder.setComputePipelineState(writer)
            encoder.setBuffer(plan.particles, offset: 0, index: 0)
            encoder.setBuffer(plan.records, offset: 0, index: 1)
            if plan.trails {
                encoder.setBuffer(plan.nextHistory, offset: 0, index: 2)
                encoder.setBuffer(plan.offsets, offset: 0, index: 3)
                encoder.setBuffer(plan.blockSums, offset: 0, index: 4)
                encoder.setBuffer(control, offset: 0, index: 5)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 6)
                encoder.setBytes(&plan.frame, length: frameLength, index: 7)
            } else {
                encoder.setBuffer(control, offset: 0, index: 2)
                encoder.setBuffer(gpu.parameters, offset: 0, index: 3)
                encoder.setBytes(&plan.frame, length: frameLength, index: 4)
                var sizes = gpu.ropeOrderSizes
                encoder.setBuffer(plan.ropeOrder ?? control, offset: 0, index: 5)
                encoder.setBytes(&sizes, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 6)
            }
            perParticle()
        }
        return true
    }

    /// The step's program (`ParticleProgramOp`: initializers, then operators) at `index`.
    private func bindProgram(_ records: [ParticleProgramOp], index: Int, fallback: MTLBuffer, encoder: MTLComputeCommandEncoder) {
        bindRecords(records, index: index, fallback: fallback, encoder: encoder)
    }

    /// `records` at `index`: inline when small, else in a buffer of their own; `fallback` without any.
    private func bindRecords<Record>(_ records: [Record], index: Int, fallback: MTLBuffer, encoder: MTLComputeCommandEncoder) {
        let bytes = records.count * MemoryLayout<Record>.stride
        if records.isEmpty {
            encoder.setBuffer(fallback, offset: 0, index: index)
        } else if bytes <= 4096 {
            records.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: bytes, index: index) }
        } else if let buffer = device.makeBuffer(bytes: records, length: bytes, options: .storageModeShared) {
            encoder.setBuffer(buffer, offset: 0, index: index)
        } else {
            encoder.setBuffer(fallback, offset: 0, index: index)
        }
    }

    /// The step's emitters (`ParticleGPUEmitterStep`) at `index`.
    private func bindEmitterSteps(_ steps: [ParticleGPUEmitterStep], index: Int, encoder: MTLComputeCommandEncoder) {
        steps.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: index) }
    }

    /// Per-group prefix sums of `values` (`control[count]` of them) into `offsets` and `blockSums`.
    private func scanBlocks(_ values: MTLBuffer, count: Int, offsets: MTLBuffer, blockSums: MTLBuffer, control: MTLBuffer,
                            encoder: MTLComputeCommandEncoder) {
        var countIndex = UInt32(count)
        encoder.setComputePipelineState(scanBlocks)
        encoder.setBuffer(values, offset: 0, index: 0)
        encoder.setBuffer(offsets, offset: 0, index: 1)
        encoder.setBuffer(blockSums, offset: 0, index: 2)
        encoder.setBuffer(control, offset: 0, index: 3)
        encoder.setBytes(&countIndex, length: 4, index: 4)
        encoder.dispatchThreadgroups(indirectBuffer: control, indirectBufferOffset: ParticleGPUSystem.Control.dispatchOffset,
                                     threadsPerThreadgroup: MTLSize(width: Self.threadgroupSize, height: 1, depth: 1))
    }

    /// The groups' offsets from `scanBlocks`' totals, and the grand total into `totals[total]`.
    private func scanSums(count: Int, into total: Int, blockSums: MTLBuffer, control: MTLBuffer, totals: MTLBuffer,
                          encoder: MTLComputeCommandEncoder) {
        var indices = SIMD2<UInt32>(UInt32(count), UInt32(total))
        encoder.setComputePipelineState(scanBlockSums)
        encoder.setBuffer(blockSums, offset: 0, index: 0)
        encoder.setBuffer(control, offset: 0, index: 1)
        encoder.setBytes(&indices, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.setBuffer(totals, offset: 0, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: Self.threadgroupSize, height: 1, depth: 1))
    }

    /// An instanced system's instances after the last committed step (tests). Blocks until the
    /// GPU is done.
    func instances(_ system: ParticleSystemRuntime, queue: MTLCommandQueue) -> [ParticleGPUInstance] {
        guard let gpu = system.gpu, let instances = gpu.instances else { return [] }
        if let commandBuffer = queue.makeCommandBuffer() {
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        let count = instances.length / MemoryLayout<ParticleGPUInstance>.stride
        let pointer = instances.contents().bindMemory(to: ParticleGPUInstance.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// The particles of `system` after the last committed step, in order (tests, diagnostics).
    /// Blocks until the GPU is done.
    func snapshot(_ system: ParticleSystemRuntime, queue: MTLCommandQueue) -> [ParticleGPUState] {
        guard let gpu = system.gpu, let particles = gpu.particles else { return [] }
        return readBack(particles, as: ParticleGPUState.self, count: min(gpu.completedCount, gpu.capacity), queue: queue)
    }

    /// The history samples of a `ropetrail` particle from `snapshot`, oldest first (tests).
    func history(_ system: ParticleSystemRuntime, particle state: ParticleGPUState, index: Int,
                 queue: MTLCommandQueue) -> [SIMD2<Float>] {
        guard let gpu = system.gpu, let history = gpu.history[gpu.historyIndex] else { return [] }
        let count = Int(state.identity.z), start = Int(state.identity.w)
        let own = readBack(history, as: SIMD2<Float>.self, count: (index + 1) * gpu.historyLimit, queue: queue)
            .suffix(gpu.historyLimit)
        return (0..<count).map { own[own.startIndex + (start + $0) % count] }
    }

    /// The last step's records (tests): `count` of them, and the indirect draw arguments.
    func records<Record>(_ system: ParticleSystemRuntime, as type: Record.Type,
                         queue: MTLCommandQueue) -> (records: [Record], material: [UInt32], fallback: [UInt32]) {
        guard let gpu = system.gpu, let records = gpu.records else { return ([], [], []) }
        let words = gpu.control.contents().bindMemory(to: UInt32.self, capacity: ParticleGPUSystem.Control.words)
        let material = (0..<4).map { words[ParticleGPUSystem.Control.materialDrawOffset / 4 + $0] }
        let fallback = (0..<4).map { words[ParticleGPUSystem.Control.fallbackDrawOffset / 4 + $0] }
        let count = Int(gpu.recordKind?.isFallback == true ? fallback[1] : material[1])
        return (readBack(records, as: type, count: count, queue: queue), material, fallback)
    }

    private func readBack<Element>(_ buffer: MTLBuffer, as type: Element.Type, count: Int,
                                   queue: MTLCommandQueue) -> [Element] {
        let bytes = min(count * MemoryLayout<Element>.stride, buffer.length)
        guard bytes > 0, let commandBuffer = queue.makeCommandBuffer(),
              let staging = device.makeBuffer(length: bytes, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: buffer, sourceOffset: 0, to: staging, destinationOffset: 0, size: bytes)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let elements = staging.contents().bindMemory(to: Element.self, capacity: bytes / MemoryLayout<Element>.stride)
        return Array(UnsafeBufferPointer(start: elements, count: bytes / MemoryLayout<Element>.stride))
    }
}
