import Foundation

/// A user property a value follows: scene.json `"user": "name"` or
/// `"user": {"name": …, "condition": …}` (a flag that is whether the property equals `condition`).
struct SceneScriptUserReference: Equatable {
    var name: String
    var condition: String?

    /// The reference in a `{value, user, …}` object, or nil when it has none.
    init?(_ user: SceneJSON?) {
        switch user {
        case .string(let name)?:
            self.name = name
        case .object(let fields)?:
            guard case .string(let name)? = fields["name"] else { return nil }
            self.name = name
            condition = fields["condition"]?.scalarString
        default:
            return nil
        }
    }

    init(name: String, condition: String? = nil) {
        self.name = name
        self.condition = condition
    }

    var javaScriptObject: [String: Any] {
        var object: [String: Any] = ["name": name]
        if let condition { object["condition"] = condition }
        return object
    }
}
