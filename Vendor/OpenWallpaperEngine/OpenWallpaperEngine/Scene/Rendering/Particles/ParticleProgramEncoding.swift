import simd

/// The encoding constants and helpers the loader, the frame inputs and `ParticleProgram.h` share:
/// the program itself runs on the GPU (`ParticleSimulation.metal`).
enum ParticleProgramEncoding {
    /// The flag that makes a sequence initializer follow the `count` override (0x1401ca184,
    /// 0x1401ca637).
    static func sequenceFollowsCountFlag(_ kind: ParticleInitializerKind) -> UInt32 {
        kind == .mapSequenceBetweenControlPoints ? 16 : 1
    }

    /// A 2D linear map as a 3D one that keeps z.
    static func embed(_ linear: simd_float2x2) -> simd_float3x3 {
        simd_float3x3(SIMD3(linear.columns.0, 0), SIMD3(linear.columns.1, 0), SIMD3(0, 0, 1))
    }

    /// WE's control point rotation from `controlpointangle<n>` (radians; 0x14022bf53…0x14022c069),
    /// as the basis whose columns are WE's rows: `axes * a` is WE's `a·R` (x first, then y, then z).
    static func controlPointRotation(_ angles: SIMD3<Float>) -> simd_float3x3 {
        let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        return simd_float3x3(SIMD3(cy * cz, cy * sz, -sy),
                             SIMD3(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy),
                             SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy))
    }
}
