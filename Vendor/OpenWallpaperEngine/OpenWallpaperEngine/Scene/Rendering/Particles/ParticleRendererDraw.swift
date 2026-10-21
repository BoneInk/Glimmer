import simd

/// One entry of a particle system's `renderers`: what it draws the system's particles as. WE draws
/// every renderer of a system, in authored order, from the one simulation; the system's own fields
/// (`SceneMetalParticleSystem.rendererName` and the rest) are the first's, and
/// `SceneMetalParticleSystem.additionalRenderers` holds the others.
/// `ParticleSystemBuilder.rendererDraw` makes it from the json with WE's defaults.
struct ParticleRendererDraw {
    /// `sprite`, `spritetrail`, `rope` or `ropetrail`.
    var name: String
    /// `SceneMetalParticleSystem.trailLength`.
    var trailLength: Float
    /// `spritetrail`'s `maxlength` and `minlength`.
    var trailLengthLimits: SIMD2<Float>
    /// `ropetrail`'s `segments`.
    var trailSegments: Int
    /// `subdivision` (`TRAILSUBDIVISION`).
    var ropeSubdivision: Int
    var fadeTrailAlpha: Bool
    var fadeTrailSize: Bool
    var orientation: ParticleOrientation
    var ropeUV: ParticleRopeUV
    /// The system's material with this renderer's combos; nil keeps the built-in particle draw.
    var material: ParticleMaterialPlan? = nil
}

/// The trail history the simulation keeps for a `ropetrail` renderer: a sample every
/// `length / segments` seconds, `segments` of them per particle.
///
/// WE times the samples with one countdown per system (`wallpaper64.exe` [system+0x24c]): each step
/// takes the frame's delta off it, and once it reaches 0 it starts again from the interval
/// ([system+0x250]) and every particle shifts its history by one and records its position
/// (0x140232cad…0x140232db8). A spawned particle starts with one sample, where it spawned
/// (0x14023f9e3). The trail's texture then slides with the countdown, so it stays on the
/// samples between them (`ParticleMaterialUniforms.ropeRenderVar`).
struct ParticleTrailHistory: Equatable {
    /// A renderer of the system is a `ropetrail`.
    var kept: Bool
    /// That renderer's `length` (seconds of history) and `segments`.
    var length: Float
    var segments: Int

    /// The samples a particle keeps.
    var limit: Int { max(segments, 1) }
    /// Seconds between two samples.
    var interval: Float { max(length, 0.001) / Float(limit) }
}
