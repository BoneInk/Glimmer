import Foundation

/// A JSON value as scene.json holds it, typed so an edit can be stored, compared and written back
/// exactly (`SceneEditOverlay`).
public enum SceneJSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SceneJSONValue])
    case object([String: SceneJSONValue])

    /// `value` as `JSONSerialization` reads it; nil for anything JSON can't hold.
    public init?(any value: Any?) {
        guard let value else { self = .null; return }
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // JSONSerialization reads `true` as an NSNumber; only its CFBoolean is a Bool.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let bool as Bool:
            self = .bool(bool)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            var values: [SceneJSONValue] = []
            for element in array {
                guard let value = SceneJSONValue(any: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: SceneJSONValue] = [:]
            for (key, element) in dictionary {
                guard let value = SceneJSONValue(any: element) else { return nil }
                values[key] = value
            }
            self = .object(values)
        default:
            return nil
        }
    }

    /// The value as `JSONSerialization` writes it. A whole number is written as an integer, as
    /// WE's files write `colorBlendMode` and ids.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { return Int(value) }
            return value
        case .string(let value): return value
        case .array(let values): return values.map(\.any)
        case .object(let values): return values.mapValues(\.any)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> SceneJSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }
}

extension SceneJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([SceneJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: SceneJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
