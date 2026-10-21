import simd

// The GPU simulation's shared structures; `ParticleSimulation.metal` declares the same layouts
// (`particleLayoutSizes` checks the sizes). Every field is a 16-byte vector so both sides agree.

/// One particle on the GPU.
struct ParticleGPUState {
    /// Position xy, velocity zw.
    var positionVelocity: SIMD4<Float>
    /// Age, lifetime, size, base size.
    var life: SIMD4<Float>
    /// Alpha, base alpha, rotation, angular velocity.
    var alphaRotation: SIMD4<Float>
    var color: SIMD4<Float>
    var baseColor: SIMD4<Float>
    /// -, -, instance.
    var trail: SIMD4<Float>
    /// Serial, sprite frame, history count, history start.
    var identity: SIMD4<UInt32>
    /// Depth and its velocity (`Particle.z`, `zVelocity`), -, -.
    var depth: SIMD4<Float>
    /// Rotation about x and y, angular velocity about x and y (`Particle.rotationXY`,
    /// `angularVelocityXY`).
    var spin: SIMD4<Float>
}


/// One instance of an instanced child system on the GPU (`ParticleChildLink`).
struct ParticleGPUInstance {
    struct Flag: OptionSet {
        let rawValue: UInt32
        static let active = Flag(rawValue: 1 << 0), emitting = Flag(rawValue: 1 << 1)
        static let fresh = Flag(rawValue: 1 << 2), clearing = Flag(rawValue: 1 << 3)
    }

    /// Translation xy, previous translation xy.
    var place: SIMD4<Float>
    /// Source velocity xy, size, rotation.
    var source: SIMD4<Float>
    /// Source colour and alpha.
    var sourceColor: SIMD4<Float>
    /// Source angular velocity.
    var emission: SIMD4<Float>
    /// Flags, source serial, live particles, first spawn.
    var state: SIMD4<UInt32>
    /// Spawned this step, spawned before it, the spawn its sequence restarts from.
    var spawn: SIMD4<UInt32>

    var flags: Flag { Flag(rawValue: state.x) }
}

/// The parent particles a linked child's control points take (link flag 1), for one
/// instance: up to eight positions, oldest first, and how many.
struct ParticleGPULinkedPoints {
    /// Scene xy and depth of each parent particle.
    var points: ParticleGPUFrame.Points
    /// Positions, -, -, -.
    var count: SIMD4<UInt32>
}

/// What a system's GPU records are drawn with this frame (`ParticleSimulation.metal`).
enum ParticleGPUDrawKind: UInt32 {
    /// WE material records (`ParticleVertexFormat`).
    case sprite = 0, rope, ropeTrail
    /// The renderer's built-in quads (`LayerUniform`).
    case fallbackSprite, fallbackSpriteTrail, fallbackRope, fallbackRopeTrail

    var isFallback: Bool { rawValue >= Self.fallbackSprite.rawValue }

    /// The material kind for `format` and the system's renderer.
    static func material(_ format: ParticleVertexFormat, rendererName: String) -> ParticleGPUDrawKind {
        switch format {
        case .sprite: return .sprite
        case .rope: return rendererName == "ropetrail" ? .ropeTrail : .rope
        }
    }

    /// The built-in draw's kind for a renderer, as `SceneMetalRenderer` picks it.
    /// A name outside WE's four (`WEParticleRendererType`) draws sprites.
    static func fallback(rendererName: String) -> ParticleGPUDrawKind {
        switch WEParticleRendererType(rawValue: rendererName) {
        case .rope: return .fallbackRope
        case .ropetrail: return .fallbackRopeTrail
        case .spritetrail: return .fallbackSpriteTrail
        case .sprite, nil: return .fallbackSprite
        }
    }
}

