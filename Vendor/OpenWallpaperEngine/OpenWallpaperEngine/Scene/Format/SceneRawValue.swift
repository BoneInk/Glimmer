import Foundation

/// A shader constant exactly as authored in `constantshadervalues` (materials and scene effect
/// instances), before any resolution. Forms seen in WE data:
/// - a number (`0.5`, `2`), a bool, or a string (vectors such as `"1 0.5 0"`);
/// - an object with some of `value`, `user` (a property name, or `{"name","condition"}`),
///   `script` plus `scriptproperties`, and `animation`.
/// This is a plain data model; resolving user properties, scripts and animation happens elsewhere.
indirect enum SceneRawValue: Decodable, Equatable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case object(Object)

    struct Object: Decodable, Equatable {
        /// The literal fallback value.
        var value: SceneRawValue?
        /// The user property the value is bound to.
        var userName: String?
        /// For `{"user":{"name","condition"}}`: the condition compared against the property.
        var userCondition: String?
        /// SceneScript source.
        var script: String?
        /// `scriptproperties`, kept as raw JSON.
        var scriptProperties: [String: SceneJSON]?
        /// The keyframe `animation` object, kept as raw JSON.
        var animation: SceneJSON?

        enum CodingKeys: String, CodingKey { case value, user, script, scriptproperties, animation }
        enum UserKeys: String, CodingKey { case name, condition }

        init(value: SceneRawValue? = nil, userName: String? = nil, userCondition: String? = nil,
             script: String? = nil, scriptProperties: [String: SceneJSON]? = nil, animation: SceneJSON? = nil) {
            self.value = value
            self.userName = userName
            self.userCondition = userCondition
            self.script = script
            self.scriptProperties = scriptProperties
            self.animation = animation
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            value = try c.decodeIfPresent(SceneRawValue.self, forKey: .value)
            script = try c.decodeIfPresent(String.self, forKey: .script)
            scriptProperties = try c.decodeIfPresent([String: SceneJSON].self, forKey: .scriptproperties)
            animation = try c.decodeIfPresent(SceneJSON.self, forKey: .animation)
            switch try c.decodeIfPresent(SceneJSON.self, forKey: .user) {
            case .string(let name)?:
                userName = name
            case .object?:
                let user = try c.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
                userName = try user.decodeIfPresent(String.self, forKey: .name)
                userCondition = try user.decodeIfPresent(SceneJSON.self, forKey: .condition)?.scalarString
            case nil, .null?:
                break
            case let other?:
                throw DecodingError.dataCorruptedError(forKey: .user, in: c,
                                                       debugDescription: "unsupported user binding \(other)")
            }
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        switch try c.decode(SceneJSON.self) {
        case .number(let n): self = .number(n)
        case .bool(let b): self = .bool(b)
        case .string(let s): self = .string(s)
        case .object: self = .object(try Object(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported shader value \(other)")
        }
    }

    /// The bound value's keyframe `animation` object; nil for a literal or a value without one.
    var animation: SceneJSON? {
        if case .object(let object) = self { return object.animation }
        return nil
    }
}

/// Arbitrary JSON, for parts of the format that are kept raw.
indirect enum SceneJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SceneJSON])
    case object([String: SceneJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // `try?` below probes the JSON type; the final branch throws if nothing matches.
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([SceneJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: SceneJSON].self)) }
    }

    /// Scalars as text (integral numbers without ".0"); nil for containers and null.
    var scalarString: String? {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        default: return nil
        }
    }
}
