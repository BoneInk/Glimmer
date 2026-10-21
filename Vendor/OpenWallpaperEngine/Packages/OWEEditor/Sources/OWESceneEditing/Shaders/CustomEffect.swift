import Foundation
import WEFormat

/// An effect made in the editor, as WE's Add Effect dialog makes one ("New", "Duplicate";
/// `duplicateEffectForEditing`): `effects/<id>/effect.json` with its materials and shaders in the
/// effect's own folder, `group` `localeffects` (WE's "My Effects"), `editable`, named by the
/// author. A new effect is a copy of WE's own blank effect (`effects/_empty` in the user's WE
/// assets, never shipped); a duplicate copies the chosen effect.
///
/// What WE writes, from the effects its editor made in Workshop wallpapers: the name `Pulse+`
/// gives `pulse_`, `Test Shader` `test_shader`; a one-material effect's material and shader are
/// renamed after it (`materials/effects/pulse_.json` drawing `effects/pulse_`); its JSON is
/// JsonCpp's styled output (`WEJSONWriter`'s `editor` style); `name` is the author's, `description` and
/// `preview` are dropped and `dependencies` lists the copied files.
public struct CustomEffect: Hashable, Sendable {
    /// `effects/<id>/effect.json`, an added effect's `file`.
    public var file: String
    /// The name the author gave (`effect.json`'s `name`).
    public var name: String
    /// Every file of the effect by its path in the wallpaper, as text.
    public var files: [String: String]

    public init(file: String, name: String, files: [String: String]) {
        self.file = file
        self.name = name
        self.files = files
    }

    /// `effects/_empty/effect.json`: WE's blank effect, which New copies.
    public static let templateFile = "effects/_empty/effect.json"
    public static let group = "localeffects"

    /// The folder name WE gives an effect named `name`: lower case, every UTF-8 byte that isn't a
    /// letter a–z or a digit an underscore (`Iris Movement +` → `iris_movement__`, a CJK
    /// character three of them).
    public static func identifier(for name: String) -> String {
        let bytes = name.lowercased().utf8.map { byte -> UInt8 in
            let isLetter = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            return isLetter || isDigit ? byte : UInt8(ascii: "_")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `effects/<id>/effect.json` of the effects among `paths` (exactly that depth), sorted.
    public static func effectFiles(in paths: [String]) -> [String] {
        Set(paths.filter { path in
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3 && parts[0] == "effects" && parts[2] == "effect.json" && !parts[1].isEmpty
        }).sorted()
    }

    /// The effect's folder (`effects/<id>`).
    public var directory: String { (file as NSString).deletingLastPathComponent }

    public enum MakeError: Error, Equatable, LocalizedError {
        /// The name gives no folder name (empty).
        case emptyName
        /// The effect to copy (or WE's blank effect) can't be read.
        case unreadable(String)
        /// A material names no shader.
        case missingShader(String)

        public var errorDescription: String? {
            switch self {
            case .emptyName: return "The effect needs a name."
            case .unreadable(let path): return "\(path) can’t be read."
            case .missingShader(let path): return "\(path) names no shader."
            }
        }
    }

    /// A new effect named `name` copied from the effect `source` (`effects/<x>/effect.json`; WE's
    /// blank effect for New). `read` reads a file as the scene loader finds it (the editor's, the
    /// wallpaper's, then WE's assets); an effect's materials and shaders are looked for in its
    /// own folder first, as the loader does.
    public static func make(named name: String, from source: String = templateFile,
                            read: (String) -> Data?) throws -> CustomEffect {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MakeError.emptyName }
        let id = identifier(for: trimmed)
        let sourceDirectory = (source as NSString).deletingLastPathComponent
        let directory = "effects/\(id)"
        func readScoped(_ path: String) -> Data? { read("\(sourceDirectory)/\(path)") ?? read(path) }
        func json(_ path: String, scoped: Bool) throws -> [String: SceneJSONValue] {
            guard let data = scoped ? readScoped(path) : read(path),
                  let object = try? TolerantJSON.object(from: data),
                  case .object(let members)? = SceneJSONValue(any: object) else { throw MakeError.unreadable(path) }
            return members
        }

        var effect = try json(source, scoped: false)
        let passes = effect["passes"]?.arrayValue ?? []
        var materials: [String] = []
        for pass in passes {
            if let material = pass["material"]?.stringValue, !materials.contains(material) { materials.append(material) }
        }
        // Read every material and the shaders it names.
        var materialDocuments: [String: [String: SceneJSONValue]] = [:]
        var shaders: [String] = []
        for material in materials {
            let document = try json(material, scoped: true)
            materialDocuments[material] = document
            for pass in document["passes"]?.arrayValue ?? [] {
                guard let shader = pass["shader"]?.stringValue, !shader.isEmpty else { throw MakeError.missingShader(material) }
                if !shaders.contains(shader) { shaders.append(shader) }
            }
        }
        // One material drawing one shader is renamed after the effect, as WE's duplicates are.
        let renames = materials.count == 1 && shaders.count == 1
        let materialPath: (String) -> String = { renames ? "materials/effects/\(id).json" : $0 }
        let shaderName: (String) -> String = { renames ? "effects/\(id)" : $0 }

        var files: [String: String] = [:]
        var dependencies: [String] = []
        for material in materials {
            var document = materialDocuments[material] ?? [:]
            document["passes"] = .array((document["passes"]?.arrayValue ?? []).map { pass in
                guard case .object(var members) = pass, let shader = members["shader"]?.stringValue else { return pass }
                members["shader"] = .string(shaderName(shader))
                return .object(members)
            })
            let path = materialPath(material)
            files["\(directory)/\(path)"] = SceneJSONValue.object(document).editorJSON
            dependencies.append(path)
        }
        for shader in shaders {
            for stage in ["frag", "vert", "geom"] {
                let file = "shaders/\(shader).\(stage)"
                guard let data = readScoped(file) else {
                    if stage == "geom" { continue } // Optional: only some effects have a geometry stage.
                    throw MakeError.unreadable(file)
                }
                let path = "shaders/\(shaderName(shader)).\(stage)"
                files["\(directory)/\(path)"] = String(decoding: data, as: UTF8.self)
                dependencies.append(path)
            }
        }

        effect["passes"] = .array(passes.map { pass in
            guard case .object(var members) = pass, let material = members["material"]?.stringValue else { return pass }
            members["material"] = .string(materialPath(material))
            return .object(members)
        })
        effect["description"] = nil
        effect["preview"] = nil
        effect["name"] = .string(trimmed)
        effect["group"] = .string(group)
        effect["editable"] = .bool(true)
        effect["replacementkey"] = .string(id)
        effect["dependencies"] = .array(Array(Set(dependencies)).sorted().map(SceneJSONValue.string))
        if effect["version"] == nil { effect["version"] = .number(1) }
        let file = "\(directory)/effect.json"
        files[file] = SceneJSONValue.object(effect).editorJSON
        return CustomEffect(file: file, name: trimmed, files: files)
    }
}

extension SceneJSONValue {
    var arrayValue: [SceneJSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }
}