/// Per-frame inputs of one system's GPU step (`ParticleFrameInputs`).
struct ParticleGPUFrame {
    /// Delta, system time, the damped step (`ParticleFrameInputs.dragDeltaTime`), engine time.
    var time: SIMD4<Float>
    /// Time of day, clears, the layer origin xy (`ParticleFrameInputs.layerOrigin`).
    var misc: SIMD4<Float>
    /// Scene size xy, render target size xy (the built-in draw's pixels).
    var scene: SIMD4<Float>
    /// Frame index, material vertex count, `g_RenderVar0` offset in floats (`noRenderVar`: none), draw kind.
    var indices: SIMD4<UInt32>
    /// `ParticleFrameInputs.space`: linear part, column 0 xy, column 1 xy; its translation xy and
    /// the motion's translation xy.
    var spaceLinear: SIMD4<Float>
    var spaceMotion: SIMD4<Float>
    /// The inverse of `space`'s linear part, column 0 xy, column 1 xy.
    var toSpace: SIMD4<Float>
    /// The control points in the system's space (xyz), last step's, and their orientations
    /// (`ParticleFrameInputs.controlPointAxes`).
    var controlPoints: Points
    var previousControlPoints: Points
    var controlPointAxes: Axes
    /// Motion linear part, column 0 xy, column 1 xy.
    var motionLinear: SIMD4<Float>
    /// Spawn size scale, spawn turn (`ParticleFrameInputs.spawnSizeScale`), has motion, trail and
    /// rope record size scale (`drawSizeScale`).
    var motionExtras: SIMD4<Float>
    /// `ParticleFrameInputs.absolutePoints` | `keptPoints` << 8, maximum, collisions,
    /// initializers | operators << 16.
    var extra: SIMD4<UInt32>
    /// `ParticleFrameInputs.spawnScale`.
    var spawnScale: SIMD4<Float>
    /// `ParticleFrameInputs.colorScale`.
    var colorScale: SIMD4<Float>
    /// `ParticleFrameInputs.substeps`, emitters (`ParticleGPUEmitterStep`), `samplesTrail` (1), -.
    var emission: SIMD4<UInt32>
    /// `ParticleFrameInputs.spriteLinear`, column 0 xy, column 1 xy.
    var spriteLinear: SIMD4<Float>
    /// A rope's texture layout (`ParticleRopeUV.layout`): rate and lifetime with their overrides,
    /// the frame-rate limit, 1 / `uvscale`.
    var rope: SIMD4<Float>

    static let noRenderVar = UInt32.max
    static let noLimit = UInt32.max

    typealias Points = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    typealias Axes = (simd_float3x3, simd_float3x3, simd_float3x3, simd_float3x3,
                      simd_float3x3, simd_float3x3, simd_float3x3, simd_float3x3)

