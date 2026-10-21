import Metal

/// One particle system's state on the GPU: its particles, trail history, the scratch the
/// compaction needs, the records it draws from and a small control block of counters and
/// indirect arguments. Buffers grow with the system and are reused every frame.
final class ParticleGPUSystem {
    /// Word indices into `control` (`ParticleSimulation.metal`'s `c…` constants).
    enum Control {
        static let count = 0, emitted = 1, total = 2, serial = 3, died = 4, boidsTotal = 5, trailTotal = 6
        static let dispatchOffset = 8 * 4
        /// `MTLDrawIndexedPrimitivesIndirectArguments` for the material draw (five words).
        static let materialDrawOffset = 12 * 4
        /// `MTLDrawPrimitivesIndirectArguments` for the built-in draw.
        static let fallbackDrawOffset = 24 * 4
        /// Events an instanced system's parent made this step (`ParticleInstances.metal`).
        static let eventTotal = 20
        static let words = 28
    }

    let parameters: MTLBuffer
    /// The system's emitters (`ParticleGPUEmitter`), in order; replaced with `imagePoints` when a
    /// resampling changes their points (`updateImagePoints`).
    private(set) var emitterParameters: MTLBuffer
    /// Each emitter's running state (`ParticleGPUEmitterState`), `slots` × emitters of them.
    let emitterStates: MTLBuffer
    let emitterCount: Int
    /// Every `layerimage` emitter's points (`ParticleSystemRuntime.emitterImages`), one after
    /// another; nil without any.
    private(set) var imagePoints: MTLBuffer?
    /// The runtime's `emitterImagesRevision` the points are from.
    private(set) var imagePointsRevision = 0
    /// A program that writes control points (`ParticleProgram.writesControlPoints`) steps in one
    /// thread (`particleEmitSerial`, `particleSimulateSerial`): each slot's points (`PointState`), and
    /// the particles' program state between records (`SerialState`, sized with the particles).
    let writesControlPoints: Bool
    let pointStates: MTLBuffer?
    private(set) var serialStates: MTLBuffer?
    /// `PointState` and `SerialState` in `ParticleProgram.h`.
    static let pointStateStride = 400, serialStateStride = 144

    /// Counters and indirect arguments; shared so tests and metrics can read the count.
    let control: MTLBuffer
    let historyLimit: Int
    let tracksHistory: Bool
    /// The most particles the system may hold: `ParticleFrameInputs.maximum`, times the instances
    /// of an instanced system. Instance overrides can change it every frame.
    private(set) var maximumCount = 0
    /// An instanced system's instances; 1 otherwise.
    let slots: Int
    /// An instanced system's instances (`ParticleGPUInstance`), zeroed at creation.
    let instances: MTLBuffer?
    /// A linked child's control points from its parent's particles (`ParticleGPULinkedPoints`), one
    /// per slot; nil without the link.
    let linkedPoints: MTLBuffer?
    /// Scratch for an event child, sized for its parent's particles: event flags, their prefix
    /// sums and the listed events.
    private(set) var eventFlags: MTLBuffer?
    private(set) var eventOffsets: MTLBuffer?
    private(set) var eventBlockSums: MTLBuffer?
    private(set) var events: MTLBuffer?
    private var eventCapacity = 0
    /// The boids slice's members (`BoidsMember` in `ParticleProgram.h`), for a program with boids;
    /// sized with the particles.
    private var boidsMemberBuffer: MTLBuffer?
    static let boidsMemberStride = 32

