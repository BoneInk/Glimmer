import simd

/// An axis-aligned box: a mesh's authored bounds (`MDLV` 17 and later), a clip's animated bounds
/// (`MDLA` 5 and later) or a model's.
public struct MDLBounds: Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    /// What a model without usable bounds gets: ±131072 on every axis, so it is never culled
    /// (0x140262349).
    public static let unbounded = MDLBounds(min: SIMD3(repeating: -131072), max: SIMD3(repeating: 131072))

    /// The union of the mesh boxes the way WE builds a model's (0x1402617c0): start from
    /// ±FLT_MAX, then `minss`/`maxss` per mesh (a mesh without bounds counts as the zero box, as
    /// WE's mesh record starts zeroed). The union counts only when max.x > min.x; otherwise, and
    /// for a model without meshes, the model is `unbounded`.
    public static func union(of meshes: [MDLBounds?]) -> MDLBounds {
        guard !meshes.isEmpty else { return .unbounded }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for box in meshes {
            let box = box ?? MDLBounds(min: .zero, max: .zero)
            for axis in 0..<3 {
                // minss/maxss keep the second operand unless the first is strictly smaller/larger.
                low[axis] = box.min[axis] < low[axis] ? box.min[axis] : low[axis]
                high[axis] = box.max[axis] > high[axis] ? box.max[axis] : high[axis]
            }
        }
        return high.x > low.x ? MDLBounds(min: low, max: high) : .unbounded
    }

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }
}
