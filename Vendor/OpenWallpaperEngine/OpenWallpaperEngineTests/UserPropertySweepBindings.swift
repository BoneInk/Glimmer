import Foundation
@testable import OpenWallpaperEngine

/// Where a scene wallpaper's user property is bound: every `"user"` reference in its scene.json
/// (and the other JSON files of the wallpaper), every script whose text names it, sorted into the
/// binding kinds a fix is made for (`UserPropertySweepTests`).
enum UserPropertySweepBindings {
    enum Kind: String, CaseIterable, Comparable {
        case effectConstant = "effect constant"
        /// A material's `usershadervalues` (constant key → property name), WE's older binding.
        case userShaderValues = "material usershadervalues"
        case effectVisible = "effect visible"
        case layerVisible = "layer visible"
        case particleOverride = "particle override"
        case text = "text"
        case colour = "colour"
        case timeline = "timeline"
        case comboCondition = "combo condition"
        case sceneGeneral = "scene general"
        case objectField = "object field"
        case audio = "audio"
        case scriptOnly = "script-only"
        case unknown = "unknown"

        static func < (lhs: Kind, rhs: Kind) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    struct Site {
        var kind: Kind
        var path: String
        /// The scene object the binding is on, when it is on one.
        var objectID: String?
    }

    /// Every binding of every property, by property name.
    static func sites(directory: URL, sceneFile: String, names: Set<String>) -> [String: [Site]] {
        var result: [String: [Site]] = [:]
        var scripts: [(path: String, objectID: String?, text: String)] = []
        let package = try? PKGParser(url: directory.appending(path: "scene.pkg"))
        func read(_ name: String) -> Data? {
            FileManager.default.contents(atPath: directory.appending(path: name).path) ?? package?.extractFile(named: name)
        }
        var files = [sceneFile]
        files += (package?.fileList ?? []).filter { $0.hasSuffix(".json") && $0 != sceneFile }
        if let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "json" {
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                if relative != "project.json", !files.contains(relative) { files.append(relative) }
            }
        }
        for file in files {
            guard let data = read(file), let document = try? SceneScriptSiteBuilder.document(from: data) else { continue }
            let prefix = file == sceneFile ? "" : file + ":"
            walk(document, path: [], objectID: nil, inScript: false) { name, site in
                result[name, default: []].append(Site(kind: site.kind, path: prefix + site.path, objectID: site.objectID))
            } script: { path, objectID, text in
                scripts.append((prefix + path, objectID, text))
            }
        }
        // A script that names the property (`engine.userProperties.x`, `changed.x`, `['x']`) reads it.
        for script in scripts {
            for name in names where mentions(script.text, name) {
                result[name, default: []].append(Site(kind: .scriptOnly, path: script.path + " (script text)", objectID: script.objectID))
            }
        }
        return result
    }

