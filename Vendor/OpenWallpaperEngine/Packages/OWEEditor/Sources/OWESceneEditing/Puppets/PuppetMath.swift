import Foundation
import simd

/// The matrix and rotation helpers of WE's rigs (docs/models-plan.md §1.3, §1.4, §2.8), as the
/// player's own (`SceneSkeleton`, `SceneBoneTransform`, `SceneBonePhysicsMath`) compute them.
/// Matrices are column-vector (`p′ = M · p`), the same memory as WE's row-vector ones: a bone's
/// world is `world(parent) · local`.
public enum PuppetMath {
    /// `T · R · S`, R = Rz·Ry·Rx from Euler angles in radians.
    public static func matrix(translation: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) -> simd_float4x4 {
        let r = rotation(euler)
        return simd_float4x4(columns: (SIMD4(r.columns.0 * scale.x, 0), SIMD4(r.columns.1 * scale.y, 0),
                                       SIMD4(r.columns.2 * scale.z, 0), SIMD4(translation, 1)))
    }

    /// The rotation matrix of Euler angles (X first: `Rz · Ry · Rx`).
    public static func rotation(_ angles: SIMD3<Float>) -> simd_float3x3 {
        let cx = cos(angles.x), sx = sin(angles.x), cy = cos(angles.y), sy = sin(angles.y)
        let cz = cos(angles.z), sz = sin(angles.z)
        return simd_float3x3(SIMD3(cy * cz, cy * sz, -sy),
                             SIMD3(sy * cz * sx - cx * sz, sy * sz * sx + cx * cz, sx * cy),
                             SIMD3(cx * cz * sy + sx * sz, cx * sz * sy - sx * cz, cx * cy))
    }

    /// A rotation matrix's Euler angles as `getLocalBoneAngles` extracts them.
    public static func angles(_ m: simd_float3x3) -> SIMD3<Float> {
        let z = atan2(m[0][1], m[0][0])
        let y = atan2(-m[0][2], (m[2][2] * m[2][2] + m[1][2] * m[1][2]).squareRoot())
        let x = atan2(sin(z) * m[2][0] - cos(z) * m[2][1], cos(z) * m[1][1] - sin(z) * m[1][0])
        return SIMD3(x, y, z)
    }

    /// `qz · qy · qx` from Euler angles, as WE builds a sample's rotation at load (0x1402640c0).
    public static func quaternion(euler: SIMD3<Float>) -> simd_quatf {
        let half = euler * 0.5
        let cx = cos(half.x), sx = sin(half.x), cy = cos(half.y), sy = sin(half.y), cz = cos(half.z), sz = sin(half.z)
        return simd_quatf(ix: sx * cy * cz - cx * sy * sz, iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz, r: cx * cy * cz + sx * sy * sz)
    }

    /// Model-space matrices from local ones, parents first (a parent after its child counts as
    /// none, as the player takes it).
    public static func worlds(locals: [simd_float4x4], parents: [Int?]) -> [simd_float4x4] {
        var worlds: [simd_float4x4] = []
        worlds.reserveCapacity(locals.count)
        for index in locals.indices {
            let parent = index < parents.count ? parents[index].flatMap { $0 < index ? $0 : nil } : nil
            worlds.append(parent.map { worlds[$0] * locals[index] } ?? locals[index])
        }
        return worlds
    }

    /// The angle (radians) a matrix turns its x axis by in the plane.
    public static func angle(of matrix: simd_float4x4) -> Float {
        atan2(matrix.columns.0.y, matrix.columns.0.x)
    }

    public static func origin(of matrix: simd_float4x4) -> SIMD2<Float> {
        SIMD2(matrix.columns.3.x, matrix.columns.3.y)
    }

    /// `matrix · (p, 0, 1)`, in the plane.
    public static func transform(_ p: SIMD2<Float>, _ matrix: simd_float4x4) -> SIMD2<Float> {
        let q = matrix * SIMD4(p.x, p.y, 0, 1)
        return SIMD2(q.x, q.y)
    }

