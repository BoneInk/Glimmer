import Foundation

/// Finds a module's top-level `import` and `export` statements in its tokens and records how to
/// turn the module into a plain function body (`SceneScriptModuleLayout`). Everything else is left
/// to JavaScriptCore, which parses the result for real.
///
/// Accepted: every static ES module form except re-exports: `import 'M'`, `import D`,
/// `import * as X`, `import { a as b }` and their combinations; `export` before `var`/`let`/
/// `const` (with destructuring), `function`, `async function`, `function*` and `class`;
/// `export { a as b }`; `export default` of a declaration or an expression.
///
/// Rejected with `SceneScriptCompileError`: re-exports (`export … from`), dynamic `import()`,
/// `import.meta`, import attributes, a top-level `return`, duplicate exports, and statements that
/// don't start where a statement can. WE's modules (`WEMath`, `WEVector`, `WEColor`) export only
/// plain names, so nothing a WE script can use is lost.
struct SceneScriptModuleScanner {
    /// The local name `export default <expression>` and anonymous default declarations bind.
    static let defaultLocal = "__oweDefault"

    private let tokens: [SceneScriptToken]
    private var layout = SceneScriptModuleLayout()
    private var exported = Set<String>()

    init(tokens: [SceneScriptToken]) {
        self.tokens = tokens
    }

