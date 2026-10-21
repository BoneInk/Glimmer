import Foundation

/// Wallpaper Engine's "Share JSON" (its UI's `BrowseWallpaperSharePresetModalCtrl`): a wallpaper's
/// properties as one JSON object of key → value, with WE's value types (bool, a slider's number,
/// a combo's value, a colour as "r g b" in 0…1, text, file paths). User shortcuts are left out.
/// WE's Copy button puts the text on the clipboard as base64; its text field takes the plain JSON
/// or the base64 form, and so does `decode`. WE saves presets the same way, as `properties` beside
/// a `name` (`WallpaperEngineConfigImport`).
///
/// OWE keeps every value as a string (`sceneUserPropertyString`); the project.json definitions
/// give each key its WE type in both directions.
enum WallpaperEngineShareJSON {
    /// The wallpaper's property definitions from its project.json; none when it can't be read.
    static func definitions(in directory: URL) -> [String: UserPropertyDefinition] {
        // No project: no properties. One that can't be read logs once.
        guard let root = OWELog.attempt(.library, "Properties: project.json in \(directory.lastPathComponent)", quietIfMissing: true, {
            try WEProject.object(in: directory)
        }) as? [String: Any] else { return [:] }
        return Dictionary(UserPropertyDefinition.all(projectJSON: root).map { ($0.key, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// `values` as Share JSON: only the wallpaper's own properties (no Scene Edit / Export edits or
    /// app adjustments, which WE doesn't know), each in its WE type, pretty-printed as WE shows it.
    static func encode(_ values: [String: String], definitions: [String: UserPropertyDefinition]) throws -> Data {
        var object: [String: Any] = [:]
        for (key, value) in values {
            guard let definition = definitions[key], definition.type != "usershortcut" else { continue }
            object[key] = weValue(value, type: definition.type)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// The object in Share JSON `text`, plain or base64 as WE's Copy writes it.
    static func decode(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = [Data(trimmed.utf8)]
        if let decoded = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) { candidates.append(decoded) }
        for data in candidates {
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return object } // the other form next
        }
        throw WallpaperPresetError.notAPresetFile
    }

    /// The entries of a Share JSON `object` that fit the wallpaper: a key it defines (matched
    /// without case when only one fits), with a value of that property's type, as OWE value
    /// strings. Everything else is left out, as WE's paste leaves out mismatched types.
    static func values(from object: [String: Any], definitions: [String: UserPropertyDefinition]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in object {
            guard let definition = definition(for: key, in: definitions),
                  let converted = oweValue(value, for: definition) else { continue }
            result[definition.key] = converted
        }
        return result
    }

    static func definition(for key: String, in definitions: [String: UserPropertyDefinition]) -> UserPropertyDefinition? {
        if let exact = definitions[key] { return exact }
        let matches = definitions.values.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    /// `value` as `definition`'s type in OWE's string form; nil when it doesn't fit.
    static func oweValue(_ value: Any, for definition: UserPropertyDefinition) -> String? {
        let number = value as? NSNumber
        let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        switch definition.type {
        case "usershortcut":
            return nil
        case "bool":
            if isBool, let number { return number.boolValue ? "true" : "false" }
            if let text = value as? String, ["true", "false"].contains(text.lowercased()) { return text.lowercased() }
            return nil
        case "slider":
            if let number, !isBool, number.doubleValue.isFinite { return number.stringValue }
            if let text = value as? String, let parsed = Double(text), parsed.isFinite { return text }
            return nil
        case "combo":
            let text: String
            if let string = value as? String { text = string } else if let number, !isBool { text = number.stringValue } else { return nil }
            return definition.options.isEmpty || definition.options.contains(where: { $0.value == text }) ? text : nil
        case "color":
            guard let text = value as? String else { return nil }
            let parts = text.split(separator: " ").compactMap { Double($0) }
            return parts.count >= 3 ? text : nil
        default:
            // Text, text input, file and directory properties hold strings.
            return value as? String
        }
    }

    /// An OWE value string as WE writes `type`: a bool, a number for a slider, else the string.
    static func weValue(_ value: String, type: String) -> Any {
        switch type {
        case "bool":
            return value.lowercased() == "true" || value == "1"
        case "slider":
            return Double(value).map { NSNumber(value: $0) } ?? value
        default:
            return value
        }
    }
}
