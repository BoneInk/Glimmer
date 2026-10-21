import simd

/// Builds a particle system's simulation configuration (`SceneMetalParticleSystem`) from its json:
/// the emitter, initializers, operators, control points and renderer, with WE's own defaults for
/// every field the json leaves out. The view model loads the assets it draws with.
///
/// WE fills the defaults into the json before it parses each element (`wallpaper64.exe`'s particle
/// parser 0x1401c1c70 and a filler per element, cited below). Many depend on the scene: an
/// orthographic (2D) scene gets values in pixels, a perspective one in world units
/// (`pixelUnits`, the parser's flag from `orthogonalprojection`, 0x14010daa0 / 0x14018768a).
enum ParticleSystemBuilder {
    static func build(_ particlePath: String, particleSystem: WEParticleSystem, object: WESceneObject,
                      world: SceneAffineTransform, overrides: SceneParticleOverrides, sceneSize: SIMD2<Float>,
                      source: SceneMetalTextureSource, spriteSheet: SpriteSheet?, material: WEMaterial,
                      materialPlan: ParticleMaterialPlan?, pixelUnits: Bool = true) -> SceneMetalParticleSystem {
        let renderer = particleSystem.renderer?.first
        let emitters = Self.registeredEmitters(particleSystem.emitter ?? [], path: particlePath)
        let emitter = emitters.first
        let defaults = ParticleDefaults(pixelUnits: pixelUnits)
        // Emitter rate: 10 a second (0x1401b8e59). Without an emitter nothing spawns.
        let rate = emitter.map { Float($0.rate ?? 10) } ?? 0
        let draw = rendererDraw(renderer, particleSystem: particleSystem)
        // The built-in draw imitates refraction with faint, thin sprites; WE's shader refracts
        // with the particle's own alpha.
        let refractAmount: Double? = materialPlan != nil ? nil
            : material.passes?.first?.constants?["ui_editor_properties_refract_amount"]?.value
        let opacityMultiplier = refractAmount.map { max(0.04, min(abs(Float($0)), 1)) } ?? 1
        var system = SceneMetalParticleSystem(
            source: source, origin: world.translation, emissionRate: max(rate, 0),
            // No default: a system without `maxcount` holds nothing.
            maximumParticleCount: max(particleSystem.maxcount ?? 0, 0),
            rendererName: draw.name, trailLength: draw.trailLength, trailSegments: draw.trailSegments,
            ropeSubdivision: draw.ropeSubdivision, fadeTrailAlpha: draw.fadeTrailAlpha,
            fadeTrailSize: draw.fadeTrailSize, spriteSheet: spriteSheet,
            animationMode: particleSystem.animationmode ?? "sequence",
            sequenceMultiplier: Float(particleSystem.sequencemultiplier ?? 1),
            opacityMultiplier: opacityMultiplier, refractive: refractAmount != nil,
            blending: material.passes?.first?.blending?.lowercased() ?? "translucent")
        system.apply(draw)
        system.objectID = object.id.map(String.init)
        system.emitterLinear = world.linear
        system.worldSpace = particleSystem.isWorldSpace
        system.perspective = (particleSystem.flags ?? 0) & 4 != 0
        system.overrides = overrides
        system.ignoredOverrides = SceneParticleOverrides.Parts(systemFlags: particleSystem.flags ?? 0)
        system.startTime = max(Float(particleSystem.starttime ?? 0), 0)
        // Bound to user properties or animated by a timeline: resolved again every frame, so a
        // change shows at once.
        if let instanceOverride = object.instanceoverride,
           instanceOverride.values.values.contains(where: { $0.userBindingSource != nil || $0.animation != nil }) {
            system.liveOverrides = instanceOverride
        }
        if let emitter {
            system.emitter = emitterShape(emitter, defaults: defaults)
            system.instantaneous = max(emitter.instantaneous ?? 0, 0)
            system.emitterTiming = ParticleEmitterTiming(emitter)
            system.rateAudio = ParticleAudioResponse(emitter)
        }
        // WE runs every emitter, each with its own rate, burst and timing (0x1402378a0).
        system.extraEmitters = emitters.dropFirst().map { authored in
            ParticleEmitter(shape: emitterShape(authored, defaults: defaults), rate: max(Float(authored.rate ?? 10), 0),
                            instantaneous: max(authored.instantaneous ?? 0, 0),
                            timing: ParticleEmitterTiming(authored), audio: ParticleAudioResponse(authored))
        }
        // A `layerimage` emitter's dependency index is its ordinal among them (0x1401c6fbf).
        var imageIndex = 0
        for index in 0...system.extraEmitters.count where (index == 0 ? system.emitter : system.extraEmitters[index - 1].shape).kind == .image {
            if index == 0 { system.emitter.imageIndex = imageIndex } else { system.extraEmitters[index - 1].shape.imageIndex = imageIndex }
            imageIndex += 1
        }
        system.controlPoints = controlPoints(particleSystem.controlpoint ?? [])
        // A `collisionmodel` operator's dependency index is its place in the same list of linked
        // slots the `layerimage` emitters were numbered in, parsed before the operators
        // (system+0x1b0: 0x1401c6fba, 0x1401cfdf0).
        var modelIndex = imageIndex
        system.program = ParticleProgram(
            operators: (particleSystem.operator ?? []).compactMap { element in
                let op = ParticleOperatorBuilder.make(element, defaults: defaults, sceneSize: sceneSize, path: particlePath,
                                                      modelIndex: modelIndex)
                if op?.collision?.modelIndex != nil { modelIndex += 1 }
                return op
            },
            initializers: (particleSystem.initializer ?? []).compactMap {
                ParticleInitializerBuilder.make($0, defaults: defaults, path: particlePath)
            })
        return system
    }

