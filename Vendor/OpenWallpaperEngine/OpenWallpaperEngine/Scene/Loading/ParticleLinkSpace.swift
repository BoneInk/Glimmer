import simd

/// The part of a child system's `children` links that its 2D emitter can't carry: each link's
/// `origin.z`, `scale.z` and the turn its `angles.x` and `angles.y` give in depth. WE builds a
/// link's local matrix from all three vectors (`wallpaper64.exe` 0x1401d09ea…0x1401d0d36) and draws
/// the child through its parent's model matrix times it. Here a child is simulated in the scene
/// plane through its 2D emitter (`ParticleChildLink.emitter`, which keeps the x and y of the turned
/// axes, as a tilted layer does), and a perspective scene draws it through
/// `world3D · space · embed(object's 2D world)⁻¹` (`SceneMetalRenderer.particleSpaceModel`); `space`
/// is the identity when every link lies in the plane.
///
/// A link's depth turn pivots on where the link sits, which an event child's instances don't
/// share (each sits on its parent particle): below an event link, only the depth offset and the
/// depth scale (which don't depend on the pivot) are carried; the turn stays the 2D emitter's.
struct ParticleLinkSpace: Equatable {
    /// From the plane the 2D links place the particles in to where their 3D links put them.
    private(set) var space = matrix_identity_float4x4
    /// The 2D links' product so far, while every link is static.
    private var planar = SceneAffineTransform.identity
    private var placed = true

    static let identity = ParticleLinkSpace()

    /// This chain followed by a link of `kind` with the local transform `local`.
    func appending(_ local: SceneLocalTransform3D, kind: ParticleChildLink.Kind) -> ParticleLinkSpace {
        var next = self
        let flat = SceneAffineTransform(local.planar)
        let flatMatrix = Self.embedded(flat)
        if kind == .static, placed, abs(simd_determinant(flat.linear)) > 1e-12 {
            let link = local.matrix * flatMatrix.inverse
            let parent = Self.embedded(planar)
            next.space = space * parent * link * parent.inverse
            next.planar = planar * flat
        } else {
            var depth = matrix_identity_float4x4
            depth.columns.2.z = local.scale.z
            depth.columns.3.z = local.origin.z
            next.space = space * depth
            next.placed = false
        }
        return next
    }

    /// A 2D transform as a 4×4 one, z untouched.
    static func embedded(_ transform: SceneAffineTransform) -> simd_float4x4 {
        let x = transform.linear.columns.0, y = transform.linear.columns.1
        return simd_float4x4(columns: (SIMD4(x.x, x.y, 0, 0), SIMD4(y.x, y.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(transform.translation.x, transform.translation.y, 0, 1)))
    }
}
