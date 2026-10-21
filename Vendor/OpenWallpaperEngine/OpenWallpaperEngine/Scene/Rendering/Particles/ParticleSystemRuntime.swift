import Metal
import QuartzCore
import simd

final class ParticleSystemRuntime {
    let texture: MTLTexture
    /// Texture 0 for the built-in draw (`SceneMetalParticleSystem.fallbackSource`); `texture`
    /// when it samples that as it is.
    let fallbackTexture: MTLTexture
    let configuration: SceneMetalParticleSystem
    var elapsedTime: Float = 0
    /// Steps taken (`ParticleFrameInputs.frameIndex`).
    var frameIndex: UInt32 = 0
    /// Steps taken while its object was hidden (`ParticleFrameInputs.hidden`): such a system is never
    /// pre-simulated (`ParticlePrewarm`).
    var hiddenSteps: UInt32 = 0
    /// Its particles were removed since its object was hidden: WE clears a hidden system once.
    var clearedWhileHidden = false
    /// Its object's binding revision (`SceneBindingRevisions`), which the renderer sets when a
    /// user property its overrides bind changes.
    var bindingRevision: UInt64 = 0
    /// Its user-bound `instanceoverride` (`SceneMetalParticleSystem.liveOverrides`) resolved at
    /// `bindingRevision`, unless a timeline animates it or a bound property follows the music.
    var liveOverrides = SceneBindingCache<SceneParticleOverrides>()
    /// The next particle's serial number: particles spawned so far.
    var nextSerial: UInt32 = 0
    /// The serial of the first spawn of the current emission period: the `mapsequence…`
    /// initializers that restart with each period count from it.
    var periodSerial: UInt32 = 0
    /// Seeds every random draw of this system (`ParticleRandom`).
    let seed: UInt32
    /// The system's state on the GPU, when `ParticleGPUSimulator` runs it.
    var gpu: ParticleGPUSystem?
    /// A periodic emitter started a period in the last step: children linked with flag 2 restart
    /// (`ParticleChildLink.restartsWithParentPeriod`).
    var startedPeriod = false
    /// The emitter's world transform at the last step (`ParticleFrameInputs.motion`).
    var lastEmitter: SceneAffineTransform?
    /// The control points in the scene (and their depth) at the last step, and their orientation
    /// (a child's flag 4 control points copy them).
    var lastControlPoints = [SIMD3<Float>](repeating: .zero, count: ParticleControlPoint.count)
    var lastControlPointAxes = [simd_float3x3](repeating: matrix_identity_float3x3, count: ParticleControlPoint.count)
    /// The control points in the system's space at the last step.
    var previousControlPoints: [SIMD3<Float>]?
    /// The emitter's scale, rotation and shear the particles are drawn through
    /// (`ParticleFrameInputs.drawLinear`), from the last step.
    var drawLinear = matrix_identity_float2x2
    /// A built-in sprite's quad axes from the last step: the renderer's orientation through
    /// `drawLinear` (`ParticleOrientation.spriteLinear`).
    var spriteLinear = matrix_identity_float2x2
    /// The last step's rope inputs (`ParticleRopeUV.layout`): rate and lifetime overrides and the
    /// frame-rate limit.
    var ropeFrame = SIMD3<Float>(1, 1, 0)
    /// Seconds until the particles next record their trail history (`ParticleTrailHistory`): WE's
    /// countdown, one per system.
    var trailTimer: Float = 0
    /// The fraction of the day (`remapvalue`'s `timeofday`), and when it was read: the calendar is
    /// asked again once a second at most.
    private var dayFraction: (value: Float, at: CFTimeInterval)?

    func timeOfDay(now: CFTimeInterval = CACurrentMediaTime()) -> Float {
        if let dayFraction, now - dayFraction.at < 1 { return dayFraction.value }
        let value = ParticleProgramEncoding.fractionOfDay()
        dayFraction = (value, now)
        return value
    }