    public static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { a.x * b.y - a.y * b.x }

    /// The barycentric coordinates of `p` in triangle `a b c`; nil for a degenerate triangle.
    public static func barycentric(_ p: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> SIMD3<Float>? {
        let area = cross(b - a, c - a)
        guard abs(area) > 1e-12 else { return nil }
        let u = cross(b - p, c - p) / area
        let v = cross(c - p, a - p) / area
        return SIMD3(u, v, 1 - u - v)
    }

    /// The distance from `p` to the segment `a b`.
    public static func distance(_ p: SIMD2<Float>, segment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_distance(p, closest(p, segment: a, b))
    }

    public static func closest(_ p: SIMD2<Float>, segment a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
        let ab = b - a
        let length = simd_length_squared(ab)
        guard length > 0 else { return a }
        return a + ab * min(max(simd_dot(p - a, ab) / length, 0), 1)
    }

    /// Normalised lerp along the shorter arc (0x1401f9020).
    public static func nlerp(_ a: simd_quatf, _ b: simd_quatf, _ t: Float) -> simd_quatf {
        let target = simd_dot(a.vector, b.vector) < 0 ? -b.vector : b.vector
        let mixed = a.vector * (1 - t) + target * t
        let length = simd_length(mixed)
        return length > 0 ? simd_quatf(vector: mixed / length) : a
    }
}

/// A pose entry as the player blends it (`SceneBoneTransform`): translation, a rotation
/// quaternion and scale; the matrix is `T · R · S`.
public struct PuppetPoseTransform: Hashable, Sendable {
    public var translation: SIMD3<Float>
    public var rotation: simd_quatf
    public var scale: SIMD3<Float>

    public static let identity = PuppetPoseTransform(translation: .zero, rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                                     scale: SIMD3(repeating: 1))

    public init(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    /// A track sample, its rotation built as WE builds it.
    public init(_ transform: PuppetTransform) {
        self.init(translation: transform.translation, rotation: PuppetMath.quaternion(euler: transform.euler),
                  scale: transform.scale)
    }

    public var matrix: simd_float4x4 {
        let r = simd_float3x3(rotation)
        return simd_float4x4(columns: (SIMD4(r.columns.0 * scale.x, 0), SIMD4(r.columns.1 * scale.y, 0),
                                       SIMD4(r.columns.2 * scale.z, 0), SIMD4(translation, 1)))
    }

    /// Translation and scale lerped, rotation nlerped.
    public static func blend(_ a: PuppetPoseTransform, _ b: PuppetPoseTransform, _ t: Float) -> PuppetPoseTransform {
        PuppetPoseTransform(translation: a.translation + (b.translation - a.translation) * t,
                            rotation: PuppetMath.nlerp(a.rotation, b.rotation, t),
                            scale: a.scale + (b.scale - a.scale) * t)
    }

    /// An additive layer's sample over `pose` (0x1401f9820): translation and scale gain
    /// `w · (sample − bind)`; the rotation's change from the bind pose is nlerped from the
    /// identity by `w` and composed after the pose.
    public static func add(_ sample: PuppetPoseTransform, over pose: PuppetPoseTransform, bind: PuppetPoseTransform,
                           weight: Float) -> PuppetPoseTransform {
        let delta = (bind.rotation.inverse * sample.rotation).normalized
        let scaled = PuppetMath.nlerp(identity.rotation, delta, weight)
        return PuppetPoseTransform(translation: pose.translation + (sample.translation - bind.translation) * weight,
                                   rotation: (pose.rotation * scaled).normalized,
                                   scale: pose.scale + (sample.scale - bind.scale) * weight)
    }

    public static func == (lhs: PuppetPoseTransform, rhs: PuppetPoseTransform) -> Bool {
        lhs.translation == rhs.translation && lhs.rotation.vector == rhs.rotation.vector && lhs.scale == rhs.scale
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(translation)
        hasher.combine(rotation.vector)
        hasher.combine(scale)
    }
}