    /// A renderer's fields with WE's defaults (`sprite` without one); its material is the caller's.
    static func rendererDraw(_ renderer: WEParticleRenderer?, particleSystem: WEParticleSystem) -> ParticleRendererDraw {
        let trail = ParticleRendererDefaults(renderer)
        if let name = renderer?.name, WEParticleRendererType(rawValue: name.lowercased()) == nil {
            OWELog.error(.scene, "Particle renderer \"\(name)\" isn't one of WE's (sprite, spritetrail, rope, ropetrail); drawn as sprites")
        }
        // The emitters WE registers (`registeredEmitters`, without its log).
        let emitters = (particleSystem.emitter ?? []).filter { supportedEmitters.contains($0.name?.lowercased() ?? "") }
        return ParticleRendererDraw(
            name: renderer?.name ?? "sprite", trailLength: trail.length,
            trailLengthLimits: SIMD2(trail.maximumLength, trail.minimumLength), trailSegments: trail.segments,
            ropeSubdivision: trail.subdivision, fadeTrailAlpha: renderer?.fadealpha ?? false,
            fadeTrailSize: renderer?.fadesize ?? false, orientation: ParticleOrientation(renderer),
            ropeUV: ParticleRopeUV(renderer, rate: ropeRate(emitters),
                                   lifetime: ropeLifetime(particleSystem.initializer ?? [])))
    }

    /// Adds the system's renderers after the first (`SceneMetalParticleSystem.additionalRenderers`),
    /// each with the material `material` makes for it. WE draws every renderer of a system, in
    /// authored order, from its one simulation. When the first isn't a `ropetrail` and a later one
    /// is, the simulation keeps that renderer's trail history.
    static func addRenderers(to system: inout SceneMetalParticleSystem, particleSystem: WEParticleSystem,
                             material: (WEParticleRenderer) -> ParticleMaterialPlan?) {
        let renderers = Array((particleSystem.renderer ?? []).dropFirst())
        guard !renderers.isEmpty else { return }
        system.additionalRenderers = renderers.map { renderer in
            var draw = rendererDraw(renderer, particleSystem: particleSystem)
            draw.material = material(renderer)
            return draw
        }
        if !system.trailHistory.kept, let trail = system.additionalRenderers.first(where: { $0.name == "ropetrail" }) {
            system.sharedHistory = ParticleTrailHistory(kept: true, length: trail.trailLength, segments: trail.trailSegments)
        }
    }

