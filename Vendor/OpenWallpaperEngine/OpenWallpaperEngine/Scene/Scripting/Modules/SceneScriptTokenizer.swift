import Foundation

/// Splits a SceneScript module into tokens (ECMAScript 2024 §12): identifiers, numbers, strings,
/// template literals with nested substitutions, regular expressions, punctuators; comments and
/// whitespace are skipped but line terminators are remembered for automatic semicolon insertion.
///
/// Whether `/` starts a regex depends on the token before it, and after `)` or `}` on what the
/// bracket closed, so the tokenizer keeps a bracket stack that knows control heads (`if (…)`),
/// blocks, object literals and function or class expressions apart.
///
/// Errors are V8's messages (WE runs its scripts in V8), with the line the bad token starts on.
struct SceneScriptTokenizer {
    private enum Bracket {
        /// `control`: the head of `if`/`for`/`while`/…; `functionExpression`: the parameters of a
        /// `function` in expression position (true) or of a declaration (false), nil otherwise.
        case paren(control: Bool, functionExpression: Bool?)
        case square
        /// `expression`: an object literal or the body of a function or class expression.
        case brace(expression: Bool)
        /// A template literal's `${ … }`.
        case substitution
    }

    /// A `function` or `class` keyword whose parameters or body are still ahead, at `depth`.
    private struct Pending {
        var isExpression: Bool
        var depth: Int
    }

    private let units: [UInt16]
    private var position = 0
    private var line = 1
    private var sawNewline = false
    /// The line the token being scanned starts on.
    private var tokenLine = 1
    private var tokens: [SceneScriptToken] = []
    private var stack: [Bracket] = []
    private var pendingFunction: Pending?
    private var pendingClass: Pending?
    /// What the last `)` closed; the `{` right after a function's parameters needs it.
    private var lastClosedParenFunctionExpression: Bool?

    static func tokenize(_ source: String) throws -> [SceneScriptToken] {
        try tokenize(Array(source.utf16))
    }

    static func tokenize(_ units: [UInt16]) throws -> [SceneScriptToken] {
        var tokenizer = SceneScriptTokenizer(units: units)
        try tokenizer.run()
        return tokenizer.tokens
    }

    private init(units: [UInt16]) {
        self.units = units
    }

    private mutating func run() throws {
        // A hashbang comment is allowed only at the very start (ECMAScript 2023).
        if units.count >= 2, units[0] == 0x23, units[1] == 0x21 {
            while position < units.count, !SceneScriptSyntax.isLineTerminator(units[position]) { position += 1 }
        }
        while true {
            try skipTrivia()
            guard position < units.count else { break }
            try scanToken()
        }
        if !stack.isEmpty {
            throw SceneScriptCompileError(message: "SyntaxError: Unexpected end of input", line: line)
        }
    }

    // MARK: - Trivia

    private mutating func skipTrivia() throws {
        while position < units.count {
            let unit = units[position]
            if SceneScriptSyntax.isLineTerminator(unit) {
                consumeLineTerminator()
                sawNewline = true
            } else if SceneScriptSyntax.isWhitespace(unit) {
                position += 1
            } else if unit == slash, peek(1) == slash {
                while position < units.count, !SceneScriptSyntax.isLineTerminator(units[position]) { position += 1 }
            } else if unit == slash, peek(1) == star {
                try skipBlockComment()
            } else {
                return
            }
        }
    }

    private mutating func skipBlockComment() throws {
        let startLine = line
        position += 2
        while position < units.count {
            if units[position] == star, peek(1) == slash {
                position += 2
                return
            }
            if SceneScriptSyntax.isLineTerminator(units[position]) {
                consumeLineTerminator()
                sawNewline = true
            } else {
                position += 1
            }
        }
        throw invalidToken(line: startLine)
    }

    // MARK: - Tokens

