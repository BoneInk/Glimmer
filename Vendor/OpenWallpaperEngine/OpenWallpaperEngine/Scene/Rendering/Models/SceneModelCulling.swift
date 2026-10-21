import simd

/// WE's cull test for model objects (0x1402222f2…0x1401e5a10), split so the shadow pass tests
/// each caster's sphere against each view's planes without making either again per pair
/// (`SceneModelRenderer.isInsideFrustum` is the one-pair form).
enum SceneModelCulling {
    /// A model's bounding sphere in world space: the box's min and max corners through the world
    /// matrix, centre their midpoint, radius half their distance.
    struct Sphere {
        var centre: SIMD4<Float>
        var radius: Float

        init(_ bounds: MDLBounds, world: simd_float4x4) {
            let low = world * SIMD4<Float>(bounds.min, 1), high = world * SIMD4<Float>(bounds.max, 1)
            let middle = (low + high) / 2
            centre = SIMD4<Float>(middle.x, middle.y, middle.z, 1)
            radius = simd_length(SIMD3<Float>(high.x - low.x, high.y - low.y, high.z - low.z)) / 2
        }
    }

    /// A view-projection's six planes in WE's clip space (x, y in ±w, z in 0…w), each with its
    /// normal's length; a plane without a normal tests nothing.
    struct Frustum {
        private var planes: [(plane: SIMD4<Float>, length: Float)] = []

        init(_ viewProjection: simd_float4x4) {
            let m = viewProjection
            func row(_ i: Int) -> SIMD4<Float> { SIMD4<Float>(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i]) }
            let x = row(0), y = row(1), z = row(2), w = row(3)
            for plane in [w + x, w - x, w + y, w - y, z, w - z] {
                let length = simd_length(SIMD3<Float>(plane.x, plane.y, plane.z))
                if length > 0 { planes.append((plane, length)) }
            }
        }

        /// Kept unless the sphere lies wholly outside one of the planes; a sphere that isn't
        /// finite is kept.
        func contains(_ sphere: Sphere) -> Bool {
            guard sphere.radius.isFinite else { return true }
            for (plane, length) in planes where simd_dot(plane, sphere.centre) / length < -sphere.radius {
                return false
            }
            return true
        }
    }
}
