import Foundation

/// Valve's KeyValues text format (VDF), as Steam writes `appworkshop_*.acf`, `libraryfolders.vdf`
/// and `loginusers.vdf`:
///
/// ```
/// "AppWorkshop"
/// {
///     "appid"     "431960"
///     "WorkshopItemsInstalled" { "123" { "size" "42" } }
/// }
/// ```
///
/// Keys and values are quoted strings (with `\"`, `\\`, `\n`, `\t` escapes) or bare tokens; a
/// value is a string or a `{ … }` block. `//` starts a comment, and a `[$WIN32]`-style condition
/// after a value is skipped. Keys keep their order and may repeat; lookups ignore case, as Steam's do.
enum ValveKeyValues {
    indirect enum Value: Equatable {
        case string(String)
        case object([Entry])
    }

    struct Entry: Equatable {
        let key: String
        let value: Value
    }

    enum ParseError: LocalizedError, Equatable {
        case unterminatedString(line: Int)
        case unexpectedCloseBrace(line: Int)
        case missingValue(key: String, line: Int)
        case unterminatedBlock(key: String)
        case nestedTooDeeply(line: Int)

        var errorDescription: String? {
            switch self {
            case .unterminatedString(let line): return "unterminated string on line \(line)"
            case .unexpectedCloseBrace(let line): return "unexpected } on line \(line)"
            case .missingValue(let key, let line): return "\"\(key)\" has no value on line \(line)"
            case .unterminatedBlock(let key): return "the block \"\(key)\" isn't closed"
            case .nestedTooDeeply(let line):
                return "blocks are nested more than \(ValveKeyValues.maximumDepth) deep on line \(line)"
            }
        }
    }

    /// The deepest block nesting read. Steam's files nest a handful of levels; this only bounds
    /// malformed input, which fails with `ParseError.nestedTooDeeply` instead of exhausting the stack.
    static let maximumDepth = 256

    /// The top-level entries of a KeyValues text.
    static func parse(_ text: String) throws -> [Entry] {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return try parser.entries(closedBy: nil)
    }

    /// Reads a file as UTF-8 (with or without a BOM), falling back to Latin-1 for older files.
    static func parse(contentsOf url: URL) throws -> [Entry] {
        let data = TolerantJSON.withoutBOM(try Data(contentsOf: url))
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    private enum Token: Equatable {
        case text(String)
        case open
        case close
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1
        var depth = 0

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
        }

        /// Entries until `}` (inside a block named `closedBy`) or the end of the text.
        mutating func entries(closedBy block: String?) throws -> [Entry] {
            var result: [Entry] = []
            while true {
                guard let token = try nextToken() else {
                    if let block { throw ParseError.unterminatedBlock(key: block) }
                    return result
                }
                switch token {
                case .close:
                    guard block != nil else { throw ParseError.unexpectedCloseBrace(line: line) }
                    return result
                case .open:
                    // A block without a key: keep its entries under an empty key.
                    result.append(Entry(key: "", value: try nestedBlock(closedBy: "")))
                case .text(let key):
                    let keyLine = line
                    guard let valueToken = try nextToken() else { throw ParseError.missingValue(key: key, line: keyLine) }
                    switch valueToken {
                    case .text(let value):
                        result.append(Entry(key: key, value: .string(value)))
                    case .open:
                        result.append(Entry(key: key, value: try nestedBlock(closedBy: key)))
                    case .close:
                        throw ParseError.missingValue(key: key, line: keyLine)
                    }
                }
            }
        }

        /// The entries of a block just opened, one level deeper.
        private mutating func nestedBlock(closedBy key: String) throws -> Value {
            guard depth < ValveKeyValues.maximumDepth else { throw ParseError.nestedTooDeeply(line: line) }
            depth += 1
            defer { depth -= 1 }
            return .object(try entries(closedBy: key))
        }

        /// The next token, skipping whitespace, comments and `[conditions]`.
        mutating func nextToken() throws -> Token? {
            while index < scalars.count {
                let scalar = scalars[index]
                switch scalar {
                case "\n":
                    line += 1
                    index += 1
                case " ", "\t", "\r":
                    index += 1
                case "/" where index + 1 < scalars.count && scalars[index + 1] == "/":
                    while index < scalars.count && scalars[index] != "\n" { index += 1 }
                case "[":
                    while index < scalars.count && scalars[index] != "]" && scalars[index] != "\n" { index += 1 }
                    if index < scalars.count && scalars[index] == "]" { index += 1 }
                case "{":
                    index += 1
                    return .open
                case "}":
                    index += 1
                    return .close
                case "\"":
                    return .text(try quoted())
                default:
                    return .text(bare())
                }
            }
            return nil
        }

        private mutating func quoted() throws -> String {
            let startLine = line
            index += 1
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                index += 1
                switch scalar {
                case "\"":
                    return String(text)
                case "\\" where index < scalars.count:
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": text.append("\n")
                    case "t": text.append("\t")
                    case "\\", "\"": text.append(escaped)
                    default:
                        // Not an escape Steam writes (e.g. a Windows path): keep both characters.
                        text.append("\\")
                        text.append(escaped)
                    }
                default:
                    if scalar == "\n" { line += 1 }
                    text.append(scalar)
                }
            }
            throw ParseError.unterminatedString(line: startLine)
        }

        private mutating func bare() -> String {
            var text = String.UnicodeScalarView()
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
                    || scalar == "{" || scalar == "}" || scalar == "\"" {
                    break
                }
                text.append(scalar)
                index += 1
            }
            return String(text)
        }
    }
}

extension ValveKeyValues.Value {
    /// The first entry named `key` (ignoring case) of a block; nil for a string or a missing key.
    subscript(key: String) -> ValveKeyValues.Value? {
        entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// The entries of a block; empty for a string.
    var entries: [ValveKeyValues.Entry] {
        if case .object(let entries) = self { return entries }
        return []
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

extension Array where Element == ValveKeyValues.Entry {
    /// The first top-level entry named `key`, ignoring case.
    subscript(key: String) -> ValveKeyValues.Value? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}
