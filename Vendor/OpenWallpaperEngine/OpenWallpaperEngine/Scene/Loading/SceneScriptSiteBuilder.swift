import Foundation

/// Finds every SceneScript attachment site of a scene document (`scene.json`, or an editor asset
/// pack's `assets.json`) and builds what the runtime needs for it (docs/scenescript-plan.md WP8):
/// the `SceneScriptInstance` with its `thisObject` binding, initial value and `scriptproperties`
/// (user-bound entries resolved), and the bound property's type and user bindings.
///
/// A site is any JSON object with a non-empty string `script`, the way WE's editor writes a bound
/// property: `{"script", "scriptproperties"?, "value", "user"?, "animation"?}` on an object field
/// (`origin`, `alpha`, `text`, …), an effect's `visible`, a material's `constantshadervalues`
/// entry, a particle system's `instanceoverride` field, or the scene's `general` settings.
///
/// Order (the order scripts load and update in): the scene's own sites first (best guess: WE
/// creates the scene before its objects), then each object in scene order, its fields in
/// `fieldOrder` then by name, then its effects (their own fields, then each pass's constants by
/// name), then `instanceoverride`, then anything else (plan §4.4 step 5).
struct SceneScriptSiteBuilder {
    /// Names script ids and logs: the Workshop id, or the wallpaper's stable local id.
    var wallpaperID: String
    /// The user properties bound values and `scriptproperties` read their initial values from.
    var userProperties: SceneScriptUserProperties
    /// The object-table slot of the object with a scene.json id (`SceneScriptObjectModel.slot(forObjectID:)`);
    /// nil gives its scripts no `thisLayer`.
    var slot: (Int) -> Int?

    /// Fields of an object in the order their scripts run, before the other fields.
    static let fieldOrder = ["visible", "origin", "scale", "angles", "alpha", "color", "text"]

    init(wallpaperID: String, userProperties: SceneScriptUserProperties = SceneScriptUserProperties(),
         slot: @escaping (Int) -> Int? = { _ in nil }) {
        self.wallpaperID = wallpaperID
        self.userProperties = userProperties
        self.slot = slot
    }

    /// Every site of `document`, in load order.
    func sites(in document: SceneJSON) -> [SceneScriptSite] {
        guard case .object(let root) = document else { return [] }
        var found: [SceneScriptSite] = []
        var ids = Set<String>()
        for (key, value) in root.sorted(by: { $0.key < $1.key }) where key != "objects" {
            for (path, node) in Self.nodes(in: value, path: [key]) {
                found.append(site(node, path: path, object: nil, ids: &ids))
            }
        }
        if case .array(let objects)? = root["objects"] {
            for (index, entry) in objects.enumerated() {
                guard case .object(let fields) = entry else { continue }
                let object = SceneScriptSiteObject(index: index, fields: fields)
                for (path, node) in Self.orderedNodes(of: fields) {
                    found.append(site(node, path: path, object: object, ids: &ids))
                }
            }
        }
        return found
    }

    /// Decodes a scene document tolerantly (comments, trailing commas, a BOM), like WE's loader.
    static func document(from data: Data) throws -> SceneJSON {
        try decodeTolerant(SceneJSON.self, from: data)
    }

    // MARK: - Walking

    /// Every bound value under `value`, depth first: an object's own fields by name, then its
    /// containers by name (an effect's `visible` before its `passes`). A bound value is not searched.
    static func nodes(in value: SceneJSON, path: [String]) -> [(path: [String], node: [String: SceneJSON])] {
        switch value {
        case .object(let fields):
            if isBound(fields) { return [(path, fields)] }
            func rank(_ key: String) -> Int { isContainer(fields[key]) ? 1 : 0 }
            let keys = fields.keys.sorted { (rank($0), $0) < (rank($1), $1) }
            return keys.flatMap { key in fields[key].map { nodes(in: $0, path: path + [key]) } ?? [] }
        case .array(let values):
            return values.enumerated().flatMap { nodes(in: $0.element, path: path + [String($0.offset)]) }
        default:
            return []
        }
    }

    private static func isBound(_ fields: [String: SceneJSON]) -> Bool {
        guard case .string(let script)? = fields["script"] else { return false }
        return !script.isEmpty
    }

    /// An array, or an object that is not a bound value.
    private static func isContainer(_ value: SceneJSON?) -> Bool {
        switch value {
        case .array?: return true
        case .object(let fields)?: return !isBound(fields)
        default: return false
        }
    }

    /// The bound values of an object's fields in load order.
    private static func orderedNodes(of fields: [String: SceneJSON]) -> [(path: [String], node: [String: SceneJSON])] {
        func rank(_ key: String) -> Int {
            if let index = fieldOrder.firstIndex(of: key) { return index }
            switch key {
            case "effects": return fieldOrder.count + 2
            case "instanceoverride": return fieldOrder.count + 3
            default:
                return isContainer(fields[key]) ? fieldOrder.count + 4 : fieldOrder.count + 1
            }
        }
        let keys = fields.keys.sorted { (rank($0), $0) < (rank($1), $1) }
        return keys.flatMap { key in fields[key].map { nodes(in: $0, path: [key]) } ?? [] }
    }

    // MARK: - Sites

