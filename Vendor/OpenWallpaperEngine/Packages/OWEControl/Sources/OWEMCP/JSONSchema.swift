import Foundation
import OWEControlProtocol

/// The JSON Schemas of the tools' inputs, and a check of arguments against them. It covers what
/// the tools use: `type` (one or several), `properties`, `required`, `additionalProperties: false`,
/// `enum`, `minimum`/`maximum`, `minLength`, `items` and `maxItems`.
enum JSONSchema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String, oneOf values: [String]? = nil, minLength: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "string", "description": .string(description)]
        if let values { schema["enum"] = .array(values.map { .string($0) }) }
        if let minLength { schema["minLength"] = .number(Double(minLength)) }
        return .object(schema)
    }

    static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "number", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(minimum) }
        if let maximum { schema["maximum"] = .number(maximum) }
        return .object(schema)
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    /// A list of objects shaped by `item` (an `object(…)` schema).
    static func objectArray(_ description: String, item: JSONValue, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": item, "description": .string(description)]
        if let maxItems { schema["maxItems"] = .number(Double(maxItems)) }
        return .object(schema)
    }

    static func integerArray(_ description: String, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": ["type": "integer"], "description": .string(description)]
        if let maxItems { schema["maxItems"] = .number(Double(maxItems)) }
        return .object(schema)
    }

    static func stringArray(_ description: String, maxItems: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "array", "items": ["type": "string"], "description": .string(description)]
        if let maxItems { schema["maxItems"] = .number(Double(maxItems)) }
        return .object(schema)
    }

    /// What is wrong with `value` against `schema`, one message per problem; empty when it fits.
    static func problems(_ value: JSONValue, against schema: JSONValue, at path: String = "") -> [String] {
        let label = path.isEmpty ? "arguments" : path
        if let types = allowedTypes(schema), !types.contains(where: { matches(value, type: $0) }) {
            return ["\(label): expected \(types.joined(separator: " or ")), got \(value.typeName)"]
        }
        var problems: [String] = []
        if let allowed = schema["enum"]?.arrayValue, !allowed.contains(value) {
            let names = allowed.compactMap(\.stringValue).map { "\"\($0)\"" }.joined(separator: ", ")
            problems.append("\(label): must be one of \(names)")
        }
        if let number = value.doubleValue {
            if let minimum = schema["minimum"]?.doubleValue, number < minimum {
                problems.append("\(label): must be at least \(format(minimum))")
            }
            if let maximum = schema["maximum"]?.doubleValue, number > maximum {
                problems.append("\(label): must be at most \(format(maximum))")
            }
        }
        if let string = value.stringValue, let minLength = schema["minLength"]?.intValue, string.count < minLength {
            problems.append("\(label): must not be empty")
        }
        if let items = value.arrayValue {
            if let maxItems = schema["maxItems"]?.intValue, items.count > maxItems {
                problems.append("\(label): at most \(maxItems) items")
            }
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    problems += self.problems(item, against: itemSchema, at: "\(label)[\(index)]")
                }
            }
        }
        if let object = value.objectValue {
            let properties = schema["properties"]?.objectValue ?? [:]
            for key in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where object[key] == nil {
                problems.append("\(path.isEmpty ? key : "\(path).\(key)"): required")
            }
            for (key, item) in object.sorted(by: { $0.key < $1.key }) {
                let itemPath = path.isEmpty ? key : "\(path).\(key)"
                if let itemSchema = properties[key] {
                    problems += self.problems(item, against: itemSchema, at: itemPath)
                } else if schema["additionalProperties"]?.boolValue == false {
                    let known = properties.keys.sorted().joined(separator: ", ")
                    problems.append("\(itemPath): unknown argument" + (known.isEmpty ? " (this tool takes none)" : " (expected \(known))"))
                }
            }
        }
        return problems
    }

    private static func allowedTypes(_ schema: JSONValue) -> [String]? {
        switch schema["type"] {
        case .string(let type): return [type]
        case .array(let types): return types.compactMap(\.stringValue)
        default: return nil
        }
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("number", .number), ("string", .string),
             ("array", .array), ("object", .object): return true
        case ("integer", .number): return value.intValue != nil
        default: return false
        }
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
