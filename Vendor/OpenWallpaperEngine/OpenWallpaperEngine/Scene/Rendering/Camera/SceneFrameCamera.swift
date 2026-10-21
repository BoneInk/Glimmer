import simd

/// The scene camera for one frame (WE's ctx: view at +0x38, eye at +0x68, forward at +0x160):
/// what the draws of this frame see. `SceneMetalRenderer` builds it once per frame from its
/// `SceneCameraRig` and carries it on `BuiltinFrameContext.camera` (docs/models-plan.md § Seams).
struct SceneFrameCamera: Equatable {
    var view = matrix_identity_float4x4
    var projection = matrix_identity_float4x4
    /// `g_EyePosition`.
    var eye = SIMD3<Float>(0, 0, 1)
    /// The view direction (`g_ViewForward`; the light packer's and `transparentsorting`'s key).
    var forward = SIMD3<Float>(0, 0, -1)
    var up = SIMD3<Float>(0, 1, 0)
    /// The vertical fov in degrees, when the projection is a perspective one.
    var fieldOfView: Float?
    /// The projection's depth runs 1 at the near plane to 0 at the far one, as WE's does
    /// everywhere (§2.4): a depth buffer for it clears to 0 and compares GREATER.
    var reversedDepth = true
    /// `camerafade`'s alpha this frame (`materials/util/fade.json`); 0 draws no fade.
    var fade: Float = 0
    /// An orthographic scene's drawn space this frame: its zoom and its camera's view, in which
    /// the renderer draws the scene (`SceneOrthographicZoom`). None in a perspective scene.
    var drawnSpace = SceneOrthographicZoom.none

    var viewProjection: simd_float4x4 { projection * view }
    var isPerspective: Bool { fieldOfView != nil }
}

/// What a rig gets each frame.
struct SceneCameraRigInput {
    /// The scene's size in scene units.
    var sceneSize: SIMD2<Float>
    /// The scene target's width over height (WE's projection aspect, R+0x84 / R+0x88).
    var aspect: Float
    /// Seconds since the scene started, and since the last frame.
    var time: Double
    var deltaTime: Float
    /// Camera shake this frame (`SceneCameraShake`) for a camera that carries it: a perspective
    /// scene's. An orthographic scene's layers are drawn without the camera, so the renderer moves
    /// them by the shake's negative instead and this stays zero.
    var shake = SIMD3<Float>.zero
    /// A camera layer's own `visible` this frame (scripts included).
    var isVisible: (String) -> Bool = { _ in true }
    /// An object's own transform this frame where scripts or timelines set it
    /// (`SceneObjectMotion.local3D`); nil keeps the authored one. Camera layers and their parents
    /// are composed with it through `SceneSpatialContent.transforms`.
    var live: SceneTransformHierarchy3D.Live = { _ in nil }
    /// A camera layer's `fov` as a script set it.
    var layerFov: (String) -> Float? = { _ in nil }
    /// A camera layer's `zoom` as a script set it (`ICamera.zoom`).
    var layerZoom: (String) -> Float? = { _ in nil }
    /// `thisScene.fov`, `nearz`, `farz` and `camerafade` as scripts or timelines set them; nil
    /// keeps the scene's.
    var fov: Float?
    var nearZ: Float?
    var farZ: Float?
    var cameraFade: Bool?
    /// The scene's default camera as `thisScene.setCameraTransforms` set it; nil keeps the
    /// `camera` block.
    var scriptCamera: SceneCameraPose?
}

/// Where a frame's camera comes from: WE's camera layers, the scene's camera paths, or the
/// `camera` block (§2.2 "View"). One rig lives per wallpaper instance and keeps its own
/// playback state (paths, queues, fades), so it is a class.
protocol SceneCameraRig: AnyObject {
    func frameCamera(_ input: SceneCameraRigInput) -> SceneFrameCamera
    /// `ILayer.setParent` on the rig's copy of the parent graph (camera layers hang from it).
    func setParent(_ id: String, to parent: String?, attachment: String?)
}

extension SceneCameraRig {
    func setParent(_ id: String, to parent: String?, attachment: String?) {}
}

enum SceneCameraRigs {
    /// The rig for a content: WE's perspective camera (`ScenePerspectiveCameraRig`) for a
    /// perspective scene, the orthographic camera otherwise. Bound values resolve against the
    /// content's user properties.
    static func make(for content: SceneMetalContent) -> any SceneCameraRig {
        let values = LiveSceneValueContext(wallpaper: content.wallpaperKey)
        guard content.spatial.camera.projection.isPerspective else {
            return SceneOrthographicCameraRig(content.spatial, values: values)
        }
        return ScenePerspectiveCameraRig(content.spatial, values: values)
    }
}

