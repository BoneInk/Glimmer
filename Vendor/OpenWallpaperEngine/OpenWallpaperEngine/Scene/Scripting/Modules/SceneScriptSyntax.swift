import Foundation

/// The few grammar facts the module compiler needs without a full parser: where a regex may start,
/// where automatic semicolon insertion ends a statement, and which characters form which tokens
/// (ECMAScript 2024 §12). JavaScriptCore parses the result for real; these only have to find the
/// module's top-level `import`/`export` statements and keep bracket depth right.
enum SceneScriptSyntax {
    /// Reserved words, plus the ones strict mode and modules reserve.
    static let reservedWords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
        "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "implements", "import",
        "in", "instanceof", "interface", "let", "new", "null", "package", "private", "protected", "public",
        "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while",
        "with", "yield",
    ]

    /// Keywords that are complete expressions.
    private static let valueKeywords: Set<String> = ["this", "super", "null", "true", "false"]

    /// Keywords after which `/` starts a regular expression rather than a division.
    private static let regexPrecedingKeywords: Set<String> = [
        "return", "typeof", "instanceof", "in", "new", "delete", "void", "throw", "case", "do", "else",
        "yield", "await", "extends",
    ]

    /// Keywords whose parenthesised head is followed by a statement.
    static let controlKeywords: Set<String> = ["if", "while", "for", "with", "switch", "catch"]

    /// Punctuators that can continue an expression on the next line, so no semicolon is inserted
    /// before them (ECMAScript §12.10). `++`/`--` are restricted productions and `{`, `!`, `~` can't
    /// follow an expression, so a line starting with them starts a statement.
    private static let continuingPunctuators: Set<String> = [
        "(", "[", ".", "?.", ",", "?", ":", "=>",
        "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=",
        "==", "!=", "===", "!==", "<", ">", "<=", ">=", "+", "-", "*", "/", "%", "**", "&", "|", "^",
        "&&", "||", "??", "<<", ">>", ">>>",
    ]

    /// Punctuators, longest first so the scanner can take the first match.
    static let punctuators: [String] = [
        ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
        "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/=", "%=", "&=",
        "|=", "^=", "**", "<<", ">>",
        "{", "}", "(", ")", "[", "]", ";", ",", "<", ">", "+", "-", "*", "/", "%", "&", "|", "^", "!", "~",
        "?", ":", "=", ".", "@",
    ]

    // MARK: - Token context

    /// The identifier at `index` follows `.` or `?.`, so it is a property name, never a keyword.
    static func isPropertyName(_ tokens: [SceneScriptToken], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = tokens[index - 1]
        return previous.isPunctuator(".") || previous.isPunctuator("?.")
    }

    /// The token at `index` is the keyword `name` (not a property name spelled the same).
    static func isKeyword(_ tokens: [SceneScriptToken], _ index: Int, _ name: String) -> Bool {
        tokens[index].isIdentifier(name) && !isPropertyName(tokens, index)
    }

    /// The token at `index` can be the last token of an expression.
    static func canEndExpression(_ tokens: [SceneScriptToken], _ index: Int) -> Bool {
        let token = tokens[index]
        switch token.kind {
        case .identifier:
            if isPropertyName(tokens, index) { return true }
            return !reservedWords.contains(token.text) || valueKeywords.contains(token.text)
        case .number, .string, .template, .templateTail, .regex, .privateName:
            return true
        case .punctuator:
            return [")", "]", "}", "++", "--"].contains(token.text)
        case .templateHead, .templateMiddle:
            return false
        }
    }

    /// `token`, at the start of a line, continues the expression of the line before it.
    static func canContinueExpression(_ token: SceneScriptToken) -> Bool {
        switch token.kind {
        case .template, .templateHead:
            return true
        case .punctuator:
            return continuingPunctuators.contains(token.text)
        case .identifier:
            return token.text == "in" || token.text == "instanceof"
        default:
            return false
        }
    }

    /// Automatic semicolon insertion ends the statement before the token at `index`, given that
    /// it is inside an expression at that expression's own nesting level.
    static func endsStatementByASI(_ tokens: [SceneScriptToken], _ index: Int) -> Bool {
        guard index > 0 else { return false }
        let token = tokens[index]
        return token.newlineBefore && canEndExpression(tokens, index - 1) && !canContinueExpression(token)
    }

    /// A `/` after the last of `tokens` starts a regular expression rather than a division.
    /// After `)` that depends on what the parenthesis closed, after `}` on what the brace closed;
    /// the tokenizer records both on the token.
    static func regexAllowed(after tokens: [SceneScriptToken]) -> Bool {
        guard let previous = tokens.last else { return true }
        let index = tokens.count - 1
        switch previous.kind {
        case .identifier:
            if isPropertyName(tokens, index) { return false }
            return regexPrecedingKeywords.contains(previous.text)
        case .punctuator:
            switch previous.text {
            case ")": return previous.closesControlHead
            case "]", "++", "--": return false
            case "}": return !previous.closesExpression
            default: return true
            }
        case .templateHead, .templateMiddle:
            return true
        case .number, .string, .template, .templateTail, .regex, .privateName:
            return false
        }
    }

    /// +1 for a token that opens a bracket (or a template substitution), -1 for one that closes
    /// it, 0 otherwise. A template's middle part closes one substitution and opens the next.
    static func depthChange(_ token: SceneScriptToken) -> Int {
        switch token.kind {
        case .punctuator:
            switch token.text {
            case "(", "[", "{": return 1
            case ")", "]", "}": return -1
            default: return 0
            }
        case .templateHead: return 1
        case .templateTail: return -1
        default: return 0
        }
    }

    /// The index of the token closing the bracket opened at `open`, or nil at the end of input.
    static func matchingClose(_ tokens: [SceneScriptToken], _ open: Int) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            depth += depthChange(tokens[index])
            if depth == 0 { return index }
        }
        return nil
    }

    // MARK: - Characters (UTF-16 code units)

    static func isLineTerminator(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09, 0x0B, 0x0C, 0x20, 0xA0, 0xFEFF, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    /// ASCII letters, `$`, `_`, `\` (a `\u` escape) and any non-ASCII unit that is not whitespace.
    /// JavaScriptCore rejects the non-ASCII units that are not ID_Start.
    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x41...0x5A, 0x61...0x7A, 0x24, 0x5F, 0x5C:
            return true
        default:
            return unit >= 0x80 && !isWhitespace(unit) && !isLineTerminator(unit)
        }
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }
}