    /// The emitters `wallpaper64.exe` registers: its parser compares each element's `name`,
    /// ignoring case, with these three and knows no other shape (0x1401c5c75, 0x1401c6390,
    /// 0x1401c6add).
    static let supportedEmitters: Set<String> = ["sphererandom", "boxrandom", "layerimage"]

    /// The authored emitters WE builds, in order. An element whose `name` is missing or isn't one
    /// of `supportedEmitters` is skipped (the parser jumps to the next element, 0x1401c6fdf): it
    /// neither spawns nor counts as the system's first emitter.
    static func registeredEmitters(_ authored: [WEParticleEmitter], path: String) -> [WEParticleEmitter] {
        authored.filter { emitter in
            guard let name = emitter.name?.lowercased(), supportedEmitters.contains(name) else {
                OWELog.info(.scene, "Particle system \(path): emitter \(emitter.name ?? "without a name") isn't one of WE's; skipped as WE does")
                return false
            }
            return true
        }
    }

    /// The emitter's shape (sphere defaults 0x1401b9100, box 0x1401b9520; shared fields 0x1401b8df0).
    static func emitterShape(_ emitter: WEParticleEmitter, defaults: ParticleDefaults) -> ParticleEmitterShape {
        var shape = ParticleEmitterShape()
        switch emitter.name?.lowercased() {
        case "boxrandom": shape.kind = .box
        case "layerimage": shape.kind = .image
        default: shape.kind = .sphere
        }
        shape.origin = ParticleDefaults.vector(emitter.origin, .zero)
        switch shape.kind {
        case .image:
            // Defaults 0x1401b9930: flags 0x10000 (the image's colour), `offsetmin` "-5 -5 0" and
            // `offsetmax` "5 5 0" in 2D, "0 0 0" in 3D, `speedmin` 0.1 and `speedmax` 0.2: the share
            // of the layer's motion a spawn inherits with flag 0x40000.
            let flags = emitter.flags ?? 0x10000
            shape.takesImageColor = flags & 0x10000 != 0
            shape.resamplesImage = flags & 0x20000 != 0
            shape.inheritsLayerMotion = flags & 0x40000 != 0
            shape.offsetsRandomly = flags & 0x80000 != 0
            shape.speed = SIMD2(Float(emitter.speedmin ?? 0.1), Float(emitter.speedmax ?? 0.2))
            shape.distanceMinimum = ParticleDefaults.vector(emitter.offsetmin, defaults.pick(SIMD3(-5, -5, 0), .zero))
            shape.distanceMaximum = ParticleDefaults.vector(emitter.offsetmax, defaults.pick(SIMD3(5, 5, 0), .zero))
            shape.directions = .zero
            shape.controlPoint = 0
            return shape
        case .sphere:
            shape.directions = ParticleDefaults.vector(emitter.directions, SIMD3(1, 1, 0))
            // Scalars (0x140086220).
            shape.distanceMinimum = SIMD3(repeating: Float(emitter.distancemin?.doubleValue ?? 0))
            shape.distanceMaximum = SIMD3(repeating: Float(emitter.distancemax?.doubleValue ?? defaults.pick(256, 1)))
        case .box:
            shape.directions = ParticleDefaults.vector(emitter.directions, defaults.pick(SIMD3(1, 1, 0), SIMD3(1, 1, 1)))
            shape.distanceMinimum = ParticleDefaults.vector(emitter.distancemin, .zero)
            shape.distanceMaximum = ParticleDefaults.vector(emitter.distancemax, defaults.pick(SIMD3(256, 256, 0), SIMD3(1, 1, 1)))
        }
        shape.speed = SIMD2(Float(emitter.speedmin ?? 0), Float(emitter.speedmax ?? 0))
        shape.sign = ParticleDefaults.vector(emitter.sign, .zero)
        // Flag 1 applies the sign; the parser sets it for any non-zero sign (0x1401c61e7).
        shape.appliesSign = ((emitter.flags ?? 0) & 1) != 0 || simd_length_squared(shape.sign) > 1.19e-7
        shape.cone = Float(emitter.cone ?? 0)
        shape.controlPoint = min(max(emitter.controlpoint ?? 0, 0), 7)
        return shape
    }

