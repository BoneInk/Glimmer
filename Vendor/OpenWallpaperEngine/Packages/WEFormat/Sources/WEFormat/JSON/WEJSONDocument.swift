import Foundation

/// A JSON document as WE reads and writes it (JsonCpp): integers and reals stay apart, as the
/// text had them (`8` is an integer, `2.0` a real), so writing it back (`WEJSONWriter`) keeps
/// each number's kind. Objects keep their members; WE writes them sorted by name.
public indirect enum WEJSONDocument: Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case real(Double)
    case string(String)
    case array([WEJSONDocument])
    case object([String: WEJSONDocument])

    public enum ParseError: Error, LocalizedError, Equatable {
        case unexpected(String, offset: Int)

        public var errorDescription: String? {
            switch self {
            case .unexpected(let what, let offset): return "Invalid JSON: \(what) at byte \(offset)"
            }
        }
    }

    /// Parses `data` (UTF-8, an optional byte-order mark, `//` and `/* */` comments as JsonCpp allows).
    public init(parsing data: Data) throws {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipBOM()
        self = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw ParseError.unexpected("trailing content", offset: parser.index) }
    }

    public subscript(key: String) -> WEJSONDocument? {
        get {
            guard case .object(let members) = self else { return nil }
            return members[key]
        }
        set {
            guard case .object(var members) = self else { return }
            members[key] = newValue
            self = .object(members)
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipBOM() {
            if TolerantJSON.hasBOM(bytes) { index = TolerantJSON.byteOrderMark.count }
        }

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                        index += 1
                    }
                    index = min(index + 2, bytes.count)
                default: return
                }
            }
        }

        mutating func value() throws -> WEJSONDocument {
            skipSpace()
            guard index < bytes.count else { throw ParseError.unexpected("end of input", offset: index) }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw ParseError.unexpected("a value", offset: index)
            }
            index += expected.count
        }

        mutating func object() throws -> WEJSONDocument {
            index += 1
            var members: [String: WEJSONDocument] = [:]
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.unexpected("a member name", offset: index) }
                let name = try string()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError.unexpected("':'", offset: index) }
                index += 1
                members[name] = try value()
                skipSpace()
                guard index < bytes.count else { throw ParseError.unexpected("end of input", offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                throw ParseError.unexpected("',' or '}'", offset: index)
            }
        }

        mutating func array() throws -> WEJSONDocument {
            index += 1
            var elements: [WEJSONDocument] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                elements.append(try value())
                skipSpace()
                guard index < bytes.count else { throw ParseError.unexpected("end of input", offset: index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                throw ParseError.unexpected("',' or ']'", offset: index)
            }
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run: [UInt8] = []
            func flush() {
                guard !run.isEmpty else { return }
                scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
                run.removeAll()
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    flush()
                    return String(scalars)
                }
                if byte != UInt8(ascii: "\\") {
                    run.append(byte)
                    index += 1
                    continue
                }
                flush()
                guard index + 1 < bytes.count else { break }
                let escape = bytes[index + 1]
                index += 2
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{8}")
                case UInt8(ascii: "f"): scalars.append("\u{C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default:
                    throw ParseError.unexpected("an escape", offset: index - 1)
                }
            }
            throw ParseError.unexpected("end of string", offset: index)
        }

        mutating func hex4() throws -> UInt32 {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw ParseError.unexpected("4 hex digits", offset: index)
            }
            index += 4
            return value
        }

        mutating func number() throws -> WEJSONDocument {
            let start = index
            var isReal = false
            while index < bytes.count {
                let byte = bytes[index]
                if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") {
                    index += 1
                } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                    isReal = true
                    index += 1
                } else {
                    break
                }
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            guard !text.isEmpty else { throw ParseError.unexpected("a value", offset: start) }
            if !isReal {
                if let value = Int64(text) { return .integer(value) }
                if let value = UInt64(text) { return .unsigned(value) }
            }
            guard let value = Double(text) else { throw ParseError.unexpected("a number", offset: start) }
            return .real(value)
        }
    }
}