/// An orthographic scene's camera (0x1401891a0): `ortho(0, width, 0, height)` over z −2000…2000,
/// and the eye WE reports afterwards, (width/2, height/2, 2000) (0x140189da0). The view is the
/// reset one (from the origin down −z, the identity) unless a camera layer or a camera path moves
/// it, as in a perspective scene (`ScenePerspectiveCameraRig`, steps 1 and 2): WE 2.8.42 plays an
/// editor-made path in an orthographic scene, its eye x 0 → 400 → 0 shifting a 1920-wide scene's
/// image 391 px and back (docs/models-plan.md §5.19). The view is then `lookAt(eye, centre, up)`,
/// and the camera's zoom the active layer's (its path's `zoom`, else its own) or the path key's.
/// WE scales the projection about its centre by `general.zoom` × the camera's zoom; the app draws
/// the scene in the drawn space of that zoom and view instead (`SceneOrthographicZoom`), which this
/// camera sees over a depth range and from an eye grown alike. Camera shake isn't in it: the
/// renderer moves the layers and lights by its negative instead, which leaves every eye-to-object
/// vector as WE's. The layer pass draws with its own matrix (`ImageMaterialRenderer.viewProjection`);
/// the models and the volumetrics draw with this one.
final class SceneOrthographicCameraRig: SceneCameraRig {
    /// `general.zoom`.
    let zoom: Float
    private let cameraFade: Bool
    private var paths: SceneCameraPaths
    private let layers: SceneCameraLayers?

    init(zoom: Float = 1) {
        self.zoom = zoom
        cameraFade = false
        paths = SceneCameraPaths([])
        layers = nil
    }

    init(_ spatial: SceneSpatialContent, values: SceneValueContext) {
        zoom = Float(spatial.camera.zoom)
        cameraFade = spatial.camera.cameraFade
        paths = SceneCameraPaths(spatial.cameraPaths)
        layers = spatial.cameraLayers.isEmpty ? nil
            : SceneCameraLayers(spatial.cameraLayers, transforms: spatial.transforms, values: values)
    }

    func setParent(_ id: String, to parent: String?, attachment: String?) {
        layers?.setParent(id, to: parent, attachment: attachment)
    }

    /// The camera layers' state (tests).
    var cameraLayers: SceneCameraLayers? { layers }

    func frameCamera(_ input: SceneCameraRigInput) -> SceneFrameCamera {
        let size = simd_max(input.sceneSize, SIMD2(1, 1))
        var pose: SceneCameraPose?
        let layerInput = SceneCameraLayers.FrameInput(deltaTime: input.deltaTime, isVisible: input.isVisible,
                                                      live: input.live, fov: input.layerFov, zoom: input.layerZoom)
        if let layer = layers?.update(layerInput) {
            pose = layer.pose
            pose?.zoom = layer.zoom
        } else if let path = paths.advance(by: input.deltaTime) {
            pose = path
        }
        let view = pose.map { SceneCamera.lookAt(eye: $0.eye, center: $0.center, up: $0.up) } ?? matrix_identity_float4x4
        let drawn = SceneOrthographicZoom(factor: zoom * (pose?.zoom ?? input.scriptCamera?.zoom ?? 1),
                                          sceneSize: input.sceneSize, view: view)
        let depth = drawn.orthographicDepth
        var camera = SceneFrameCamera(projection: SceneCamera.orthographic(left: 0, right: size.x, bottom: 0, top: size.y,
                                                                           near: -depth, far: depth),
                                      eye: SIMD3(size.x / 2, size.y / 2, depth))
        camera.drawnSpace = drawn
        if input.cameraFade ?? cameraFade { camera.fade = paths.fade }
        return camera
    }

    /// The zoom this frame: `general` × the camera's, as `thisScene.setCameraTransforms` set it
    /// (1 until a script does).
    static func frameZoom(general: Float, input: SceneCameraRigInput) -> SceneOrthographicZoom {
        SceneOrthographicZoom(factor: general * (input.scriptCamera?.zoom ?? 1), sceneSize: input.sceneSize)
    }
}

extension SceneScriptSceneState {
    /// The default camera as `thisScene.setCameraTransforms` left it (the eye, centre, up and
    /// zoom of the scene buffer), once a script has set any of them; nil before.
    var scriptCamera: SceneCameraPose? {
        let fields: [SceneScriptSceneField] = [.cameraEye, .cameraCenter, .cameraUp, .cameraZoom]
        guard fields.contains(where: owned.contains) else { return nil }
        func vector(_ field: SceneScriptSceneField) -> SIMD3<Float> {
            SIMD3(values[field.offset], values[field.offset + 1], values[field.offset + 2])
        }
        return SceneCameraPose(eye: vector(.cameraEye), center: vector(.cameraCenter), up: vector(.cameraUp),
                               zoom: values[SceneScriptSceneField.cameraZoom.offset])
    }
}
