import simd

/// One sample of a bone or link track: position, Euler angles in radians and scale, 9 floats
/// (docs/models-plan.md §1.4).
public struct MDLBonePose: Equatable {
    public static let floatCount = 9

    public var position: SIMD3<Float>
    /// Radians, applied X first: R = Rz·Ry·Rx.
    public var euler: SIMD3<Float>
    public var scale: SIMD3<Float>

    public init(position: SIMD3<Float>, euler: SIMD3<Float>, scale: SIMD3<Float>) {
        self.position = position
        self.euler = euler
        self.scale = scale
    }

    /// From 9 floats in file order.
    public init<C: Collection>(_ values: C) where C.Element == Float, C.Index == Int {
        let v = Array(values)
        precondition(v.count == Self.floatCount, "a pose is 9 floats")
        position = SIMD3(v[0], v[1], v[2])
        euler = SIMD3(v[3], v[4], v[5])
        scale = SIMD3(v[6], v[7], v[8])
    }

    /// The rotation as WE builds it at load (0x1402640c0): half angles through cosf/sinf, then
    /// q = qz·qy·qx.
    public var rotation: simd_quatf {
        let half = euler * 0.5
        let cx = cos(half.x), sx = sin(half.x)
        let cy = cos(half.y), sy = sin(half.y)
        let cz = cos(half.z), sz = sin(half.z)
        return simd_quatf(ix: sx * cy * cz - cx * sy * sz,
                          iy: cx * sy * cz + sx * cy * sz,
                          iz: cx * cy * sz - sx * sy * cz,
                          r: cx * cy * cz + sx * sy * sz)
    }
}
