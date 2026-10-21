import simd

/// What a particle system's simulation step reads from outside the particles: the time step,
/// script-evaluated values, the system's space this frame, control points and the encoded
/// program, evaluated once per frame on the CPU for the GPU's step (`ParticleGPUSimulator`).
///
/// WE simulates a system in its object's space unless the system is `worldspace` (flag 1), and
/// draws it through the object's model matrix (`wallpaper64.exe` 0x14023761b…0x14023767a; the
/// particle vertex shaders expand in that space). The particles here are kept in the scene;
/// `space` takes the system's space to the scene, and every initializer and operator runs in the
/// system's space (`ParticleProgram.h`), so velocities, gravity and every
/// distance scale and turn with the object as they do in WE.
struct ParticleFrameInputs {
    var deltaTime: Float = 0
    /// Seconds since the system started (after this step): WE's system time.
    var elapsedTime: Float = 0
    /// Seconds since the scene started: WE's engine time, which `turbulence`,
    /// `turbulentvelocityrandom` and `positionoffsetrandom` read.
    var engineTime: Float = 0
    /// The fraction of the day that has passed (`remapvalue`'s `timeofday`).
    var timeOfDay: Float = 0
    /// Steps taken, this one included.
    var frameIndex: UInt32 = 0
    /// The system's trail countdown ran out this step: every particle records its trail history
    /// (`ParticleTrailHistory`).
    var samplesTrail = false
    /// Each emitter's part of the step, in the order WE runs them (0x1402378a0); the first is
    /// `emissionRate`, `burst`, `startsPeriod`, `periodLimit` and `onePerFrame`.
    var emitters = [ParticleEmitterStep()]
    /// The engine's frame time: the last frame's length in seconds (`wallpaper64.exe`
    /// [engine+0x14c], which SceneScript reads as `engine.frametime`). WE damps drag and the
    /// field operators below 40 frames a second by it (`dragFactor`).
    var frameTime: Float = 0
    /// The frame-rate limit setting (WE's `fps`, [engine+0x148], copied from the settings' `fps` at
    /// 0x1401114f1). At 1…20 the operators run twice, in half steps (`substeps`).
    var frameRateLimit = 0
    /// The most particles the system (each instance, when instanced) may hold: the authored
    /// maximum times the `count` override and the particle budget's factor.
    var maximum = 0
    /// The instance overrides spawned particles take: size, alpha, lifetime and speed factors.
    var spawnScale = SIMD4<Float>(repeating: 1)
    /// The overrides' tint times brightness: spawned particles' base colour.
    var colorScale = SIMD3<Float>(repeating: 1)
    /// Collision shapes in the scene this step (`ParticleOperatorKind.collision` records index them).
    var collisions: [ParticleCollisionPlacement] = []
    /// How many of `collisions` each collision operator placed, in program order.
    var collisionCounts: [Int] = []
    /// The system emits nothing and shows nothing this frame: every particle is removed.
    var clears = false

    /// The first emitter's rate this step (`emitters[0]`).
    var emissionRate: Float {
        get { emitters[0].rate }
        set { emitters[0].rate = newValue }
    }
    /// The first emitter's burst: particles emitted at once this step on top of the rate, its
    /// `instantaneous` burst when it starts or starts a period (`ParticleEmitterClock`).
    var burst: Int {
        get { emitters[0].burst }
        set { emitters[0].burst = newValue }
    }
    /// A period of the first emitter starts this step: its per-period count restarts.
    var startsPeriod: Bool {
        get { emitters[0].startsPeriod }
        set { emitters[0].startsPeriod = newValue }
    }
    /// The most the first emitter's rate emits in one period; nil without a limit.
    var periodLimit: Int? {
        get { emitters[0].periodLimit }
        set { emitters[0].periodLimit = newValue }
    }
    /// The first emitter's rate emits at most one particle a step.
    var onePerFrame: Bool {
        get { emitters[0].onePerFrame }
        set { emitters[0].onePerFrame = newValue }
    }

