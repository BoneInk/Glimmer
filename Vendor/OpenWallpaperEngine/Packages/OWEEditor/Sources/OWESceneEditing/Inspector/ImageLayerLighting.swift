import Foundation
import WEFormat

/// An image layer's material as WE's Lighting & Reflections section edits it: its first pass's
/// `LIGHTING` and `REFLECTION` combos, the normal map (`textures[1]`, `g_Texture1`) and the
/// material constants of WE's generic image shaders. WE's editor writes them into the material
/// file the layer's model names; the editor keeps the edited material in the overlay
/// (`SceneEditOverlay.documents`) instead.
public struct ImageLayerLighting: Hashable, Sendable {
    /// One of the shader's material constants (`"material"` in its annotation).
    public struct Constant: Hashable, Sendable, Identifiable {
        public enum Kind: Hashable, Sendable {
            case number(ClosedRange<Double>)
            case color
        }

        /// The key in `constantshadervalues`.
        public let key: String
        /// WE's label key (`ui_editor_properties_…`), for the editor's own title.
        public let label: String
        public let kind: Kind
        public let defaultValue: [Double]
        public var id: String { key }
    }

    /// The material file's path in the wallpaper (`materials/<name>.json`).
    public let path: String
    /// The whole material document as the scene now reads it.
    public let document: SceneJSONValue

    /// WE's generic image shaders that take lighting and reflections (each declares the
    /// `LIGHTING`/`REFLECTION` combos and the normal map in its annotations).
    public static let lightableShaders: Set<String> = ["genericimage2", "genericimage3", "genericimage4"]

    /// The shader's material constants, from its annotations (`assets/shaders/<shader>.frag` of
    /// WE 2.8): `genericimage2` defaults roughness and metallic to 0.5 and has no specular tint;
    /// `genericimage3` and `genericimage4` default them to 0.7 and 0.
    public static func constants(shader: String) -> [Constant] {
        let two = shader == "genericimage2"
        var result: [Constant] = [
            Constant(key: "roughness", label: "ui_editor_properties_roughness", kind: .number(0...1), defaultValue: [two ? 0.5 : 0.7]),
            Constant(key: "metallic", label: "ui_editor_properties_metallic", kind: .number(0...1), defaultValue: [two ? 0.5 : 0]),
        ]
        if !two {
            result.append(Constant(key: "speculartint", label: "ui_editor_properties_specular_tint", kind: .color, defaultValue: [1, 1, 1]))
        }
        result += [
            Constant(key: "emissivecolor", label: "ui_editor_properties_emissive_color", kind: .color, defaultValue: [1, 1, 1]),
            Constant(key: "emissivebrightness", label: "ui_editor_properties_emissive_brightness", kind: .number(0...10), defaultValue: [1]),
            Constant(key: "reflectivity", label: "ui_editor_properties_reflectivity", kind: .number(0...1), defaultValue: [1]),
        ]
        return result
    }

    public init(path: String, document: SceneJSONValue) {
        self.path = path
        self.document = document
    }

    var firstPass: [String: SceneJSONValue] {
        MaterialPassDocument(document)?.pass ?? [:]
    }

    public var shader: String { firstPass["shader"]?.stringValue?.lowercased() ?? "" }

    /// The layer can be lit: its material is one of WE's generic image shaders.
    public var isLightable: Bool { Self.lightableShaders.contains(shader) }

    public func combo(_ name: String) -> Int {
        MaterialPassDocument(document)?.combo(name, default: 0) ?? 0
    }

    public var lighting: Bool { combo("LIGHTING") != 0 }
    public var reflection: Bool { combo("REFLECTION") != 0 }

    /// `textures[1]`: the normal map; nil for none.
    public var normalMap: String? {
        guard case .array(let textures)? = firstPass["textures"], textures.count > 1 else { return nil }
        return textures[1].stringValue
    }

    /// The constant's components, the shader's default when the material leaves it out.
    public func constant(_ constant: Constant) -> [Double] {
        let value = firstPass["constantshadervalues"]?[constant.key]
        return SceneVector.components(SceneFieldBinding.literal(of: value), fallback: constant.defaultValue)
    }

