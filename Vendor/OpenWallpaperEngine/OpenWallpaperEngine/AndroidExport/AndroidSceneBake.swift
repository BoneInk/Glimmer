import Foundation
import OWESceneEditing

/// Scene Edit / Export's Android Export mode, Dynamic: the mode's version of the wallpaper (its
/// isolated store's values, `IsolatedSceneEditSession.values`) baked into the package's files, as
/// Save as New Wallpaper bakes the editor's overlay into scene.json, so the phone renders the
/// edited scene with WE's own fields:
///
/// - scene.json: an object's replaced JSON, origin and scale (`ScenePreparation.resolvedScene`),
///   its `visible` (`sceneObjectVisibilityKey`), and each effect's `visible`
///   (`sceneAuthoredEffectEnabledKey`), first pass's `constantshadervalues` and `combos`
///   (`sceneAuthoredEffectOverrideKey`), where the loader applies them: a value bound to a user
///   property keeps its binding, a timeline or script keeps running from the edited value;
/// - a package file's replaced JSON (`sceneAssetOverrideKey`) as that file;
/// - project.json: each declared user property's `value`, in its declared type.
///
/// What WE's scene format has no field for stays out: material blending (a material file several
/// layers can share), music sync, and the app's own picture settings.
enum AndroidSceneBake {
    // MARK: scene.json

    /// scene.json with the layer edits among `values`.
    static func scene(_ data: Data, values: [String: String]) throws -> Data {
        // Without layer edits the scene goes as authored (its numbers keep their kinds).
        guard values.keys.contains(where: { $0.hasPrefix("_owe_scene_object_") || $0.hasPrefix("_owe_authored_effect_") }) else {
            return data
        }
        let resolved = try ScenePreparation.resolvedScene(data, edits: ScenePreparation.split(storedValues: values).edits)
        guard var root = try JSONSerialization.jsonObject(with: resolved) as? [String: Any],
              var objects = root["objects"] as? [[String: Any]] else { return resolved }
        for index in objects.indices {
            let id = SceneObjects.objectID(objects[index], index: index)
            if let visible = values[sceneObjectVisibilityKey(objectID: id)] {
                objects[index]["visible"] = visible.lowercased() != "false"
            }
            if var effects = objects[index]["effects"] as? [[String: Any]] {
                for effectIndex in effects.indices {
                    bake(&effects[effectIndex], objectID: id, effectIndex: effectIndex, values: values)
                }
                objects[index]["effects"] = effects
            }
        }
        root["objects"] = objects
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    /// One effect's enabled state, constants and combos.
    private static func bake(_ effect: inout [String: Any], objectID: Int, effectIndex: Int, values: [String: String]) {
        if let enabled = values[sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)] {
            effect["visible"] = enabled.lowercased() != "false"
        }
        let prefix = sceneAuthoredEffectOverrideKey(objectID: objectID, effectIndex: effectIndex, parameter: "")
        let enabledKey = sceneAuthoredEffectEnabledKey(objectID: objectID, effectIndex: effectIndex)
        let edits = values.filter { key, _ in
            key.hasPrefix(prefix) && key != enabledKey && !key.hasSuffix("_musicSync") && !key.hasSuffix("_musicAmount")
        }
        guard !edits.isEmpty else { return }
        var passes = effect["passes"] as? [[String: Any]] ?? []
        if passes.isEmpty { passes = [[:]] }
        var constants = passes[0]["constantshadervalues"] as? [String: Any] ?? [:]
        var combos = passes[0]["combos"] as? [String: Any] ?? [:]
        let comboPrefix = SceneEffectParameters.comboOverrideKey("")
        for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
            let parameter = String(key.dropFirst(prefix.count))
            if parameter.hasPrefix(comboPrefix.lowercased()) {
                guard let number = Int(value) else { continue }
                let name = String(parameter.dropFirst(comboPrefix.count)).uppercased()
                let existing = combos.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
                combos[existing] = number
                continue
            }
            guard let literal = literal(value) else { continue }
            let existing = constants.keys.first { $0.caseInsensitiveCompare(parameter) == .orderedSame }
            switch existing.flatMap({ constants[$0] }) {
            case let bound as [String: Any] where bound["user"] != nil:
                // Bound to a user property: the user property sets it, as in WE's editor.
                continue
            case var animated as [String: Any]:
                animated["value"] = literal
                constants[existing ?? parameter] = animated
            default:
                constants[existing ?? parameter] = literal
            }
        }
        if !constants.isEmpty { passes[0]["constantshadervalues"] = constants }
        if !combos.isEmpty { passes[0]["combos"] = combos }
        effect["passes"] = passes
    }

    /// A WE value string as scene.json writes it: one number as a number, a vector as its
    /// components' text, space-separated; nil when it isn't numbers.
    static func literal(_ value: String) -> Any? {
        let tokens = SceneVector.tokens(value).map(String.init)
        let components = tokens.compactMap { Double($0) }
        guard !components.isEmpty, components.count == tokens.count else { return nil }
        if components.count == 1 { return components[0] }
        return tokens.joined(separator: " ")
    }

    // MARK: Package files

    /// `files` with each replaced package file's JSON in its place (added when the file comes
    /// from WE's assets, which a package's own file overrides).
    static func replacingFiles(_ files: [AndroidPackageBuilder.File], values: [String: String]) -> [AndroidPackageBuilder.File] {
        var result = files
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            guard let path = sceneAssetOverridePath(fromKey: key) else { continue }
            let data = Data(value.utf8)
            if let index = result.firstIndex(where: { $0.path == path }) {
                result[index].data = data
            } else {
                result.append(AndroidPackageBuilder.File(path: path, data: data))
            }
        }
        return result
    }

    // MARK: project.json

    /// project.json with each declared user property's `value` set from `values`, in the type
    /// its declaration has.
    static func project(_ data: Data, values: [String: String]) throws -> Data {
        var document: WEJSONDocument
        do {
            document = try WEJSONDocument(parsing: data)
        } catch {
            throw AndroidPackageBuilder.Failure.unreadable("project.json", error)
        }
        guard var general = document["general"], case .object(var properties)? = general["properties"] else { return data }
        let given = ScenePreparation.split(storedValues: values).properties
        for (name, value) in given {
            guard var property = properties[name] else { continue }
            property["value"] = typed(value, as: property)
            properties[name] = property
        }
        general["properties"] = .object(properties)
        document["general"] = general
        return WEJSONWriter.data(document)
    }

    /// `value` in the type the property declares: a checkbox's bool, a slider's number, a
    /// combo's option as its options are written, text for the rest.
    static func typed(_ value: String, as property: WEJSONDocument) -> WEJSONDocument {
        let type = property["type"]?.stringValue?.lowercased()
        switch type {
        case "bool":
            return .bool(value.lowercased() == "true" || value == "1")
        case "slider":
            return number(value) ?? .string(value)
        case "combo":
            if case .array(let options)? = property["options"], let first = options.first?["value"], first.stringValue == nil {
                return number(value) ?? .string(value)
            }
            return .string(value)
        default:
            if let current = property["value"], current.stringValue == nil, let number = number(value) { return number }
            return .string(value)
        }
    }

    private static func number(_ value: String) -> WEJSONDocument? {
        guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
        if number == number.rounded(), abs(number) < 1e15 { return .integer(Int64(number)) }
        return .real(number)
    }
}
