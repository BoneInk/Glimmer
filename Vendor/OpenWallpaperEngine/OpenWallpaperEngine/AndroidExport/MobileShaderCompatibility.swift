import Foundation

/// The edits WE's mobile export makes to a scene's own shaders (`shaders/*.frag`, `*.vert`), for
/// GLSL ES, which reserves `sample` and has no implicit int-to-float conversion. Taken from WE
/// 2.8.42's export of a Workshop scene, whose six shaders these rules reproduce byte for byte:
///
/// - the identifier `sample` becomes `_sample` (`vec4 sample = …` → `vec4 _sample = …`);
/// - a whole-number literal that is a whole argument of a float constructor (`vec2`–`vec4`,
///   `CAST2`–`CAST4`, `float`, `mat2`–`mat4`) becomes a float (`CAST3(0)` → `CAST3(0.0)`,
///   `vec2(0, 1)` → `vec2(0.0, 1.0)`);
/// - in a `float`/`vecN` declaration with an initialiser, a whole-number literal next to an
///   arithmetic operator becomes a float (`float blend = 2 * abs(…)` → `2.0 * abs(…)`), except
///   inside `[…]` and `int(…)`.
///
/// Preprocessor lines and `//` comments (the annotations) are left alone; line ends are kept.
enum MobileShaderCompatibility {
    static let floatConstructors: Set<String> = ["vec2", "vec3", "vec4", "CAST2", "CAST3", "CAST4", "float", "mat2", "mat3", "mat4"]

    static func rewrite(_ source: String) -> String {
        let separator = source.contains("\r\n") ? "\r\n" : "\n"
        return source.components(separatedBy: separator).map(rewriteLine).joined(separator: separator)
    }

    static func rewriteLine(_ line: String) -> String {
        guard !line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("#") else { return line }
        let commentStart = line.range(of: "//")?.lowerBound ?? line.endIndex
        var code = Array(line[..<commentStart])
        let comment = String(line[commentStart...])
        code = renameSample(code)
        var insertions = Set<Int>()
        for span in constructorArguments(code) {
            let argument = code[span].drop(while: { $0 == " " || $0 == "\t" })
            let trimmed = String(argument).trimmingCharacters(in: .whitespaces)
            let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { continue }
            let start = span.lowerBound + (span.count - argument.count) + (trimmed.hasPrefix("-") ? 1 : 0)
            insertions.insert(start + digits.count)
        }
        if isFloatDeclaration(code), let equals = code.firstIndex(of: "=") {
            for literal in integerLiterals(code, from: equals + 1) where isArithmeticOperand(code, literal) {
                insertions.insert(literal.upperBound)
            }
        }
        for position in insertions.sorted(by: >) { code.insert(contentsOf: ".0", at: position) }
        return String(code) + comment
    }

    // MARK: Pieces

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func renameSample(_ code: [Character]) -> [Character] {
        let word = Array("sample")
        var result: [Character] = []
        var index = 0
        while index < code.count {
            if index + word.count <= code.count, Array(code[index..<index + word.count]) == word,
               index == 0 || !isIdentifier(code[index - 1]),
               index + word.count == code.count || !isIdentifier(code[index + word.count]) {
                result.append(contentsOf: "_sample")
                index += word.count
            } else {
                result.append(code[index])
                index += 1
            }
        }
        return result
    }

    /// The top-level argument spans of every float-constructor call in `code`.
    private static func constructorArguments(_ code: [Character]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var index = 0
        while index < code.count {
            guard isIdentifier(code[index]), index == 0 || !isIdentifier(code[index - 1]) else { index += 1; continue }
            var end = index
            while end < code.count, isIdentifier(code[end]) { end += 1 }
            let name = String(code[index..<end])
            var open = end
            while open < code.count, code[open] == " " || code[open] == "\t" { open += 1 }
            guard floatConstructors.contains(name), open < code.count, code[open] == "(" else { index = end; continue }
            var depth = 0, cursor = open + 1, start = open + 1
            scan: while cursor < code.count {
                switch code[cursor] {
                case "(", "[": depth += 1
                case ")", "]":
                    if depth == 0 { spans.append(start..<cursor); break scan }
                    depth -= 1
                case "," where depth == 0:
                    spans.append(start..<cursor)
                    start = cursor + 1
                default: break
                }
                cursor += 1
            }
            index = end
        }
        return spans
    }

    private static func isFloatDeclaration(_ code: [Character]) -> Bool {
        var words = String(code).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if words.first == "const" { words.removeFirst() }
        if let first = words.first, ["lowp", "mediump", "highp"].contains(first) { words.removeFirst() }
        guard words.count >= 2, ["float", "vec2", "vec3", "vec4"].contains(words[0]) else { return false }
        let rest = words.dropFirst().joined(separator: " ")
        guard let equals = rest.firstIndex(of: "=") else { return false }
        let name = rest[..<equals].trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && name.allSatisfy(isIdentifier) && !rest[rest.index(after: equals)...].hasPrefix("=")
    }

    /// Whole-number literals from `start` on: digits not next to a letter, digit, `_` or `.`.
    private static func integerLiterals(_ code: [Character], from start: Int) -> [Range<Int>] {
        var literals: [Range<Int>] = []
        var index = start
        while index < code.count {
            guard code[index].isASCIIDigit, index == 0 || !(isIdentifier(code[index - 1]) || code[index - 1] == ".") else {
                index += 1
                continue
            }
            var end = index
            while end < code.count, code[end].isASCIIDigit { end += 1 }
            if end == code.count || !(isIdentifier(code[end]) || code[end] == ".") { literals.append(index..<end) }
            index = end
        }
        return literals
    }

    private static func isArithmeticOperand(_ code: [Character], _ literal: Range<Int>) -> Bool {
        let before = code[..<literal.lowerBound]
        guard before.filter({ $0 == "[" }).count <= before.filter({ $0 == "]" }).count, !isInsideIntCall(before) else { return false }
        let previous = before.last(where: { $0 != " " && $0 != "\t" })
        let next = code[literal.upperBound...].first(where: { $0 != " " && $0 != "\t" })
        let operators: Set<Character> = ["*", "/", "+", "-"]
        let trimmedBefore = String(before).trimmingCharacters(in: .whitespaces)
        let afterIncrement = trimmedBefore.hasSuffix("++") || trimmedBefore.hasSuffix("--")
        if let previous, operators.contains(previous) || previous == "=", !afterIncrement { return true }
        if let next, operators.contains(next) { return true }
        return false
    }

    /// Whether the text ends inside an unclosed `int(`.
    private static func isInsideIntCall(_ before: ArraySlice<Character>) -> Bool {
        let text = String(before)
        guard let range = text.range(of: "int(", options: .backwards) ?? text.range(of: "int (", options: .backwards) else { return false }
        if range.lowerBound > text.startIndex, isIdentifier(text[text.index(before: range.lowerBound)]) { return false }
        return !text[range.upperBound...].contains(")")
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