    // MARK: Changing

    /// The document with its first pass changed by `change`.
    func changingFirstPass(_ change: (inout [String: SceneJSONValue]) -> Void) -> SceneJSONValue {
        guard var material = MaterialPassDocument(document) else { return document }
        material.changeExistingPass(change)
        return .object(material.root)
    }

    /// With combo `name` at `value`; 0 drops it (every combo's default here).
    public func settingCombo(_ name: String, to value: Int) -> SceneJSONValue {
        changingFirstPass { pass in
            var combos: [String: SceneJSONValue] = { if case .object(let combos)? = pass["combos"] { return combos }; return [:] }()
            combos[name] = value == 0 ? nil : .number(Double(value))
            pass["combos"] = combos.isEmpty ? nil : .object(combos)
        }
    }

    /// With the constant at `components` (a number for one component, else WE's `"x y z"`).
    public func settingConstant(_ key: String, to components: [Double]) -> SceneJSONValue {
        changingFirstPass { pass in
            var constants: [String: SceneJSONValue] = {
                if case .object(let constants)? = pass["constantshadervalues"] { return constants }
                return [:]
            }()
            let value: SceneJSONValue = components.count == 1 ? .number(components[0]) : SceneVector.value(components)
            // A constant a user property sets keeps its binding; the edit is its value.
            if case .object(var bound)? = constants[key], bound["user"] != nil || bound["script"] != nil {
                bound["value"] = value
                constants[key] = .object(bound)
            } else {
                constants[key] = value
            }
            pass["constantshadervalues"] = .object(constants)
        }
    }

    /// With `texture` as the normal map (`textures[1]`); nil removes it.
    public func settingNormalMap(_ texture: String?) -> SceneJSONValue {
        changingFirstPass { pass in
            var textures: [SceneJSONValue] = { if case .array(let textures)? = pass["textures"] { return textures }; return [] }()
            if let texture {
                while textures.count < 2 { textures.append(.null) }
                textures[1] = .string(texture)
            } else if textures.count > 1 {
                textures[1] = .null
                while let last = textures.last, last == .null, textures.count > 1 { textures.removeLast() }
            }
            pass["textures"] = .array(textures)
        }
    }
}

extension SceneEditSession {
    /// The material the image layer's model names (`material`), as the scene now reads it: the
    /// editor's edit, else the file `readAsset` reads (the wallpaper's, else WE's). Nil for a
    /// layer without one, or a file that can't be read.
    public func imageMaterial(of layerID: Int, readAsset: (String) -> Data?) -> ImageLayerLighting? {
        guard let layer = outline.layer(layerID), layer.imageRole == .picture,
              let modelPath = value("image", of: layerID)?.stringValue,
              let model = Self.documentJSON(readAsset(modelPath)), let path = model["material"]?.stringValue else { return nil }
        if let edited = overlay.document(path) { return ImageLayerLighting(path: path, document: edited) }
        guard let document = Self.documentJSON(readAsset(path)) else { return nil }
        return ImageLayerLighting(path: path, document: document)
    }

    /// Writes `document` as the image layer's material, one undo step (a run of one control's
    /// changes, one step); the wallpaper's own document drops the edit.
    public func setImageMaterial(_ document: SceneJSONValue, path: String, readAsset: (String) -> Data?,
                                 actionName: String, coalescingKey: String? = nil) {
        var next = overlay
        let authored = Self.documentJSON(readAsset(path))
        next.setDocument(path, to: document == authored ? nil : document)
        commit(next, actionName: actionName, coalescingKey: coalescingKey)
    }

    /// A WE JSON document as the editor holds it; nil for no file or one that isn't JSON (the
    /// scene's build logs it when it reads it).
    static func documentJSON(_ data: Data?) -> SceneJSONValue? {
        guard let data, let object = try? TolerantJSON.object(from: data) else { return nil }
        return SceneJSONValue(any: object)
    }
}
