import Foundation

/// One JavaScript token of a SceneScript module, as `SceneScriptTokenizer` produces it. Ranges are
/// UTF-16 offsets into the source, so edits can be applied without re-reading it.
struct SceneScriptToken {
    enum Kind {
        /// Identifiers and keywords alike; the text tells them apart (`SceneScriptSyntax`).
        case identifier
        /// `#name` (a class's private member).
        case privateName
        case punctuator
        case number
        case string
        /// A template literal without substitutions: `` `…` ``.
        case template
        /// `` `…${ ``
        case templateHead
        /// `}…${`
        case templateMiddle
        /// `` }…` ``
        case templateTail
        case regex
    }

    var kind: Kind
    var range: Range<Int>
    /// 1-based line of the token's first character.
    var line: Int
    /// A line terminator separates this token from the previous one (automatic semicolon insertion).
    var newlineBefore: Bool
    var text: String
    /// For `)`: it closes the head of `if`, `for`, `while`, `with`, `switch` or `catch`, so what
    /// follows starts a statement.
    var closesControlHead = false
    /// For `}`: it closes an object literal or the body of a function or class *expression*, so an
    /// operator may follow it.
    var closesExpression = false

    func isPunctuator(_ text: String) -> Bool {
        kind == .punctuator && self.text == text
    }

    func isIdentifier(_ text: String) -> Bool {
        kind == .identifier && self.text == text
    }
}