    private let device: MTLDevice
    private(set) var capacity = 0
    private(set) var particles: MTLBuffer?
    private(set) var stepped: MTLBuffer?
    private(set) var alive: MTLBuffer?
    private(set) var offsets: MTLBuffer?
    private(set) var blockSums: MTLBuffer?
    private(set) var trailCounts: MTLBuffer?
    /// Ping-ponged by the compaction; `history[historyIndex]` holds the live trails.
    private(set) var history: [MTLBuffer?] = [nil, nil]
    private(set) var historyIndex = 0
    private(set) var records: MTLBuffer?
    private(set) var recordKind: ParticleGPUDrawKind?
    /// Live particles can't exceed this: emission so far, bounded by the maximum. The CPU tracks
    /// it without reading the GPU, so buffers grow before a step can overflow them.
    private(set) var upperBound = 0
    /// Each emitter's `instantaneous` burst, which any instance may fire on its own clock.
    private let instanceBursts: [Int]
    /// This frame's buffers are in place (`ParticleGPUSimulator.encode`); a system that can't
    /// grow draws nothing.
    var isReady = false
    var reportedFailure = false
    /// The simulator's frame serial of the last step that could hold or add particles (nil before
    /// the first step); once that frame has completed with no particle alive the system is empty.
    var lastLiveSerial: UInt64?

    /// The emitters' records and their points, one image's after another.
    private static func emitterRecords(_ configuration: SceneMetalParticleSystem, images: [ParticleEmitterImage])
        -> (emitters: [ParticleGPUEmitter], points: [SIMD4<Int32>]) {
        var pointList: [SIMD4<Int32>] = []
        let emitters = configuration.emitters.map { emitter -> ParticleGPUEmitter in
            guard emitter.shape.kind == .image, emitter.shape.imageIndex < images.count else {
                return ParticleGPUEmitter(emitter)
            }
            let points = images[emitter.shape.imageIndex].points
            defer { pointList += points }
            return ParticleGPUEmitter(emitter, imagePoints: (pointList.count, points.count))
        }
        return (emitters, pointList)
    }

    /// Takes a runtime's resampled points (`ParticleSystemRuntime.replaceImagePoints`) when they
    /// changed since the last: new buffers, so a frame still on the GPU keeps reading the old ones.
    func updateImagePoints(_ runtime: ParticleSystemRuntime) {
        guard runtime.emitterImagesRevision != imagePointsRevision else { return }
        let (emitters, pointList) = Self.emitterRecords(runtime.configuration, images: runtime.emitterImages)
        guard let parameters = device.makeBuffer(bytes: emitters, length: emitters.count * MemoryLayout<ParticleGPUEmitter>.stride,
                                                 options: .storageModeShared) else { return }
        let points = pointList.isEmpty ? nil
            : device.makeBuffer(bytes: pointList, length: pointList.count * MemoryLayout<SIMD4<Int32>>.stride,
                                options: .storageModeShared)
        guard pointList.isEmpty || points != nil else { return }
        parameters.label = "Particle emitters"
        points?.label = "Particle layer image points"
        emitterParameters = parameters
        imagePoints = points
        imagePointsRevision = runtime.emitterImagesRevision
    }

