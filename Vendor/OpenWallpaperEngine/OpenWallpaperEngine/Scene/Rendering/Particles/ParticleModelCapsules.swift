import simd

/// A capsule a `collisionmodel` operator collides particles with (docs/models-plan.md §2.12): the
/// segment from `start` along the unit `direction` for `length`, grown by `radius`. WE builds one
/// per bone of the linked model, or one from its box, every frame (`wallpaper64.exe` 0x1401d4580),
/// in the particles' space.
struct ParticleCapsule: Equatable {
    var start: SIMD3<Float>
    var direction: SIMD3<Float>
    var length: Float
    var radius: Float

    /// A capsule in its own frame, fitted to a box's half extents (0x1401d5880): the axis is the
    /// largest component's (a unit vector), the radius vector the second largest's (as a vector,
    /// so a frame's scale along it scales the radius), and the half length of the segment their
    /// difference. Ties keep x before y, and the larger of those before z.
    struct Fit: Equatable {
        var axis: SIMD3<Float>
        var halfLength: Float
        var radius: SIMD3<Float>

        /// What a bone gets whose extent's squared length is below 0.01 (0x1401d4950, the
        /// constant at 0x140492620): a point on +y with no radius, which nothing hits.
        static let degenerate = Fit(axis: SIMD3(0, 1, 0), halfLength: 0, radius: .zero)
    }

    static func fit(_ extent: SIMD3<Float>) -> Fit {
        let x = SIMD3<Float>(extent.x, 0, 0), y = SIMD3<Float>(0, extent.y, 0), z = SIMD3<Float>(0, 0, extent.z)
        func squared(_ v: SIMD3<Float>) -> Float { simd_length_squared(v) }
        // The larger of x and y, then of that and z, is the axis; the second is the larger of
        // what the axis displaced and the smaller of x and y.
        let (big, small) = squared(y) > squared(x) ? (y, x) : (x, y)
        let (major, displaced) = squared(z) > squared(big) ? (z, big) : (big, z)
        let second = squared(displaced) > squared(small) ? displaced : small
        let total: Float = major.x + major.y + major.z
        let axis = total != 0 ? major / total : SIMD3<Float>(0, 1, 0)
        return Fit(axis: axis, halfLength: total - (second.x + second.y + second.z), radius: second)
    }

    /// `fit` through `frame` (column vectors): the ends are the frame's images of ∓half length
    /// along the axis, the direction the frame's turn of the axis, the radius the length of the
    /// frame's turn of the radius vector (0x1401d4a40…0x1401d5099).
    init(_ fit: Fit, frame: simd_float4x4) {
        let linear = simd_float3x3(SIMD3<Float>(frame.columns.0.x, frame.columns.0.y, frame.columns.0.z),
                                   SIMD3<Float>(frame.columns.1.x, frame.columns.1.y, frame.columns.1.z),
                                   SIMD3<Float>(frame.columns.2.x, frame.columns.2.y, frame.columns.2.z))
        let origin = SIMD3<Float>(frame.columns.3.x, frame.columns.3.y, frame.columns.3.z)
        let half: SIMD3<Float> = fit.axis * fit.halfLength
        let start: SIMD3<Float> = linear * -half + origin
        let end: SIMD3<Float> = linear * half + origin
        let turned: SIMD3<Float> = linear * fit.axis
        let turnedLength = simd_length(turned)
        self.start = start
        direction = turnedLength > 0 ? turned / turnedLength : .zero
        length = simd_distance(start, end)
        radius = simd_length(linear * fit.radius)
    }

    init(start: SIMD3<Float>, direction: SIMD3<Float>, length: Float, radius: Float) {
        self.start = start
        self.direction = direction
        self.length = length
        self.radius = radius
    }

    /// A model's capsules this frame (0x1401d4580), with `world` the model's world matrix brought
    /// into the particles' space. With the `.mdl`'s per-bone block (`MDLSkeleton.boneVectors`: a
    /// box's half extents and its frame in the bone's space) one per bone, through the bone's
    /// posed world (`boneWorlds`, model space; a bone past them takes the identity, as a puppet's
    /// does in WE); without it one from the model's box when it isn't empty (max.x > min.x),
    /// centred on the box.
    static func capsules(boneVectors: [MDLSkeleton.BoneVector]?, boneWorlds: [simd_float4x4], bounds: MDLBounds,
                         world: simd_float4x4) -> [ParticleCapsule] {
        if let boneVectors, !boneVectors.isEmpty {
            return boneVectors.enumerated().map { index, bone in
                let fit = simd_length_squared(bone.vector) < 0.01 ? Fit.degenerate : Self.fit(bone.vector)
                let pose = index < boneWorlds.count ? boneWorlds[index] : matrix_identity_float4x4
                return ParticleCapsule(fit, frame: world * pose * bone.matrix)
            }
        }
        guard bounds.max.x > bounds.min.x else { return [] }
        let half: SIMD3<Float> = (bounds.max - bounds.min) * 0.5
        let centre: SIMD3<Float> = bounds.min + half
        var frame = world
        frame.columns.3 = world * SIMD4<Float>(centre, 1)
        return [ParticleCapsule(Self.fit(half), frame: frame)]
    }
}
