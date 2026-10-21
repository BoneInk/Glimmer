import simd

/// A perspective scene's camera, `wallpaper64.exe`'s camera update (0x1401891a0) and projection
/// (0x140183a70); docs/models-plan.md §2.1, §2.2:
///
/// 1. Every visible camera layer plays its paths; the last visible one is the camera, with its
///    (or its path's) fov (`SceneCameraLayers`).
/// 2. Without one: the `camera` block when the scene has no camera paths (or what
///    `thisScene.setCameraTransforms` set in its place), else the paths (`SceneCameraPaths`),
///    with the scene's `fov`.
/// 3. Camera shake moves the eye and the centre; the fov is clamped to 0.1…179.9.
/// 4. The view is `lookAtRH`; the projection is reversed-Z with `nearz`/`farz` and the target's
///    aspect. `general.zoom` and every other zoom do nothing here: WE 2.8.0.42 renders a
///    perspective scene identically at any zoom (docs/models-plan.md §5).
///
/// `camerafade` fades each scene camera path in and out whichever source is the camera, as WE
/// computes it from the paths' state alone (0x140180c1a).
final class ScenePerspectiveCameraRig: SceneCameraRig {
    private let settings: SceneCameraSettings
    private let staticPose: SceneCameraPose
    private var paths: SceneCameraPaths
    private let layers: SceneCameraLayers

    init(_ spatial: SceneSpatialContent, values: SceneValueContext) {
        settings = spatial.camera
        staticPose = SceneCameraPose(eye: spatial.staticEye, center: spatial.staticCenter, up: spatial.staticUp)
        paths = SceneCameraPaths(spatial.cameraPaths)
        layers = SceneCameraLayers(spatial.cameraLayers, transforms: spatial.transforms, values: values)
    }

    func setParent(_ id: String, to parent: String?, attachment: String?) {
        layers.setParent(id, to: parent, attachment: attachment)
    }

    /// The camera layers' state (tests).
    var cameraLayers: SceneCameraLayers { layers }

    func frameCamera(_ input: SceneCameraRigInput) -> SceneFrameCamera {
        let layerInput = SceneCameraLayers.FrameInput(deltaTime: input.deltaTime, isVisible: input.isVisible,
                                                      live: input.live, fov: input.layerFov, zoom: input.layerZoom)
        var pose: SceneCameraPose
        var fov = input.fov ?? Float(settings.fov)
        if let layer = layers.update(layerInput) {
            pose = layer.pose
            fov = layer.fov
        } else if let path = paths.advance(by: input.deltaTime) {
            pose = path
        } else {
            pose = input.scriptCamera ?? staticPose
        }
        pose = pose.shaken(by: input.shake)
        fov = SceneCamera.clampedFov(fov)
        let near = input.nearZ ?? Float(settings.nearZ), far = input.farZ ?? Float(settings.farZ)
        var camera = SceneFrameCamera(view: SceneCamera.lookAt(eye: pose.eye, center: pose.center, up: pose.up),
                                      projection: SceneCamera.perspective(fovDegrees: fov, aspect: input.aspect,
                                                                          near: near, far: far),
                                      eye: pose.eye, forward: pose.forward, up: pose.up, fieldOfView: fov)
        if input.cameraFade ?? settings.cameraFade { camera.fade = paths.fade }
        return camera
    }
}
