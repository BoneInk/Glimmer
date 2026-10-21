import Foundation

/// A camera layer: a scene object whose `camera` is a string (dispatcher 0x14019065e; the value,
/// "default" in every library scene, isn't otherwise read). Its transform, `parent` and
/// `visible` (with its user condition) are the object's own: the active camera is the last
/// visible camera layer in scene order, it looks down its world −Z with +Y up
/// (docs/models-plan.md §2.3).
///
/// ```json
/// {"camera": "default", "fov": 31.14, "zoom": 1.0, "origin": "0 1.4 4", "angles": "-0.384 0 0",
///  "path": "scripts/camera_paths_203.json", "queuemode": "random",
///  "visible": {"user": {"condition": "0", "name": "camerastyle"}, "value": true}}
/// ```
struct WESceneCameraLayer: Equatable {
    /// `queuemode` (0x1401f347a…): how the layer moves from one path of its file to the next.
    enum QueueMode: Equatable {
        /// "random" (0): a bag of the visible paths (`SceneCameraLayers`).
        case random
        /// "sequential" (1): the next enabled path, wrapping.
        case sequential
    }

    /// The `camera` string.
    var camera: String
    /// `path`: a camera-path file (`WECameraLayerPathFile`), relative to the wallpaper.
    var path: String?
    /// `queuemode`; WE's default is `random` (0) [I: an unknown name keeps it].
    var queueMode: QueueMode = .random
    /// `fov` and `zoom` in their authored form (bindable: 3378346807 binds `fov`).
    var values: [SceneCameraLayerValueField: SceneRawValue] = [:]
    /// Whether the object authors `visible` (in any form). WE 2.8.42 plays a camera layer's paths
    /// only then: an editor-made path doesn't move the view of a layer without the key, in an
    /// orthographic scene or a perspective one, and does once `"visible": {"value": true}` is
    /// added (docs/models-plan.md §5.19; `tools/peer/requests/owe-beta3/models-open/519b-ortho-camera-path`).
    /// The layer is still the camera from its transform: library scenes without the key (3455121165,
    /// 3657770939, …) are framed by theirs.
    var authorsVisible = true

    init(camera: String, path: String? = nil, queueMode: QueueMode = .random,
         values: [SceneCameraLayerValueField: SceneRawValue] = [:], authorsVisible: Bool = true) {
        self.camera = camera
        self.path = path
        self.queueMode = queueMode
        self.values = values
        self.authorsVisible = authorsVisible
    }

    /// Decodes from the scene object's own container; nil when `camera` isn't a string.
    init?(object c: KeyedDecodingContainer<AnyCodingKey>, userInfo info: [CodingUserInfoKey: Any]) {
        func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }
        guard case .string(let camera)? = c.decodeLogged(SceneJSON.self, forKey: key("camera"), userInfo: info) else {
            return nil
        }
        self.camera = camera
        authorsVisible = c.contains(key("visible"))
        path = c.decodeLogged(SceneRawValue.self, forKey: key("path"), userInfo: info)?.literalString
        switch c.decodeLogged(SceneRawValue.self, forKey: key("queuemode"), userInfo: info)?.literalString {
        case "sequential"?: queueMode = .sequential
        default: queueMode = .random
        }
        for field in SceneCameraLayerValueField.allCases {
            if let raw = c.decodeLogged(SceneRawValue.self, forKey: key(field.rawValue), userInfo: info) {
                values[field] = raw
            }
        }
    }

    // Literal fallbacks with WE's defaults (the camera layer constructor: +0x2d8, +0x2dc).
    var fov: Double { values[.fov]?.literalDouble ?? SceneCameraDefaults.fov }
    var zoom: Double { values[.zoom]?.literalDouble ?? SceneCameraDefaults.zoom }
}