    /// The operators' time step for drag and the field operators: the step times
    /// `pow(min(0.025 / frame time, 1), 0.7)` (`wallpaper64.exe` 0x140237724…0x14023775f). It passes
    /// to the operator VM next to the step (0x14023fbc0: [rbp+0x5f0]); `movement` and
    /// `angularmovement` damp by it, and `controlpointattract`, `turbulence`, `vortex`, `vortex_v2`'s
    /// spin and `boids` push by it (their handlers read it, 0x14024155b, 0x1402429cb, 0x1402432b9,
    /// 0x140243449, 0x1402441b5). The same as the step at 40 frames a second or more.
    var dragDeltaTime: Float {
        // A frame time of 0 (no frame yet) divides to infinity and keeps the factor 1.
        deltaTime * pow(min(0.025 / frameTime, 1), 0.7)
    }

    /// How many times the operators run this step: twice, each with half the step and half
    /// `dragDeltaTime`, when the frame-rate limit is 1…20 (0x140237764…0x140237793); once otherwise.
    var substeps: Int { (1...20).contains(frameRateLimit) ? 2 : 1 }

    /// The system's space in the scene: the emitter's transform, identity for a `worldspace`
    /// system (which simulates in the scene).
    var space = SceneAffineTransform.identity
    /// The control points in the system's space (x and y as the scene's plane maps them, z the
    /// depth), by index, and where they were last step.
    var controlPoints = [SIMD3<Float>](repeating: .zero, count: ParticleControlPoint.count)
    var previousControlPoints = [SIMD3<Float>](repeating: .zero, count: ParticleControlPoint.count)
    /// Each control point's orientation in the system's space: rows 0…2 of WE's control point
    /// matrix as columns (`ParticleProgramEncoding.controlPointRotation`), from its `controlpointangle<n>`
    /// override and, in a `worldspace` system, the emitter's scale and rotation. An emitter's spawn
    /// offsets and the velocity initializers turn with its point's (0x140237c14, 0x14023b364).
    var controlPointAxes = [simd_float3x3](repeating: matrix_identity_float3x3, count: ParticleControlPoint.count)
    /// The offsets the object's `controlpoint<n>` overrides give, by index; nil for a point they
    /// don't drive.
    var overridePoints = [SIMD3<Float>?](repeating: nil, count: ParticleControlPoint.count)
    /// The points an override drives that didn't change since the last step: the GPU keeps what the
    /// last step wrote there (`particleEmitSerial`). Bit n is control point n.
    var keptPoints: UInt32 = 0
    /// The particle object's position in the scene (`remapvalue`'s `layerorigin`, WE's layer
    /// origin, 0x1402448d0).
    var layerOrigin = SIMD2<Float>.zero
    /// Control points that sit in the scene (the cursor, scene-space and linked ones): an instance
    /// of an instanced system doesn't carry them (`placed(at:)`). Bit n is control point n.
    var absolutePoints: UInt32 = 0
    /// This step's program: every record with its scripts and audio evaluated.
    var initializers: [ParticleProgramOp] = []
    var operators: [ParticleProgramOp] = []

    /// How the emitter moved since the last step, for systems whose particles live in its space:
    /// applied to every particle alive before this step's spawns. Nil when it did not move.
    var motion: SceneAffineTransform?

    /// What the emitter's scale and rotation make of a spawned particle's size and rotation, for a
    /// `worldspace` system, whose particles leave its space when they spawn: the area scale's
    /// square root and the turn. A system whose particles stay in its space draws them through its
    /// transform instead (`drawLinear`), and keeps 1 and 0.
    var spawnSizeScale: Float = 1
    var spawnTurn: Float = 0

