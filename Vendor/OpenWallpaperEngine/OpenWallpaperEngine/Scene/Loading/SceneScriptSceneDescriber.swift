import Foundation

/// The object model's view of a scene document (docs/scenescript-plan.md WP7, WP11): every object
/// with its transform, colour, strings, particle instance overrides, effects with their materials'
/// constants, and animations, the way `SceneScriptObjectHost` describes a loaded scene. Values are
/// user-resolved (a bound value takes the user property's current value) and in the object table's
/// units, which are scene.json's (angles in radians). The renderer keeps them current each frame
/// afterwards; this is what scripts see before the first frame and what `createLayer` layers
/// start from.
struct SceneScriptSceneDescriber {
    /// The user properties bound values resolve against.
    var userProperties: SceneScriptUserProperties
    /// Reads a file of the wallpaper (its package, folder, Workshop dependencies, WE's assets); nil
    /// when absent. Used for texture animations and `createLayer(assetPath)`.
    var file: (String) -> Data?

    /// Where `createLayer` layers' ids start: past any id a scene uses.
    static let firstCreatedID = 1_000_000_000

    /// The scene's objects in document order, its `general` settings and scene-level animations.
    func scene(_ document: SceneJSON) -> SceneScriptSceneDescription {
        guard case .object(let root) = document else { return SceneScriptSceneDescription(objects: []) }
        var description = SceneScriptSceneDescription(objects: Self.objects(of: document).enumerated().map {
            object($0.element, id: Self.objectID($0.element, index: $0.offset))
        })
        if case .object(let general)? = root["general"] {
            for field in SceneScriptSceneField.allCases where !field.isCamera {
                if let components = components(general[field.rawValue], count: field.components) {
                    description.settings[field] = components
                }
                if let animation = Self.animation(general[field.rawValue], property: "general.\(field.rawValue)") {
                    description.animations.append(animation)
                }
            }
        }
        for (field, value) in Self.defaultCamera(root) { description.settings[field] = value }
        return description
    }

