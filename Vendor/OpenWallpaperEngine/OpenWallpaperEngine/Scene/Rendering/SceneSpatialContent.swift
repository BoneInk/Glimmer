/// What a scene holds for WE's 3D runtime (docs/models-plan.md § Seams): the projection and
/// camera settings, the model objects, the camera layers and the scene camera paths, and the
/// draw-order mode. Built by `SceneSpatialContentBuilder`; nothing draws from it yet except
/// through `SceneCameraRigs`.
struct SceneSpatialContent: Equatable {
    var camera = SceneCameraSettings()
    /// The `camera` block's eye, centre and up, with WE's defaults for missing vectors.
    var staticEye = SceneCameraDefaults.eye
    var staticCenter = SceneCameraDefaults.center
    var staticUp = SceneCameraDefaults.up
    /// Every path of every `camera.paths` file, in order (they play in sequence and loop).
    var cameraPaths: [WESceneCameraPath] = []
    var cameraLayers: [SceneCameraLayerObject] = []
    var models: [SceneModelObject] = []
    var drawOrder = SceneDrawOrderMode.sceneOrder
    /// Every object's authored 3D transform, parent and bone attachment, with WE's defaults
    /// (`SceneTransformHierarchy3D`): the model matrices of a perspective scene, and of an
    /// orthographic scene's models and `perspective` objects.
    var transforms = SceneTransformHierarchy3D.empty
    /// `sortorder`, `castshadow`, `reflected` and `depthtest` of every object that authors one, by
    /// object id (`WESceneObject.renderValues`).
    var renderValues: [String: [SceneObjectRenderField: SceneRawValue]] = [:]
    /// Objects WE's factory keeps out of the planar reflection's list whatever their `reflected`
    /// (0x14018ff60: only models, particles, images, sprites and texts join it, 0x1401908f9): the
    /// shapes, the one kind of those that draws here.
    var unreflectable: Set<String> = []

    /// An object's `sortorder` (`customsortorder`'s key; WE reads it as an int, 0 unset).
    func sortOrder(of id: String) -> Int {
        guard let value = renderValues[id]?[.sortorder].flatMap(Self.literal) else { return 0 }
        switch value {
        case .number(let number): return number.isFinite ? Int(saturating: number) : 0
        case .string(let text): return Int(text) ?? Double(text).map { $0.isFinite ? Int(saturating: $0) : 0 } ?? 0
        case .bool(let flag): return flag ? 1 : 0
        case .object: return 0
        }
    }

    /// Whether an object draws into the planar reflection (`ScenePlanarReflection.isReflected`).
    func isReflected(_ id: String) -> Bool {
        !unreflectable.contains(id) && ScenePlanarReflection.isReflected(renderValues[id]?[.reflected])
    }

    /// A text object's `depthtest` (WE's enum: "disabled" is off, anything else on); nil when not
    /// authored.
    func depthTest(of id: String) -> Bool? {
        guard let value = renderValues[id]?[.depthtest].flatMap(Self.literal) else { return nil }
        switch value {
        case .string(let text): return text.lowercased() != "disabled"
        case .bool(let flag): return flag
        case .number(let number): return number == 0
        case .object: return nil
        }
    }

    /// A value's literal: a bound value's fallback (the content is rebuilt when a user property
    /// changes, with the bindings resolved).
    private static func literal(_ value: SceneRawValue) -> SceneRawValue? {
        if case .object(let object) = value { return object.value.flatMap(literal) }
        return value
    }
}
