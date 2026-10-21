import simd

/// When an emitter emits: WE's emitter `delay`, `duration`, random periodic emission and "limit to
/// one per frame".
///
/// - `delay`: seconds before the emitter starts; its `instantaneous` burst comes when it does.
/// - `duration`: seconds it emits once started; 0 emits for ever. Particles already out live on.
/// - Random periodic emission (`flags` bit 2): it emits for a random `min…maxperiodicduration`,
///   pauses for a random `min…maxperiodicdelay`, and so on. Each period bursts `instantaneous`
///   again, and `maxtoemitperperiod` (when above 0, scaled by the `count` instance override) caps
///   what the rate emits in one period.
/// - Limit to one per frame (`flags` bit 1): the rate emits at most one particle a step.
///
/// WE reads the fields in its emitter parser (`wallpaper64.exe` 0x1401c1c70): an unset periodic
/// range defaults to 2…3 s emitting and 1…2 s paused, and a minimum above its maximum is lowered to
/// it. Its changelog gives the rest: "periodic emission reset instant particles", the per-period
/// limit applies "when rate emission is used" and "scale[s] with particle instance count", and
/// the duration counts down every frame.
struct ParticleEmitterTiming: Equatable {
    var delay: Float = 0
    var duration: Float = 0
    var periodic = false
    var periodDuration: ClosedRange<Float> = 2...3
    var periodDelay: ClosedRange<Float> = 1...2
    /// The most the rate emits in one period; 0 sets no limit.
    var maximumPerPeriod = 0
    var onePerFrame = false

    static let onePerFrameFlag = 2, periodicFlag = 4

    init() {}

    init(_ emitter: WEParticleEmitter) {
        delay = max(Float(emitter.delay ?? 0), 0)
        duration = max(Float(emitter.duration ?? 0), 0)
        let flags = emitter.flags ?? 0
        periodic = flags & Self.periodicFlag != 0
        onePerFrame = flags & Self.onePerFrameFlag != 0
        periodDuration = Self.range(emitter.minperiodicduration, emitter.maxperiodicduration, default: 2...3)
        periodDelay = Self.range(emitter.minperiodicdelay, emitter.maxperiodicdelay, default: 1...2)
        maximumPerPeriod = max(emitter.maxtoemitperperiod ?? 0, 0)
    }

    /// WE's `min(minimum, maximum)…maximum`, never negative.
    private static func range(_ minimum: Double?, _ maximum: Double?, default range: ClosedRange<Float>) -> ClosedRange<Float> {
        let upper = max(Float(maximum ?? Double(range.upperBound)), 0)
        let lower = min(max(Float(minimum ?? Double(range.lowerBound)), 0), upper)
        return lower...upper
    }

    /// The per-period limit this frame, for a `count` override of `countScale`; nil without one.
    func periodLimit(countScale: Float) -> Int? {
        guard periodic, maximumPerPeriod > 0 else { return nil }
        return Int(saturating: (Float(maximumPerPeriod) * countScale).rounded(), in: 0...Int(UInt32.max))
    }
}

/// One emitter's place in its `ParticleEmitterTiming`: a system's own, or each instance's
/// (`ParticleGPUInstance`). `ParticleInstances.metal` steps the same state (`emitterClock`).
struct ParticleEmitterClock: Equatable {
    /// Seconds since the emitter was made, seconds left in the current periodic phase, the phase
    /// plus one (0: not started; odd: emitting, even: paused), and what the rate emitted this
    /// period (instances; a system counts in its step).
    var state = SIMD4<Float>.zero

    struct Step: Equatable {
        /// The rate emits this step.
        var emits = false
        /// The `instantaneous` burst goes out this step.
        var bursts = false
        /// A period starts: the per-period count restarts.
        var startsPeriod = false
    }

    /// Advances the clock by `deltaTime`. `seed` and `key` name its random periods.
    mutating func advance(_ deltaTime: Float, timing: ParticleEmitterTiming, seed: UInt32, key: UInt32) -> Step {
        state.x += deltaTime
        let running = timing.duration <= 0 || state.x - timing.delay < timing.duration
        if state.z == 0 {
            guard state.x >= timing.delay else { return Step() }
            state.z = 1
            state.y = timing.periodic ? Self.phaseLength(0, timing: timing, seed: seed, key: key) : 0
            state.w = 0
            return Step(emits: running, bursts: true, startsPeriod: true)
        }
        var step = Step()
        if timing.periodic {
            state.y -= deltaTime
            if state.y <= 0 {
                let phase = UInt32(state.z)
                state.z += 1
                state.y = Self.phaseLength(phase, timing: timing, seed: seed, key: key)
                if phase % 2 == 0 {
                    state.w = 0
                    step.startsPeriod = true
                    step.bursts = running
                }
            }
        }
        step.emits = running && (!timing.periodic || UInt32(state.z - 1) % 2 == 0)
        return step
    }

    /// The length of phase `phase`: emitting when even, paused when odd.
    static func phaseLength(_ phase: UInt32, timing: ParticleEmitterTiming, seed: UInt32, key: UInt32) -> Float {
        let range = phase % 2 == 0 ? timing.periodDuration : timing.periodDelay
        let stream: ParticleRandom.Stream = phase % 2 == 0 ? .periodDuration : .periodDelay
        return ParticleRandom.value(in: range, seed: seed &+ key &* 0x9E37_79B9, serial: phase, stream)
    }
}

/// One emitter's running state: its clock, the fraction of a particle its rate carries into the next
/// step and what the rate emitted this period. WE keeps these per emitter record
/// (`wallpaper64.exe` 0x1402379aa…0x140237b74: carry at +0x24, the period's count at +0x3c), so
/// every emitter of a system counts on its own.
struct ParticleEmitterState: Equatable {
    var clock = ParticleEmitterClock()
    var remainder: Float = 0
    var periodEmitted = 0
    /// Spawned this step and whether a period started (an instance's, `ParticleGPUInstance`).
    var spawnCount = 0
    var startsPeriod = false
    /// A `layerimage` emitter's layer world (`ParticleEmitterStep.layerWorld`) at its last step that
    /// spawned, and the one before, which this step's spawns inherit the layer's motion from: WE
    /// keeps the layer's matrix after each step that spawns (0x14023adef), starting from the
    /// identity (0x1401c6ba2). Nil stands for that identity.
    var lastLayerWorld: SceneAffineTransform?
    var spawnLayerWorld: SceneAffineTransform?

    /// A step that spawns: its spawns read the layer world of the step that spawned last.
    mutating func spawns(layerWorld: SceneAffineTransform) {
        spawnLayerWorld = lastLayerWorld
        lastLayerWorld = layerWorld
    }

    /// The key naming emitter `emitter`'s random periods, from the key of the system's (or the
    /// instance's) first emitter.
    static func clockKey(_ base: UInt32, emitter: Int) -> UInt32 { base &+ UInt32(emitter) &* 0x632B_E5AB }
}
