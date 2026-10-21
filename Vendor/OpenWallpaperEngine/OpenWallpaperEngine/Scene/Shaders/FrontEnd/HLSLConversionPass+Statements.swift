import Foundation

extension HLSLConversionPass {
    /// `{ statements }` at `position`, in a scope of its own.
    mutating func block() throws {
        try expect("{")
        scopes.append([:])
        defer { scopes.removeLast() }
        while !isPunctuation("}") {
            guard position < tokens.count else { throw Failure() }
            statementOrSkip()
        }
        position += 1
    }

    /// One statement; one that can't be typed is left as written.
    mutating func statementOrSkip() {
        let mark = edits.count
        let start = position
        let depth = scopes.count
        do {
            try statement()
        } catch {
            edits.rollBack(to: mark)
            scopes.removeLast(scopes.count - depth)
            position = start
            skipStatement()
        }
        if position == start { position += 1 }
    }

    mutating func statement() throws {
        guard let token = current else { throw Failure() }
        if token.kind == .punctuation {
            switch token.text {
            case "{": try block(); return
            case ";": position += 1; return
            default: break
            }
        }
        switch token.text {
        case "if":
            position += 1
            try condition()
            try nested()
            if peek() == "else" {
                position += 1
                try nested()
            }
        case "while":
            position += 1
            try condition()
            try nested()
        case "do":
            position += 1
            try nested()
            guard peek() == "while" else { throw Failure() }
            position += 1
            try condition()
            try expect(";")
        case "for":
            position += 1
            try expect("(")
            scopes.append([:])
            defer { scopes.removeLast() }
            if !isPunctuation(";") {
                if isDeclarationStart() { try declaration() } else { _ = try expression(); try expect(";") }
            } else {
                position += 1
            }
            if !isPunctuation(";") {
                let test = try expression()
                convert(test, to: .scalar(.bool), onlyScalars: true)
            }
            try expect(";")
            if !isPunctuation(")") { _ = try expression() }
            try expect(")")
            try nested()
        case "switch":
            position += 1
            try expect("(")
            _ = try expression()
            try expect(")")
            try block()
        case "case":
            position += 1
            _ = try conditional()
            try expect(":")
        case "default":
            position += 1
            try expect(":")
        case "return":
            position += 1
            if isPunctuation(";") { position += 1; return }
            let value = try expression()
            if let returnType { convert(value, to: returnType) }
            try expect(";")
        case "break", "continue", "discard":
            position += 1
            try expect(";")
        default:
            if isDeclarationStart() {
                try declaration()
            } else {
                _ = try expression()
                try expect(";")
            }
        }
    }

    /// A statement that is a branch or loop body: a scope of its own even without braces.
    mutating func nested() throws {
        scopes.append([:])
        defer { scopes.removeLast() }
        let mark = edits.count
        let start = position
        do {
            try statement()
        } catch {
            edits.rollBack(to: mark)
            position = start
            skipStatement()
        }
    }

    /// `( e )` of `if`/`while`: HLSL tests a number against zero.
    mutating func condition() throws {
        try expect("(")
        let test = try expression()
        convert(test, to: .scalar(.bool), onlyScalars: true)
        try expect(")")
    }

    /// Whether a declaration starts at `position`: qualifiers, then a type name followed by a name.
    func isDeclarationStart() -> Bool {
        var index = position
        while index < tokens.count, Self.qualifiers.contains(tokens[index].text) { index += 1 }
        guard index + 1 < tokens.count, isTypeName(tokens[index].text) || tokens[index].text == "struct" else { return false }
        var next = index + 1
        // `float[3] a`.
        if tokens[next].text == "[", let close = closing(from: next) { next = close + 1 }
        return next < tokens.count && tokens[next].kind == .identifier
    }

    /// `T a = e, b[2], c;` with each initializer converted to its declarator's type.
    mutating func declaration() throws {
        while let word = peek(), Self.qualifiers.contains(word) { position += 1 }
        guard let name = peek() else { throw Failure() }
        var base = type(named: name)
        position += 1
        if isPunctuation("["), let close = closing(from: position) {
            base = base.map { .array($0, nil) }
            position = close + 1
        }
        try declarators(base)
    }

    /// `a = e, b[2], c;` declared as `base`, through the `;`.
    mutating func declarators(_ base: HLSLType?) throws {
        while true {
            guard let nameToken = current, nameToken.kind == .identifier else { throw Failure() }
            position += 1
            let declared = try arraySuffix(base)
            // HLSL register or semantic annotations.
            if isPunctuation(":") { position += 2 }
            if isPunctuation("=") {
                position += 1
                if isPunctuation("{"), let close = closing(from: position) {
                    position = close + 1
                } else {
                    let value = try assignment()
                    if let declared { convert(value, to: declared) }
                }
            }
            declare(nameToken.text, declared)
            if isPunctuation(",") { position += 1; continue }
            try expect(";")
            return
        }
    }
}
