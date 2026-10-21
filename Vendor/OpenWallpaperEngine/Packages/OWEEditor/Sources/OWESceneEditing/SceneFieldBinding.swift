import Foundation

/// How an authored field gets its value, which decides what an edit of it changes.
public enum SceneFieldBinding: Hashable, Sendable {
    /// A plain value: the edit replaces it.
    case literal
    /// `{"user": …}`: the user property sets it, as in WE's editor, which shows no value for it.
    case userProperty(String)
    /// `{"script": …, "value": …}` or `{"animation": …, "value": …}`: the edit sets the starting
    /// `value` and the script or animation keeps running from it, as WE's editor does.
    case driven
    /// Missing: the edit adds it.
    case absent

    public init(_ value: SceneJSONValue?) {
        guard let value else { self = .absent; return }
        guard case .object(let fields) = value else { self = .literal; return }
        if let user = fields["user"] {
            // `{"user": "name"}` or `{"user": {"name": …, "condition": …}}`.
            self = .userProperty(user.stringValue ?? user["name"]?.stringValue ?? "")
        } else if fields["script"] != nil || fields["animation"] != nil || fields["value"] != nil {
            self = .driven
        } else {
            self = .literal
        }
    }

    /// The value an authored field shows: its own, or a driven field's starting `value`.
    public static func literal(of value: SceneJSONValue?) -> SceneJSONValue? {
        guard let value else { return nil }
        if case .object(let fields) = value, fields["user"] != nil || fields["script"] != nil
            || fields["animation"] != nil || fields["value"] != nil {
            return fields["value"]
        }
        return value
    }
}