    /// `getCameraTransforms()`'s camera before a script sets it: WE's default camera, the `camera`
    /// block with its defaults (eye (2, 2, 2), centre 0, up +y, zoom 1), which an orthographic
    /// scene without camera paths resets to the origin looking down −z (0x14018866b). Camera
    /// layers and paths don't move it (docs/models-plan.md §2.3 "Script camera").
    static func defaultCamera(_ root: [String: SceneJSON]) -> [SceneScriptSceneField: [Float]] {
        var eye = SceneCameraDefaults.eye, center = SceneCameraDefaults.center, up = SceneCameraDefaults.up
        var hasPaths = false
        if case .object(let camera)? = root["camera"] {
            func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
                guard case .string(let text)? = camera[key] else { return fallback }
                let (x, y, z) = text.parseVector3()
                return SIMD3(Float(x), Float(y), Float(z))
            }
            eye = vector("eye", eye)
            center = vector("center", center)
            up = vector("up", up)
            if case .array(let paths)? = camera["paths"] { hasPaths = !paths.isEmpty }
        }
        var projection = WESceneProjection.perspective
        if case .object(let general)? = root["general"] { projection = WESceneProjection(json: general["orthogonalprojection"]) }
        if !projection.isPerspective, !hasPaths {
            eye = .zero
            center = SIMD3(0, 0, -1)
            up = SIMD3(0, 1, 0)
        }
        return [.cameraEye: [eye.x, eye.y, eye.z], .cameraCenter: [center.x, center.y, center.z],
                .cameraUp: [up.x, up.y, up.z], .cameraZoom: [1]]
    }

    /// The objects of a document (`scene.json` or an asset pack's `assets.json`).
    static func objects(of document: SceneJSON) -> [[String: SceneJSON]] {
        guard case .object(let root) = document, case .array(let entries)? = root["objects"] else { return [] }
        return entries.map { entry in
            if case .object(let fields) = entry { return fields }
            return [:]
        }
    }

    /// An object's scene.json `id`, else its index: the id `SceneObjectIdentity` gives it, which
    /// the renderer keys its layers by.
    static func objectID(_ fields: [String: SceneJSON], index: Int) -> Int {
        if case .number(let number)? = fields["id"], number.isFinite, number == number.rounded(), abs(number) < 1e15 {
            return Int(number)
        }
        return index
    }

    /// The layer `thisScene.createLayer` asked for, with the scene.json-form object it is made
    /// from (the renderer builds the layer from that): an asset of the wallpaper (a model or an
    /// object JSON), a configuration in scene.json form, or a copy of `copying` (the source
    /// layer's authored configuration). Nil when nothing can be made from it; `createLayer` then
    /// returns null, as in WE.
    func layer(_ source: SceneScriptLayerSource, id: Int,
               copying: [String: SceneJSON]?) -> (description: SceneScriptObjectDescription, json: [String: SceneJSON])? {
        var json: [String: SceneJSON]
        switch source {
        case .asset(let written, let workshopID):
            // Under the script's Workshop item first, then as written (RF1).
            let found = SceneScriptLayerSource.assetPaths(written, workshopID: workshopID).lazy
                .compactMap { path in file(path).map { (path, $0) } }.first
            guard let (path, data) = found else { return nil }
            // WE picks the kind by the asset's folder (scenescript64.dll 0x1816342a8): a file under
            // `sounds/` is a sound object, which plays it.
            if path.replacingOccurrences(of: "\\", with: "/").lowercased().hasPrefix("sounds/") {
                json = ["sound": .string(path), "name": .string(path)]
                break
            }
            let object: SceneJSON
            do {
                object = try decodeTolerant(SceneJSON.self, from: data)
            } catch {
                OWELog.error(.script, "createLayer('\(written)'): \(path) is not JSON: \(error)")
                return nil
            }
            guard case .object(let fields) = object else { return nil }
            // A model file becomes an image object showing it, a particle definition a particle
            // system; an object file is used as it is.
            if fields["image"] != nil || fields["text"] != nil || fields["particle"] != nil {
                json = fields
            } else if fields["emitter"] != nil || fields["renderer"] != nil {
                json = ["particle": .string(path), "name": .string(path)]
            } else {
                json = ["image": .string(path), "name": .string(path)]
            }
        case .configuration(let text):
            guard case .object(let fields)? = try? decodeTolerant(SceneJSON.self, from: Data(text.utf8)) else {
                // Optional: WE's stringifyConfig always produces a JSON object; anything else makes no layer.
                return nil
            }
            json = fields
        case .copy:
            guard let copying else { return nil }
            json = copying
        }
        json["id"] = .number(Double(id))
        return (object(json, id: id), json)
    }

    /// One object as the object model sees it.
    func object(_ json: [String: SceneJSON], id: Int) -> SceneScriptObjectDescription {
        let kind = Self.kind(of: json)
        var name = ""
        if case .string(let text)? = json["name"] { name = text }
        var parentID: Int?
        if case .number(let parent)? = json["parent"], parent.isFinite, abs(parent) < 1e15 { parentID = Int(parent) }
        var description = SceneScriptObjectDescription(kind: kind, id: id, name: name, parentID: parentID)
        if kind == .text {
            // WE's text constructor's values for what the object leaves out (`WETextDefaults`).
            description.values[.pointsize] = [Float(WETextDefaults.pointSize)]
            description.values[.padding] = [WETextDefaults.padding]
            description.values[.maxwidth] = [Float(WETextDefaults.maxWidth)]
            description.values[.maxrows] = [Float(WETextDefaults.maxRows)]
        }
        for field in SceneScriptObjectField.allCases where field.group == .layer && !field.isReadOnly {
            // scene.json writes `angles` in radians, the table's unit (scripts see degrees).
            if let components = components(json[field.rawValue], count: field.components) { description.values[field] = components }
        }
        if let size = components(json["size"], count: 2) { description.values[.size] = size }
        // WE starts particle systems playing; `isPlaying()` reads this until a script changes it.
        if kind == .particle { description.values[.playing] = [1] }
        // A sound plays from load unless `startsilent` (wallpaper64.exe 0x1401f4f20); the renderer
        // keeps it current from then on.
        if kind == .sound {
            var silent = false
            if case .bool(let flag)? = json["startsilent"] { silent = flag }
            description.values[.playing] = [silent ? 0 : 1]
        }
        if case .object(let overrides)? = json["instanceoverride"] {
            let instanceFields: [String: SceneScriptObjectField] = [
                "alpha": .instanceAlpha, "size": .instanceSize, "count": .instanceCount, "speed": .instanceSpeed,
                "lifetime": .instanceLifetime, "rate": .instanceRate, "colorn": .instanceColorn,
            ]
            for (key, field) in instanceFields {
                if let numbers = numbers(overrides[key]), let first = numbers.first { description.values[field] = [first] }
            }
            for index in 0..<8 {
                guard let field = SceneScriptObjectField(rawValue: "controlpoint\(index)"),
                      let point = components(overrides["controlpoint\(index)"], count: 3) else { continue }
                description.values[field] = point
            }
        }
        for field in SceneScriptStringField.allCases where field != .name {
            if let text = string(json[field.rawValue]) { description.strings[field] = text }
        }
        if case .array(let effects)? = json["effects"] {
            description.effects = effects.compactMap { entry in
                guard case .object(let effect) = entry else { return nil }
                return self.effect(effect)
            }
        }
        for key in json.keys.sorted() where key != "effects" && key != "instanceoverride" {
            if let animation = Self.animation(json[key], property: key) { description.animations.append(animation) }
        }
        if case .object(let overrides)? = json["instanceoverride"] {
            for key in overrides.keys.sorted() {
                if let animation = Self.animation(overrides[key], property: "instanceoverride.\(key)") {
                    description.animations.append(animation)
                }
            }
        }
        // An animation layer's timelines (`rate`, `blend`) belong to the object: their events go to
        // its scripts, and `getAnimationLayer(name).getAnimation(name)` finds them by the layer's
        // index in `animationlayers` (`objects-layers.js`).
        if case .array(let layers)? = json["animationlayers"] {
            for (index, entry) in layers.enumerated() {
                guard case .object(let layer) = entry else { continue }
                for key in layer.keys.sorted() {
                    let property = SceneAnimationSite(owner: .animationLayer(object: id, layer: index), key: key).scriptProperty
                    if let animation = Self.animation(layer[key], property: property) { description.animations.append(animation) }
                }
            }
        }
        if kind == .image, case .string(let image)? = json["image"] {
            description.textureAnimation = textureAnimation(model: image)
            description.videoDuration = videoDuration(model: image)
            // A video texture plays from the start (`IVideoTexture.isPlaying()`).
            if description.videoDuration != nil { description.values[.playing] = [1] }
            (description.rig, description.cursorShape) = puppetImage(image, animationLayers: json["animationlayers"])
        }
        if kind == .model, case .string(let model)? = json["model"] {
            (description.rig, description.cursorShape) = modelObject(model, animationLayers: json["animationlayers"])
        }
        description.initialConfigurationJSON = Self.jsonText(.object(json))
        return description
    }

    /// The object kind scripts see (`ILayer` parts).
    static func kind(of json: [String: SceneJSON]) -> SceneScriptObjectDescription.Kind {
        if json["text"] != nil { return .text }
        if json["particle"] != nil { return .particle }
        if json["sound"] != nil { return .sound }
        if json["light"] != nil { return .light }
        if case .string(let model)? = json["model"], model.hasSuffix(".mdl") { return .model }
        // A script's model data (`createLayer({model: modelData})` writes its token).
        if case .number? = json["model"] { return .model }
        if json["image"] != nil { return .image }
        return .group
    }

    // MARK: - Values

    /// A field's value with user bindings resolved: `{"user", "value"}` takes the user property's
    /// current value (a flag for a `{"name", "condition"}` binding), otherwise the innermost literal.
    func resolved(_ field: SceneJSON?) -> SceneJSON? {
        guard case .object(let fields)? = field else { return field }
        if let user = SceneScriptUserReference(fields["user"]), let current = userProperties.value(of: user.name) {
            if let condition = user.condition { return .bool(current.scalarString == condition) }
            return current
        }
        return resolved(fields["value"])
    }

    /// The numbers of a field: vector text, a number or a flag. Nil for anything else.
    func numbers(_ field: SceneJSON?) -> [Float]? {
        switch resolved(field) {
        case .number(let number)?: return [Float(number)]
        case .bool(let flag)?: return [flag ? 1 : 0]
        case .string(let text)?: return SceneScriptSceneValue.numbers(in: text)?.map(Float.init)
        default: return nil
        }
    }

    /// `count` numbers of a field the way WE's converter reads a vector (SceneScriptSceneValue):
    /// one number fills every component, missing components are 0, extra ones are dropped.
    func components(_ field: SceneJSON?, count: Int) -> [Float]? {
        guard let numbers = numbers(field), !numbers.isEmpty else { return nil }
        if numbers.count == 1 { return Array(repeating: numbers[0], count: count) }
        return (0..<count).map { $0 < numbers.count ? numbers[$0] : 0 }
    }

    private func string(_ field: SceneJSON?) -> String? {
        if case .string(let text)? = resolved(field) { return text }
        return nil
    }

    private func effect(_ json: [String: SceneJSON]) -> SceneScriptObjectDescription.Effect {
        var file = ""
        if case .string(let path)? = json["file"] { file = path }
        let folder = URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
        var name = folder
        if case .string(let custom)? = json["name"], !custom.isEmpty { name = custom }
        let visible = numbers(json["visible"]).map { $0.first != 0 } ?? true
        var materials: [SceneScriptObjectDescription.Material] = []
        if case .array(let passes)? = json["passes"] {
            materials = passes.map { entry in
                guard case .object(let pass) = entry, case .object(let constants)? = pass["constantshadervalues"] else {
                    return SceneScriptObjectDescription.Material(constants: [])
                }
                var material = SceneScriptObjectDescription.Material(constants: constants.keys.sorted().compactMap { key in
                    guard let numbers = numbers(constants[key]) else { return nil }
                    return SceneScriptObjectDescription.Constant(name: key, value: Array(numbers.prefix(4)))
                })
                material.animations = constants.keys.sorted().compactMap { Self.animation(constants[$0], property: $0) }
                return material
            }
        }
        var effect = SceneScriptObjectDescription.Effect(name: name, visible: visible, materials: materials)
        effect.animations = Self.animation(json["visible"], property: "visible").map { [$0] } ?? []
        return effect
    }

    // MARK: - Animations

    /// A property's timeline animation (`{"value", "animation": {"c0": keys, "options": {…}}}`).
    static func animation(_ field: SceneJSON?, property: String) -> SceneScriptAnimationDescription? {
        guard case .object(let fields)? = field, case .object(let animation)? = fields["animation"] else { return nil }
        var options: [String: SceneJSON] = [:]
        if case .object(let found)? = animation["options"] { options = found }
        var fps = 30.0, length = 0, startPaused = false, name = ""
        if case .number(let value)? = options["fps"] { fps = value }
        if case .number(let value)? = options["length"], value.isFinite { length = Int(max(0, min(value, 1e9))) }
        if case .bool(let value)? = options["startpaused"] { startPaused = value }
        if case .string(let value)? = options["name"] { name = value }
        return SceneScriptAnimationDescription(name: name, fps: fps, frameCount: length,
                                               duration: fps > 0 ? Double(length) / fps : 0, playing: !startPaused,
                                               property: property)
    }

    /// The spritesheet animation of an image's texture: model JSON → material → first texture's
    /// `.tex`, whose `TEXS` block lists the frames and their durations. Nil for a still texture.
    func textureAnimation(model path: String) -> SceneScriptAnimationDescription? {
        guard let tex = firstTexture(model: path) else { return nil }
        guard let frames = TEXSpriteFrames.durations(Array(tex)), !frames.isEmpty else { return nil }
        let duration = frames.reduce(0, +)
        return SceneScriptAnimationDescription(name: "", fps: duration > 0 ? Double(frames.count) / duration : 0,
                                               frameCount: frames.count, duration: duration, playing: true)
    }

    /// The length of an image's video texture (its MP4's `mvhd`); nil for a picture.
    func videoDuration(model path: String) -> Double? {
        guard let tex = firstTexture(model: path), let video = TEXParser(data: tex).extractVideoData() else { return nil }
        return MP4Duration.seconds(of: video) ?? 0
    }

    /// The `.tex` of an image's texture: model JSON → material → first texture.
    private func firstTexture(model path: String) -> Data? {
        guard let modelData = file(path),
              case .object(let model)? = try? decodeTolerant(SceneJSON.self, from: modelData),
              case .string(let materialPath)? = model["material"],
              let materialData = file(materialPath),
              case .object(let material)? = try? decodeTolerant(SceneJSON.self, from: materialData),
              case .array(let passes)? = material["passes"], case .object(let pass)? = passes.first,
              case .array(let textures)? = pass["textures"], case .string(let texture)? = textures.first,
              let tex = file("materials/\(texture).tex") else {
            // Optional: models without a material or a texture file have no texture.
            return nil
        }
        return tex
    }

    /// `value` as compact JSON text; nil when it cannot be encoded.
    static func jsonText(_ value: SceneJSON) -> String? {
        do {
            let data = try JSONSerialization.data(withJSONObject: value.foundationObject, options: [.sortedKeys, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        } catch {
            OWELog.error(.script, "A scene object can't be encoded as JSON: \(error)")
            return nil
        }
    }
}