    /// The emitter's scale, rotation and shear its particles are drawn through, as WE draws a system
    /// through its model matrix: a sprite is squashed and turned with it
    /// (`ParticleSystemRuntime.drawLinear`). Identity for a `worldspace` system.
    var drawLinear = matrix_identity_float2x2
    /// The factor on the size of trail and rope records, whose width the shaders don't take from
    /// `drawLinear`: its area scale's square root (`ParticleSystemRuntime.drawSizeScale`).
    var drawSizeScale: Float = 1
    /// A built-in sprite's quad axes: the renderer's orientation through `drawLinear`
    /// (`ParticleSystemRuntime.spriteLinear`).
    var spriteLinear = matrix_identity_float2x2
    /// The instance overrides of rate and lifetime a rope lays its texture by (`ParticleRopeUV`).
    var ropeRateScale: Float = 1
    var ropeLifetimeScale: Float = 1

    /// The system's space to the scene's inverse linear part (identity when it collapses).
    var toSpace: simd_float2x2 { space.inverse?.linear ?? matrix_identity_float2x2 }

    /// Advances `system`'s clock and evaluates this step's inputs. `emitter` is the emitter's
    /// world transform this frame; nil keeps the authored one. `scripted` is what the wallpaper's
    /// scripts wrote into the system's `instanceoverride`. `modelCapsules` gives the capsules of
    /// an object a `collisionmodel` operator links, in the scene's plane and depth
    /// (`ParticleCapsule`).
    static func advance(_ system: ParticleSystemRuntime, deltaTime: Float, cursor: SIMD2<Float>,
                        emitter: SceneAffineTransform? = nil, values: SceneValueContext? = nil,
                        scripted: SceneScriptInstanceOverrides? = nil, audio: AudioSpectrumSnapshot = .silent, frameTime: Float? = nil,
                        frameRateLimit: Int = 0,
                        layerWorld: (String) -> SceneAffineTransform? = { _ in nil },
                        layerBones: (String) -> ParticleLayerBones? = { _ in nil },
                        modelCapsules: (String) -> [ParticleCapsule] = { _ in [] }) -> ParticleFrameInputs {
        let configuration = system.configuration
        restartWithParent(system)
        system.clearedWhileHidden = false
        system.elapsedTime += deltaTime
        system.frameIndex &+= 1
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        // A step of its own (the tests, WE's pre-simulation) is its frame.
        inputs.frameTime = frameTime ?? deltaTime
        inputs.frameRateLimit = frameRateLimit
        inputs.elapsedTime = system.elapsedTime
        inputs.engineTime = system.elapsedTime
        inputs.frameIndex = system.frameIndex
        inputs.samplesTrail = advanceTrailTimer(system, deltaTime: deltaTime)
        inputs.timeOfDay = system.timeOfDay()
        let world = emitter ?? childEmitter(system) ?? configuration.authoredWorld
        inputs.motion = motion(of: system, to: world)
        let time = Double(system.elapsedTime)
        let context = values ?? LiveSceneValueContext()
        let overrides = inputs.applyOverrides(system, values: context, scripted: scripted)
        let emitters = configuration.emitters
        inputs.emitters = emitters.map { emitter in
            var step = ParticleEmitterStep()
            // The emitter parser binds `rate` and `maxtoemitperperiod` to the `count` override
            // (0x1401c6e6c…0x1401c6ef6, gated by the system's flag 0x20). The `rate` override
            // binds only the turbulence operators' `timescale` (`encodeProgram`).
            step.rate = emitter.rate * overrides.count
            step.instantaneous = max(emitter.instantaneous, 0)
            step.periodLimit = emitter.timing.periodLimit(countScale: overrides.count)
            step.onePerFrame = emitter.timing.onePerFrame
            return step
        }
        // A system without a rate or burst still steps: scripts' `emitParticles(count)` bursts
        // into it (`SceneMetalRenderer.applyScriptPlayback`), and what they emitted lives out its
        // lifetime. An empty one costs no GPU step (`ParticleGPUSimulator.skippingEmpty`).
        if configuration.opacityMultiplier <= 0.0001 {
            inputs.clears = true
            return inputs
        }
        if system.emitterStates.count < emitters.count {
            system.emitterStates += Array(repeating: ParticleEmitterState(), count: emitters.count - system.emitterStates.count)
        }
        for (index, emitter) in emitters.enumerated() {
            // An instanced system times each instance instead (`ParticleInstances.metal`).
            if !configuration.isInstanced {
                let key = ParticleEmitterState.clockKey(0, emitter: index)
                let step = system.emitterStates[index].clock.advance(deltaTime, timing: emitter.timing, seed: system.seed, key: key)
                inputs.emitters[index].burst = step.bursts ? inputs.emitters[index].instantaneous : 0
                inputs.emitters[index].startsPeriod = step.startsPeriod
                if !step.emits { inputs.emitters[index].rate = 0 }
            }
            // Silence stops an audio-responsive emitter without clearing what it emitted.
            if let response = emitter.audio { inputs.emitters[index].rate *= response.response(audio) }
        }
        // A periodic emitter starting a period restarts the children linked with flag 2 (0x14022f790).
        system.startedPeriod = !configuration.isInstanced
            && zip(emitters, inputs.emitters).contains { $0.timing.periodic && $1.startsPeriod }
        inputs.space = configuration.worldSpace ? .identity : world
        inputs.placeImages(system, layerWorld: layerWorld, layerBones: layerBones)
        inputs.layerOrigin = world.translation
        if configuration.worldSpace {
            let linear = world.linear
            inputs.spawnSizeScale = sqrt(abs(simd_determinant(linear)))
            inputs.spawnTurn = atan2(linear.columns.0.y, linear.columns.0.x)
        }
        let drawLinear = configuration.worldSpace ? matrix_identity_float2x2 : world.linear
        if drawLinear != system.drawLinear || system.frameIndex == 1 {
            system.drawLinear = drawLinear
            system.spriteLinear = configuration.orientation.spriteLinear(linear: drawLinear)
        }
        inputs.drawLinear = system.drawLinear
        inputs.drawSizeScale = system.drawSizeScale
        inputs.spriteLinear = system.spriteLinear
        inputs.ropeRateScale = overrides.count
        inputs.ropeLifetimeScale = inputs.spawnScale.z
        system.ropeFrame = SIMD3(inputs.ropeRateScale, inputs.ropeLifetimeScale, Float(frameRateLimit))
        inputs.placeControlPoints(system, world: world, cursor: cursor, overrides: overrides, modelCapsules: modelCapsules)
        inputs.encodeProgram(system, audio: audio, overrides: overrides)
        return inputs
    }