    static func points(_ values: [SIMD3<Float>]) -> Points {
        func at(_ i: Int) -> SIMD4<Float> { i < values.count ? SIMD4(values[i], 0) : .zero }
        return (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
    }

    static func axes(_ values: [simd_float3x3]) -> Axes {
        func at(_ i: Int) -> simd_float3x3 { i < values.count ? values[i] : matrix_identity_float3x3 }
        return (at(0), at(1), at(2), at(3), at(4), at(5), at(6), at(7))
    }

    init(_ inputs: ParticleFrameInputs, sceneSize: SIMD2<Float>, targetSize: SIMD2<Float>, kind: ParticleGPUDrawKind,
         materialVertexCount: Int, renderVarOffset: Int?) {
        time = SIMD4(inputs.deltaTime, inputs.elapsedTime, inputs.dragDeltaTime, inputs.engineTime)
        misc = SIMD4(inputs.timeOfDay, inputs.clears ? 1 : 0, inputs.layerOrigin.x, inputs.layerOrigin.y)
        scene = SIMD4(sceneSize.x, sceneSize.y, targetSize.x, targetSize.y)
        indices = SIMD4(inputs.frameIndex, UInt32(materialVertexCount),
                        renderVarOffset.map { UInt32($0 / 4) } ?? Self.noRenderVar, kind.rawValue)
        spaceLinear = Self.columns(inputs.space.linear)
        let motion = inputs.motion ?? .identity
        spaceMotion = SIMD4(inputs.space.translation.x, inputs.space.translation.y, motion.translation.x, motion.translation.y)
        toSpace = Self.columns(inputs.toSpace)
        controlPoints = Self.points(inputs.controlPoints)
        previousControlPoints = Self.points(inputs.previousControlPoints)
        controlPointAxes = Self.axes(inputs.controlPointAxes)
        motionLinear = Self.columns(motion.linear)
        motionExtras = SIMD4(inputs.spawnSizeScale, inputs.spawnTurn, inputs.motion == nil ? 0 : 1, inputs.drawSizeScale)
        spriteLinear = Self.columns(inputs.spriteLinear)
        rope = .zero
        extra = SIMD4(inputs.absolutePoints | inputs.keptPoints << 8, UInt32(clamping: inputs.maximum), UInt32(inputs.collisions.count),
                      UInt32(inputs.initializers.count) | UInt32(inputs.operators.count) << 16)
        spawnScale = inputs.spawnScale
        colorScale = SIMD4(inputs.colorScale, 1)
        emission = SIMD4(UInt32(inputs.substeps), UInt32(inputs.emitters.count), inputs.samplesTrail ? 1 : 0, 0)
    }

    static func columns(_ matrix: simd_float2x2) -> SIMD4<Float> {
        SIMD4(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.1.x, matrix.columns.1.y)
    }
}

/// A system's configuration as the GPU step reads it; built once per system.
struct ParticleGPUParameters {
    struct Flag: OptionSet {
        let rawValue: UInt32
        static let history = Flag(rawValue: 1 << 0), ropeSmoothing = Flag(rawValue: 1 << 1)
        static let ropeScrolling = Flag(rawValue: 1 << 5)
        static let spriteSheet = Flag(rawValue: 1 << 2), instanced = Flag(rawValue: 1 << 3)
        static let worldSpace = Flag(rawValue: 1 << 4)
    }

    var counts = SIMD4<UInt32>.zero
    var trail = SIMD4<Float>.zero
    /// `spritetrail` maxlength, minlength.
    var trailLimits = SIMD4<Float>.zero
    var spriteSheet = SIMD4<Float>.zero
    var sprite = SIMD4<Float>.zero
    /// Link kind (0: none), instances, emitters (`ParticleGPUEmitter`), -.
    var instancing = SIMD4<UInt32>.zero
    /// Probability.
    var link = SIMD4<Float>.zero
    /// Linked (1), first control point, per parent instance (1).
    var linking = SIMD4<UInt32>.zero

    /// Samples each `ropetrail` particle keeps.
    var historyLimit: Int { Int(counts.w) }

