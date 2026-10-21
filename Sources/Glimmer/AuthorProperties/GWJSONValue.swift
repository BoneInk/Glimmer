import Foundation

/// Typed JSON for author metadata. sourceData on AuthorPropertyProject additionally
/// retains the exact original bytes, including whitespace and numeric spellings.
enum GWJSONValue: Codable, Hashable, Sendable {
    case bool(Bool), number(Double), string(String), array([GWJSONValue]), object([String: GWJSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self), number.isFinite { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([GWJSONValue].self) { self = .array(array) }
        else if let object = try? value.decode([String: GWJSONValue].self) { self = .object(object) }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unsupported/nonfinite JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .bool(let bool): try value.encode(bool)
        case .number(let number):
            guard number.isFinite else { throw EncodingError.invalidValue(number, .init(codingPath: encoder.codingPath, debugDescription: "Nonfinite JSON number")) }
            try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        case .null: try value.encodeNil()
        }
    }

    var objectValue: [String: GWJSONValue]? { if case .object(let value) = self { return value }; return nil }
    var arrayValue: [GWJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
}

struct AuthorPropertyError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}