    /// The system's instance overrides this frame, less the parts its flags switch off; bound to
    /// user properties, they resolve again, and scripts' values replace them.
    private mutating func applyOverrides(_ system: ParticleSystemRuntime, values: SceneValueContext,
                                         scripted: SceneScriptInstanceOverrides?) -> SceneParticleOverrides {
        let configuration = system.configuration
        let authored = configuration.liveOverrides.map { live in
            let resolve = { SceneParticleOverrides(live, in: values, object: configuration.objectID.flatMap { Int($0) }) }
            // Kept per binding revision unless something changes it every frame.
            let perFrame = live.values.values.contains {
                $0.animation != nil || $0.userPropertyName.map(values.isMusicSynced) == true
            }
            return perFrame ? resolve() : system.liveOverrides.value(at: system.bindingRevision, resolve)
        } ?? configuration.overrides
        var overrides = (scripted?.applied(to: authored) ?? authored).ignoring(configuration.ignoredOverrides)
        // The particle budget thins the system as the `count` override does: its maximum, and
        // through the count its emitters' rates.
        overrides.count *= configuration.budgetScale
        // Saturating: a huge or non-finite override stays a bound instead of stopping the process.
        maximum = Int(saturating: (Float(configuration.maximumParticleCount) * overrides.count).rounded(),
                      in: 0...Int(UInt32.max))
        // Negative multipliers would invert the ranges; WE treats them as 0.
        spawnScale = SIMD4(overrides.size, max(overrides.alpha, 0), max(overrides.lifetime, 0), overrides.speed)
        colorScale = overrides.tint * overrides.brightness
        return overrides
    }

