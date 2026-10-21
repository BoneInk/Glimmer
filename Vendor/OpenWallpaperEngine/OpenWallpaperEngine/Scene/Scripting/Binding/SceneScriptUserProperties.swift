import Foundation

/// A wallpaper's user properties in the raw form WE hands to scripts: `{name: {type, value}}` as
/// in project.json's `general.properties`, with the user's current values. The runtime passes it
/// to WE's `_Internal.convertUserProperties` (colours become `Vec3`, user shortcuts
/// `{isbound, commandtype, file}` from the user's binding, everything else its value) for `applyUserProperties` and
/// `engine.userProperties`, and property binding reads user-bound values from it.
struct SceneScriptUserProperties {
    struct Property: Equatable {
        /// project.json `type`: `bool`, `slider`, `color`, `combo`, `textinput`, `usershortcut`, …
        var type: String
        var value: SceneJSON
        /// What a `usershortcut` gives scripts besides its type (`isbound`, `commandtype`, `file`),
        /// from the user's binding (`UserShortcutBinding.scriptMembers`); its `value` is the
        /// binding as stored, which scripts never see.
        var shortcut: [String: SceneJSON] = [:]

        static let userShortcutType = "usershortcut"
    }

    private(set) var properties: [String: Property] = [:]

    init() {}

    /// From project.json's `general.properties` (entries that are not objects are skipped).
    init(definitions: SceneJSON?) {
        guard case .object(let entries)? = definitions else { return }
        for (name, entry) in entries {
            guard case .object(let fields) = entry else { continue }
            var type = "text"
            if case .string(let declared)? = fields["type"] { type = declared }
            var property = Property(type: type, value: fields["value"] ?? .null)
            if type == Property.userShortcutType {
                // Only the user binds a shortcut: what project.json says (value, isbound,
                // commandtype, file) is never used.
                property.value = .string("")
                property.shortcut = UserShortcutBinding.scriptMembers(storedValue: "")
            }
            properties[name] = property
        }
    }

    /// From a whole project.json.
    init(project: SceneJSON?) {
        guard case .object(let root)? = project, case .object(let general)? = root["general"] else {
            self.init()
            return
        }
        self.init(definitions: general["properties"])
    }

    /// The property's current value, or nil when the wallpaper has no such property.
    func value(of name: String) -> SceneJSON? {
        properties[name]?.value
    }

    /// Sets the user's value of an existing property; unknown names are ignored (WE only binds
    /// declared properties).
    mutating func set(_ name: String, to value: SceneJSON) {
        properties[name]?.value = value
        if properties[name]?.type == Property.userShortcutType {
            guard case .string(let stored) = value else {
                properties[name]?.value = .string("")
                properties[name]?.shortcut = UserShortcutBinding.scriptMembers(storedValue: "")
                return
            }
            properties[name]?.shortcut = UserShortcutBinding.scriptMembers(storedValue: stored)
        }
    }

    /// The stored binding of each `usershortcut` property, for `engine.openUserShortcut`.
    var userShortcutBindings: [String: String] {
        var bindings: [String: String] = [:]
        for (name, property) in properties where property.type == Property.userShortcutType {
            if case .string(let stored) = property.value { bindings[name] = stored }
        }
        return bindings
    }

    /// `{name: {type, value}}` for `SceneScriptRuntime.load(userProperties:)`, or only `names`
    /// for `userPropertiesDidChange(_:)`.
    func payload(only names: Set<String>? = nil) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (name, property) in properties where names?.contains(name) ?? true {
            var entry: [String: Any] = ["type": property.type]
            // A user shortcut's value is the user's binding, path or command included: wallpaper64.exe
            // hands scripts only its type, isbound, commandtype and file.
            if property.type != Property.userShortcutType { entry["value"] = property.value.foundationObject }
            for (key, member) in property.shortcut { entry[key] = member.foundationObject }
            payload[name] = entry
        }
        return payload
    }
}
