import Foundation

struct WESceneObject: Decodable {
    // Common
    var id: Int?
    var parent: Int?
    var name: String?
    var origin: String?
    var scale: String?
    var angles: String?
    var visible: Bool?
    var visibleCondition: String?
    var visibleUserProperty: String?
    var effects: [WEObjectEffect]?
    var shape: String?

    // Text objects
    var textValue: String?
    var font: String?
    var pointsize: Double?
    var horizontalalign: String?
    var verticalalign: String?
    /// Authored as either a scalar ("32") or a pair ("32 32").
    var padding: String?
    var maxwidth: Double?
    var maxrows: Int?
    var limitwidth: Bool?
    var limitrows: Bool?
    var limituseellipsis: Bool?
    /// Dynamic screen anchor: none, center, top, topright, …
    var anchor: String?
    var blockalign: Bool?
    /// `opaquebackground` and `backgroundcolor` ("r g b"): a box behind the text.
    var opaquebackground: Bool?
    var backgroundcolor: String?
    /// `backgroundbrightness`: the box's colour is `backgroundcolor` times it (WE 2.8's editor
    /// writes 1 beside `opaquebackground`).
    var backgroundbrightness: Double?
    /// `spacing` (WE 2.8's letter spacing), "x y" or one number for both.
    var spacing: String?
    /// `outline`, `blur`, `dropshadow` and their values (`msdf` too).
    var textEffects = WETextEffectFields()

    // Image objects
    var image: String?       // path to model JSON
    var alpha: Double?
    var brightness: Double?
    var color: String?
    var colorBlendMode: Int?
    /// Sample the image with clamp-to-edge rather than WE's default repeat.
    var clampuvs: Bool?
    var size: String?
    var alignment: String?
    var solid: Bool?
    /// A cursor hit on this object stops cursor events from reaching objects under it, while it
    /// and its parents are visible (wallpaper64.exe 0x14018a86f; flag 0x4000). WE's default: false.
    var disablepropagation: Bool?
    var copybackground: Bool?
    var parallaxDepth: String?
    var perspective: Bool?

    /// `parallaxDepth`, or WE's default (1, 1) when the object leaves it out: WE's object
    /// constructor sets it to 1 1 (like `scale`), and its scene writer omits default values, so
    /// an absent key is a layer that moves with camera parallax.
    var parallaxDepthValue: (Double, Double, Double) {
        parallaxDepth?.parseVector3() ?? (1, 1, 0)
    }

    // Particle objects
    var particle: String?    // path to particle JSON
    var instanceoverride: WEInstanceOverride?

    /// An image object's `instance`: its material's per-object combos, textures and `usertextures`
    /// (a solid layer's `{"textures": ["util/white"], "usertextures": [{"name": "$mediaThumbnail", …}]}`).
    var instance: WEObjectEffectPass?

    // Sound objects (WE builds one when `"sound"` is not null)
    var sound: WESceneSound?

    // Light objects (WE builds one when `"light"` is not null)
    var light: WESceneLight?

    /// Model objects: WE builds one when `model` is a string, number or object, before any other
    /// kind (docs/models-plan.md §2.6).
    var model: WESceneModel?
    /// Camera layers: WE builds one when `camera` is a string (docs/models-plan.md §2.3).
    var cameraLayer: WESceneCameraLayer?
    /// `sortorder`, `castshadow`, `reflected` and `depthtest` in their authored form.
    var renderValues: [SceneObjectRenderField: SceneRawValue] = [:]
    /// `dependencies`, element by element.
    var dependencies: [WEObjectDependency]?
    /// `animationlayers`, element by element: a model's, or a puppet image's (the same parser,
    /// 0x1402230c0 and 0x1401fcc20). Empty when not authored.
    var animationLayers: [WEAnimationLayer] = []
    /// `attachment`: the name of an attachment point of the parent's model or puppet rig, which
    /// every object's base loader reads (0x1401de5b2; docs/models-plan.md §5.15).
    var attachment: String?

    /// Every value-bearing field in its full authored form (literal, `user`, `script`, `animation`).
    /// The typed fields above hold only the literal fallback.
    var values: [SceneObjectValueField: SceneRawValue] = [:]