    /// A child linked with flag 2 starts over when its parent started a period in its step, which
    /// came first (`ParticleChildLink.restartsWithParentPeriod`, 0x14022f6c0): its time, every
    /// emitter's clock (delay, duration, burst and period), carry and period count, and the
    /// sequences restarting with each period. Its particles live on.
    private static func restartWithParent(_ system: ParticleSystemRuntime) {
        guard let link = system.configuration.link, link.restartsWithParentPeriod, !system.configuration.isInstanced,
              system.parent?.startedPeriod == true else { return }
        restart(system)
    }

    /// WE's system restart (`wallpaper64.exe` 0x14022f6c0): its time, every emitter's clock (delay,
    /// duration, burst and period), carry and period count, and the sequences restarting with each
    /// period. Its particles are left to the caller.
    private static func restart(_ system: ParticleSystemRuntime) {
        system.elapsedTime = 0
        system.emitterStates = system.emitterStates.map { _ in ParticleEmitterState() }
        system.periodSerial = system.nextSerial
    }

    /// A step of a system whose object is hidden (its own `visible` or a parent's), as WE's particle
    /// object update runs it (`wallpaper64.exe` 0x140230650). On the first hidden step that finds
    /// particles alive (0x14023068e) WE restarts the system (0x1402306bc, `restart`) and removes its
    /// particles (0x1402306c1…0x1402307a2); every hidden step then advances the system's time with
    /// emission off (0x140230869: `emit` is the visibility), so the emitters' clocks stay where the
    /// restart left them. Shown again, the system emits from those clocks: no pre-simulation, which
    /// runs only when the system is built. `holdsParticles` says whether any particle is alive.
    /// Returns the clearing step to simulate, or nil when there is nothing to clear.
    static func hidden(_ system: ParticleSystemRuntime, deltaTime: Float, holdsParticles: Bool) -> ParticleFrameInputs? {
        let clears = holdsParticles && !system.clearedWhileHidden
        if clears { restart(system) }
        system.elapsedTime += deltaTime
        system.hiddenSteps &+= 1
        guard clears else { return nil }
        system.clearedWhileHidden = true
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        inputs.frameTime = deltaTime
        inputs.elapsedTime = system.elapsedTime
        inputs.engineTime = system.elapsedTime
        inputs.frameIndex = system.frameIndex
        inputs.emitters = system.configuration.emitters.map { _ in ParticleEmitterStep() }
        inputs.clears = true
        return inputs
    }

    /// Takes `deltaTime` off the system's trail countdown, and starts it again from the interval
    /// once it runs out, which is when the particles record their trail history: WE's
    /// [system+0x24c] (0x140232cad…0x140232ce0).
    private static func advanceTrailTimer(_ system: ParticleSystemRuntime, deltaTime: Float) -> Bool {
        let history = system.configuration.trailHistory
        guard history.kept else { return false }
        system.trailTimer -= deltaTime
        guard system.trailTimer <= 0 else { return false }
        system.trailTimer = history.interval
        return true
    }

    /// A child's emitter this frame: from its parent's, which stepped first.
    private static func childEmitter(_ system: ParticleSystemRuntime) -> SceneAffineTransform? {
        guard let link = system.configuration.link, let parent = system.parent else { return nil }
        return link.emitter(parent: parent.lastEmitter ?? parent.configuration.authoredWorld)
    }

    /// The emitter's move since the last step for a system whose particles follow it, and records
    /// `world` as the latest.
    private static func motion(of system: ParticleSystemRuntime, to world: SceneAffineTransform) -> SceneAffineTransform? {
        defer { system.lastEmitter = world }
        guard !system.configuration.worldSpace, let last = system.lastEmitter, last != world,
              let undo = last.inverse else { return nil }
        return world * undo
    }

