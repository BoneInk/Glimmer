import Foundation

/// A SceneScript on a field, as WE's editor writes it into scene.json:
/// `{"script": source, "scriptproperties": {…}, "value": …}` (docs/scenescript-plan.md §1.2).
public struct SceneScriptAttachment: Codable, Hashable, Sendable {
    public var source: String
    /// The values of the properties the script declares (`createScriptProperties()`), by name;
    /// nil keeps the authored ones.
    public var scriptProperties: [String: SceneJSONValue]?

    public init(source: String, scriptProperties: [String: SceneJSONValue]? = nil) {
        self.source = source
        self.scriptProperties = scriptProperties
    }
}

/// A field bound to a user property: `{"user": name, "value": …}`, or for a flag driven by a combo,
/// `{"user": {"name": name, "condition": value}, "value": …}` (on when the combo has that value).
public struct SceneUserBinding: Codable, Hashable, Sendable {
    public var name: String
    public var condition: String?

    public init(name: String, condition: String? = nil) {
        self.name = name
        self.condition = condition
    }

    /// The `user` member as scene.json writes it.
    public var json: SceneJSONValue {
        guard let condition, !condition.isEmpty else { return .string(name) }
        return .object(["name": .string(name), "condition": .string(condition)])
    }

    /// From a `user` member: `"name"` or `{"name", "condition"}`.
    public init?(json: SceneJSONValue?) {
        switch json {
        case .string(let name)?:
            guard !name.isEmpty else { return nil }
            self.init(name: name)
        case .object(let fields)?:
            guard let name = fields["name"]?.stringValue, !name.isEmpty else { return nil }
            let condition: String?
            switch fields["condition"] {
            case .string(let text)?: condition = text
            case .number(let number)?: condition = SceneVector.format(number)
            case .bool(let flag)?: condition = flag ? "true" : "false"
            default: condition = nil
            }
            self.init(name: name, condition: condition)
        default:
            return nil
        }
    }
}

/// The editor's change to what drives one field: a script attached, replaced or removed, a user
/// property bound or unbound. Kept in the overlay (`SceneAuthoring`) and applied where the scene
/// loads, before the field's value edits, so an edited value becomes the driver's start `value`.
public struct SceneFieldDriverEdit: Codable, Hashable, Sendable {
    /// The script the field runs; nil leaves the authored one unless `removesScript`.
    public var script: SceneScriptAttachment?
    public var removesScript: Bool?
    /// The user property that sets the field; nil leaves the authored binding unless `removesUser`.
    public var user: SceneUserBinding?
    public var removesUser: Bool?
    /// The start `value` for a field the scene doesn't have (a script or a binding needs one).
    public var value: SceneJSONValue?

    public init(script: SceneScriptAttachment? = nil, removesScript: Bool? = nil,
                user: SceneUserBinding? = nil, removesUser: Bool? = nil, value: SceneJSONValue? = nil) {
        self.script = script
        self.removesScript = removesScript
        self.user = user
        self.removesUser = removesUser
        self.value = value
    }

    public var isEmpty: Bool {
        script == nil && removesScript != true && user == nil && removesUser != true
    }

    public mutating func attach(_ script: SceneScriptAttachment) {
        self.script = script
        removesScript = nil
    }

    public mutating func detachScript(authored: Bool) {
        script = nil
        removesScript = authored ? true : nil
    }

    public mutating func bind(_ user: SceneUserBinding) {
        self.user = user
        removesUser = nil
    }

    public mutating func unbind(authored: Bool) {
        user = nil
        removesUser = authored ? true : nil
    }

    /// The field as scene.json has it after this edit. A field left with only its `value` is
    /// written as that plain value again; a field left with nothing is removed (nil).
    public func applied(to authored: SceneJSONValue?) -> SceneJSONValue? {
        var node: [String: SceneJSONValue]
        if case .object(let fields)? = authored, Self.isDriven(fields) {
            node = fields
        } else {
            node = [:]
            if let authored, authored != .null { node["value"] = authored }
        }
        if let script {
            node["script"] = .string(script.source)
            if let properties = script.scriptProperties {
                node["scriptproperties"] = properties.isEmpty ? nil : .object(properties)
            }
        } else if removesScript == true {
            node["script"] = nil
            node["scriptproperties"] = nil
        }
        if let user {
            node["user"] = user.json
        } else if removesUser == true {
            node["user"] = nil
        }
        if node["value"] == nil, let value, node["script"] != nil || node["user"] != nil {
            node["value"] = value
        }
        let drivers = ["script", "user", "animation"]
        if !drivers.contains(where: { node[$0] != nil }) {
            // Nothing drives it any more: the plain value, as WE's editor writes an unbound field.
            let others = node.keys.filter { $0 != "value" && $0 != "scriptproperties" }
            if others.isEmpty { return node["value"] }
        }
        return .object(node)
    }

    /// `{"script"|"user"|"animation"|"value": …}`: a bound field rather than an object value.
    static func isDriven(_ fields: [String: SceneJSONValue]) -> Bool {
        fields["script"] != nil || fields["user"] != nil || fields["animation"] != nil || fields["value"] != nil
    }
}

/// What drives a field now: its script and user binding, authored or edited.
public struct SceneFieldDrivers: Hashable, Sendable {
    public var script: SceneScriptAttachment?
    public var user: SceneUserBinding?
    public var hasAnimation: Bool

    public init(script: SceneScriptAttachment? = nil, user: SceneUserBinding? = nil, hasAnimation: Bool = false) {
        self.script = script
        self.user = user
        self.hasAnimation = hasAnimation
    }

    /// Read from a field as scene.json has it.
    public init(_ field: SceneJSONValue?) {
        guard case .object(let fields)? = field, SceneFieldDriverEdit.isDriven(fields) else {
            self.init()
            return
        }
        var script: SceneScriptAttachment?
        if let source = fields["script"]?.stringValue, !source.isEmpty {
            var properties: [String: SceneJSONValue]?
            if case .object(let entries)? = fields["scriptproperties"] { properties = entries }
            script = SceneScriptAttachment(source: source, scriptProperties: properties)
        }
        self.init(script: script, user: SceneUserBinding(json: fields["user"]), hasAnimation: fields["animation"] != nil)
    }
}