    mutating func scan() throws -> SceneScriptModuleLayout {
        var depth = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            depth += SceneScriptSyntax.depthChange(token)
            switch token.kind {
            case .identifier where !SceneScriptSyntax.isPropertyName(tokens, index):
                switch token.text {
                case "import":
                    if try isDynamicImport(index) {
                        throw error("dynamic import() is not supported; SceneScript imports are static", token)
                    }
                    if index + 1 < tokens.count, tokens[index + 1].isPunctuator(".") {
                        throw error("import.meta is not supported", token)
                    }
                    if depth == 0 {
                        try requireStatementStart(index)
                        index = try scanImport(index)
                        continue
                    }
                case "export" where depth == 0:
                    try requireStatementStart(index)
                    index = try scanExport(index)
                    continue
                case "return" where depth == 0:
                    throw SceneScriptCompileError(message: "SyntaxError: Illegal return statement", line: token.line)
                default:
                    break
                }
            default:
                break
            }
            index += 1
        }
        return layout
    }

    // MARK: - Imports

    /// `import(` that is a call, not a method named `import` (`import() { … }`).
    private func isDynamicImport(_ index: Int) throws -> Bool {
        guard index + 1 < tokens.count, tokens[index + 1].isPunctuator("(") else { return false }
        let close = try matchingClose(index + 1)
        return !(close + 1 < tokens.count && tokens[close + 1].isPunctuator("{"))
    }

    private mutating func scanImport(_ start: Int) throws -> Int {
        var index = start + 1
        var entry = SceneScriptModuleLayout.Import(specifier: "", namespace: nil, line: tokens[start].line)
        if try token(index).kind == .string {
            entry.specifier = SceneScriptStringLiteral.value(of: tokens[index].text)
            index += 1
        } else {
            var clauseStarted = false
            if tokens[index].kind == .identifier {
                entry.bindings.append((imported: "default", local: try bindingName(index)))
                index += 1
                clauseStarted = true
                if try token(index).isPunctuator(",") {
                    index += 1
                    clauseStarted = false
                }
            }
            if !clauseStarted {
                let clause = try token(index)
                if clause.isPunctuator("*") {
                    try expectIdentifier("as", at: index + 1)
                    entry.namespace = try bindingName(index + 2)
                    index += 3
                } else if clause.isPunctuator("{") {
                    index = try scanNamedImports(from: index + 1, into: &entry)
                } else {
                    throw unexpected(clause)
                }
            }
            try expectIdentifier("from", at: index)
            let specifier = try token(index + 1)
            guard specifier.kind == .string else { throw unexpected(specifier) }
            entry.specifier = SceneScriptStringLiteral.value(of: specifier.text)
            index += 2
        }
        if index < tokens.count, tokens[index].isIdentifier("with") || tokens[index].isIdentifier("assert"),
           !tokens[index].newlineBefore {
            throw error("import attributes are not supported", tokens[index])
        }
        let end = try endOfStatement(index)
        layout.edits.append(.blank(tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound, separator: true))
        layout.imports.append(entry)
        return end
    }

    private func scanNamedImports(from start: Int, into entry: inout SceneScriptModuleLayout.Import) throws -> Int {
        var index = start
        while true {
            let name = try token(index)
            if name.isPunctuator("}") { return index + 1 }
            guard name.kind == .identifier || name.kind == .string else { throw unexpected(name) }
            let imported = name.kind == .string ? SceneScriptStringLiteral.value(of: name.text) : name.text
            index += 1
            let local: String
            if try token(index).isIdentifier("as") {
                local = try bindingName(index + 1)
                index += 2
            } else {
                guard name.kind == .identifier else { throw unexpected(tokens[index]) }
                local = try bindingName(index - 1)
            }
            entry.bindings.append((imported: imported, local: local))
            let separator = try token(index)
            if separator.isPunctuator(",") {
                index += 1
            } else if !separator.isPunctuator("}") {
                throw unexpected(separator)
            }
        }
    }

    // MARK: - Exports

    private mutating func scanExport(_ start: Int) throws -> Int {
        let keyword = try token(start + 1)
        guard keyword.kind == .identifier || keyword.kind == .punctuator else { throw unexpected(keyword) }
        let exportRange = tokens[start].range
        switch keyword.text {
        case "var", "let", "const":
            let names = try SceneScriptBindingNames(tokens: tokens).declared(from: start + 2)
            for name in names { try addExport(name, local: name, at: tokens[start]) }
            layout.edits.append(.blank(exportRange, separator: false))
            return start + 1
        case "function", "async", "class":
            guard let name = try declarationName(at: start + 1) else {
                throw SceneScriptCompileError(message: "SyntaxError: Function statements require a function name",
                                              line: keyword.line)
            }
            try addExport(name, local: name, at: tokens[start])
            layout.edits.append(.blank(exportRange, separator: false))
            return start + 1
        case "{":
            return try scanExportList(start)
        case "*":
            throw error("re-exports (export * from …) are not supported", keyword)
        case "default":
            return try scanDefaultExport(start)
        default:
            throw unexpected(keyword)
        }
    }

    private mutating func scanExportList(_ start: Int) throws -> Int {
        var index = start + 2
        var entries: [(name: String, local: String)] = []
        while true {
            let local = try token(index)
            if local.isPunctuator("}") { break }
            guard local.kind == .identifier || local.kind == .string else { throw unexpected(local) }
            index += 1
            var name = local.kind == .string ? SceneScriptStringLiteral.value(of: local.text) : local.text
            if try token(index).isIdentifier("as") {
                let alias = try token(index + 1)
                guard alias.kind == .identifier || alias.kind == .string else { throw unexpected(alias) }
                name = alias.kind == .string ? SceneScriptStringLiteral.value(of: alias.text) : alias.text
                index += 2
            }
            entries.append((name: name, local: local.kind == .string ? "" : local.text))
            let separator = try token(index)
            if separator.isPunctuator(",") {
                index += 1
            } else if !separator.isPunctuator("}") {
                throw unexpected(separator)
            }
        }
        index += 1
        if index < tokens.count, tokens[index].isIdentifier("from") {
            throw error("re-exports (export { … } from …) are not supported", tokens[index])
        }
        for entry in entries {
            guard !entry.local.isEmpty, !SceneScriptSyntax.reservedWords.contains(entry.local) else {
                throw error("export { … } must name local bindings", tokens[start + 1])
            }
            try addExport(entry.name, local: entry.local, at: tokens[start])
        }
        let end = try endOfStatement(index)
        layout.edits.append(.blank(tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound, separator: true))
        return end
    }

    /// `export default function|class [name] …` stays a declaration (hoisted, as in a module); an
    /// anonymous one is given `defaultLocal` as its name. `export default <expression>` becomes
    /// `const __oweDefault = <expression>`, which ends where the export would.
    private mutating func scanDefaultExport(_ start: Int) throws -> Int {
        let keyword = start + 1
        let prefix = tokens[start].range.lowerBound..<tokens[keyword].range.upperBound
        let value = try token(keyword + 1)
        if value.isIdentifier("function") || value.isIdentifier("class")
            || (value.isIdentifier("async") && keyword + 2 < tokens.count
                && tokens[keyword + 2].isIdentifier("function") && !tokens[keyword + 2].newlineBefore) {
            layout.edits.append(.blank(prefix, separator: false))
            if let name = try declarationName(at: keyword + 1) {
                try addExport("default", local: name, at: tokens[start])
            } else {
                let nameAfter = try anonymousNamePosition(at: keyword + 1)
                layout.edits.append(.replace(nameAfter..<nameAfter, with: " " + Self.defaultLocal))
                try addExport("default", local: Self.defaultLocal, at: tokens[start])
            }
            return keyword + 1
        }
        layout.edits.append(.replace(prefix, with: "const \(Self.defaultLocal) ="))
        try addExport("default", local: Self.defaultLocal, at: tokens[start])
        return keyword + 1
    }

    /// The name of the `function`, `async function`, `function*` or `class` declaration at
    /// `index`, or nil when it has none.
    private func declarationName(at index: Int) throws -> String? {
        var cursor = index
        if tokens[cursor].isIdentifier("async") {
            cursor += 1
            guard try token(cursor).isIdentifier("function"), !tokens[cursor].newlineBefore else {
                throw unexpected(tokens[cursor])
            }
        }
        cursor += 1
        if tokens[cursor - 1].isIdentifier("function"), try token(cursor).isPunctuator("*") { cursor += 1 }
        let name = try token(cursor)
        guard name.kind == .identifier, !(tokens[index].isIdentifier("class") && name.text == "extends") else {
            return nil
        }
        return try bindingName(cursor)
    }

    /// Where an anonymous default `function`, `function*` or `class` gets its name inserted.
    private func anonymousNamePosition(at index: Int) throws -> Int {
        var cursor = index
        if tokens[cursor].isIdentifier("async") { cursor += 1 }
        if tokens[cursor].isIdentifier("function"), try token(cursor + 1).isPunctuator("*") { cursor += 1 }
        return tokens[cursor].range.upperBound
    }

    private mutating func addExport(_ name: String, local: String, at token: SceneScriptToken) throws {
        guard exported.insert(name).inserted else {
            throw SceneScriptCompileError(message: "SyntaxError: Duplicate export of '\(name)'", line: token.line)
        }
        layout.exports.append(.init(name: name, local: local))
    }

    // MARK: - Statements

    /// An `import`/`export` at `index` must start a statement: after `;`, a block, or a line break
    /// that ends the previous statement.
    private func requireStatementStart(_ index: Int) throws {
        guard index > 0 else { return }
        let previous = tokens[index - 1]
        let token = tokens[index]
        if previous.isPunctuator(";") { return }
        if previous.isPunctuator("}"), !previous.closesExpression || token.newlineBefore { return }
        if token.newlineBefore, SceneScriptSyntax.canEndExpression(tokens, index - 1),
           !(previous.isPunctuator(")") && previous.closesControlHead) {
            return
        }
        throw unexpected(token)
    }

    /// The index after the statement that ends at `index`: past its `;`, or at a line break.
    private func endOfStatement(_ index: Int) throws -> Int {
        guard index < tokens.count else { return index }
        if tokens[index].isPunctuator(";") { return index + 1 }
        if tokens[index].newlineBefore { return index }
        throw unexpected(tokens[index])
    }

    // MARK: - Tokens

    private func token(_ index: Int) throws -> SceneScriptToken {
        guard index < tokens.count else {
            let line = tokens.last?.line ?? 1
            throw SceneScriptCompileError(message: "SyntaxError: Unexpected end of input", line: line)
        }
        return tokens[index]
    }

    private func bindingName(_ index: Int) throws -> String {
        let name = try token(index)
        guard name.kind == .identifier, !SceneScriptSyntax.reservedWords.contains(name.text) else {
            throw unexpected(name)
        }
        return name.text
    }

    private func expectIdentifier(_ text: String, at index: Int) throws {
        let found = try token(index)
        guard found.isIdentifier(text) else { throw unexpected(found) }
    }

    private func matchingClose(_ open: Int) throws -> Int {
        guard let close = SceneScriptSyntax.matchingClose(tokens, open) else {
            throw SceneScriptCompileError(message: "SyntaxError: Unexpected end of input", line: tokens.last?.line ?? 1)
        }
        return close
    }

    private func unexpected(_ token: SceneScriptToken) -> SceneScriptCompileError {
        SceneScriptCompileError(message: "SyntaxError: Unexpected token '\(token.text)'", line: token.line)
    }

    private func error(_ message: String, _ token: SceneScriptToken) -> SceneScriptCompileError {
        SceneScriptCompileError(message: "SyntaxError: \(message)", line: token.line)
    }
}
