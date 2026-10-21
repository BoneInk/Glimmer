import Foundation

/// A model object: a scene object whose `model` is a string, a number or an object. WE's object
/// dispatcher looks at `model` before every other kind (0x14018ff7a, the type check at
/// 0x14019012e), so such an object is a model whatever else it carries. Its transform, `parent`,
/// `visible`, `solid`, `perspective` and the render fields (`SceneObjectRenderField`) are the
/// object's own, and so are its `animationlayers` (`WESceneObject.animationLayers`, which a puppet
/// image carries too); this holds the model's fields (docs/models-plan.md §2.6).
///
/// Not read by WE, so not here: per-mesh material overrides (a model's look is its `.mdl`'s
/// materials, `skin` picking one set), `alpha`, `color`, `brightness` and `instances`.
struct WESceneModel: Equatable {
    /// What `model` names.
    enum Source: Equatable {
        /// A `.mdl` path, relative to the wallpaper (cached per scene, ctx+0x1a60).
        case path(String)
        /// The id of a model already loaded (ctx+0x1bf8).
        case loadedID(Int)
        /// An object value; its load path wasn't traced [?]. No library scene has one.
        case object(SceneJSON)
    }

    var source: Source
    /// `attachment`: an exact name in the parent model's MDAT attachment list; the object then
    /// hangs from that bone (0x1402248c0). Nil: none (WE's −1).
    var attachment: String?
    /// The bindable model fields in their authored form.
    var values: [SceneModelValueField: SceneRawValue] = [:]

    init(source: Source, attachment: String? = nil, values: [SceneModelValueField: SceneRawValue] = [:]) {
        self.source = source
        self.attachment = attachment
        self.values = values
    }

    /// Decodes from the scene object's own container; nil when `model` doesn't make a model
    /// (missing, `null`, a bool or an array).
    init?(object c: KeyedDecodingContainer<AnyCodingKey>, userInfo info: [CodingUserInfoKey: Any]) {
        func key(_ name: String) -> AnyCodingKey { AnyCodingKey(stringValue: name) }
        switch c.decodeLogged(SceneJSON.self, forKey: key("model"), userInfo: info) {
        case .string(let path)?: source = .path(path)
        case .number(let id)?: source = .loadedID(Int(SceneTimelineDocument.asInt(id)))
        case .object(let object)?: source = .object(.object(object))
        default: return nil
        }
        attachment = c.decodeLogged(SceneRawValue.self, forKey: key("attachment"), userInfo: info)?.literalString
        for field in SceneModelValueField.allCases {
            if let raw = c.decodeLogged(SceneRawValue.self, forKey: key(field.rawValue), userInfo: info) {
                values[field] = raw
            }
        }
    }

    /// The `.mdl` path, when `model` is one.
    var path: String? {
        if case .path(let path) = source { return path }
        return nil
    }

    // Literal fallbacks with WE's defaults.
    /// `skin`: every mesh draws `materials[min(skin, M − 1)]` (0x140224dc4). Default 0.
    var skin: Int { values[.skin]?.literalInt ?? 0 }
    /// `rootmotion`: the factory turns it on (0x1401901b1).
    var rootMotion: Bool { values[.rootmotion]?.literalBool ?? true }
}
