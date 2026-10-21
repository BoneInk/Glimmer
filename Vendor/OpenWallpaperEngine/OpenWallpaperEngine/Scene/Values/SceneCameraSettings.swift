import simd

/// WE's defaults for the camera when a scene doesn't author a field: the scene constructor
/// (0x140186d13), the camera layer's (+0x2d8, +0x2dc) and the `camera` block's (0x14018821c…);
/// docs/models-plan.md §2.1, §2.2.
enum SceneCameraDefaults {
    /// `general.fov` and a camera layer's `fov`: vertical, in degrees.
    static let fov: Double = 50
    /// `general.perspectiveoverridefov`: the fov of `perspective` layers in an orthographic scene.
    static let perspectiveOverrideFov: Double = 95
    /// `general.nearz` / `farz`: perspective only; an orthographic scene is always z −2000…2000.
    static let nearZ: Double = 0.1
    static let farZ: Double = 10000
    /// `general.zoom` and a camera layer's `zoom`: orthographic only; a perspective scene
    /// ignores them (WE 2.8.0.42's captures, docs/models-plan.md §5).
    static let zoom: Double = 1
    /// The effective fov is clamped to this range (0x140189b1a).
    static let fovRange: ClosedRange<Double> = 0.1...179.9
    /// The `camera` block's eye, centre and up.
    static let eye = SIMD3<Float>(2, 2, 2)
    static let center = SIMD3<Float>(0, 0, 0)
    static let up = SIMD3<Float>(0, 1, 0)
}

/// `general`'s camera and draw-order fields and `orthogonalprojection`, resolved against the user
/// properties (docs/models-plan.md §2.1, §2.4). Built once per content; the camera (M2) and the
/// draw loop (M4) read it.
struct SceneCameraSettings: Equatable {
    var projection = WESceneProjection.perspective
    var fov = SceneCameraDefaults.fov
    var perspectiveOverrideFov = SceneCameraDefaults.perspectiveOverrideFov
    var nearZ = SceneCameraDefaults.nearZ
    var farZ = SceneCameraDefaults.farZ
    var zoom = SceneCameraDefaults.zoom
    /// `camerafade`: fade each scene camera path in and out. On by default (scene flag bit 2).
    var cameraFade = true
    /// `transparentsorting` (flag bit 12) and `customsortorder` (bit 13), both off by default.
    var transparentSorting = false
    var customSortOrder = false

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func double(_ field: SceneGeneralValueField, _ fallback: Double) -> Double {
            general.value(field, in: context).map { Double($0.float) } ?? fallback
        }
        func flag(_ field: SceneGeneralValueField, _ fallback: Bool) -> Bool {
            general.value(field, in: context).map { $0.float != 0 } ?? fallback
        }
        projection = general.projection
        fov = double(.fov, SceneCameraDefaults.fov)
        perspectiveOverrideFov = double(.perspectiveoverridefov, SceneCameraDefaults.perspectiveOverrideFov)
        nearZ = double(.nearz, SceneCameraDefaults.nearZ)
        farZ = double(.farz, SceneCameraDefaults.farZ)
        zoom = double(.zoom, SceneCameraDefaults.zoom)
        cameraFade = flag(.camerafade, true)
        transparentSorting = flag(.transparentsorting, false)
        customSortOrder = flag(.customsortorder, false)
    }

    /// The fov before any camera layer or path (0x1401892a0): `fov` in a perspective scene,
    /// `perspectiveoverridefov` in an orthographic one, clamped.
    var sceneFov: Double {
        let fov = projection.isPerspective ? fov : perspectiveOverrideFov
        return min(max(fov, SceneCameraDefaults.fovRange.lowerBound), SceneCameraDefaults.fovRange.upperBound)
    }
}
