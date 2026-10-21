import Foundation
import simd

/// A scene camera-path file: one entry of `camera.paths` in scene.json, read the way
/// `wallpaper64.exe` reads it (0x140198e20; docs/models-plan.md §2.2):
///
/// ```json
/// {"paths": [{"duration": 30, "name": "", "disabled": false,
///             "transforms": [{"eye": "…", "center": "…", "up": "…", "zoom": 1, "timestamp": 0}, …]}]}
/// ```
///
/// The paths play in order and loop; `camerafade` fades each in and out. Playback is the camera's
/// (docs/models-plan.md M2); this is the file only.
struct WESceneCameraPathFile: Equatable {
    var paths: [WESceneCameraPath]

    init(paths: [WESceneCameraPath]) {
        self.paths = paths
    }

    /// WE's rules: `paths` must be an array; a path that isn't an object, is `disabled`, or has
    /// no `transforms` array or an empty one is skipped, and so is a disabled or non-object key.
    init(json: SceneJSON) {
        guard case .object(let root) = json, case .array(let list)? = root["paths"] else {
            paths = []
            return
        }
        paths = list.compactMap(WESceneCameraPath.init(json:))
    }

    init(data: Data) throws {
        self.init(json: try decodeTolerant(SceneJSON.self, from: data))
    }
}

/// One path of a `WESceneCameraPathFile`.
struct WESceneCameraPath: Equatable {
    /// A keyframe (0x2c bytes: t, eye, center, up, zoom).
    struct Key: Equatable {
        /// Seconds from the path's start. A key without a numeric `timestamp` sits at
        /// `i / (n − 1) · duration`, i its index and n the count of `transforms` (0x1401993c4).
        var timestamp: Float
        var eye: SIMD3<Float>
        var center: SIMD3<Float>
        var up: SIMD3<Float>
        /// `zoom`; 1 when missing (0x14019937c).
        var zoom: Float = 1
    }

    var name: String?
    /// `duration`, in seconds.
    var duration: Float
    var keys: [Key]

    init(name: String? = nil, duration: Float, keys: [Key]) {
        self.name = name
        self.duration = duration
        self.keys = keys
    }

    init?(json: SceneJSON) {
        guard case .object(let path) = json, case .array(let transforms)? = path["transforms"],
              !transforms.isEmpty else { return nil }
        if case .bool(true)? = path["disabled"] { return nil }
        name = path["name"]?.scalarString
        duration = path["duration"]?.cameraPathNumber ?? 0
        let count = transforms.count
        var keys: [Key] = []
        for (index, element) in transforms.enumerated() {
            guard case .object(let key) = element else { continue }
            if case .bool(true)? = key["disabled"] { continue }
            let timestamp = key["timestamp"]?.cameraPathNumber
                ?? (index == 0 ? 0 : Float(index) / Float(count - 1) * duration)
            keys.append(Key(timestamp: timestamp, eye: key["eye"].cameraPathVector,
                            center: key["center"].cameraPathVector, up: key["up"].cameraPathVector,
                            zoom: key["zoom"]?.cameraPathNumber ?? 1))
        }
        self.keys = keys
    }
}

/// A camera layer's path file (its `path`), read the way `wallpaper64.exe` reads it (0x1401f2030;
/// docs/models-plan.md §2.3):
///
/// ```json
/// {"paths": [{"id": 208, "name": "Left to Right", "visible": true,
///             "options": {"fps": 30, "length": 132, "mode": "single", "wraploop": false, "events": null},
///             "eye": {"c0": […], "c1": […], "c2": […]}, "center": {…}, "up": {…},
///             "fov": [{"frame": 0, "value": 50, …}, …], "zoom": null}]}
/// ```
///
/// Every channel is a timeline in the property-animation format (`SceneTimelineDocument`), all
/// sharing the path's `options`. Every library file but 3159348391's is `{"paths": []}`.
struct WECameraLayerPathFile: Equatable {
    var paths: [WECameraLayerPath]