    /// The rate a rope lays its texture by (`ParticleRopeUV`): the first emitter's that isn't 0
    /// (0x1401c6ab4).
    static func ropeRate(_ emitters: [WEParticleEmitter]) -> Float {
        emitters.lazy.map { max(Float($0.rate ?? 10), 0) }.first { $0 != 0 } ?? 0
    }

    /// The lifetime a rope lays its texture by: the first `lifetimerandom`'s middle, min + ½·(max −
    /// min) with WE's defaults 0…1 (0x1401c72e5); 0 without one.
    static func ropeLifetime(_ initializers: [WEParticleInitializer]) -> Float {
        guard let lifetime = initializers.first(where: { $0.name?.lowercased() == "lifetimerandom" }) else { return 0 }
        let low = ParticleDefaults.scalar(lifetime.min, 0), high = ParticleDefaults.scalar(lifetime.max, 1)
        return low + 0.5 * (high - low)
    }

    /// The eight control points by index (WE ignores `id` and `locktopointer`, 0x1401d0530). WE
    /// parses `angles` (0x1401d06ce) but never reads them: a point starts unturned (0x14022cdf4),
    /// and only the object's `controlpointangle<n>` turns it.
    static func controlPoints(_ authored: [WEParticleControlPoint]) -> [ParticleControlPoint] {
        var points = ParticleControlPoint.defaults
        for (index, point) in authored.enumerated() where index < ParticleControlPoint.count {
            let flags = point.flags ?? 0
            let offset = (point.offset ?? "0 0 0").parseVector3()
            points[index] = ParticleControlPoint(offset: SIMD3(Float(offset.0), Float(offset.1), Float(offset.2)),
                                                 followsCursor: flags & 1 != 0,
                                                 worldSpace: flags & 2 != 0 && index != 0,
                                                 parentControlPoint: flags & 4 != 0 ? point.parentcontrolpoint ?? 0 : nil,
                                                 parentRawValue: flags & 8 != 0)
        }
        return points
    }
}

/// WE's defaults for one scene kind: pixel values in an orthographic scene, world units otherwise.
struct ParticleDefaults {
    let pixelUnits: Bool

    func pick<T>(_ pixels: T, _ world: T) -> T { pixelUnits ? pixels : world }

    /// A vector field: "x y z", or a bare number on every axis.
    static func vector(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        guard let value else { return fallback }
        let v = value.vectorValue
        return SIMD3(Float(v.0), Float(v.1), Float(v.2))
    }

    /// A field WE reads as a number (a string of one number too).
    static func scalar(_ value: WEFlexValue?, _ fallback: Float) -> Float {
        guard let value else { return fallback }
        return Float(value.doubleValue)
    }
}

/// A renderer's trail fields with WE's defaults (0x1401cfe21 `spritetrail`, `rope`, `ropetrail`).
struct ParticleRendererDefaults {
    /// `spritetrail`: the shader's stretch per unit of speed (0.05); `ropetrail`: seconds of
    /// history (1).
    let length: Float
    /// `spritetrail`'s `maxlength` (10) and `minlength` (0).
    let maximumLength: Float
    let minimumLength: Float
    let segments: Int
    /// `rope` 4 (clamped to 0…32), `ropetrail` 1.
    let subdivision: Int

    init(_ renderer: WEParticleRenderer?) {
        let name = renderer?.name ?? "sprite"
        length = Float(renderer?.length ?? (name == "ropetrail" ? 1 : 0.05))
        maximumLength = Float(renderer?.maxlength ?? 10)
        minimumLength = Float(renderer?.minlength ?? 0)
        segments = max(renderer?.segments ?? 4, 1)
        subdivision = min(max(renderer?.subdivision ?? (name == "rope" ? 4 : 1), 0), 32)
    }
}