    init?(device: MTLDevice, configuration: SceneMetalParticleSystem, seed: UInt32,
          images: [ParticleEmitterImage]? = nil) {
        var values = ParticleGPUParameters(configuration, seed: seed)
        let (emitters, pointList) = Self.emitterRecords(configuration, images: images ?? configuration.emitterImages)
        let slotCount = configuration.isInstanced ? max(configuration.link?.maximumInstances ?? 0, 1) : 1
        guard let parameters = device.makeBuffer(bytes: &values, length: MemoryLayout<ParticleGPUParameters>.stride,
                                                 options: .storageModeShared),
              let control = device.makeBuffer(length: Control.words * 4, options: .storageModeShared),
              let emitterParameters = device.makeBuffer(bytes: emitters, length: emitters.count * MemoryLayout<ParticleGPUEmitter>.stride,
                                                        options: .storageModeShared),
              let emitterStates = device.makeBuffer(length: slotCount * emitters.count * MemoryLayout<ParticleGPUEmitterState>.stride,
                                                    options: .storageModeShared) else { return nil }
        memset(control.contents(), 0, control.length)
        memset(emitterStates.contents(), 0, emitterStates.length)
        emitterParameters.label = "Particle emitters"
        emitterStates.label = "Particle emitter states"
        self.emitterParameters = emitterParameters
        self.emitterStates = emitterStates
        emitterCount = emitters.count
        instanceBursts = configuration.emitters.map { max($0.instantaneous, 0) }
        if pointList.isEmpty {
            imagePoints = nil
        } else {
            guard let buffer = device.makeBuffer(bytes: pointList, length: pointList.count * MemoryLayout<SIMD4<Int32>>.stride,
                                                 options: .storageModeShared) else { return nil }
            buffer.label = "Particle layer image points"
            imagePoints = buffer
        }
        writesControlPoints = configuration.program.writesControlPoints
        if writesControlPoints {
            guard let points = device.makeBuffer(length: slotCount * Self.pointStateStride, options: .storageModeShared) else {
                return nil
            }
            memset(points.contents(), 0, points.length)
            points.label = "Particle control point writes"
            pointStates = points
        } else {
            pointStates = nil
        }
        self.device = device
        self.parameters = parameters
        self.control = control
        historyLimit = values.historyLimit
        tracksHistory = configuration.trailHistory.kept
        if configuration.isInstanced {
            let slots = max(configuration.link?.maximumInstances ?? 0, 0)
            self.slots = slots
            guard let instances = device.makeBuffer(length: max(slots, 1) * MemoryLayout<ParticleGPUInstance>.stride,
                                                    options: .storageModeShared) else { return nil }
            memset(instances.contents(), 0, instances.length)
            instances.label = "Particle instances"
            self.instances = instances
        } else {
            slots = 1
            instances = nil
        }
        if configuration.link?.controlPointStart != nil {
            let bytes = max(slots, 1) * MemoryLayout<ParticleGPULinkedPoints>.stride
            guard let linked = device.makeBuffer(length: bytes, options: .storageModePrivate) else { return nil }
            linked.label = "Particle linked control points"
            linkedPoints = linked
        } else {
            linkedPoints = nil
        }
        parameters.label = "Particle parameters"
        control.label = "Particle control"
    }

    /// Live particles as of the last completed frame (it may lag the GPU by a frame or two).
    var completedCount: Int {
        Int(control.contents().load(fromByteOffset: Control.count * 4, as: UInt32.self))
    }

    func toggleHistory() { historyIndex ^= 1 }

    /// For a renderer after a system's first (`ParticleSystemRuntime.simulation`): sizes this
    /// frame's records for `simulation`'s particles, which the step draws from. False when that
    /// system has nothing to draw from this frame.
    func follow(_ simulation: ParticleGPUSystem) -> Bool {
        capacity = simulation.capacity
        return simulation.isReady && simulation.particles != nil
    }

    /// Updates the bound for this step and grows the state buffers to hold it, copying the live
    /// particles with `blit` (made on demand). False when a buffer can't be allocated.
    func reserve(for inputs: ParticleFrameInputs, blit: () -> MTLBlitCommandEncoder?) -> Bool {
        // Every instance may hold the system's maximum.
        let (product, overflow) = max(inputs.maximum, 0).multipliedReportingOverflow(by: max(slots, 0))
        maximumCount = overflow ? Int.max : product
        let stepSpawns = Self.stepSpawns(inputs, instanceBursts: instances != nil ? instanceBursts : nil,
                                         slots: slots, maximumCount: maximumCount)
        let held = upperBound
        upperBound = inputs.clears ? 0 : Int(min(Double(upperBound) + Double(stepSpawns), Double(maximumCount)))
        let plan = Self.capacityPlan(held: held, stepSpawns: stepSpawns, maximumCount: maximumCount, capacity: capacity)
        guard plan.grows || particles == nil else { return true }
        return grow(to: plan.capacity, blit: blit)
    }

