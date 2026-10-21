import Foundation

/// A token of preprocessed GLSL, located by UTF-16 offsets in the text it was read from.
struct GLSLToken {
    enum Kind: Equatable {
        case identifier
        case number(HLSLType.Scalar)
        case punctuation
    }

    let kind: Kind
    let start: Int
    let end: Int
    let text: String
}

/// Splits preprocessed GLSL into tokens. Whitespace, comments and preprocessor lines (`#version`,
/// `#extension`, `#line`) are skipped.
enum GLSLTokenizer {
    private static let threeCharacterOperators: Set<String> = ["<<=", ">>="]
    private static let twoCharacterOperators: Set<String> = [
        "++", "--", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "&&", "||", "^^", "<<", ">>",
        "&=", "|=", "^=",
    ]

    static func tokens(_ code: [UInt16]) -> [GLSLToken] {
        var result: [GLSLToken] = []
        result.reserveCapacity(code.count / 3)
        scan(code) { result.append($0); return true }
        return result
    }

    /// Reads the tokens of `code` in order until `body` returns false.
    static func scan(_ code: [UInt16], _ body: (GLSLToken) -> Bool) {
        let count = code.count
        var index = 0
        var lineStart = true
        func text(_ start: Int, _ end: Int) -> String { String(decoding: code[start..<end], as: UTF16.self) }
        while index < count {
            let c = code[index]
            if c == 10 { lineStart = true; index += 1; continue }
            if c == 32 || c == 9 || c == 13 { index += 1; continue }
            if c == 35, lineStart { // a preprocessor line
                while index < count, code[index] != 10 { index += 1 }
                continue
            }
            lineStart = false
            if c == 47, index + 1 < count, code[index + 1] == 47 {
                while index < count, code[index] != 10 { index += 1 }
                continue
            }
            if c == 47, index + 1 < count, code[index + 1] == 42 {
                index += 2
                while index + 1 < count, !(code[index] == 42 && code[index + 1] == 47) { index += 1 }
                index += 2
                continue
            }
            if isIdentifierStart(c) {
                var end = index + 1
                while end < count, isIdentifier(code[end]) { end += 1 }
                guard body(GLSLToken(kind: .identifier, start: index, end: end, text: text(index, end))) else { return }
                index = end
                continue
            }
            if isDigit(c) || (c == 46 && index + 1 < count && isDigit(code[index + 1])) {
                let (end, scalar) = number(code, from: index)
                guard body(GLSLToken(kind: .number(scalar), start: index, end: end, text: text(index, end))) else { return }
                index = end
                continue
            }
            var length = 1
            if index + 2 < count, threeCharacterOperators.contains(text(index, index + 3)) {
                length = 3
            } else if index + 1 < count, twoCharacterOperators.contains(text(index, index + 2)) {
                length = 2
            }
            guard body(GLSLToken(kind: .punctuation, start: index, end: index + length, text: text(index, index + length))) else { return }
            index += length
        }
    }

    /// The end of the number literal at `start` and its type: a float with a point, an exponent or
    /// an `f`/`lf` suffix, a uint with a `u` suffix, else an int.
    private static func number(_ code: [UInt16], from start: Int) -> (Int, HLSLType.Scalar) {
        let count = code.count
        var end = start
        var isFloat = false
        if code[start] == 48, start + 1 < count, code[start + 1] == 120 || code[start + 1] == 88 { // 0x
            end = start + 2
            while end < count, isHexDigit(code[end]) { end += 1 }
        } else {
            while end < count, isDigit(code[end]) || code[end] == 46 {
                if code[end] == 46 { isFloat = true }
                end += 1
            }
            if end < count, code[end] == 101 || code[end] == 69 { // e, E
                var exponent = end + 1
                if exponent < count, code[exponent] == 43 || code[exponent] == 45 { exponent += 1 }
                if exponent < count, isDigit(code[exponent]) {
                    isFloat = true
                    end = exponent
                    while end < count, isDigit(code[end]) { end += 1 }
                }
            }
        }
        let suffixStart = end
        while end < count, isIdentifier(code[end]) { end += 1 }
        let suffix = String(decoding: code[suffixStart..<end], as: UTF16.self).lowercased()
        if suffix.contains("f") { return (end, .float) }
        if suffix.contains("u") { return (end, .uint) }
        return (end, isFloat ? .float : .int)
    }

    static func isIdentifierStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
    static func isIdentifier(_ c: UInt16) -> Bool { isIdentifierStart(c) || isDigit(c) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private static func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
}