    private mutating func scanToken() throws {
        let start = position
        tokenLine = line
        let unit = units[position]
        if unit == backtick {
            try scanTemplate(from: start, isHead: true)
        } else if SceneScriptSyntax.isIdentifierStart(unit) {
            scanIdentifierName()
            append(.identifier, from: start)
            noteKeyword()
        } else if SceneScriptSyntax.isDigit(unit) || (unit == dot && peek(1).map(SceneScriptSyntax.isDigit) == true) {
            scanNumber()
            append(.number, from: start)
        } else if unit == doubleQuote || unit == singleQuote {
            try scanString(quote: unit)
            append(.string, from: start)
        } else if unit == hash, let next = peek(1), SceneScriptSyntax.isIdentifierStart(next) {
            position += 1
            scanIdentifierName()
            append(.privateName, from: start)
        } else if unit == slash, SceneScriptSyntax.regexAllowed(after: tokens) {
            try scanRegex()
            append(.regex, from: start)
        } else {
            try scanPunctuator()
        }
    }

    private mutating func scanIdentifierName() {
        while position < units.count, SceneScriptSyntax.isIdentifierPart(units[position]) {
            if units[position] == backslash {
                // `\uXXXX` or `\u{X…}`; JavaScriptCore validates it.
                position += 2
                if position < units.count, units[position] == openBrace {
                    while position < units.count, units[position] != closeBrace { position += 1 }
                    position += 1
                } else {
                    position += 4
                }
                position = min(position, units.count)
            } else {
                position += 1
            }
        }
    }

