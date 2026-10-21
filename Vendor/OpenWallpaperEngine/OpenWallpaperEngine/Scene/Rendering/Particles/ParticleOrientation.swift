import simd

/// A renderer's `orientation`: how its sprites (and a rope's ribbon) face. WE's shared renderer
/// parser (`wallpaper64.exe` 0x1401c22e0) reads `orientation` ("screen" 0, "upright" 1, "fixed" 2;
/// 0x1401c261b…0x1401c268b), `axis` and `flags`, and each draw (0x1402298b0) turns them into
/// `g_OrientationRight`, `g_OrientationUp` and `g_OrientationForward`, the axes the particle
/// shaders expand a sprite along in the system's space:
///
/// - screen: forward faces the camera; up is the object's up (the camera's with flag 1), made
///   perpendicular to forward.
/// - upright: up is the axis; right is the camera's view direction × up, so the sprite turns about
///   the axis to face the camera.
/// - fixed: forward is the axis, up the basis vector across it; the sprite lies in a fixed plane.
///
/// With `flags` bit 0 clear the axes turn with the object (its model matrix, 0x1402298f5); the
/// result is brought into the system's space and normalised. Right = up × forward and forward =
/// right × up keep the three right-handed.
struct ParticleOrientation: Equatable {
    enum Mode: Int { case screen = 0, upright, fixed }

    var mode = Mode.screen
    /// The axis basis (0x1401c2759…0x1401c297f): `axis` normalised, (0, 1, 0) for none; and the
    /// basis's third vector, axis × normalize(y × axis), (0, 0, −1) for an axis along y.
    var axis = SIMD3<Float>(0, 1, 0)
    var across = SIMD3<Float>(0, 0, -1)
    /// `flags` bit 0 clear: the axis and the screen's up turn with the object.
    var objectSpace = true

    /// The 2D scene camera: it looks down −z with y up (WE's camera forward and up, [engine+0x160]
    /// and [engine+0x178]).
    static let cameraForward = SIMD3<Float>(0, 0, -1)
    static let cameraUp = SIMD3<Float>(0, 1, 0)

    init() {}

    init(_ renderer: WEParticleRenderer?) {
        switch renderer?.orientation?.lowercased() {
        case "upright": mode = .upright
        case "fixed": mode = .fixed
        default: mode = .screen
        }
        objectSpace = ((renderer?.flags ?? 0) & 1) == 0
        let authored = ParticleDefaults.vector(renderer?.axis, .zero)
        guard authored != .zero else { return }
        axis = simd_normalize(authored)
        let first: SIMD3<Float>
        if axis.x == 0, axis.z == 0 {
            first = SIMD3(1, 0, 0)
            across = SIMD3(0, 0, -1)
        } else {
            first = simd_normalize(simd_cross(SIMD3(0, 1, 0), axis))
            across = simd_normalize(simd_cross(axis, first))
        }
    }

    /// `g_OrientationRight`, `g_OrientationUp` and `g_OrientationForward` as the shaders here read
    /// them: WE's axes in the system's space, through `linear`, the object's scale and rotation the
    /// particles are drawn with (`ParticleSystemRuntime.drawLinear`). The default (screen, object
    /// space) gives `linear`'s own columns and z. `cameraForward` and `cameraUp` are the frame
    /// camera's (`SceneFrameCamera`) in the space the particles are simulated in: the 2D camera's
    /// by default, a perspective camera's in 3D (`ParticleMaterialUniforms.Placement`).
    func axes(linear: simd_float2x2, cameraForward: SIMD3<Float> = ParticleOrientation.cameraForward,
              cameraUp: SIMD3<Float> = ParticleOrientation.cameraUp) -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let model = simd_float3x3(SIMD3(linear.columns.0, 0), SIMD3(linear.columns.1, 0), SIMD3(0, 0, 1))
        func turned(_ v: SIMD3<Float>) -> SIMD3<Float> { objectSpace ? model * v : v }
        var up: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>
        switch mode {
        case .screen:
            forward = -cameraForward
            up = objectSpace ? model * SIMD3(0, 1, 0) : cameraUp
            up -= simd_dot(up, forward) * forward
            right = simd_cross(up, forward)
        case .upright:
            up = turned(axis)
            right = simd_cross(cameraForward, up)
            forward = simd_cross(right, up)
        case .fixed:
            forward = turned(axis)
            up = turned(across)
            right = simd_cross(up, forward)
        }
        // Into the system's space, normalised, then drawn through the object's transform.
        func drawn(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let local = model.transpose * v
            let length = simd_length(local)
            return length > 1e-12 ? model * (local / length) : .zero
        }
        return (drawn(right), drawn(up), drawn(forward))
    }

    /// The quad axes a built-in sprite is drawn with (`ParticleSystemRuntime.spriteLinear`): right
    /// and up in the scene plane.
    func spriteLinear(linear: simd_float2x2) -> simd_float2x2 {
        let axes = axes(linear: linear)
        return simd_float2x2(SIMD2(axes.right.x, axes.right.y), SIMD2(axes.up.x, axes.up.y))
    }
}