    private static func mentions(_ text: String, _ name: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: name, range: search) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : " "
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : " "
            let word: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            if !word(before), !word(after) { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func walk(_ value: SceneJSON, path: [String], objectID: String?, inScript: Bool,
                             found: (String, Site) -> Void, script: (String, String?, String) -> Void) {
        switch value {
        case .object(let fields):
            var objectID = objectID
            // A scene object: `objects/<index>` (its children's too).
            if path.count >= 2, path[path.count - 2] == "objects" || path[path.count - 2] == "children",
               let id = fields["id"]?.scalarString {
                objectID = id
            }
            let hasScript: Bool = {
                if case .string(let text)? = fields["script"], !text.isEmpty { return true }
                return false
            }()
            if case .string(let text)? = fields["script"], !text.isEmpty {
                script(format(path, objectID: objectID), objectID, text)
            }
            if let user = SceneScriptUserReference(fields["user"]) {
                let kind = classify(path: path, fields: fields, user: user, inScript: inScript || hasScript)
                found(user.name, Site(kind: kind, path: format(path, objectID: objectID)
                                        + (user.condition.map { " (condition \($0))" } ?? ""), objectID: objectID))
            }
            if case .object(let bound)? = fields["usershadervalues"] {
                for (key, value) in bound.sorted(by: { $0.key < $1.key }) {
                    guard let name = value.scalarString else { continue }
                    found(name, Site(kind: inScript ? .scriptOnly : .userShaderValues,
                                     path: format(path + ["usershadervalues", key], objectID: objectID), objectID: objectID))
                }
            }
            for (key, field) in fields.sorted(by: { $0.key < $1.key }) where key != "user" && key != "usershadervalues" {
                walk(field, path: path + [key], objectID: objectID,
                     inScript: inScript || key == "scriptproperties", found: found, script: script)
            }
        case .array(let values):
            for (index, element) in values.enumerated() {
                var label = String(index)
                if path.last == "objects" || path.last == "children", case .object(let fields) = element,
                   let name = fields["name"]?.scalarString {
                    label += "(\(name))"
                }
                walk(element, path: path + [label], objectID: objectID, inScript: inScript, found: found, script: script)
            }
        default:
            break
        }
    }

    private static func classify(path: [String], fields: [String: SceneJSON], user: SceneScriptUserReference,
                                 inScript: Bool) -> Kind {
        let key = path.last?.lowercased() ?? ""
        if inScript { return .scriptOnly }
        if fields["animation"] != nil { return .timeline }
        if path.contains("instanceoverride") { return .particleOverride }
        if user.condition != nil { return .comboCondition }
        if path.contains("constantshadervalues") { return .effectConstant }
        if key == "visible" { return path.contains("effects") ? .effectVisible : .layerVisible }
        if path.first == "general" { return key.contains("color") ? .colour : .sceneGeneral }
        if ["text", "pointsize", "font", "horizontalalign", "verticalalign", "padding", "limitrows",
            "limituppercase", "maxrows", "maxwidth"].contains(key) { return .text }
        if key.contains("color") { return .colour }
        if ["volume", "sound", "playbackmode", "mintime", "maxtime", "muteineditor"].contains(key) { return .audio }
        if path.isEmpty { return .unknown }
        return .objectField
    }

    private static func format(_ path: [String], objectID: String?) -> String {
        path.joined(separator: "/") + (objectID.map { " [id \($0)]" } ?? "")
    }
}

/// The value a sweep sets a property to: clearly different from `current` and valid for it.
enum UserPropertySweepValues {
    /// nil for a property the sweep can't change (a file or folder picker, a combo with one option).
    static func changed(type: String, property: [String: Any], current: String) -> String? {
        switch type {
        case "bool":
            return current.lowercased() == "true" || current == "1" ? "false" : "true"
        case "slider":
            let minimum = number(property["min"]) ?? 0
            let maximum = number(property["max"]) ?? 1
            let value = Double(current) ?? minimum
            let target = abs(value - minimum) >= abs(maximum - value) ? minimum : maximum
            guard target != value else { return nil }
            let integral = (property["fraction"] as? Bool) == false
                || (minimum.rounded() == minimum && maximum.rounded() == maximum && (property["fraction"] as? Bool) != true
                    && value.rounded() == value && !current.contains("."))
            return integral && target.rounded() == target ? String(Int(target)) : String(target)
        case "combo":
            let options = (property["options"] as? [[String: Any]] ?? []).compactMap { $0["value"].map(sceneUserPropertyString) }
            return options.first { $0 != current }
        case "color":
            let parts = current.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
            let rgb = parts.count >= 3 ? Array(parts.prefix(3)) : [0, 0, 0]
            let candidates: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0], [1, 1, 1], [1, 0, 1]]
            let far = candidates.max { distance($0, rgb) < distance($1, rgb) }!
            return far.map { $0 == 0 ? "0" : "1" }.joined(separator: " ")
        case "textinput", "text":
            return current.isEmpty ? "Sweep 42" : current + " Sweep 42"
        default:
            return nil
        }
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
