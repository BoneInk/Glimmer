import Metal
import simd

/// The per-particle records WE's particle shaders read, as the simulation writes them.
///
/// Every field is a 16-byte `float4` slot, so the layout is the same in Swift and in Metal: a
/// future compute simulation can write the buffer directly and the draw stays the same. One
/// record is one geometry-shader input point, drawn as one instance: a particle for
/// `genericparticle`, one segment for `genericropeparticle`.
enum ParticleVertexFormat: Equatable {
    /// `genericparticle`: sprites and sprite trails.
    case sprite
    /// `genericropeparticle`: one record per rope segment.
    case rope

    /// Bytes per record.
    var stride: Int {
        switch self {
        case .sprite: return MemoryLayout<ParticleSpriteInstance>.stride
        case .rope: return MemoryLayout<ParticleRopeSegmentInstance>.stride
        }
    }

    /// Where WE's vertex attribute `name` sits in a record. Nil when the format has no such
    /// stream; the attribute then reads zero. `ParticleQuadExpansion.recordAttribute` is the
    /// record slot the no-geometry-shader stream derives its per-corner attributes from.
    func recordOffset(ofAttribute name: String) -> Int? {
        switch (self, name) {
        case (.sprite, "a_Position"), (.sprite, "a_PositionVec4"): return 0
        case (.sprite, "a_TexCoordVec4"), (.sprite, ParticleQuadExpansion.recordAttribute): return 16
        case (.sprite, "a_TexCoordVec4C1"): return 32
        case (.sprite, "a_Color"): return 48
        case (.rope, "a_PositionVec4"), (.rope, "a_Position"): return 0
        case (.rope, "a_TexCoordVec4"): return 16
        case (.rope, "a_TexCoordVec4C1"): return 32
        case (.rope, "a_TexCoordVec4C2"), (.rope, "a_TexCoordVec3C2"): return 48
        case (.rope, "a_TexCoordVec4C3"): return 64
        case (.rope, "a_Color"): return 80
        default: return nil
        }
    }
}

/// One particle, as `genericparticle.vert` reads it. Positions and vectors are in the system's
/// model space (the scene, y up); sizes are the particles' (`ParticleRecords.metal`).
struct ParticleSpriteInstance {
    /// `a_Position`: xyz; w unused.
    var position: SIMD4<Float>
    /// `a_TexCoordVec4`: rotation (radians, xyz) and size (the quad's width).
    var rotationSize: SIMD4<Float>
    /// `a_TexCoordVec4C1`: velocity (xyz) and the sprite-sheet phase (`frac` picks the frame).
    var velocityLifetime: SIMD4<Float>
    /// `a_Color`: rgb and alpha.
    var color: SIMD4<Float>
}

/// One rope segment, as `genericropeparticle.vert` reads it.
struct ParticleRopeSegmentInstance {
    /// `a_PositionVec4`: start point and its size (half the ribbon width).
    var start: SIMD4<Float>
    /// `a_TexCoordVec4`: end point; w is the trail's point count (`in_ParticleTrailLength`): a
    /// rope's points, a `ropetrail`'s samples over uvscale, or a scrolling one's segment index.
    var end: SIMD4<Float>
    /// `a_TexCoordVec4C1`: the point before `start` (spline control); w is the segment index.
    var previous: SIMD4<Float>
    /// `a_TexCoordVec4C2`: the point after `end`; w is the size at `end`.
    var next: SIMD4<Float>
    /// `a_TexCoordVec4C3`: colour at `end` (thick format).
    var endColor: SIMD4<Float>
    /// `a_Color`: colour at `start`.
    var color: SIMD4<Float>
}