    enum CodingKeys: String, CodingKey {
        case id, parent, name, origin, scale, angles, visible, effects, text, font, pointsize, horizontalalign, verticalalign
        case padding, maxwidth, maxrows, limitwidth, limitrows, limituseellipsis, anchor, blockalign, spacing
        case opaquebackground, backgroundcolor, backgroundbrightness
        case image, alpha, brightness, color, colorBlendMode, clampuvs, size, alignment, shape
        case solid, disablepropagation, copybackground, parallaxDepth, perspective
        case particle, instanceoverride, instance, sound, light
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for field in SceneObjectValueField.allCases {
            guard let key = CodingKeys(rawValue: field.rawValue) else { continue }
            if let raw = c.decodeLogged(SceneRawValue.self, forKey: key, userInfo: decoder.userInfo) {
                values[field] = raw
            }
        }
        // Fields that are always simple types
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        parent = try? c.decodeIfPresent(Int.self, forKey: .parent)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        image = try? c.decodeIfPresent(String.self, forKey: .image)
        particle = try? c.decodeIfPresent(String.self, forKey: .particle)
        instanceoverride = c.decodeLogged(WEInstanceOverride.self, forKey: .instanceoverride, userInfo: decoder.userInfo)
        instance = c.decodeLogged(WEObjectEffectPass.self, forKey: .instance, userInfo: decoder.userInfo)
        // `decodeNil` throws only for a missing key, which `contains` ruled out.
        if c.contains(.sound), (try? c.decodeNil(forKey: .sound)) == false {
            do {
                sound = try WESceneSound(from: decoder)
            } catch {
                OWELog.error(.scene, "sound object \(name ?? "?") can't be read: \(error)")
            }
        }
        // `decodeNil` throws only for a missing key, which `contains` ruled out.
        if c.contains(.light), (try? c.decodeNil(forKey: .light)) == false {
            do {
                light = try WESceneLight(from: decoder)
            } catch {
                OWELog.error(.scene, "light object \(name ?? "?") can't be read: \(error)")
            }
        }
        let keyed = try decoder.container(keyedBy: AnyCodingKey.self)
        model = WESceneModel(object: keyed, userInfo: decoder.userInfo)
        cameraLayer = WESceneCameraLayer(object: keyed, userInfo: decoder.userInfo)
        for field in SceneObjectRenderField.allCases {
            if let raw = keyed.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: field.rawValue),
                                            userInfo: decoder.userInfo) {
                renderValues[field] = raw
            }
        }
        dependencies = keyed.decodeElements(WEObjectDependency.self, forKey: AnyCodingKey(stringValue: "dependencies"),
                                            userInfo: decoder.userInfo)
        animationLayers = keyed.decodeElements(WEAnimationLayer.self, forKey: AnyCodingKey(stringValue: "animationlayers"),
                                               userInfo: decoder.userInfo) ?? []
        attachment = keyed.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "attachment"),
                                        userInfo: decoder.userInfo)?.literalString
        effects = c.decodeElements(WEObjectEffect.self, forKey: .effects, userInfo: decoder.userInfo)
        shape = try? c.decodeIfPresent(String.self, forKey: .shape)
        if let scriptedText = try? c.decode(WEScriptedProperty.self, forKey: .text) {
            textValue = scriptedText.stringValue
        } else {
            textValue = try? c.decodeIfPresent(String.self, forKey: .text)
        }
        pointsize = values[.pointsize]?.literalDouble
        // A text object's layout fields may be bound like any other (`{"script": …, "value": 1200}`,
        // `{"user": …, "value": …}`): each keeps its authored value, which a script or user
        // property then replaces.
        func literal(_ key: CodingKeys) -> SceneRawValue? {
            c.decodeLogged(SceneRawValue.self, forKey: key, userInfo: decoder.userInfo)
        }
        font = literal(.font)?.literalString
        horizontalalign = literal(.horizontalalign)?.literalString
        verticalalign = literal(.verticalalign)?.literalString
        padding = literal(.padding)?.literalString
        maxwidth = literal(.maxwidth)?.literalDouble
        maxrows = literal(.maxrows)?.literalInt
        limitwidth = literal(.limitwidth)?.literalBool
        limitrows = literal(.limitrows)?.literalBool
        limituseellipsis = literal(.limituseellipsis)?.literalBool
        anchor = literal(.anchor)?.literalString
        blockalign = literal(.blockalign)?.literalBool
        spacing = literal(.spacing)?.literalString
        opaquebackground = literal(.opaquebackground)?.literalBool
        backgroundcolor = literal(.backgroundcolor)?.literalString
        backgroundbrightness = literal(.backgroundbrightness)?.literalDouble
        // Optional: each field is read on its own, and an object without them has none.
        textEffects = (try? WETextEffectFields(from: decoder)) ?? WETextEffectFields()

        // Fields that may be simple values or {"script":..,"value":..} objects
        let scriptedOrigin = try? c.decode(WEScriptedProperty.self, forKey: .origin)
        origin = (try? c.decodeIfPresent(String.self, forKey: .origin)) ?? scriptedOrigin?.stringValue
        let scriptedScale = try? c.decode(WEScriptedProperty.self, forKey: .scale)
        scale = (try? c.decodeIfPresent(String.self, forKey: .scale)) ?? scriptedScale?.stringValue
        let scriptedAngles = try? c.decode(WEScriptedProperty.self, forKey: .angles)
        angles = (try? c.decodeIfPresent(String.self, forKey: .angles)) ?? scriptedAngles?.stringValue
        if let conditional = try? c.decode(WEConditionalBool.self, forKey: .visible) {
            visible = conditional.value
            visibleCondition = conditional.condition
            visibleUserProperty = conditional.property
        } else {
            visible = try? c.decodeIfPresent(Bool.self, forKey: .visible)
            visibleCondition = nil
            visibleUserProperty = nil
        }
        if let boundAlpha = try? c.decode(WEBoundScalar.self, forKey: .alpha) {
            alpha = boundAlpha.value
        } else {
            alpha = try? c.decodeIfPresent(Double.self, forKey: .alpha)
        }
        if let scriptedBrightness = try? c.decode(WEScriptedProperty.self, forKey: .brightness) {
            brightness = scriptedBrightness.stringValue.flatMap(Double.init)
        } else {
            brightness = try? c.decodeIfPresent(Double.self, forKey: .brightness)
        }
        if let scriptedColor = try? c.decode(WEScriptedProperty.self, forKey: .color) {
            color = scriptedColor.stringValue
        } else {
            color = try? c.decodeIfPresent(String.self, forKey: .color)
        }
        colorBlendMode = try? c.decodeIfPresent(Int.self, forKey: .colorBlendMode)
        clampuvs = c.decodeLogged(Bool.self, forKey: .clampuvs, userInfo: decoder.userInfo)
        let scriptedSize = try? c.decode(WEScriptedProperty.self, forKey: .size)
        size = (try? c.decodeIfPresent(String.self, forKey: .size)) ?? scriptedSize?.stringValue
        alignment = try? c.decodeIfPresent(String.self, forKey: .alignment)
        solid = try? c.decodeIfPresent(Bool.self, forKey: .solid)
        disablepropagation = c.decodeLogged(Bool.self, forKey: .disablepropagation, userInfo: decoder.userInfo)
        copybackground = try? c.decodeIfPresent(Bool.self, forKey: .copybackground)
        parallaxDepth = try? c.decodeIfPresent(String.self, forKey: .parallaxDepth)
        perspective = try? c.decodeIfPresent(Bool.self, forKey: .perspective)
    }
}