    private mutating func scanNumber() {
        if units[position] == zero, let prefix = peek(1), [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(prefix) {
            position += 2
            while position < units.count, SceneScriptSyntax.isIdentifierPart(units[position]) { position += 1 }
            return
        }
        consumeDigits()
        if position < units.count, units[position] == dot {
            position += 1
            consumeDigits()
        }
        if position < units.count, units[position] == 0x65 || units[position] == 0x45 {
            position += 1
            if position < units.count, units[position] == 0x2B || units[position] == 0x2D { position += 1 }
            consumeDigits()
        }
        // A BigInt's `n`, or letters JavaScriptCore reports as an error.
        while position < units.count, SceneScriptSyntax.isIdentifierPart(units[position]) { position += 1 }
    }

    private mutating func consumeDigits() {
        while position < units.count, SceneScriptSyntax.isDigit(units[position]) || units[position] == 0x5F {
            position += 1
        }
    }

    private mutating func scanString(quote: UInt16) throws {
        let startLine = line
        position += 1
        while position < units.count {
            let unit = units[position]
            if unit == quote {
                position += 1
                return
            }
            if unit == backslash {
                position += 1
                guard position < units.count else { break }
                if SceneScriptSyntax.isLineTerminator(units[position]) { consumeLineTerminator() } else { position += 1 }
            } else if unit == 0x0A || unit == 0x0D {
                // A raw line break inside a string (U+2028/9 are allowed since ES2019).
                break
            } else if SceneScriptSyntax.isLineTerminator(unit) {
                consumeLineTerminator()
            } else {
                position += 1
            }
        }
        throw invalidToken(line: startLine)
    }

    /// Scans from `` ` `` (`isHead`) or from the `}` that closes a substitution, up to and
    /// including the closing `` ` `` or the next `${`.
    private mutating func scanTemplate(from start: Int, isHead: Bool) throws {
        let startLine = line
        position += 1
        while position < units.count {
            let unit = units[position]
            if unit == backtick {
                position += 1
                append(isHead ? .template : .templateTail, from: start, line: startLine)
                return
            }
            if unit == dollar, peek(1) == openBrace {
                position += 2
                append(isHead ? .templateHead : .templateMiddle, from: start, line: startLine)
                stack.append(.substitution)
                return
            }
            if unit == backslash {
                position += 1
                guard position < units.count else { break }
            }
            if SceneScriptSyntax.isLineTerminator(units[position]) { consumeLineTerminator() } else { position += 1 }
        }
        throw SceneScriptCompileError(message: "SyntaxError: Unterminated template literal", line: startLine)
    }

    private mutating func scanRegex() throws {
        let startLine = line
        position += 1
        var inClass = false
        while position < units.count {
            let unit = units[position]
            if SceneScriptSyntax.isLineTerminator(unit) { break }
            position += 1
            if unit == backslash {
                guard position < units.count, !SceneScriptSyntax.isLineTerminator(units[position]) else { break }
                position += 1
            } else if unit == openBracket {
                inClass = true
            } else if unit == closeBracket {
                inClass = false
            } else if unit == slash, !inClass {
                while position < units.count, SceneScriptSyntax.isIdentifierPart(units[position]) { position += 1 }
                return
            }
        }
        throw SceneScriptCompileError(message: "SyntaxError: Invalid regular expression: missing /", line: startLine)
    }

    private mutating func scanPunctuator() throws {
        let start = position
        guard let text = SceneScriptSyntax.punctuators.first(where: matches) else {
            throw invalidToken(line: line)
        }
        position += text.utf16.count
        switch text {
        case "(":
            openParen(from: start)
        case "[":
            append(.punctuator, from: start)
            stack.append(.square)
        case "{":
            let isExpression = braceIsExpression()
            append(.punctuator, from: start)
            stack.append(.brace(expression: isExpression))
        case ")", "]", "}":
            try close(text, from: start)
        default:
            append(.punctuator, from: start)
        }
    }

    /// The punctuator `text` starts at `position`. `?.` followed by a digit is `?` then a number.
    private func matches(_ text: String) -> Bool {
        guard units[position...].starts(with: text.utf16) else { return false }
        if text == "?.", let next = peek(2), SceneScriptSyntax.isDigit(next) { return false }
        return true
    }

    private mutating func openParen(from start: Int) {
        let index = tokens.count
        var control = false
        if index > 0 {
            if SceneScriptSyntax.controlKeywords.contains(tokens[index - 1].text),
               tokens[index - 1].kind == .identifier, !SceneScriptSyntax.isPropertyName(tokens, index - 1) {
                control = true
            } else if index > 1, SceneScriptSyntax.isKeyword(tokens, index - 1, "await"),
                      SceneScriptSyntax.isKeyword(tokens, index - 2, "for") {
                control = true
            }
        }
        var functionExpression: Bool?
        if let pending = pendingFunction, pending.depth == stack.count {
            functionExpression = pending.isExpression
            pendingFunction = nil
        }
        append(.punctuator, from: start)
        stack.append(.paren(control: control, functionExpression: functionExpression))
    }

    private mutating func close(_ text: String, from start: Int) throws {
        let open = stack.popLast()
        switch (text, open) {
        case (")", .paren(let control, let functionExpression)?):
            append(.punctuator, from: start)
            tokens[tokens.count - 1].closesControlHead = control
            lastClosedParenFunctionExpression = functionExpression
        case ("]", .square?):
            append(.punctuator, from: start)
        case ("}", .brace(let expression)?):
            append(.punctuator, from: start)
            tokens[tokens.count - 1].closesExpression = expression
        case ("}", .substitution?):
            position = start
            try scanTemplate(from: start, isHead: false)
        default:
            throw SceneScriptCompileError(message: "SyntaxError: Unexpected token '\(text)'", line: line)
        }
    }

    // MARK: - Context

    /// After an identifier: `function` and `class` decide what their body's `}` closes.
    private mutating func noteKeyword() {
        let index = tokens.count - 1
        guard !SceneScriptSyntax.isPropertyName(tokens, index) else { return }
        switch tokens[index].text {
        case "function":
            // `async function`: the statement position is decided before `async`.
            var before = index - 1
            if before >= 0, tokens[before].isIdentifier("async"), !tokens[index].newlineBefore { before -= 1 }
            let isDeclaration = startsStatement(after: before, newlineBefore: tokens[before + 1].newlineBefore)
            pendingFunction = Pending(isExpression: !isDeclaration, depth: stack.count)
        case "class":
            let isDeclaration = startsStatement(after: index - 1, newlineBefore: tokens[index].newlineBefore)
            pendingClass = Pending(isExpression: !isDeclaration, depth: stack.count)
        default:
            break
        }
    }

    /// A token after `tokens[previous]` (or at the start when `previous < 0`) starts a statement.
    private func startsStatement(after previous: Int, newlineBefore: Bool) -> Bool {
        guard previous >= 0 else { return true }
        let token = tokens[previous]
        if token.kind == .punctuator {
            switch token.text {
            case ";": return true
            case "}": return !token.closesExpression || newlineBefore
            case "{":
                if case .brace(expression: false)? = stack.last { return true }
                return false
            case ")": return token.closesControlHead || newlineBefore
            case ":", "=>": return false
            default: break
            }
        }
        if token.kind == .identifier, !SceneScriptSyntax.isPropertyName(tokens, previous),
           ["else", "do", "export", "default"].contains(token.text) {
            return true
        }
        return newlineBefore && SceneScriptSyntax.canEndExpression(tokens, previous)
    }

    /// Classifies the `{` about to be appended: an object literal or expression body (true), or a
    /// block, a declaration's body, an arrow body or a class declaration's body (false).
    private mutating func braceIsExpression() -> Bool {
        if let pending = pendingClass, pending.depth == stack.count {
            pendingClass = nil
            return pending.isExpression
        }
        let previous = tokens.count - 1
        guard previous >= 0 else { return false }
        let token = tokens[previous]
        if token.isPunctuator(")") { return lastClosedParenFunctionExpression == true }
        if token.isPunctuator("=>") { return false }
        if startsStatement(after: previous, newlineBefore: sawNewline) { return false }
        if token.kind == .identifier, !SceneScriptSyntax.isPropertyName(tokens, previous) {
            switch token.text {
            case "try", "finally": return false
            case "return", "yield": return !sawNewline
            default: break
            }
        }
        if token.isPunctuator(":") {
            // An object literal's value, or a `case`/label body; a ternary's `: {` is rare enough.
            if case .brace(expression: false)? = stack.last { return false }
            if stack.isEmpty { return false }
        }
        return true
    }

    // MARK: - Helpers

    private mutating func append(_ kind: SceneScriptToken.Kind, from start: Int, line tokenLine: Int? = nil) {
        let text = String(decoding: units[start..<position], as: UTF16.self)
        tokens.append(SceneScriptToken(kind: kind, range: start..<position, line: tokenLine ?? self.tokenLine,
                                       newlineBefore: sawNewline, text: text))
        sawNewline = false
    }

    private mutating func consumeLineTerminator() {
        if units[position] == 0x0D, peek(1) == 0x0A { position += 2 } else { position += 1 }
        line += 1
    }

    private func peek(_ offset: Int) -> UInt16? {
        position + offset < units.count ? units[position + offset] : nil
    }

    /// V8's message for a token it cannot scan (an unterminated string or comment, a stray character).
    private func invalidToken(line: Int) -> SceneScriptCompileError {
        SceneScriptCompileError(message: "SyntaxError: Invalid or unexpected token", line: line)
    }

    private let slash: UInt16 = 0x2F
    private let star: UInt16 = 0x2A
    private let backslash: UInt16 = 0x5C
    private let backtick: UInt16 = 0x60
    private let dollar: UInt16 = 0x24
    private let hash: UInt16 = 0x23
    private let dot: UInt16 = 0x2E
    private let zero: UInt16 = 0x30
    private let singleQuote: UInt16 = 0x27
    private let doubleQuote: UInt16 = 0x22
    private let openBrace: UInt16 = 0x7B
    private let closeBrace: UInt16 = 0x7D
    private let openBracket: UInt16 = 0x5B
    private let closeBracket: UInt16 = 0x5D
}
