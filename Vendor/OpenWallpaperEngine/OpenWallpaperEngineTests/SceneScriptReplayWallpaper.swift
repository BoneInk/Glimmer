import CryptoKit
import Foundation
@testable import OpenWallpaperEngine

/// One wallpaper as the SceneScript replay sees it (docs/scenescript-plan.md WP9): its files (from
/// `scene.pkg` and the folder), `project.json`, and the document whose objects carry scripts —
/// `scene.json`, or `assets.json` for an editor asset pack. Script sites are found the way the
/// corpus extractor finds them: every JSON object with a non-empty string `script`.
struct SceneScriptReplayWallpaper {
    struct LoadError: Error, CustomStringConvertible {
        var description: String
    }

    /// One attachment site: a script bound to one property.
    struct Site {
        /// Index into `objects`, or nil for scene-level sites (`general.*`).
        var objectIndex: Int?
        /// The field path relative to the object (`origin`, `effects.1.visible`, …) or the document.
        var field: String
        var source: String
        /// The corpus name of the source: the first 12 hex digits of its SHA-1.
        var hash: String
        /// The authored `value` (JSON), user-bound values already resolved.
        var value: Any
        /// `scriptproperties` with user-bound entries resolved, as JSON text.
        var scriptPropertiesJSON: String?
    }

    struct Object {
        /// scene.json `id`, else the object's index (`SceneScriptSceneDescriber.objectID`).
        var id: Int
        var name: String
        var kind: SceneScriptObjectDescription.Kind
        var json: [String: Any]
    }

    var id: String
    var directory: URL
    var documentName: String
    var document: [String: Any]
    var project: [String: Any]
    var objects: [Object]
    var sites: [Site]
    private var packageFiles: [String: Data]