/// An effect instance on a scene object. `passes` holds every authored pass, in order.
struct WEObjectEffect: Decodable {
    let file: String
    let id: Int?
    let name: String?
    let visible: Bool?
    let visibleCondition: String?
    let visibleUserProperty: String?
    let passes: [WEObjectEffectPass]?

    enum CodingKeys: String, CodingKey { case file, id, name, visible, passes }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        file = try container.decode(String.self, forKey: .file)
        id = container.decodeLogged(Int.self, forKey: .id, userInfo: info)
        name = container.decodeLogged(String.self, forKey: .name, userInfo: info)
        switch container.decodeLogged(SceneJSON.self, forKey: .visible, userInfo: info) {
        case .object?:
            let conditional = container.decodeLogged(WEConditionalBool.self, forKey: .visible, userInfo: info)
            visible = conditional?.value
            visibleCondition = conditional?.condition
            visibleUserProperty = conditional?.property
        case .bool(let flag)?:
            (visible, visibleCondition, visibleUserProperty) = (flag, nil, nil)
        case .number(let number)?:
            (visible, visibleCondition, visibleUserProperty) = (number != 0, nil, nil)
        case .string(let text)?:
            (visible, visibleCondition, visibleUserProperty) = (!["false", "0"].contains(text.lowercased()), nil, nil)
        default:
            (visible, visibleCondition, visibleUserProperty) = (nil, nil, nil)
        }
        passes = container.decodeElements(WEObjectEffectPass.self, forKey: .passes, userInfo: info)
    }
}

/// Per-instance overrides for one pass of an effect.
struct WEObjectEffectPass: Decodable {
    /// Legacy view of the constants (number/string/script only), used by the current renderer.
    let constantshadervalues: [String: WEEffectConstant]?
    /// Every constant with its full authored form.
    let constants: [String: SceneRawValue]
    /// Texture slots; nil entries are kept so indices match the material.
    let textures: [String?]?
    let combos: [String: Int]?
    /// `usertextures` (e.g. `[null, {"name":"$mediaThumbnail","type":"system"}]`), kept raw.
    let usertextures: SceneJSON?

