import simd

/// One light's volume in one frame (`wallpaper64.exe` 0x140196ce0; docs/lighting-plan.md §2.8):
/// where its mesh goes, what the volumetric shaders read about it, and whether the camera is inside.
struct SceneVolumetricLight: Equatable {
    var shape: SceneVolumeMesh.Shape
    /// `g_AltModelMatrix` (ctx+0xa70): the light's projection (+0x338), world to light clip space.
    var lightProjection: simd_float4x4
    /// `g_AltViewProjectionMatrix` (ctx+0xab0): the mesh into the world.
    var volume: simd_float4x4
    /// `g_RenderVar0…4`.
    var renderVars: [SIMD4<Float>]
    /// The camera is inside the volume: `volumetrics_fullscreen` draws it (0x140198536).
    var cameraInside: Bool

    /// The spot's clip volume is a box when it has a cookie or a shadow (0x140185940), else a cone.
    static func shape(of light: SceneLight) -> SceneVolumeMesh.Shape {
        switch light.kind {
        case .point: return .sphere
        default: return light.useCookie || light.castShadow ? .box : .cone
        }
    }

    /// `camera` is the scene camera this frame (`SceneFrameCamera`), which WE's volumetrics draw
    /// through (ctx+0x930).
    init(light: SceneLight, world: simd_float4x4, camera: SceneFrameCamera) {
        shape = Self.shape(of: light)
        let position = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let forward = SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z)
        let color = light.color
        // 0x140198716…0x1401987f5. The shadow transform (+0x310) and a point's projection info
        // (+0x320) are the frame's shadow maps' (`SceneShadowFrame`), which `SceneVolumetrics` sets.
        var var3 = SIMD4<Float>.zero
        if light.kind == .point {
            lightProjection = matrix_identity_float4x4
            // A unit sphere scaled by the radius at the light's position (0x1401985d0) [?: whether
            // WE keeps the light's rotation there wasn't traced; a sphere doesn't show it].
            volume = simd_float4x4(diagonal: SIMD4(light.radius, light.radius, light.radius, 1))
            volume.columns.3 = SIMD4(position, 1)
        } else {
            lightProjection = Self.spotProjection(light: light, world: world, orthographic: !camera.isPerspective)
            volume = lightProjection.inverse
            // WE's row 0 of the world matrix as it stands, scale included (0x1401985b3).
            var3 = SIMD4(forward, 0)
        }
        renderVars = [
            .zero,
            SIMD4(light.radius * 0.99, cos(light.innerCone * .pi / 180), cos(light.outerCone * .pi / 180), light.intensity),
            SIMD4(position, light.density),
            var3,
            SIMD4(color, light.volumetricsExponent),
        ]
        cameraInside = Self.cameraInside(shape: shape, light: light, position: position, forward: forward,
                                         lightProjection: lightProjection, camera: camera)
    }

    /// A spot's projection (+0x338, 0x14025d420): a view down the light's local +X with local +Y
    /// up, then a square perspective of twice the outer cone, from 0.05 (1 in an orthographic
    /// scene) to the radius.
    static func spotProjection(light: SceneLight, world: simd_float4x4, orthographic: Bool) -> simd_float4x4 {
        let near: Float = orthographic ? 1 : 0.05
        let far = max(light.radius, near + 0.01)
        let axis = { (column: SIMD4<Float>) in SIMD3(column.x, column.y, column.z) }
        let position = axis(world.columns.3)
        let view = lookAt(eye: position, forward: axis(world.columns.0), up: axis(world.columns.1))
        return perspective(fieldOfView: 2 * light.outerCone * .pi / 180, aspect: 1, near: near, far: far) * view
    }

    /// Right-handed: the view looks down −z. WE's light view (0x14025d4b3…0x14025d8d3) normalises
    /// the world's axes: +x is the light's local +Z, +y its +Y, −z its +X.
    static func lookAt(eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(forward)
        let right = simd_normalize(simd_cross(f, up))
        let trueUp = simd_cross(right, f)
        return simd_float4x4(rows: [
            SIMD4(right, -simd_dot(right, eye)),
            SIMD4(trueUp, -simd_dot(trueUp, eye)),
            SIMD4(-f, simd_dot(f, eye)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    /// The device's perspective (vt+0x10), right-handed and reversed like the scene camera's
    /// (`SceneCamera.perspective`); `fieldOfView` in radians.
    static func perspective(fieldOfView: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        SceneCamera.perspective(fovDegrees: fieldOfView * 180 / .pi, aspect: aspect, near: near, far: far)
    }

    /// WE's test for the camera inside the volume (0x1401979c3…0x1401980e5), at a point just in
    /// front of the eye.
    static func cameraInside(shape: SceneVolumeMesh.Shape, light: SceneLight, position: SIMD3<Float>,
                             forward: SIMD3<Float>, lightProjection: simd_float4x4,
                             camera: SceneFrameCamera) -> Bool {
        switch shape {
        case .box:
            // 0.1 ahead, inside all six planes of the light's frustum (0x1401849e0).
            let clip = lightProjection * SIMD4(camera.eye + 0.1 * camera.forward, 1)
            return clip.w + clip.x >= 0 && clip.w - clip.x >= 0 && clip.w + clip.y >= 0 && clip.w - clip.y >= 0
                && clip.z >= 0 && clip.w - clip.z >= 0
        case .cone:
            // 0.2 ahead: past the apex, before the radius, and within the cone's radius there,
            // which is the far plane's (the distance between the unprojected far centre and far
            // top edge) scaled by the distance over the radius.
            let delta = camera.eye + 0.2 * camera.forward - position
            let direction = simd_normalize(forward)
            let along = simd_dot(direction, delta)
            let across = simd_length(delta - direction * along)
            let inverse = lightProjection.inverse
            let unproject = { (clip: SIMD4<Float>) -> SIMD3<Float> in
                let world = inverse * clip
                return SIMD3(world.x, world.y, world.z) / world.w
            }
            let farRadius = simd_distance(unproject(SIMD4(0, 1, SceneVolumeMesh.farDepth, 1)),
                                          unproject(SIMD4(0, 0, SceneVolumeMesh.farDepth, 1)))
            return along > 0 && light.radius >= along && along / light.radius * farRadius >= across
        case .sphere:
            let delta = camera.eye + 0.2 * camera.forward - position
            return light.radius * light.radius > simd_length_squared(delta)
        }
    }
}