    /// `project.json`'s `general.properties`, raw (`{type, value, …}`), as WE hands them to
    /// `_Internal.convertUserProperties`.
    var userProperties: [String: Any] {
        ((project["general"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
    }

    init(directory: URL, id: String) throws {
        self.id = id
        self.directory = directory
        var packageFiles: [String: Data] = [:]
        let package = directory.appending(path: "scene.pkg")
        if FileManager.default.fileExists(atPath: package.path) {
            let parser = try PKGParser(url: package)
            for name in parser.fileList where name.hasSuffix(".json") || name.hasSuffix(".tex") {
                packageFiles[name] = parser.extractFile(named: name)
            }
        }
        self.packageFiles = packageFiles
        let projectData = try Data(contentsOf: directory.appending(path: "project.json"))
        project = try Self.jsonObject(projectData, name: "project.json")

        var documentName = "scene.json"
        var documentData = Self.file(documentName, packageFiles: packageFiles, directory: directory)
        if documentData == nil {
            documentName = "assets.json"
            documentData = Self.file(documentName, packageFiles: packageFiles, directory: directory)
        }
        guard let documentData else { throw LoadError(description: "\(id): no scene.json or assets.json") }
        self.documentName = documentName
        document = try Self.jsonObject(documentData, name: documentName)

        let properties = ((project["general"] as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
        var objects: [Object] = []
        for (index, entry) in ((document["objects"] as? [Any]) ?? []).enumerated() {
            let json = entry as? [String: Any] ?? [:]
            let objectID = (json["id"] as? NSNumber)?.intValue ?? index
            objects.append(Object(id: objectID, name: json["name"] as? String ?? "", kind: Self.kind(of: json), json: json))
        }
        self.objects = objects

        var found: [(path: [String], node: [String: Any])] = []
        Self.walk(document, path: [], into: &found)
        sites = found.map { path, node in
            let isObject = path.count >= 2 && path[0] == "objects"
            let source = node["script"] as? String ?? ""
            return Site(objectIndex: isObject ? Int(path[1]) : nil,
                        field: (isObject ? path.dropFirst(2) : path[...]).joined(separator: "."),
                        source: source, hash: Self.hash(source),
                        value: Self.resolve(node, properties: properties),
                        scriptPropertiesJSON: Self.scriptProperties(node["scriptproperties"], properties: properties))
        }
    }

    /// A file of the wallpaper: the package first, then the folder. Nil when absent.
    func file(_ path: String) -> Data? {
        Self.file(path, packageFiles: packageFiles, directory: directory)
    }

    /// The scene document as the app reads it.
    func sceneDocument() throws -> SceneJSON {
        guard let data = file(documentName) else { throw LoadError(description: "\(id): no \(documentName)") }
        return try SceneScriptSiteBuilder.document(from: data)
    }

    /// project.json's user properties with their authored values.
    func sceneUserProperties() throws -> SceneScriptUserProperties {
        SceneScriptUserProperties(project: try SceneScriptSiteBuilder.document(from: JSONSerialization.data(withJSONObject: project)))
    }

    // MARK: - Values

    /// The value of a scene.json field that may be `{"value": …, "user": …}`: the user property's
    /// value when it is bound to one that exists, else the authored value.
    static func resolve(_ field: Any?, properties: [String: Any]) -> Any {
        guard let dictionary = field as? [String: Any] else { return field ?? NSNull() }
        if let user = dictionary["user"] as? String, let property = properties[user] as? [String: Any],
           let value = property["value"] {
            return value
        }
        return dictionary["value"] ?? NSNull()
    }

    /// The numbers of a field value: `"1 2 3"`, a number or a flag. Nil for anything else.
    static func numbers(_ value: Any?) -> [Float]? {
        switch value {
        case let number as NSNumber: return [number.floatValue]
        case let text as String:
            let parts = text.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Float($0) }
            return parts.isEmpty ? nil : parts
        default: return nil
        }
    }

    static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Private

    /// Editor asset packs keep their files under `contents/`, which the editor merges into the
    /// project that imports them; paths are relative to that project.
    private static func file(_ path: String, packageFiles: [String: Data], directory: URL) -> Data? {
        if let data = packageFiles[path] { return data }
        for candidate in [path, "contents/" + path] {
            let url = directory.appending(path: candidate)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                return try Data(contentsOf: url)
            } catch {
                OWELog.error(.script, "Reading \(url.path) failed: \(error)")
            }
        }
        return nil
    }

    private static func jsonObject(_ data: Data, name: String) throws -> [String: Any] {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw LoadError(description: "\(name) is not a JSON object")
        }
        return object
    }

    /// The object kind as the corpus extractor names it.
    static func kind(of json: [String: Any]) -> SceneScriptObjectDescription.Kind {
        if json["text"] != nil { return .text }
        if json["particle"] != nil { return .particle }
        if json["sound"] != nil { return .sound }
        if json["light"] != nil { return .light }
        if let model = json["model"] as? String, model.hasSuffix(".mdl") { return .model }
        if json["image"] != nil { return .image }
        return .group
    }

    private static func walk(_ node: Any, path: [String], into found: inout [(path: [String], node: [String: Any])]) {
        if let dictionary = node as? [String: Any] {
            if let script = dictionary["script"] as? String,
               !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append((path, dictionary))
            }
            for key in dictionary.keys.sorted() where key != "script" {
                walk(dictionary[key] as Any, path: path + [key], into: &found)
            }
        } else if let array = node as? [Any] {
            for (index, element) in array.enumerated() {
                walk(element, path: path + [String(index)], into: &found)
            }
        }
    }

    private static func scriptProperties(_ value: Any?, properties: [String: Any]) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        var resolved: [String: Any] = [:]
        for (key, entry) in dictionary {
            resolved[key] = entry is [String: Any] ? resolve(entry, properties: properties) : entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: resolved, options: [.sortedKeys]) else {
            // Optional: JSON that JSONSerialization read always serializes back.
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func hash(_ source: String) -> String {
        Digest.hex(Insecure.SHA1.hash(data: Data(source.utf8))).prefix(12).description
    }
}
