import Foundation

/// A token of JavaScript source, for the script editor's highlighting.
public struct JavaScriptToken: Hashable, Sendable {
    public enum Kind: Sendable {
        case keyword, identifier, number, string, template, regex, lineComment, blockComment, punctuation
        /// A SceneScript global (`engine`, `thisLayer`, `Vec3`, …).
        case api
    }

    public let kind: Kind
    /// UTF-16 range in the source (`NSString`'s).
    public let range: NSRange
}

/// Splits JavaScript into tokens in one pass: comments, string and template literals (an
/// unterminated one runs to the end of its line, or of the source for a template), regex literals
/// where an operand is expected, numbers, identifiers and punctuation. Not a parser: good enough to
/// colour code as it is typed, never throws, and always covers the whole source.
public enum JavaScriptTokenizer {
    static let keywords: Set<String> = Set(SceneScriptAPICatalog.keywords)
    static let apiNames: Set<String> = Set(SceneScriptAPICatalog.standard.globals.map(\.name))

    public static func tokens(in source: String) -> [JavaScriptToken] {
        let units = Array(source.utf16)
        var tokens: [JavaScriptToken] = []
        var index = 0
        /// A `/` starts a regex here (no operand before it).
        var expectsOperand = true

        func add(_ kind: JavaScriptToken.Kind, _ start: Int) {
            tokens.append(JavaScriptToken(kind: kind, range: NSRange(location: start, length: index - start)))
        }
        func unit(_ offset: Int) -> UInt16? { index + offset < units.count ? units[index + offset] : nil }

        while index < units.count {
            let start = index
            let c = units[index]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
            case 0x2F where unit(1) == 0x2F: // //
                while index < units.count, units[index] != 0x0A { index += 1 }
                add(.lineComment, start)
            case 0x2F where unit(1) == 0x2A: // /*
                index += 2
                while index < units.count, !(units[index] == 0x2A && unit(1) == 0x2F) { index += 1 }
                index = min(units.count, index + 2)
                add(.blockComment, start)
            case 0x22, 0x27: // " '
                index += 1
                while index < units.count, units[index] != c, units[index] != 0x0A {
                    if units[index] == 0x5C { index += 1 }
                    index += 1
                }
                if index < units.count, units[index] == c { index += 1 }
                index = min(index, units.count)
                add(.string, start)
                expectsOperand = false
            case 0x60: // `
                index += 1
                while index < units.count, units[index] != 0x60 {
                    if units[index] == 0x5C { index += 1 }
                    index += 1
                }
                index = min(units.count, index + 1)
                add(.template, start)
                expectsOperand = false
            case 0x2F where expectsOperand: // a regex literal
                index += 1
                var inClass = false
                while index < units.count, units[index] != 0x0A {
                    let current = units[index]
                    if current == 0x5C { index += 2; continue }
                    if current == 0x5B { inClass = true } else if current == 0x5D { inClass = false }
                    if current == 0x2F, !inClass { break }
                    index += 1
                }
                index = min(units.count, index + 1)
                while index < units.count, isIdentifierPart(units[index]) { index += 1 } // flags
                add(.regex, start)
                expectsOperand = false
            case _ where (0x30...0x39).contains(c) || (c == 0x2E && unit(1).map({ (0x30...0x39).contains($0) }) == true):
                index += 1
                while index < units.count, isIdentifierPart(units[index]) || units[index] == 0x2E
                        || ((units[index] == 0x2B || units[index] == 0x2D) && (units[index - 1] | 0x20) == 0x65) {
                    index += 1
                }
                add(.number, start)
                expectsOperand = false
            default:
                if isIdentifierStart(c) {
                    while index < units.count, isIdentifierPart(units[index]) { index += 1 }
                    let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                    let precededByDot = start > 0 && units[start - 1] == 0x2E
                    if keywords.contains(word), !precededByDot {
                        add(.keyword, start)
                        expectsOperand = !["this", "super", "true", "false", "null", "undefined"].contains(word)
                    } else {
                        add(!precededByDot && apiNames.contains(word) ? .api : .identifier, start)
                        expectsOperand = false
                    }
                } else {
                    index += 1
                    add(.punctuation, start)
                    // After `)`, `]` or `}` an operator follows; after anything else an operand does.
                    expectsOperand = !(c == 0x29 || c == 0x5D || c == 0x7D)
                }
            }
        }
        return tokens
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) || unit == 0x5F || unit == 0x24 || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || (0x30...0x39).contains(unit)
    }
}