    /// The most particles one step can add. A step holds last step's particles (the ones that
    /// die aging are compacted away at its end) and its spawns. The carried remainder is below 1
    /// at the start of a step, so an emitter spawns at most ⌊rate·Δt⌋ + 1 particles plus its
    /// burst. An instanced system's instances (`instanceBursts` non-nil) each emit on their own
    /// clock and may each fire their emitters' `instantaneous` bursts this step
    /// (`particleInstanceStep`), so each counts that bound; each instance stays within the
    /// per-instance maximum, so the whole stays within `maximumCount`.
    static func stepSpawns(_ inputs: ParticleFrameInputs, instanceBursts: [Int]?, slots: Int, maximumCount: Int) -> Int {
        let deltaTime = Double(inputs.deltaTime)
        func rateBound(_ emitter: ParticleEmitterStep) -> Double {
            (Double(max(emitter.rate, 0)) * deltaTime).rounded(.down) + 1
        }
        let spawns: Double
        if let instanceBursts {
            let count = max(instanceBursts.count, inputs.emitters.count)
            let perInstance = (0..<count).reduce(0.0) { total, index in
                let emitter = index < inputs.emitters.count ? inputs.emitters[index] : ParticleEmitterStep()
                let burst = max(index < instanceBursts.count ? instanceBursts[index] : 0, emitter.burst, emitter.instantaneous, 0)
                return total + rateBound(emitter) + Double(burst)
            }
            spawns = perInstance * Double(max(slots, 1))
        } else {
            spawns = inputs.emitters.reduce(0.0) { $0 + rateBound($1) + Double(max($1.burst, 0)) }
        }
        return Int(min(spawns, Double(maximumCount)))
    }

    /// Whether the state buffers grow this step, and to what. They grow a step early (when the
    /// step after this one could overflow them), doubling, so a growing system reallocates
    /// rarely and never past what a step can hold (`maximumCount + stepSpawns`).
    static func capacityPlan(held: Int, stepSpawns: Int, maximumCount: Int, capacity: Int) -> (grows: Bool, capacity: Int) {
        let needed = min(held + stepSpawns, maximumCount + stepSpawns)
        let limit = maximumCount + stepSpawns
        let ahead = min(needed + stepSpawns, limit)
        guard ahead > capacity || capacity == 0 else { return (false, capacity) }
        let grown = max(ahead, capacity * 2, 256)
        return (true, maximumCount > 0 ? min(grown, max(limit, 1)) : 256)
    }

    private func grow(to newCapacity: Int, blit: () -> MTLBlitCommandEncoder?) -> Bool {
        let stateStride = MemoryLayout<ParticleGPUState>.stride
        let slots = (newCapacity + 255) / 256 * 256
        func buffer(_ bytes: Int, _ label: String) -> MTLBuffer? {
            let buffer = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
            buffer?.label = label
            return buffer
        }
        var newSerialStates: MTLBuffer?
        if writesControlPoints {
            guard let serial = buffer(slots * Self.serialStateStride, "Particle serial states") else { return false }
            newSerialStates = serial
        }
        guard let newParticles = buffer(slots * stateStride, "Particles"),
              let newStepped = buffer(slots * stateStride, "Particles stepped"),
              let newAlive = buffer(slots * 4, "Particle alive"),
              let newOffsets = buffer(slots * 4, "Particle offsets"),
              let newBlockSums = buffer((slots / 256 + 1) * 4, "Particle block sums") else { return false }
        var newHistory: [MTLBuffer?] = [nil, nil]
        var newTrailCounts: MTLBuffer?
        if tracksHistory {
            let bytes = slots * historyLimit * MemoryLayout<SIMD2<Float>>.stride
            guard let first = buffer(bytes, "Particle history"), let second = buffer(bytes, "Particle history"),
                  let counts = buffer(slots * 4, "Particle trail counts") else { return false }
            newHistory = [first, second]
            newTrailCounts = counts
        }
        if let old = particles, capacity > 0, let encoder = blit() {
            encoder.copy(from: old, sourceOffset: 0, to: newParticles, destinationOffset: 0,
                         size: min(old.length, newParticles.length))
            if let oldHistory = history[historyIndex], let target = newHistory[historyIndex] {
                encoder.copy(from: oldHistory, sourceOffset: 0, to: target, destinationOffset: 0,
                             size: min(oldHistory.length, target.length))
            }
        }
        particles = newParticles
        stepped = newStepped
        serialStates = newSerialStates
        alive = newAlive
        offsets = newOffsets
        blockSums = newBlockSums
        history = newHistory
        trailCounts = newTrailCounts
        capacity = newCapacity
        records = nil
        return true
    }

