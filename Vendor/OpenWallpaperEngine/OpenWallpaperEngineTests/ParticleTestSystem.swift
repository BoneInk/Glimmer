import AppKit
import simd
@testable import OpenWallpaperEngine

/// A particle system configuration for simulation tests: an emitter, the common initializers,
/// `movement` and whatever other operators a test adds.
struct ParticleTestSystem {
    var source: SceneMetalTextureSource = .image(NSImage())
    var origin = SIMD2<Float>(500, 500)
    var emissionRate: Float = 600
    var maximum = 1000
    /// The emitter's half extent: a box's, or the sphere's radii per axis.
    var spawnExtent = SIMD2<Float>(50, 30)
    var emitterName = "sphererandom"
    /// `lifetimerandom`, `sizerandom` (WE's size is half of it), `alpharandom`.
    var lifetime: ClosedRange<Float> = 1...2
    var size: ClosedRange<Float> = 10...20
    var alpha: ClosedRange<Float> = 0.5...1
    /// `velocityrandom`.
    var minimumVelocity = SIMD2<Float>(-40, -20)
    var maximumVelocity = SIMD2<Float>(40, 60)
    /// `colorrandom`, 0…1.
    var minimumColor = SIMD4<Float>(0.2, 0.3, 0.4, 1)
    var maximumColor = SIMD4<Float>(0.9, 0.8, 1, 1)
    /// `rotationrandom` and `angularvelocityrandom` about z.
    var rotation: ClosedRange<Float> = 0...1
    var angularVelocity: ClosedRange<Float> = -1...1
    /// The `movement` operator every test system starts with.
    var gravity = SIMD2<Float>.zero
    var drag: Float = 0
    /// `movement` flag 1: gravity in the scene.
    var worldGravity = false
    /// Spin the particles (`angularmovement`).
    var spins = true
    /// `inheritinitialvaluefromevent` and `inheritvaluefromevent` (last, when set).
    var inheritOnSpawn: ParticleInheritance = []
    var inheritEachStep: ParticleInheritance = []
    /// Operators after `movement` and initializers after the common ones, in order.
    var operators: [ParticleOperator] = []
    var initializers: [ParticleInitializer] = []
    /// The emitter object's world scale and rotation (with `origin`, its transform).
    var emitterLinear = matrix_identity_float2x2
    var worldSpace = false
    var instantaneous = 0
    var emitterTiming = ParticleEmitterTiming()
    /// Emitters after the first (`SceneMetalParticleSystem.extraEmitters`).
    var extraEmitters: [ParticleEmitter] = []
    var orientation = ParticleOrientation()
    var ropeUV = ParticleRopeUV()
    var emitterSpeed = SIMD2<Float>.zero
    /// A sphere's inner radius as a fraction of the outer.
    var minimumSpawnRatio: Float = 0
    var emitterSign = SIMD2<Float>.zero
    var emitterControlPoint = 0
    var controlPoints = ParticleControlPoint.defaults
    var rendererName = "sprite"
    var trailLength: Float = 1
    var trailSegments = 4
    var ropeSubdivision = 1
    var fadeTrailAlpha = false
    var fadeTrailSize = false
    var spriteSheet: SpriteSheet?
    var animationMode = "sequence"
    var material: ParticleMaterialPlan?

    var emitter: ParticleEmitterShape {
        var shape = ParticleEmitterShape()
        shape.kind = emitterName == "boxrandom" ? .box : .sphere
        if shape.kind == .box {
            shape.directions = SIMD3(1, 1, 0)
            shape.distanceMaximum = SIMD3(abs(spawnExtent.x), abs(spawnExtent.y), 0)
        } else {
            shape.directions = SIMD3(spawnExtent.x, spawnExtent.y, 0)
            shape.distanceMinimum = SIMD3(repeating: minimumSpawnRatio)
            shape.distanceMaximum = SIMD3(repeating: 1)
        }
        shape.speed = emitterSpeed
        shape.sign = SIMD3(emitterSign, 0)
        shape.appliesSign = emitterSign != .zero
        shape.controlPoint = emitterControlPoint
        return shape
    }

