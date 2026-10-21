import Foundation

/// JSON read with its objects' keys in document order, which `JSONSerialization` and `Codable`
/// drop. WE's particle editor schema lists each component's fields in the order WE's panel shows
/// them (`ParticleEditorSchema`), so the order is part of what it says.
enum OrderedJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OrderedJSON])
    case object([(key: String, value: OrderedJSON)])

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .number(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .array(let values): hasher.combine(values)
        case .object(let pairs):
            for pair in pairs {
                hasher.combine(pair.key)
                hasher.combine(pair.value)
            }
        }
    }

    enum ParseError: Error, Equatable {
        case unexpected(offset: Int)
    }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else { throw ParseError.unexpected(offset: parser.offset) }
        return value
    }

    subscript(key: String) -> OrderedJSON? {
        if case .object(let pairs) = self { return pairs.first { $0.key == key }?.value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var pairs: [(key: String, value: OrderedJSON)] {
        if case .object(let pairs) = self { return pairs }
        return []
    }

    /// The value without its order, as the scene's edits hold values.
    var sceneValue: SceneJSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(\.sceneValue))
        case .object(let pairs):
            var values: [String: SceneJSONValue] = [:]
            for pair in pairs where values[pair.key] == nil { values[pair.key] = pair.value.sceneValue }
            return .object(values)
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func skipWhitespace() {
            while offset < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[offset]) { offset += 1 }
        }

        func fail() -> ParseError { .unexpected(offset: offset) }

        mutating func value() throws -> OrderedJSON {
            guard offset < bytes.count else { throw fail() }
            switch bytes[offset] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard offset + expected.count <= bytes.count, Array(bytes[offset..<offset + expected.count]) == expected else {
                throw fail()
            }
            offset += expected.count
        }

        mutating func object() throws -> OrderedJSON {
            offset += 1
            var pairs: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
                offset += 1
                return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else { throw fail() }
                let key = try string()
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else { throw fail() }
                offset += 1
                skipWhitespace()
                pairs.append((key, try value()))
                skipWhitespace()
                guard offset < bytes.count else { throw fail() }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                guard bytes[offset] == UInt8(ascii: "}") else { throw fail() }
                offset += 1
                return .object(pairs)
            }
        }

        mutating func array() throws -> OrderedJSON {
            offset += 1
            var values: [OrderedJSON] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
                offset += 1
                return .array(values)
            }
            while true {
                skipWhitespace()
                values.append(try value())
                skipWhitespace()
                guard offset < bytes.count else { throw fail() }
                if bytes[offset] == UInt8(ascii: ",") { offset += 1; continue }
                guard bytes[offset] == UInt8(ascii: "]") else { throw fail() }
                offset += 1
                return .array(values)
            }
        }

        /// A string token, its escapes decoded by `JSONSerialization` (which reads a quoted
        /// fragment exactly as it reads one inside a document).
        mutating func string() throws -> String {
            let start = offset
            offset += 1
            var escaped = false
            while offset < bytes.count {
                let byte = bytes[offset]
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    offset += 1
                    let token = Data(bytes[start..<offset])
                    guard let text = try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else {
                        throw ParseError.unexpected(offset: start)
                    }
                    return text
                }
                offset += 1
            }
            throw fail()
        }

        mutating func number() throws -> Double {
            let start = offset
            while offset < bytes.count, "+-0123456789.eE".utf8.contains(bytes[offset]) { offset += 1 }
            guard offset > start, let text = String(bytes: bytes[start..<offset], encoding: .ascii),
                  let number = Double(text) else { throw ParseError.unexpected(offset: start) }
            return number
        }
    }
}