    init(_ c: SceneMetalParticleSystem, seed: UInt32) {
        var flags: Flag = []
        // The history is the simulation's (a `ropetrail` among the system's renderers); the rest is
        // the renderer's.
        let history = c.trailHistory
        let historyLimit = history.limit
        if history.kept { flags.insert(.history) }
        if c.ropeUV.smoothing { flags.insert(.ropeSmoothing) }
        if c.ropeUV.scrolling { flags.insert(.ropeScrolling) }
        let fades: Float = (c.fadeTrailAlpha ? 1 : 0) + (c.fadeTrailSize ? 2 : 0)
        trail = SIMD4(history.interval, c.trailLength, Float(max(c.ropeSubdivision, 1)), fades)
        trailLimits = SIMD4(c.trailLengthLimits.x, c.trailLengthLimits.y, 0, 0)
        if let sheet = c.spriteSheet {
            flags.insert(.spriteSheet)
            spriteSheet = SIMD4(Float(sheet.frames), Float(sheet.columns), Float(sheet.rows), sheet.duration)
        } else {
            spriteSheet = SIMD4(1, 1, 1, 1)
        }
        let mode: Float
        switch c.animationMode {
        case "randomframe": mode = 2
        case "once": mode = 1
        default: mode = 0
        }
        sprite = SIMD4(mode, c.sequenceMultiplier, c.opacityMultiplier, c.refractive ? 1 : 0)
        if c.worldSpace { flags.insert(.worldSpace) }
        if let link = c.link, link.instanced {
            flags.insert(.instanced)
            instancing = SIMD4(link.kind.rawValue, UInt32(clamping: link.maximumInstances), 0, 0)
            self.link = SIMD4(link.probability, 0, 0, 0)
        }
        instancing.z = UInt32(c.emitters.count)
        if let link = c.link, let start = link.controlPointStart {
            linking = SIMD4(1, UInt32(clamping: start), link.kind == .static && link.instanced ? 1 : 0, 0)
        }
        counts = SIMD4(UInt32(clamping: c.maximumParticleCount), flags.rawValue, seed, UInt32(historyLimit))
    }
}

/// One emitter of a system on the GPU (`ParticleEmitter`); a system's emitters are a buffer of them.
struct ParticleGPUEmitter {
    /// Origin xyz, control point.
    var origin: SIMD4<Float>
    /// Directions xyz, −cos(cone·π).
    var directions: SIMD4<Float>
    /// Distance minimum xyz, speed minimum.
    var minimum: SIMD4<Float>
    /// Distance maximum xyz, speed maximum.
    var maximum: SIMD4<Float>
    /// Sign xyz.
    var sign: SIMD4<Float>
    /// `ParticleEmitterTiming` (an instance's clock): delay, duration, periodic duration minimum
    /// and maximum; periodic delay minimum and maximum, periodic, -.
    var timing: SIMD4<Float>
    var period: SIMD4<Float>
    /// Kind (`ParticleEmitterShape.Kind`), applies its sign (1), `instantaneous`, inherits the
    /// layer's motion (1).
    var flags: SIMD4<UInt32>
    /// A `layerimage` emitter's points in the system's point buffer: first, count, takes the
    /// image's colour (1), offsets randomly (1).
    var image: SIMD4<UInt32>

    /// `imagePoints`: where the emitter's points start in the system's point buffer and how many
    /// there are (`ParticleGPUSystem.imagePoints`).
    init(_ emitter: ParticleEmitter, imagePoints: (first: Int, count: Int) = (0, 0)) {
        let shape = emitter.shape
        origin = SIMD4(shape.origin, Float(shape.controlPoint))
        directions = SIMD4(shape.directions, -cos(shape.cone * .pi))
        minimum = SIMD4(shape.distanceMinimum, shape.speed.x)
        maximum = SIMD4(shape.distanceMaximum, shape.speed.y)
        sign = SIMD4(shape.sign, 0)
        let timing = emitter.timing
        self.timing = SIMD4(timing.delay, timing.duration, timing.periodDuration.lowerBound, timing.periodDuration.upperBound)
        period = SIMD4(timing.periodDelay.lowerBound, timing.periodDelay.upperBound, timing.periodic ? 1 : 0, 0)
        flags = SIMD4(shape.kind.rawValue, shape.appliesSign ? 1 : 0, UInt32(clamping: max(emitter.instantaneous, 0)),
                      shape.kind == .image && shape.inheritsLayerMotion ? 1 : 0)
        image = SIMD4(UInt32(clamping: imagePoints.first), UInt32(clamping: imagePoints.count),
                      shape.takesImageColor ? 1 : 0, shape.offsetsRandomly ? 1 : 0)
    }
}

/// One emitter's part of a GPU step (`ParticleEmitterStep`).
struct ParticleGPUEmitterStep {
    /// Rate, the engine's frame time, -, -.
    var rate: SIMD4<Float>
    /// Burst, period limit (`ParticleGPUFrame.noLimit`: none), starts a period, one per frame.
    var control: SIMD4<UInt32>
    /// A `layerimage` emitter's image in the system's space (`ParticleEmitterStep.image`): the
    /// linear part's columns, then the translation.
    var imageLinear: SIMD4<Float>
    var imageTranslation: SIMD4<Float>
    /// The layer's world and the system's space from the scene (`ParticleEmitterStep.layerWorld`,
    /// `toSpace`): their linear parts' columns, then both translations.
    var layerLinear: SIMD4<Float>
    var toSpaceLinear: SIMD4<Float>
    var translations: SIMD4<Float>
    /// A rigged layer's bones this step in the step's bone list (`ParticleGPUImageBone`): first,
    /// count, -, -.
    var bones: SIMD4<UInt32>

