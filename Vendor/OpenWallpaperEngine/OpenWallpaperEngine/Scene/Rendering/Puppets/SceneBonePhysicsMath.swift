import Foundation
import simd

/// The rotation helpers WE's bone physics uses (docs/models-plan.md §2.14), with WE's thresholds
/// and branches. Quaternions are Hamilton, w first in WE's memory (`simd_quatf`'s `real`);
/// matrices are the memory of WE's row-vector ones, so `m[i][j]` is WE's `m[i][j]` and WE's
/// `v · M` is `M * v` here.
enum SceneBonePhysicsMath {
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// WE's `1 − FLT_EPSILON` (0x140492700), where a dot product counts as 1.
    static let nearlyOne: Float = 0.99999988
    static let degrees: Float = 0.017453292
    static let radians: Float = 57.29578

    /// The rotation matrix of Euler angles `x`, `y`, `z` (radians, X first: `Rz · Ry · Rx`),
    /// built element by element as the update does (0x14020166e…0x14020182a).
    static func euler(_ angles: SIMD3<Float>) -> simd_float3x3 {
        let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        return simd_float3x3(SIMD3(cy * cz, cy * sz, -sy),
                             SIMD3(sy * cz * sx - cx * sz, sy * sz * sx + cx * cz, sx * cy),
                             SIMD3(cx * cz * sy + sx * sz, cx * sz * sy - sx * cz, cx * cy))
    }

    /// A rotation matrix's Euler angles (0x140201e04…0x140201fec), as `getLocalBoneAngles` reads
    /// them: z = atan2(m01, m00), y = atan2(−m02, |(m12, m22)|), x from the rest.
    static func angles(_ m: simd_float3x3) -> SIMD3<Float> {
        let z = atan2(m[0][1], m[0][0])
        let y = atan2(-m[0][2], (m[2][2] * m[2][2] + m[1][2] * m[1][2]).squareRoot())
        let x = atan2(sin(z) * m[2][0] - cos(z) * m[2][1], cos(z) * m[1][1] - sin(z) * m[1][0])
        return SIMD3(x, y, z)
    }

    /// `qz · qy · qx` of Euler angles in radians (the impulse's, 0x140210a77…).
    static func quaternion(euler angles: SIMD3<Float>) -> simd_quatf {
        let h = angles * 0.5
        let cx = cos(h.x), sx = sin(h.x), cy = cos(h.y), sy = sin(h.y), cz = cos(h.z), sz = sin(h.z)
        return simd_quatf(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
    }

    /// The shortest rotation taking unit vector `a` to `b` (0x1402167c0).
    static func alignment(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let d = simd_dot(a, b)
        if d >= nearlyOne { return identity }
        if d < -nearlyOne {
            // Half a turn about an axis across `a`: z × a, or x × a when that is too short.
            var axis = SIMD3<Float>(-a.y, a.x, 0)
            if simd_length_squared(axis) < 1.1920929e-7 { axis = SIMD3(0, -a.z, a.y) }
            return simd_quatf(real: cos(Float.pi / 2), imag: axis / simd_length(axis) * sin(Float.pi / 2))
        }
        let s = (2 * (1 + d)).squareRoot()
        return simd_quatf(real: s * 0.5, imag: simd_cross(a, b) / s)
    }

    /// Spherical interpolation along the shorter arc, lerped without normalising past WE's
    /// threshold (0x140216070).
    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        var b = b.vector
        var d = simd_dot(a.vector, b)
        if d < 0 {
            b = -b
            d = -d
        }
        if d > nearlyOne { return simd_quatf(vector: a.vector * (1 - t) + b * t) }
        let angle = acos(d)
        return simd_quatf(vector: (a.vector * sin((1 - t) * angle) + b * sin(t * angle)) / sin(angle))
    }

    /// The quaternion scaled to unit length; the identity when it has none (0x140217ac0).
    static func normalized(_ q: simd_quatf) -> simd_quatf {
        let length = simd_length(q.vector)
        return length > 0 ? simd_quatf(vector: q.vector / length) : identity
    }

    /// The vector scaled to unit length as WE's SSE code does (no zero test).
    static func unit(_ v: SIMD3<Float>) -> SIMD3<Float> { v * (1 / simd_length(v)) }

    /// `lt`: each axis's turn of the angular velocity clamped to ±`degrees` (0x140201a94…).
    static func limitTorque(_ q: simd_quatf, degrees limit: Float) -> simd_quatf {
        let tangents = q.imag / q.real
        var clamped = SIMD3<Float>.zero
        for axis in 0..<3 {
            var angle = min(atan(tangents[axis]) * radians * 2, limit)
            if -limit > angle { angle = -limit }
            clamped[axis] = tan(angle * degrees * 0.5)
        }
        return normalized(simd_quatf(real: 1, imag: clamped))
    }

    /// An angle wrapped to −π…π as the spring does (0x1402031c4).
    static func wrap(_ angle: Float) -> Float {
        angle < 0 ? fmodf(angle - .pi, 2 * .pi) + .pi : fmodf(angle + .pi, 2 * .pi) - .pi
    }
}