    /// The control points this frame, as `wallpaper64.exe` 0x14022e3e0 updates them: on the
    /// cursor (flag 1), on the parent system's control point `parentcontrolpoint` (flag 4, before
    /// flag 2; with flag 8 its value in the parent's space, unchanged), at a scene position (flag 2,
    /// control points 1…7) or at their offset in the emitter's space. The
    /// object's `controlpoint<n>` override replaces the offset (3D) and `controlpointangle<n>` turns
    /// the point (0x14022bf15); neither moves a point on the cursor or the parent's. Orientation
    /// (0x14022a070): the point's own; in a `worldspace` system composed with the emitter's scale
    /// and rotation, except a flag 2 point, which a system in its emitter's space sees through the
    /// emitter's inverse; the cursor's keeps its own; a parent's is copied.
    private mutating func placeControlPoints(_ system: ParticleSystemRuntime, world: SceneAffineTransform,
                                             cursor: SIMD2<Float>, overrides: SceneParticleOverrides,
                                             modelCapsules: (String) -> [ParticleCapsule]) {
        let configuration = system.configuration
        let toSpace = self.space.inverse ?? .identity
        let emitterToSpace = toSpace * world
        let model = ParticleProgramEncoding.embed(world.linear)
        let unmodel = abs(model.determinant) > 1e-12 ? model.inverse : matrix_identity_float3x3
        func inSpace(_ scene: SIMD3<Float>) -> SIMD3<Float> { SIMD3(toSpace.apply(SIMD2(scene.x, scene.y)), scene.z) }
        for index in 0..<ParticleControlPoint.count {
            let point = index < configuration.controlPoints.count ? configuration.controlPoints[index] : ParticleControlPoint()
            let driven = overrides.controlPoints[index]
            overridePoints[index] = driven
            if let driven, system.lastOverridePoints[index] == driven { keptPoints |= 1 << UInt32(index) }
            system.lastOverridePoints[index] = driven
            let turn = overrides.controlPointAngles[index].map(ParticleProgramEncoding.controlPointRotation) ?? matrix_identity_float3x3
            let offset = driven ?? point.offset
            if point.followsCursor {
                controlPoints[index] = inSpace(SIMD3(cursor, 0))
                controlPointAxes[index] = matrix_identity_float3x3
                absolutePoints |= 1 << UInt32(index)
            } else if let parentIndex = point.parentControlPoint, let parent = system.parent,
                      parentIndex >= 0, parentIndex < parent.lastControlPoints.count {
                // 0x14022e6b3: both in the scene, or flag 8, copy the parent's point as it is.
                if point.parentRawValue, let raw = parent.previousControlPoints, parentIndex < raw.count {
                    controlPoints[index] = raw[parentIndex]
                } else {
                    controlPoints[index] = inSpace(parent.lastControlPoints[parentIndex])
                }
                controlPointAxes[index] = parent.lastControlPointAxes[parentIndex]
                absolutePoints |= 1 << UInt32(index)
            } else if point.worldSpace, index != 0 {
                controlPoints[index] = inSpace(offset)
                controlPointAxes[index] = configuration.worldSpace ? turn : unmodel * turn
                absolutePoints |= 1 << UInt32(index)
            } else {
                controlPoints[index] = SIMD3(emitterToSpace.apply(SIMD2(offset.x, offset.y)), offset.z)
                controlPointAxes[index] = configuration.worldSpace ? model * turn : turn
            }
            system.lastControlPoints[index] = sceneControlPoint(index)
            system.lastControlPointAxes[index] = controlPointAxes[index]
        }
        previousControlPoints = system.previousControlPoints ?? controlPoints
        system.previousControlPoints = controlPoints
        guard configuration.program.operators.contains(where: { $0.collision != nil }) else { return }
        let simulationSpace = SceneParticleEmitterSpace(world: space)
        let points = controlPoints
        let spaceToScene = space
        for collision in configuration.program.operators.compactMap(\.collision) {
            let placed: [ParticleCollisionPlacement]
            if let index = collision.modelIndex {
                placed = configuration.collisionModels[index].map { collision.placed(capsules: modelCapsules($0)) } ?? []
            } else {
                placed = collision.placed(in: simulationSpace) { index in
                    let point = points[min(max(index, 0), 7)]
                    return spaceToScene.apply(SIMD2(point.x, point.y))
                }
            }
            collisions += placed
            collisionCounts.append(placed.count)
        }
    }