    enum CodingKeys: String, CodingKey { case constantshadervalues, textures, combos, usertextures }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let info = decoder.userInfo
        constants = c.decodeEntries(SceneRawValue.self, forKey: .constantshadervalues, userInfo: info) ?? [:]
        // Failures are already reported by `constants` above.
        constantshadervalues = try? c.decodeIfPresent([String: WEEffectConstant].self, forKey: .constantshadervalues)
        textures = c.decodeElements(String?.self, forKey: .textures, userInfo: info)
        combos = c.decodeEntries(Int.self, forKey: .combos, userInfo: info)
        usertextures = c.decodeLogged(SceneJSON.self, forKey: .usertextures, userInfo: info)
    }
}

struct WEEffectConstant: Decodable {
    let number: Double?
    let string: String?
    let script: String?

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            number = try? container.decodeIfPresent(Double.self, forKey: .value)
            string = try? container.decodeIfPresent(String.self, forKey: .value)
            script = try? container.decodeIfPresent(String.self, forKey: .script)
        } else {
            let container = try decoder.singleValueContainer()
            number = try? container.decode(Double.self)
            string = try? container.decode(String.self)
            script = nil
        }
    }

    enum CodingKeys: String, CodingKey { case value, script }
}

struct WEConditionalBool: Decodable {
    let value: Bool?
    let condition: String?
    let property: String?

    enum CodingKeys: String, CodingKey { case value, user }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = (try? container.decodeIfPresent(Bool.self, forKey: .value))
            ?? (try? container.decodeIfPresent(Int.self, forKey: .value)).map { $0 != 0 }
        if let property = try? container.decode(String.self, forKey: .user) {
            self.property = property
            condition = nil
        } else {
            let user = try? container.decode([String: String].self, forKey: .user)
            property = user?["name"]
            condition = user?["condition"]
        }
    }
}

/// A scalar authored as `{"value", …}`: its value. A timeline (`animation`) on it is the wallpaper
/// instance's (`SceneAnimationSet`, built from the document), a script the SceneScript runtime's.
struct WEBoundScalar: Decodable {
    @WEFlexibleDouble var value: Double?
}

/// A field authored as `{"value", "animation"?, "script"?}`: its value. Its script runs in the
/// wallpaper's SceneScript runtime (`SceneScriptSiteBuilder` finds it); its timeline in the
/// instance's `SceneAnimationSet` (docs/timeline-plan.md §2.1).
struct WEScriptedProperty: Decodable {
    let stringValue: String?

    enum CodingKeys: String, CodingKey { case value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? container.decode(String.self, forKey: .value) {
            stringValue = string
        } else if let number = try? container.decode(Double.self, forKey: .value) {
            stringValue = String(number)
        } else {
            stringValue = nil
        }
    }
}

/// A particle object's `instanceoverride`. Every field may be a literal or bound to a user
/// property or script; `values` keeps the authored forms.
struct WEInstanceOverride: Decodable {
    var id: Int?
    var values: [SceneInstanceOverrideField: SceneRawValue] = [:]

    /// Literal fallbacks, for callers that don't resolve bindings.
    var colorn: String? { values[.colorn]?.literalString }
    var size: Double? { values[.size]?.literalDouble }

    init(values: [SceneInstanceOverrideField: SceneRawValue] = [:], id: Int? = nil) {
        self.values = values
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: "id"), userInfo: decoder.userInfo)?
            .literalDouble.map { Int(saturating: $0) }
        for field in SceneInstanceOverrideField.allCases {
            if let raw = c.decodeLogged(SceneRawValue.self, forKey: AnyCodingKey(stringValue: field.rawValue),
                                        userInfo: decoder.userInfo) {
                values[field] = raw
            }
        }
    }
}

struct WEScriptValue: Codable {
    var script: String?
    var value: Double?

    init(script: String?, value: Double?) {
        self.script = script
        self.value = value
    }

    init(from decoder: Decoder) throws {
        // Can be just a number or an object with script+value
        if let container = try? decoder.singleValueContainer(),
           let num = try? container.decode(Double.self) {
            self.value = num
            self.script = nil
        } else if let container = try? decoder.singleValueContainer(),
                  let string = try? container.decode(String.self),
                  let num = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = num
            self.script = nil
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.script = try container.decodeIfPresent(String.self, forKey: .script)
            self.value = try container.decodeIfPresent(Double.self, forKey: .value)
                ?? container.decodeIfPresent(String.self, forKey: .value).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case script, value
    }
}

// MARK: - Model / Material
