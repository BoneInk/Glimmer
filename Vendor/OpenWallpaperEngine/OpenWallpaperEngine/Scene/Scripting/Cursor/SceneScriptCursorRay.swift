import simd

/// The ray WE's cursor pass tests objects with (wallpaper64.exe 0x14018e1a0, the scene camera's
/// vt+0xb0, called at 0x140189e5f): the cursor's window point, normalized with y up, unprojected
/// through the camera's view and projection at depth 0.5 (0x14019df90, `glm::unProject`).
///
/// - **Orthographic** (camera flag 0x8): from that point, with the eye's z, straight down the
///   view axis, `(0, 0, −1)`.
/// - **Perspective:** from the eye, towards that point, normalized.
///
/// No test checks the ray's parameter against 0, so only the line counts: an orthographic ray's z
/// never changes a hit, and the app starts it at z = 0.
struct SceneScriptCursorRay: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>

    /// An orthographic scene's ray through the scene point `point` (scene units, y up; the camera
    /// shake's offset included, as WE's shaken eye gives it).
    static func orthographic(through point: SIMD2<Float>) -> Self {
        Self(origin: SIMD3(point.x, point.y, 0), direction: SIMD3(0, 0, -1))
    }

    /// A perspective scene's ray: from `eye` through the cursor at `normalized` (0…1 across the
    /// scene, y up), unprojected through `viewProjection` (Metal's clip space; any depth in front of
    /// the eye gives the same direction). Nil when the matrix can't be inverted or the point lands
    /// on the eye.
    static func perspective(eye: SIMD3<Float>, viewProjection: simd_float4x4, normalized: SIMD2<Float>) -> Self? {
        guard abs(viewProjection.determinant) > 0 else { return nil }
        let clip = SIMD4<Float>(normalized.x * 2 - 1, normalized.y * 2 - 1, 0.5, 1)
        let world: SIMD4<Float> = viewProjection.inverse * clip
        guard world.w != 0 else { return nil }
        let point = SIMD3<Float>(world.x, world.y, world.z) / world.w
        let towards = point - eye
        let length = simd_length(towards)
        guard length > 0, length.isFinite else { return nil }
        return Self(origin: eye, direction: towards / length)
    }
}
