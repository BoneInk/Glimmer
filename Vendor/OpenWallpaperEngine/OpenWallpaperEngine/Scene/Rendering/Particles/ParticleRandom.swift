import simd

/// Deterministic particle randomness, as the GPU simulation draws it (`ParticleShared.h`).
///
/// Every draw is a pure function of the system's seed, the particle's serial number (its spawn
/// order) and a stream naming what the draw is for, so a particle gets the same values whichever
/// simulation runs it, and in whatever order particles are processed.
/// `ParticleSimulation.metal` implements the same hash and streams; change both together.
enum ParticleRandom {
    /// What a draw is for. Spawn streams are drawn once per particle; per-frame draws use
    /// `frameStream`.
    enum Stream: UInt32 {
        /// The emitter's draws: a sphere's angle, height and radius (a box's x, y and z), its speed,
        /// and a direction for a particle spawned at the centre.
        case spawnAngle = 0, spawnHeight, spawnRadius, emitterSpeed, fallbackX, fallbackY, fallbackZ
        case spriteFrame
        /// Whether a parent particle's event makes a child instance (keyed by the parent's serial).
        case eventProbability
        /// A periodic emitter's emitting and paused phases (keyed by the phase, `ParticleEmitterClock`).
        case periodDuration, periodDelay
        /// The particle's one random value every operator reads (WE's [system+0x338]).
        case `operator`
    }
    // Initializers draw from their own streams (`initializerStream` in `ParticleShared.h`), from 64 on.

    /// PCG hash (Jarzynski and Olano, "Hash Functions for GPU Rendering", 2020).
    static func pcg(_ value: UInt32) -> UInt32 {
        let state = value &* 747_796_405 &+ 2_891_336_453
        let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277_803_737
        return (word >> 22) ^ word
    }

    /// Uniform in [0, 1), 24 bits.
    static func unit(seed: UInt32, serial: UInt32, stream: UInt32) -> Float {
        let hash = pcg(seed &+ pcg(serial &+ pcg(stream)))
        return Float(hash >> 8) * (1 / 16_777_216)
    }

    /// Between `a` and `b` (either order; equal bounds give the bound).
    static func value(_ a: Float, _ b: Float, seed: UInt32, serial: UInt32, stream: UInt32) -> Float {
        a + (b - a) * unit(seed: seed, serial: serial, stream: stream)
    }

    static func value(_ a: Float, _ b: Float, seed: UInt32, serial: UInt32, _ stream: Stream) -> Float {
        value(a, b, seed: seed, serial: serial, stream: stream.rawValue)
    }

    static func value(in range: ClosedRange<Float>, seed: UInt32, serial: UInt32, _ stream: Stream) -> Float {
        value(range.lowerBound, range.upperBound, seed: seed, serial: serial, stream: stream.rawValue)
    }

    /// An integer in `0..<count`.
    static func index(_ count: Int, seed: UInt32, serial: UInt32, _ stream: Stream) -> Int {
        let count = max(count, 1)
        return min(Int(unit(seed: seed, serial: serial, stream: stream.rawValue) * Float(count)), count - 1)
    }
}
