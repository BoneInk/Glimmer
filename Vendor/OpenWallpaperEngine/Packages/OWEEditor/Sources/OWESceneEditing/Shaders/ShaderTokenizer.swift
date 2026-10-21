import Foundation

/// A token of a WE shader (GLSL with WE's HLSL-isms), for the shader editor's highlighting.
public struct ShaderToken: Hashable, Sendable {
    public enum Kind: Sendable {
        case keyword, type, number, string, comment, preprocessor, punctuation, identifier
        /// A GLSL built-in function or one of WE's portable macros (`texSample2D`, `mul`, `CAST3`).
        case builtin
        /// What WE's engine provides: its constants (`g_Time`), attributes (`a_Position`) and the
        /// shader outputs (`gl_FragColor`).
        case engine
    }

    public let kind: Kind
    /// UTF-16 range in the source (`NSString`'s).
    public let range: NSRange
}

/// Splits a shader into tokens in one pass: `//` and `/* */` comments, a preprocessor directive
/// to the end of its line (its comment apart), strings, numbers (`1.0f`, `.5`, `1e-3`, `0xFF`),
/// words by what they are to WE's shader dialect (`ShaderLanguage`), and punctuation.
public enum ShaderTokenizer {
    public static func tokens(in source: String) -> [ShaderToken] {
        let units = Array(source.utf16)
        var tokens: [ShaderToken] = []
        var index = 0
        var lineStart = true
        func add(_ kind: ShaderToken.Kind, _ start: Int) {
            tokens.append(ShaderToken(kind: kind, range: NSRange(location: start, length: index - start)))
        }
        while index < units.count {
            let unit = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            let start = index
            if unit == 0x0A { lineStart = true; index += 1; continue }
            if unit == 0x20 || unit == 0x09 || unit == 0x0D { index += 1; continue }
            defer { lineStart = false }
            if unit == slash && next == slash {
                while index < units.count, units[index] != 0x0A { index += 1 }
                add(.comment, start)
            } else if unit == slash && next == star {
                index += 2
                while index < units.count, !(units[index] == star && index + 1 < units.count && units[index + 1] == slash) { index += 1 }
                index = min(index + 2, units.count)
                add(.comment, start)
            } else if unit == hash && lineStart {
                // To the end of the line or a comment, a line ending in `\` continuing it.
                while index < units.count, units[index] != 0x0A {
                    if units[index] == slash, index + 1 < units.count, units[index + 1] == slash || units[index + 1] == star { break }
                    if units[index] == backslash, index + 1 < units.count, units[index + 1] == 0x0A { index += 1 }
                    index += 1
                }
                add(.preprocessor, start)
            } else if unit == quote {
                index += 1
                while index < units.count, units[index] != quote, units[index] != 0x0A { index += 1 }
                index = min(index + 1, units.count)
                add(.string, start)
            } else if isDigit(unit) || (unit == dot && isDigit(next)) {
                let isHex = unit == zero && (next == 0x78 || next == 0x58)
                index += 1
                while index < units.count {
                    let current = units[index]
                    let afterExponent = units[index - 1] == 0x65 || units[index - 1] == 0x45
                    if isIdentifier(current) || current == dot || ((current == plus || current == minus) && afterExponent && !isHex) {
                        index += 1 // `1.0f`, `0xFF`, an exponent and its sign (`1e-3`).
                    } else {
                        break
                    }
                }
                add(.number, start)
            } else if isIdentifierStart(unit) {
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                let word = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
                add(ShaderLanguage.kind(of: word), start)
            } else {
                index += 1
                add(.punctuation, start)
            }
        }
        return tokens
    }

    private static let slash: UInt16 = 0x2F, star: UInt16 = 0x2A, hash: UInt16 = 0x23, quote: UInt16 = 0x22
    private static let backslash: UInt16 = 0x5C, dot: UInt16 = 0x2E, plus: UInt16 = 0x2B, minus: UInt16 = 0x2D
    private static let zero: UInt16 = 0x30

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
    }
    static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }
}