    /// `firstBone`: where the step's bones start in the list of the system's.
    init(_ step: ParticleEmitterStep, firstBone: Int = 0) {
        rate = SIMD4(step.rate, step.frameTime, 0, 0)
        imageLinear = Self.columns(step.image.linear)
        imageTranslation = SIMD4(step.image.translation.x, step.image.translation.y, 0, 0)
        layerLinear = Self.columns(step.layerWorld.linear)
        toSpaceLinear = Self.columns(step.toSpace.linear)
        translations = SIMD4(step.layerWorld.translation.x, step.layerWorld.translation.y,
                             step.toSpace.translation.x, step.toSpace.translation.y)
        bones = SIMD4(UInt32(clamping: firstBone), UInt32(clamping: step.bones.count), 0, 0)
        control = SIMD4(UInt32(clamping: max(step.burst, 0)), step.periodLimit.map { UInt32(clamping: $0) } ?? ParticleGPUFrame.noLimit,
                        step.startsPeriod ? 1 : 0, step.onePerFrame ? 1 : 0)
    }

    /// A 2 × 2 matrix's columns, one after the other.
    static func columns(_ linear: simd_float2x2) -> SIMD4<Float> {
        SIMD4(linear.columns.0.x, linear.columns.0.y, linear.columns.1.x, linear.columns.1.y)
    }
}

/// One bone of a rigged layer's step on the GPU (`ParticleImageBone`, `ImageBone`).
struct ParticleGPUImageBone {
    /// Now, in the system's space: the linear part's columns.
    var currentLinear: SIMD4<Float>
    /// Now's translation, last frame's.
    var translations: SIMD4<Float>
    /// Last frame: the linear part's columns.
    var previousLinear: SIMD4<Float>

    init(_ bone: ParticleImageBone) {
        currentLinear = ParticleGPUEmitterStep.columns(bone.current.linear)
        translations = SIMD4(bone.current.translation.x, bone.current.translation.y,
                             bone.previous.translation.x, bone.previous.translation.y)
        previousLinear = ParticleGPUEmitterStep.columns(bone.previous.linear)
    }
}

/// One emitter's running state on the GPU (`ParticleEmitterState`), for the system or one of its
/// instances: `slots × emitters` of them.
struct ParticleGPUEmitterState {
    /// `ParticleEmitterClock.state` (an instance's).
    var clock: SIMD4<Float>
    /// Carried fraction, -, -, -.
    var carry: SIMD4<Float>
    /// What the rate emitted this period (a system's), this step's first spawn and spawns (among the
    /// system's or the instance's), the spawn index its sequence restarts from.
    var counts: SIMD4<UInt32>
    /// A `layerimage` emitter's layer world at its last step that spawned and the one before
    /// (`ParticleEmitterState.lastLayerWorld`, `spawnLayerWorld`): the linear part's columns, then
    /// the translation and whether it is set (z, unset the identity).
    var lastWorldLinear: SIMD4<Float>
    var lastWorldTranslation: SIMD4<Float>
    var spawnWorldLinear: SIMD4<Float>
    var spawnWorldTranslation: SIMD4<Float>
}