    /// The boids slice's list, large enough for the current capacity; nil when it can't be allocated.
    func boidsMembers() -> MTLBuffer? {
        let bytes = (capacity + 255) / 256 * 256 * Self.boidsMemberStride
        if let boidsMemberBuffer, boidsMemberBuffer.length >= bytes { return boidsMemberBuffer }
        boidsMemberBuffer = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
        boidsMemberBuffer?.label = "Particle boids slice"
        return boidsMemberBuffer
    }

    private var ropeOrderBuffer: MTLBuffer?

    /// `particleRopeOrder`'s slots and capacity.
    var ropeOrderSizes: SIMD2<UInt32> { SIMD2(UInt32(max(slots, 1)), UInt32(capacity)) }

    /// An instanced rope's strand order (starts and lengths per instance, sorted indices and
    /// places), large enough for the current capacity; nil when it can't be allocated.
    func ropeOrder() -> MTLBuffer? {
        let bytes = (max(slots, 1) * 2 + capacity * 2) * 4
        if let ropeOrderBuffer, ropeOrderBuffer.length >= bytes { return ropeOrderBuffer }
        ropeOrderBuffer = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
        ropeOrderBuffer?.label = "Particle rope order"
        return ropeOrderBuffer
    }

    /// Sizes the event scratch for a parent holding up to `parentCapacity` particles. False when
    /// a buffer can't be allocated.
    func reserveEvents(parentCapacity: Int) -> Bool {
        guard parentCapacity > eventCapacity || events == nil else { return true }
        let slots = (max(parentCapacity, 1) + 255) / 256 * 256
        func buffer(_ bytes: Int, _ label: String) -> MTLBuffer? {
            let buffer = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
            buffer?.label = label
            return buffer
        }
        guard let flags = buffer(slots * 4, "Particle event flags"), let offsets = buffer(slots * 4, "Particle event offsets"),
              let blockSums = buffer((slots / 256 + 1) * 4, "Particle event block sums"),
              let list = buffer(slots * 4, "Particle events") else { return false }
        eventFlags = flags
        eventOffsets = offsets
        eventBlockSums = blockSums
        events = list
        eventCapacity = slots
        return true
    }

    /// The record buffer for `kind`, large enough for the current capacity.
    func recordBuffer(for kind: ParticleGPUDrawKind, subdivision: Int) -> MTLBuffer? {
        let bytes = Self.recordBytes(kind, capacity: capacity, historyLimit: historyLimit, subdivision: subdivision)
        if let records, recordKind == kind, records.length >= bytes { return records }
        records = device.makeBuffer(length: max(bytes, 16), options: .storageModePrivate)
        records?.label = "Particle records"
        recordKind = kind
        return records
    }

    static func recordBytes(_ kind: ParticleGPUDrawKind, capacity: Int, historyLimit: Int, subdivision: Int) -> Int {
        let instance = MemoryLayout<LayerUniform>.stride
        switch kind {
        case .sprite: return capacity * MemoryLayout<ParticleSpriteInstance>.stride
        case .rope: return capacity * MemoryLayout<ParticleRopeSegmentInstance>.stride
        case .ropeTrail: return capacity * historyLimit * MemoryLayout<ParticleRopeSegmentInstance>.stride
        case .fallbackSprite, .fallbackSpriteTrail: return capacity * instance
        case .fallbackRope: return capacity * subdivision * instance
        case .fallbackRopeTrail: return capacity * historyLimit * subdivision * instance
        }
    }
}