    /// The offsets the instance override gave the control points last step (`keptPoints`).
    var lastOverridePoints = [SIMD3<Float>?](repeating: nil, count: ParticleControlPoint.count)
    /// Each emitter's clock (`ParticleEmitterTiming`), carried fraction and what its rate emitted this
    /// period (`ParticleFrameInputs.periodLimit`) for a system that isn't instanced.
    var emitterStates: [ParticleEmitterState]
    /// The system this one is a child of (`SceneMetalParticleSystem.link`).
    weak var parent: ParticleSystemRuntime?
    /// Its `layerimage` emitters' images (`SceneMetalParticleSystem.emitterImages`) as last
    /// sampled: the load's until a resampling (flag 0x20000) replaces their points.
    var emitterImages: [ParticleEmitterImage]
    /// Bumped whenever `emitterImages` change, so the GPU state takes the new points.
    private(set) var emitterImagesRevision = 0
    /// Each emitter's seconds of emitting since its image was last sampled (flag 0x20000; WE's
    /// per-emitter timer, 0x140238d4f).
    var imageResampleTimers: [Float]
    /// The `emitterImages` slots whose layer is due to be sampled again after this step.
    var imageResamplesDue: Set<Int> = []
    /// Each emitter's layer image world (the layer's world, before the system's space) at its last
    /// step, where a rigged layer's bones were last frame (`ParticleFrameInputs.placeImages`).
    var lastImageWorlds: [SceneAffineTransform?]

    /// For a renderer after a system's first (`SceneMetalParticleSystem.additionalRenderers`): the
    /// system whose particles it draws. It has no simulation of its own; each frame it draws what
    /// that system's step left (`followSimulation`).
    private(set) weak var simulation: ParticleSystemRuntime?

    init(texture: MTLTexture, configuration: SceneMetalParticleSystem, seed: UInt32 = 0,
         fallbackTexture: MTLTexture? = nil, simulation: ParticleSystemRuntime? = nil) {
        self.simulation = simulation
        self.texture = texture
        self.fallbackTexture = fallbackTexture ?? texture
        self.configuration = configuration
        self.seed = seed
        emitterStates = Array(repeating: ParticleEmitterState(), count: configuration.emitters.count)
        emitterImages = configuration.emitterImages
        imageResampleTimers = Array(repeating: 0, count: configuration.emitters.count)
        lastImageWorlds = Array(repeating: nil, count: configuration.emitters.count)
    }

    /// Replaces the points of image `slot` (a resampling's, `ParticleEmitterImageResampler`).
    func replaceImagePoints(_ points: [SIMD4<Int32>], slot: Int) {
        guard emitterImages.indices.contains(slot), emitterImages[slot].points != points else { return }
        emitterImages[slot].points = points
        emitterImagesRevision &+= 1
    }

    /// Points each child at its parent (`SceneMetalParticleSystem.link`), in a scene's list of
    /// systems; a system that couldn't be prepared is nil and leaves its children without one.
    /// The first emitter's carried fraction of a particle.
    var emissionRemainder: Float { emitterStates.first?.remainder ?? 0 }

    static func linkFamilies(_ systems: [ParticleSystemRuntime?]) {
        for system in systems {
            guard let system, let parentIndex = system.configuration.link?.parentIndex,
                  systems.indices.contains(parentIndex) else { continue }
            system.parent = systems[parentIndex]
        }
    }
}

extension ParticleSystemRuntime {
    /// Each system followed by a draw of each of its renderers after the first
    /// (`SceneMetalParticleSystem.additionalRenderers`), in authored order: WE draws every renderer
    /// of a system from its one simulation. A system with one renderer is left as it is.
    static func addingRendererDraws(_ systems: [ParticleSystemRuntime]) -> [ParticleSystemRuntime] {
        systems.flatMap { system -> [ParticleSystemRuntime] in
            [system] + system.configuration.additionalRenderers.map { renderer in
                ParticleSystemRuntime(texture: system.texture, configuration: system.configuration.drawing(renderer),
                                      seed: system.seed, fallbackTexture: system.fallbackTexture, simulation: system)
            }
        }
    }

    /// Takes the draw state `simulation`'s step left this frame, with this renderer's orientation.
    func followSimulation() {
        guard let simulation else { return }
        elapsedTime = simulation.elapsedTime
        frameIndex = simulation.frameIndex
        trailTimer = simulation.trailTimer
        ropeFrame = simulation.ropeFrame
        drawLinear = simulation.drawLinear
        spriteLinear = configuration.orientation.spriteLinear(linear: drawLinear)
    }

    /// The factor on a trail's or rope's size (`ParticleFrameInputs.drawSizeScale`): the area scale
    /// of `drawLinear`, which WE's trail and rope shaders apply along directions of their own.
    /// Sprites take `drawLinear` whole and keep 1.
    var drawSizeScale: Float {
        let name = configuration.rendererName
        guard name.contains("trail") || name.hasPrefix("rope") else { return 1 }
        return sqrt(abs(simd_determinant(drawLinear)))
    }
}
