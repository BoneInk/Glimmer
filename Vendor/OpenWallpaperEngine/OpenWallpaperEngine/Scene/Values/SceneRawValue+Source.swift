import Foundation

extension SceneJSON {
    /// The JSONSerialization-style object for this value.
    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }
}

extension SceneRawValue {
    /// The JSONSerialization-style object this value was decoded from.
    var foundationObject: Any {
        switch self {
        case .number(let value): return NSNumber(value: value)
        case .bool(let value): return value
        case .string(let value): return value
        case .object(let object):
            var result: [String: Any] = [:]
            if let value = object.value { result["value"] = value.foundationObject }
            if let name = object.userName {
                result["user"] = object.userCondition.map { ["name": name, "condition": $0] } ?? name
            }
            if let script = object.script { result["script"] = script }
            if let properties = object.scriptProperties { result["scriptproperties"] = properties.mapValues(\.foundationObject) }
            if let animation = object.animation { result["animation"] = animation.foundationObject }
            return result
        }
    }

    /// The resolvable form of this value (literal, user-, script- or animation-bound).
    var valueSource: SceneValueSource? { SceneValueSource(json: foundationObject) }
}