    /// Each `layerimage` emitter's image in the system's space this step: its layer's world
    /// transform, which WE multiplies by the inverse of the system's model matrix (0x140238cc8,
    /// 0x140238db9) unless the system is `worldspace`. On a Puppet Warp layer each bone's place
    /// too, now and last frame (`ParticleLayerBones`, 0x1401d4360, 0x1401d4400), which every
    /// point on it follows. An emitter that resamples its image (flag 0x20000) counts the seconds
    /// it emits, and once past one second its image is due to be sampled again (0x140238d4f:
    /// `fmod` by 1) [I: WE counts the steps that spawn; this counts those that may].
    private mutating func placeImages(_ system: ParticleSystemRuntime, layerWorld: (String) -> SceneAffineTransform?,
                                      layerBones: (String) -> ParticleLayerBones?) {
        let configuration = system.configuration
        let toSpace = space.inverse ?? .identity
        for (index, emitter) in configuration.emitters.enumerated() where emitter.shape.kind == .image {
            let slot = emitter.shape.imageIndex
            guard index < emitters.count, slot < system.emitterImages.count,
                  !system.emitterImages[slot].points.isEmpty,
                  let world = layerWorld(system.emitterImages[slot].layerID) else {
                // Without its layer's points WE's emitter spawns nothing (0x140238dca).
                if index < emitters.count {
                    emitters[index].rate = 0
                    emitters[index].burst = 0
                }
                continue
            }
            emitters[index].image = toSpace * world
            emitters[index].layerWorld = world
            emitters[index].toSpace = toSpace
            emitters[index].frameTime = frameTime
            let last = index < system.lastImageWorlds.count ? system.lastImageWorlds[index] : nil
            if index < system.lastImageWorlds.count { system.lastImageWorlds[index] = world }
            if let bones = layerBones(system.emitterImages[slot].layerID) {
                let image = emitters[index].image
                emitters[index].bones = bones.motion.indices.map { bone in
                    // Last frame's bones through the layer's world then; before there were any, WE
                    // takes the identity for them.
                    let previous = bones.previous.flatMap { $0.indices.contains(bone) ? $0[bone] : nil }
                        .map { toSpace * (last ?? world) * $0 }
                        ?? toSpace * (bones.inverseRest.indices.contains(bone) ? bones.inverseRest[bone] : .identity)
                    return ParticleImageBone(current: image * bones.motion[bone], previous: previous)
                }
            }
            if emitter.shape.resamplesImage, index < system.imageResampleTimers.count,
               emitters[index].rate > 0 || emitters[index].burst > 0 {
                system.imageResampleTimers[index] += deltaTime
                if system.imageResampleTimers[index] > 1 {
                    system.imageResampleTimers[index] = fmod(system.imageResampleTimers[index], 1)
                    system.imageResamplesDue.insert(slot)
                }
            }
        }
    }

