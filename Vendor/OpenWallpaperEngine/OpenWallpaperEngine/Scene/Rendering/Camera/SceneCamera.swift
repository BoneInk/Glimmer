import Foundation
import simd

/// A camera before it becomes matrices: where it is, what it looks at, which way is up, and its
/// `zoom` (WE's scene camera at scene+0xf0: eye +0xf0, centre +0xfc, up +0x108, zoom +0x114).
struct SceneCameraPose: Equatable {
    var eye: SIMD3<Float>
    var center: SIMD3<Float>
    var up: SIMD3<Float>
    /// Orthographic scenes only [I: no reader of it on the perspective path].
    var zoom: Float = 1

    /// The view direction, WE's ctx+0x160.
    var forward: SIMD3<Float> { simd_normalize(center - eye) }

    /// The pose moved by camera shake: WE moves the eye and the centre by the same vector
    /// (0x140199580).
    func shaken(by offset: SIMD3<Float>) -> SceneCameraPose {
        var pose = self
        pose.eye += offset
        pose.center += offset
        return pose
    }
}

/// WE's camera matrices (docs/models-plan.md §2.2): right-handed views that look down −z, and
/// projections with **reversed depth**, 1 at the near plane and 0 at the far one, as WE draws
/// everywhere (§2.4). Every matrix is in simd's column-vector convention, whose memory is WE's
/// row-vector matrix (and glm's column-major one), so it uploads as it is.
enum SceneCamera {
    /// An orthographic scene's depth range, whatever `nearz`/`farz` say (0x140183df9).
    static let orthographicDepth: Float = 2000

    /// The perspective projection (0x140183a70 through the device's builder, vt+0x10 at
    /// 0x14009a370): vertical `fov` in degrees, `aspect` the render target's width over height.
    /// As WE's row-vector matrix:
    ///
    /// ```
    /// [cot/aspect 0 0 0; 0 cot 0 0; 0 0 n/(f−n) −1; 0 0 n·f/(f−n) 0]
    /// ```
    static func perspective(fovDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let cot = 1 / tan(fovDegrees * .pi / 360)
        let range = near / (far - near)
        return simd_float4x4(columns: (SIMD4(cot / max(aspect, 0.0001), 0, 0, 0),
                                       SIMD4(0, cot, 0, 0),
                                       SIMD4(0, 0, range, -1),
                                       SIMD4(0, 0, range * far, 0)))
    }

    /// The orthographic projection (the device's builder vt+0x18, 0x14009a630), reversed like the
    /// perspective one: m22 = −1/(n−f), m32 = −f/(n−f). An orthographic scene passes n = −2000 and
    /// f = 2000, so z = 2000 is the near plane.
    static func orthographic(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(2 / (right - left), 0, 0, 0),
                                SIMD4(0, 2 / (top - bottom), 0, 0),
                                SIMD4(0, 0, -1 / (near - far), 0),
                                SIMD4(-(right + left) / (right - left), -(top + bottom) / (top - bottom),
                                      -far / (near - far), 1)))
    }

    /// An orthographic scene's projection: `ortho(0, width, 0, height)` over z −2000…2000
    /// (0x140183e1b…0x140183e95), before the placement WE's fit modes add (the app's composite
    /// places the scene target instead).
    static func orthographic(size: SIMD2<Float>) -> simd_float4x4 {
        orthographic(left: 0, right: max(size.x, 1), bottom: 0, top: max(size.y, 1),
                     near: -orthographicDepth, far: orthographicDepth)
    }

    /// `lookAtRH` (0x14019d920): f = normalize(centre − eye), s = normalize(f × up), u = s × f.
    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(rows: [SIMD4(s, -simd_dot(s, eye)),
                                    SIMD4(u, -simd_dot(u, eye)),
                                    SIMD4(-f, simd_dot(f, eye)),
                                    SIMD4(0, 0, 0, 1)])
    }

    /// The effective fov's clamp (0x140189b1a).
    static func clampedFov(_ fov: Float) -> Float {
        let range = SceneCameraDefaults.fovRange
        return min(max(fov, Float(range.lowerBound)), Float(range.upperBound))
    }
}