    init(paths: [WECameraLayerPath]) {
        self.paths = paths
    }

    /// A path whose `options` aren't a timeline's (an object with numeric `fps` and `length`) is
    /// dropped: WE destroys it (0x1401f25c8). One that isn't an object is logged and skipped.
    init(data: Data, failures: DecodeFailureLog? = nil) throws {
        paths = try decodeTolerant(Root.self, from: data, failures: failures).paths.compactMap { $0 }
    }

    private struct Root: Decodable {
        var paths: [WECameraLayerPath?]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            paths = c.decodeElements(Element.self, forKey: AnyCodingKey(stringValue: "paths"), userInfo: decoder.userInfo)?
                .map(\.path) ?? []
        }
    }

    /// A path element; `path` is nil for one WE drops.
    private struct Element: Decodable {
        var path: WECameraLayerPath?

        init(from decoder: Decoder) throws {
            path = try WECameraLayerPath(decoder: decoder)
        }
    }
}

/// One path of a `WECameraLayerPathFile`.
struct WECameraLayerPath: Equatable {
    var id: Int?
    var name: String?
    /// `visible`, as authored: a hidden path isn't queued.
    var visible: SceneRawValue?
    /// `options`, shared by every channel.
    var options: SceneTimelineDocument.Options
    /// Vector channels (`c0`…`c2`). Nil when missing: the channel then follows the layer's
    /// transform (eye = its translation, centre = eye − 5·forward, up = its Y row).
    var eye: SceneTimelineDocument?
    var center: SceneTimelineDocument?
    var up: SceneTimelineDocument?
    /// Scalar channels (a keyframe list, or `c0`). Nil when missing: the layer's own `fov` and
    /// `zoom`. Perspective scenes animate `fov`, orthographic ones `zoom` (0x1401f3351).
    var fov: SceneTimelineDocument?
    var zoom: SceneTimelineDocument?

    /// Nil when `options` isn't a timeline's; throws when the path isn't an object.
    init?(decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let info = decoder.userInfo
        func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }
        guard case .object(let optionsObject)? = c.decodeLogged(SceneJSON.self, forKey: key("options"), userInfo: info),
              let options = Self.timeline(["options": .object(optionsObject)])?.options else { return nil }
        self.options = options
        id = c.decodeLogged(SceneRawValue.self, forKey: key("id"), userInfo: info)?.literalInt
        name = c.decodeLogged(SceneRawValue.self, forKey: key("name"), userInfo: info)?.literalString
        visible = c.decodeLogged(SceneRawValue.self, forKey: key("visible"), userInfo: info)
        func channel(_ name: String) -> SceneTimelineDocument? {
            var object: [String: SceneJSON]
            switch c.decodeLogged(SceneJSON.self, forKey: key(name), userInfo: info) {
            case .object(let channels)?: object = channels
            case .array(let keyframes)?: object = ["c0": .array(keyframes)]
            default: return nil
            }
            object["options"] = .object(optionsObject)
            return Self.timeline(object)
        }
        eye = channel("eye")
        center = channel("center")
        up = channel("up")
        fov = channel("fov")
        zoom = channel("zoom")
    }

    /// `SceneTimelineDocument(json:)` throws only for a value that isn't an object.
    private static func timeline(_ object: [String: SceneJSON]) -> SceneTimelineDocument? {
        try? SceneTimelineDocument(json: .object(object))
    }
}

private extension SceneJSON {
    /// A JSON number as WE's `asFloat`.
    var cameraPathNumber: Float? {
        if case .number(let number) = self { return Float(number) }
        return nil
    }
}

private extension Optional where Wrapped == SceneJSON {
    /// An `"x y z"` string; zero when missing or not a string [I: WE's default wasn't traced].
    var cameraPathVector: SIMD3<Float> {
        guard case .string(let text)? = self else { return .zero }
        let (x, y, z) = text.parseVector3()
        return SIMD3(Float(x), Float(y), Float(z))
    }
}