    /// This step's records: each with its audio response, the instance overrides WE's parser binds
    /// into them (`ParticleOverrideBindings`) and, for the `mapsequence…` initializers, the `count`
    /// override applied to their step.
    private mutating func encodeProgram(_ system: ParticleSystemRuntime, audio: AudioSpectrumSnapshot,
                                        overrides: SceneParticleOverrides) {
        let countScale = overrides.count
        let program = system.configuration.program
        var collision: UInt32 = 0
        var collisionOperator = 0
        operators = program.operators.map { element in
            var record = element.record
            if let response = element.audio { record.e.w = response.response(audio) }
            if element.kind == .collision {
                // What `placeControlPoints` placed for it (a model's capsules vary by frame).
                let count = element.collision != nil && collisionOperator < collisionCounts.count
                    ? collisionCounts[collisionOperator] : 0
                if element.collision != nil { collisionOperator += 1 }
                record.header.z = collision | (UInt32(count) << 16)
                collision += UInt32(count)
            }
            return ParticleOverrideBindings.bind(record, operator: element.kind, overrides: overrides)
        }
        initializers = ParticleInitializer.encoded(program.initializers, records: program.initializers.map { element in
            var record = element.record
            if let response = element.audio { record.e.w = response.response(audio) }
            if let count = element.sequenceCount {
                let scaled = (record.header.y & ParticleProgramEncoding.sequenceFollowsCountFlag(element.kind)) != 0
                    ? count * countScale : count
                let between = element.kind == .mapSequenceBetweenControlPoints
                record.a.x = 1 / max(between ? scaled - 1 : scaled, 0.0001)
            }
            return ParticleOverrideBindings.bind(record, initializer: element.kind, overrides: overrides)
        })
    }

    /// These inputs for one instance of an instanced system, whose emitter sits at `translation`
    /// (on top of the shared emitter transform the inputs were placed with); it sat at `previous`
    /// last step.
    func placed(at translation: SIMD2<Float>, previous: SIMD2<Float>) -> ParticleFrameInputs {
        var inputs = self
        inputs.space.translation += translation
        let toSpace = self.toSpace
        for index in 0..<ParticleControlPoint.count where absolutePoints & (1 << UInt32(index)) != 0 {
            inputs.controlPoints[index] -= SIMD3(toSpace * translation, 0)
            inputs.previousControlPoints[index] -= SIMD3(toSpace * previous, 0)
        }
        inputs.collisions = collisions.map { $0.moved(by: translation) }
        return inputs
    }
}

extension ParticleFrameInputs {
    /// Control point `index` in the scene (its depth kept).
    func sceneControlPoint(_ index: Int) -> SIMD3<Float> {
        let point = controlPoints[index]
        return SIMD3(space.apply(SIMD2(point.x, point.y)), point.z)
    }
}

/// One emitter's part of a step (`ParticleFrameInputs.emitters`).
struct ParticleEmitterStep: Equatable {
    /// Particles a second, scripts, overrides, audio and the emitter's clock applied.
    var rate: Float = 0
    /// Particles emitted at once this step on top of the rate: the emitter's `instantaneous`
    /// burst when it starts or starts a period (`ParticleEmitterClock`).
    var burst = 0
    /// The emitter's `instantaneous`, which an instanced system's instances burst on their own clock.
    var instantaneous = 0
    /// A period of a periodic emitter starts this step: its per-period count restarts.
    var startsPeriod = false
    /// The most the rate emits in one period (`ParticleEmitterTiming.periodLimit`), for the system
    /// or each instance; nil without a limit.
    var periodLimit: Int?
    /// The rate emits at most one particle a step.
    var onePerFrame = false
    /// A `layerimage` emitter's image (its points' space, the layer's) in the system's space.
    var image = SceneAffineTransform.identity
    /// The layer's world (`image` before the system's space) and the system's space from the scene,
    /// which a spawn inheriting the layer's motion places last time's world through.
    var layerWorld = SceneAffineTransform.identity
    var toSpace = SceneAffineTransform.identity
    /// A Puppet Warp layer's bones this step, by bone index (`ParticleImageBone`); empty for any
    /// other layer.
    var bones: [ParticleImageBone] = []
    /// The engine's frame time, over which the inherited motion is a velocity.
    var frameTime: Float = 0
}
