import Foundation

/// The names an exported `var`/`let`/`const` declaration binds, destructuring patterns included
/// (`export const { a, b: [c, d = 1], ...rest } = …` binds a, c, d and rest). Initializers and
/// defaults are skipped, up to the `,` that starts the next declarator or the end of the statement
/// (`;` or automatic semicolon insertion).
struct SceneScriptBindingNames {
    let tokens: [SceneScriptToken]

    /// The names bound by the declarator list starting at `start` (the token after the keyword).
    func declared(from start: Int) throws -> [String] {
        var index = start
        var names: [String] = []
        while true {
            try collect(&index, into: &names)
            if index < tokens.count, tokens[index].isPunctuator("=") { index = skipExpression(from: index + 1) }
            guard index < tokens.count, tokens[index].isPunctuator(",") else { return names }
            index += 1
        }
    }

    private func collect(_ index: inout Int, into names: inout [String]) throws {
        let first = try token(index)
        if first.kind == .identifier, !SceneScriptSyntax.reservedWords.contains(first.text) {
            names.append(first.text)
            index += 1
        } else if first.isPunctuator("{") {
            index += 1
            try collectObjectPattern(&index, into: &names)
        } else if first.isPunctuator("[") {
            index += 1
            try collectArrayPattern(&index, into: &names)
        } else {
            throw unexpected(first)
        }
    }

    private func collectObjectPattern(_ index: inout Int, into names: inout [String]) throws {
        while true {
            let entry = try token(index)
            if entry.isPunctuator("}") {
                index += 1
                return
            }
            if entry.isPunctuator("...") {
                index += 1
                try collect(&index, into: &names)
            } else {
                var shorthand: SceneScriptToken?
                if entry.isPunctuator("[") {
                    index = try matchingClose(index) + 1
                } else if entry.kind == .identifier {
                    shorthand = entry
                    index += 1
                } else if entry.kind == .string || entry.kind == .number {
                    index += 1
                } else {
                    throw unexpected(entry)
                }
                if try token(index).isPunctuator(":") {
                    index += 1
                    try collect(&index, into: &names)
                } else if let shorthand, !SceneScriptSyntax.reservedWords.contains(shorthand.text) {
                    names.append(shorthand.text)
                } else {
                    throw unexpected(tokens[index])
                }
                if try token(index).isPunctuator("=") { index = skipExpression(from: index + 1) }
            }
            let separator = try token(index)
            if separator.isPunctuator(",") {
                index += 1
            } else if !separator.isPunctuator("}") {
                throw unexpected(separator)
            }
        }
    }

    private func collectArrayPattern(_ index: inout Int, into names: inout [String]) throws {
        while true {
            let element = try token(index)
            if element.isPunctuator("]") {
                index += 1
                return
            }
            if element.isPunctuator(",") {
                index += 1
                continue
            }
            if element.isPunctuator("...") { index += 1 }
            try collect(&index, into: &names)
            if try token(index).isPunctuator("=") { index = skipExpression(from: index + 1) }
            let separator = try token(index)
            if separator.isPunctuator(",") {
                index += 1
            } else if !separator.isPunctuator("]") {
                throw unexpected(separator)
            }
        }
    }

    /// The index of the first token after the expression starting at `start`: a `,` or `;` at the
    /// expression's own level, a bracket closing an enclosing one, or where a semicolon is inserted.
    func skipExpression(from start: Int) -> Int {
        var depth = 0
        var index = start
        while index < tokens.count {
            let token = tokens[index]
            if depth == 0 {
                if token.isPunctuator(",") || token.isPunctuator(";") { return index }
                if token.kind == .punctuator, [")", "]", "}"].contains(token.text) { return index }
                if token.kind == .templateMiddle || token.kind == .templateTail { return index }
                if index > start, SceneScriptSyntax.endsStatementByASI(tokens, index) { return index }
            }
            depth += SceneScriptSyntax.depthChange(token)
            index += 1
        }
        return index
    }

    private func matchingClose(_ open: Int) throws -> Int {
        guard let close = SceneScriptSyntax.matchingClose(tokens, open) else { throw endOfInput }
        return close
    }

    private func token(_ index: Int) throws -> SceneScriptToken {
        guard index < tokens.count else { throw endOfInput }
        return tokens[index]
    }

    private var endOfInput: SceneScriptCompileError {
        SceneScriptCompileError(message: "SyntaxError: Unexpected end of input", line: tokens.last?.line ?? 1)
    }

    private func unexpected(_ token: SceneScriptToken) -> SceneScriptCompileError {
        SceneScriptCompileError(message: "SyntaxError: Unexpected token '\(token.text)'", line: token.line)
    }
}