    private func site(_ node: [String: SceneJSON], path: [String], object: SceneScriptSiteObject?,
                      ids: inout Set<String>) -> SceneScriptSite {
        let fieldPath = path.joined(separator: ".")
        let user = SceneScriptUserReference(node["user"])
        // The literal's shape is the property's; a bound user property supplies the value.
        let userValue = user.flatMap { userProperties.value(of: $0.name) }
        let literal = Self.literal(node["value"])
        let type = SceneScriptPropertyType(fieldPath: path, value: literal ?? userValue)
        let condition = userValue != nil ? user?.condition : nil
        let initial = (userValue ?? literal).flatMap {
            SceneScriptSceneValue.javaScriptValue($0, as: type, condition: condition)
        } ?? Self.defaultValue(path: path, type: type)

        var scriptUsers: [String: SceneScriptUserReference] = [:]
        let scriptProperties = resolveScriptProperties(node["scriptproperties"], users: &scriptUsers)
        let objectSlot = object?.id.flatMap(slot)
        let binding = SceneScriptObjectBinding(fieldPath: fieldPath, slot: objectSlot)

        var id = "\(wallpaperID)/\(object?.label ?? "scene")/\(fieldPath)"
        if ids.contains(id) {
            var suffix = 2
            while ids.contains("\(id)~\(suffix)") { suffix += 1 }
            id += "~\(suffix)"
        }
        ids.insert(id)

        var source = ""
        if case .string(let script)? = node["script"] { source = script }
        let instance = SceneScriptInstance(id: id, source: source, initialValue: initial,
                                           scriptPropertiesJSON: scriptProperties, objectSlot: objectSlot,
                                           binding: binding)
        let property = SceneScriptBoundProperty(path: fieldPath, type: type, user: user,
                                                scriptPropertyUsers: scriptUsers)
        return SceneScriptSite(instance: instance, property: property, objectID: object?.id, objectIndex: object?.index)
    }

    /// `scriptproperties` as name → entry. Older WE editors saved an array of `{key, value, …}`
    /// rows (e.g. 2176097362) instead of an object.
    static func scriptPropertyEntries(_ value: SceneJSON?) -> [String: SceneJSON] {
        switch value {
        case .object(let entries)?:
            return entries
        case .array(let rows)?:
            var entries: [String: SceneJSON] = [:]
            for row in rows {
                guard case .object(let fields) = row, case .string(let key)? = fields["key"],
                      let entry = fields["value"] else { continue }
                entries[key] = entry
            }
            return entries
        default:
            return [:]
        }
    }

    /// `scriptproperties` as the JSON WE's `_Internal.updateScriptProperties` parses: literals as
    /// authored (colours stay `"r g b"` text; the script's `Vec3` default converts them), user-bound
    /// entries (`{"user", "value"}`, possibly nested) as the user property's current value, else
    /// their innermost literal. Nil when there are none.
    private func resolveScriptProperties(_ value: SceneJSON?,
                                         users: inout [String: SceneScriptUserReference]) -> String? {
        let entries = Self.scriptPropertyEntries(value)
        guard !entries.isEmpty else { return nil }
        var resolved: [String: Any] = [:]
        for (key, entry) in entries {
            if let (literal, user) = resolveScriptProperty(entry) {
                resolved[key] = literal.foundationObject
                if let user { users[key] = user }
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: resolved, options: [.sortedKeys, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        } catch {
            OWELog.error(.script, "\(wallpaperID): scriptproperties \(entries.keys.sorted()) can't be encoded: \(error)")
            return nil
        }
    }

    /// An entry's value and the user property it follows (the outermost one), or nil for null.
    private func resolveScriptProperty(_ entry: SceneJSON) -> (SceneJSON, SceneScriptUserReference?)? {
        guard case .object(let fields) = entry else {
            if case .null = entry { return nil }
            return (entry, nil)
        }
        let user = SceneScriptUserReference(fields["user"])
        let inner = fields["value"].flatMap(resolveScriptProperty)
        if let user, let current = userProperties.value(of: user.name) {
            if let condition = user.condition { return (.bool(current.scalarString == condition), user) }
            return (current, user)
        }
        guard let inner else { return nil }
        return (inner.0, user ?? inner.1)
    }

    /// The innermost literal of a value (`{"value": {"user": …, "value": 1}}` is 1).
    private static func literal(_ value: SceneJSON?) -> SceneJSON? {
        guard case .object(let fields)? = value else { return value }
        return literal(fields["value"])
    }

    /// WE's value for a bound field that has none: the object model's defaults, else zero.
    private static func defaultValue(path: [String], type: SceneScriptPropertyType) -> Any {
        var numbers: [Float]?
        if path.count == 2, path[0] == "general" {
            numbers = SceneScriptSceneField(rawValue: path[1])?.defaultValue
        } else if path.count == 2, path[0] == "instanceoverride" {
            numbers = SceneScriptObjectField.allCases.first { $0.group == .instance && $0.scriptName == path[1] }?.defaultValue
        } else if path.count == 1 {
            numbers = SceneScriptObjectField.allCases.first { $0.group == .layer && $0.scriptName == path[0] }?.defaultValue
        } else if path.count == 3, path[0] == "effects", path[2] == "visible" {
            numbers = [1]
        }
        let components = numbers ?? [0]
        let fallback: SceneJSON
        switch type {
        case .string: fallback = .string("")
        case .bool: fallback = .bool(components.first != 0)
        default: fallback = .string(components.map { String(Double($0)) }.joined(separator: " "))
        }
        return SceneScriptSceneValue.javaScriptValue(fallback, as: type) ?? NSNull()
    }
}

/// The object a site belongs to: its scene.json id (nil in asset packs that leave it out) and the
/// label its script ids carry.
private struct SceneScriptSiteObject {
    var index: Int
    var id: Int?
    var label: String

    init(index: Int, fields: [String: SceneJSON]) {
        self.index = index
        if case .number(let number)? = fields["id"], number.isFinite, number == number.rounded(),
           abs(number) < 1e15 {
            id = Int(number)
        }
        var name = ""
        if case .string(let text)? = fields["name"] { name = text }
        label = "\(name)#\(id.map(String.init) ?? "i\(index)")"
    }
}
