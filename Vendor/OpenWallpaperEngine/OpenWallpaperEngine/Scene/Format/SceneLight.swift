import Foundation

/// A light's type: the `light` key of a scene object, parsed by `wallpaper64.exe`'s enum table
/// (0x14025e853…0x14025e9c9). The raw values are WE's.
enum WELightKind: Int, CaseIterable {
    case point = 0
    case spot = 1
    case tube = 2
    case directional = 3
    /// `point`: the legacy light. It fills one of 4 fixed slots of `g_LightsColorRadius` and
    /// `g_LightsPosition` and never reaches the `LightingV1` arrays (docs/lighting-plan.md §2.2).
    /// It is also the constructor's type (0x140190486) before `light` is read.
    case legacyPoint = 5

    /// `lpoint`, `lspot`, `ltube`, `ldirectional` or `point`. No other names exist.
    init?(name: String) {
        switch name {
        case "lpoint": self = .point
        case "lspot": self = .spot
        case "ltube": self = .tube
        case "ldirectional": self = .directional
        case "point": self = .legacyPoint
        default: return nil
        }
    }
}

/// A light object: a scene object with a `light` key (docs/lighting-plan.md §1.1). Its transform,
/// `parent`, `visible` and `parallaxDepth` are the object's own; this holds the light's fields in
/// their authored form. WE's defaults for missing fields are `SceneLightDefaults`; `SceneLight`
/// resolves the values.
struct WESceneLight: Decodable {
    var kind: WELightKind
    /// Every authored light field in its full form (literal, `user`, `script`, `animation`).
    var values: [SceneLightValueField: SceneRawValue] = [:]
    /// `cookie`: the texture a `usecookie` light projects, a path like `cookie/flashlight1`. The
    /// light parser reads it only for a cookie light (0x14025d0a5).
    var cookie: String?

    init(kind: WELightKind, values: [SceneLightValueField: SceneRawValue] = [:], cookie: String? = nil) {
        self.kind = kind
        self.values = values
        self.cookie = cookie
    }

    /// Decodes from the scene object's own container. Throws when the object has no `light` key.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let key = AnyCodingKey(stringValue: "light")
        let name = try container.decode(SceneRawValue.self, forKey: key).literalString ?? ""
        if let kind = WELightKind(name: name) {
            self.kind = kind
        } else {
            // WE's enum setter leaves the constructor's type in place [?: not traced].
            OWELog.error(.scene, "light type \"\(name)\" is not one of WE's; it stays WE's constructor default, the legacy point")
            kind = .legacyPoint
        }
        for field in SceneLightValueField.allCases {
            if let raw = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: field.rawValue),
                                                userInfo: decoder.userInfo) {
                values[field] = raw
            }
        }
        cookie = container.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "cookie"),
                                        userInfo: decoder.userInfo)?.literalString
    }
}
