import Foundation

/// One entry of a model's (or a puppet image's) `animationlayers`, read the way `wallpaper64.exe`
/// reads it (parser 0x1402230c0, layer properties 0x14026c980; docs/models-plan.md §2.6):
///
/// ```json
/// {"animation": 273, "id": 322, "name": "Closed", "visible": true, "additive": false,
///  "blendin": false, "blendout": false, "rate": 1.0, "blend": {"value": 1, "animation": {…}},
///  "blendtime": 0.5}
/// ```
///
/// The clip's play mode, fps and frame count are the `.mdl`'s (MDLA), not the scene's. A layer
/// whose `animation` names no clip of the model makes no layer; that is the loader's check, since
/// it needs the model.
struct WEAnimationLayer: Decodable, Equatable {
    /// `animation`: the MDLA clip id. WE requires a JSON number (0x1402230fe) and reads it as an
    /// unsigned 64-bit id; nil when it isn't one, which makes no layer.
    var animation: UInt64?
    var id: Int?
    var name: String?
    /// `autosort`: insert before the trailing run of additive layers.
    var autosort: Bool?
    /// `index`: insert at `clamp(index, 0, count − 1)` (0x14022375c) when `autosort` isn't set.
    var index: Int?
    /// The bindable fields in their authored form (literal, `user`, `script`, `animation`):
    /// `rate` and `blend` are animatable floats (0x1401a4b00).
    var values: [SceneAnimationLayerValueField: SceneRawValue] = [:]
    /// Its index in the object's `animationlayers` as authored (decoded elements that fail are
    /// skipped, so it can differ from the position in a decoded list): where its timelines live
    /// (`SceneAnimationOwner.animationLayer`).
    var position: Int?

    init(animation: UInt64?, id: Int? = nil, name: String? = nil,
         values: [SceneAnimationLayerValueField: SceneRawValue] = [:]) {
        self.animation = animation
        self.id = id
        self.name = name
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        let info = decoder.userInfo
        position = decoder.codingPath.last?.intValue
        func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }
        if case .number(let number)? = c.decodeLogged(SceneJSON.self, forKey: key("animation"), userInfo: info),
           number >= 0, number < 0x1p64 {
            animation = UInt64(number)
        }
        id = c.decodeLogged(SceneRawValue.self, forKey: key("id"), userInfo: info)?.literalInt
        name = c.decodeLogged(SceneRawValue.self, forKey: key("name"), userInfo: info)?.literalString
        autosort = c.decodeLogged(SceneRawValue.self, forKey: key("autosort"), userInfo: info)?.literalBool
        index = c.decodeLogged(SceneRawValue.self, forKey: key("index"), userInfo: info)?.literalInt
        for field in SceneAnimationLayerValueField.allCases {
            if let raw = c.decodeLogged(SceneRawValue.self, forKey: key(field.rawValue), userInfo: info) {
                values[field] = raw
            }
        }
    }

    // Literal fallbacks with WE's defaults (the layer constructor 0x14026c680).
    var visible: Bool { values[.visible]?.literalBool ?? true }
    var additive: Bool { values[.additive]?.literalBool ?? false }
    var blendIn: Bool { values[.blendin]?.literalBool ?? false }
    /// Kept only for "single" clips (0x140223548).
    var blendOut: Bool { values[.blendout]?.literalBool ?? false }
    var rate: Double { values[.rate]?.literalDouble ?? 1 }
    var blend: Double { values[.blend]?.literalDouble ?? 1 }
    var blendTime: Double { values[.blendtime]?.literalDouble ?? 0.5 }
}