    var program: ParticleProgram {
        var initializers = [
            ParticleInitializer(.lifetimeRandom, a: SIMD4(lifetime.lowerBound, lifetime.upperBound, 1, 0)),
            ParticleInitializer(.sizeRandom, a: SIMD4(size.lowerBound, size.upperBound, 1, 0)),
            ParticleInitializer(.alphaRandom, a: SIMD4(alpha.lowerBound, alpha.upperBound, 1, 0)),
            ParticleInitializer(.colorRandom, a: SIMD4(minimumColor.x, minimumColor.y, minimumColor.z, 1),
                                b: SIMD4(maximumColor.x, maximumColor.y, maximumColor.z, 0)),
            ParticleInitializer(.velocityRandom, a: SIMD4(minimumVelocity.x, minimumVelocity.y, 0, 1),
                                b: SIMD4(maximumVelocity.x, maximumVelocity.y, 0, 0)),
            ParticleInitializer(.rotationRandom, a: SIMD4(0, 0, rotation.lowerBound, 1), b: SIMD4(0, 0, rotation.upperBound, 0)),
            ParticleInitializer(.angularVelocityRandom, a: SIMD4(0, 0, angularVelocity.lowerBound, 1),
                                b: SIMD4(0, 0, angularVelocity.upperBound, 0)),
        ]
        initializers += self.initializers
        if !inheritOnSpawn.isEmpty {
            initializers.append(ParticleInitializer(.inheritInitialValueFromEvent, flags: inheritOnSpawn.rawValue))
        }
        var operators = [ParticleOperator(.movement, flags: worldGravity ? 1 : 0, a: SIMD4(gravity.x, gravity.y, 0, drag))]
        if spins { operators.append(ParticleOperator(.angularMovement)) }
        operators += self.operators
        if !inheritEachStep.isEmpty {
            operators.append(ParticleOperator(.inheritValueFromEvent, flags: inheritEachStep.rawValue))
        }
        return ParticleProgram(operators: operators, initializers: initializers)
    }

    var configuration: SceneMetalParticleSystem {
        var system = SceneMetalParticleSystem(
            source: source, origin: origin, emissionRate: emissionRate,
            maximumParticleCount: maximum, rendererName: rendererName, trailLength: trailLength,
            trailSegments: trailSegments, ropeSubdivision: ropeSubdivision, fadeTrailAlpha: fadeTrailAlpha,
            fadeTrailSize: fadeTrailSize, spriteSheet: spriteSheet, animationMode: animationMode, sequenceMultiplier: 1,
            opacityMultiplier: 1, refractive: false, blending: "translucent")
        system.emitter = emitter
        system.program = program
        system.controlPoints = controlPoints
        system.emitterLinear = emitterLinear
        system.worldSpace = worldSpace
        system.instantaneous = instantaneous
        system.emitterTiming = emitterTiming
        system.extraEmitters = extraEmitters
        system.orientation = orientation
        system.ropeUV = ropeUV
        system.material = material
        system.hasEventChildren = false
        return system
    }

    /// A control point at `offset` in the system's space (or on the cursor).
    static func point(_ offset: SIMD2<Float>, z: Float = 0, cursor: Bool = false) -> ParticleControlPoint {
        ParticleControlPoint(offset: SIMD3(offset, z), followsCursor: cursor)
    }

    /// This system as a child (`ParticleChildLink`).
    struct Linked {
        let system: ParticleTestSystem
        let kind: ParticleChildLink.Kind
        let instances: Int
        let probability: Float
        var origin = SIMD2<Float>.zero
        var instanced: Bool?
        /// Link flag 1 (`ParticleChildLink.controlPointStart`).
        var controlPointStart: Int?

        func link(parentIndex: Int, parent: ParticleChildLink?) -> ParticleChildLink {
            ParticleChildLink(parentIndex: parentIndex, kind: kind,
                              local: SceneLocalTransform(origin: origin, scale: SIMD2(1, 1), angle: 0),
                              probability: probability, maximumInstances: instances,
                              instanced: instanced ?? (kind != .static || parent?.instanced == true),
                              controlPointStart: controlPointStart)
        }
    }

    func link(_ kind: ParticleChildLink.Kind, instances: Int, probability: Float, origin: SIMD2<Float> = .zero,
              instanced: Bool? = nil) -> Linked {
        Linked(system: self, kind: kind, instances: instances, probability: probability, origin: origin, instanced: instanced)
    }
}
