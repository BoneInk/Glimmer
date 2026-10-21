import Foundation

/// The typed half of the HLSL front end: types every expression of a preprocessed stage and makes
/// HLSL's implicit conversions explicit where GLSL has none, as WE's compiler (FXC) applies them.
///
/// Where a type can't be known (a name it can't resolve, syntax it doesn't parse), nothing is
/// converted: the statement is left as written. Edits never touch the prelude, whose functions are
/// only read for their signatures.
struct HLSLConversionPass {
    struct Parameter {
        let qualifier: String
        let type: HLSLType?
    }

    struct Signature {
        let returnType: HLSLType?
        let parameters: [Parameter]
    }

    /// A typed expression: its type (nil when unknown) and where it is in the text.
    struct Expression {
        var type: HLSLType?
        let start: Int
        let end: Int
        /// Tokens it spans.
        let firstToken: Int
        let endToken: Int
        /// An element of a `float` array whose size is a multiple of 4, which WE's HLSL packs as
        /// `float4`s and some shaders index twice (`x[i][j]`).
        var packedArrayElement = false
        /// A name, member, swizzle or index chain without calls or side effects.
        var isSimpleLValue = false
    }

    struct Failure: Error {}

    let code: [UInt16]
    let tokens: [GLSLToken]
    var edits: HLSLEdits
    var position = 0
    var scopes: [[String: HLSLType]] = [[:]]
    var structs: [String: [String: HLSLType]] = [:]
    var functions: [String: [Signature]] = [:]
    var returnType: HLSLType?

    /// `text` with HLSL's implicit conversions made explicit after `editableFrom` (UTF-16 offset).
    static func apply(to text: String, editableFrom: Int = 0) -> String {
        let code = Array(text.utf16)
        var pass = HLSLConversionPass(code: code, tokens: GLSLTokenizer.tokens(code), edits: HLSLEdits(editableFrom: editableFrom))
        pass.collectDeclarations()
        pass.translationUnit()
        guard pass.edits.count > 0 else { return text }
        return String(decoding: pass.edits.apply(to: code), as: UTF16.self)
    }

    // MARK: - Tokens

    var current: GLSLToken? { position < tokens.count ? tokens[position] : nil }

    func peek(_ offset: Int = 0) -> String? {
        position + offset < tokens.count ? tokens[position + offset].text : nil
    }

    func isPunctuation(_ text: String, at offset: Int = 0) -> Bool {
        guard position + offset < tokens.count else { return false }
        let token = tokens[position + offset]
        return token.kind == .punctuation && token.text == text
    }

    mutating func expect(_ text: String) throws {
        guard isPunctuation(text) else { throw Failure() }
        position += 1
    }

    /// The index of the bracket closing the one at `index` (`(`, `[` or `{`), or nil.
    func closing(from index: Int) -> Int? {
        var depth = 0
        var i = index
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .punctuation {
                if token.text == "(" || token.text == "[" || token.text == "{" { depth += 1 }
                if token.text == ")" || token.text == "]" || token.text == "}" {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            i += 1
        }
        return nil
    }

    /// Moves past the statement or declaration at `position`: to after the next `;` at this depth,
    /// or after a block that ends it.
    mutating func skipStatement() {
        while position < tokens.count {
            let token = tokens[position]
            if token.kind == .punctuation {
                if token.text == ";" { position += 1; return }
                if token.text == "}" { return }
                if token.text == "(" || token.text == "[" || token.text == "{" {
                    guard let close = closing(from: position) else { position = tokens.count; return }
                    position = close + 1
                    if token.text == "{", !isPunctuation(";") { return }
                    continue
                }
            }
            position += 1
        }
    }

    // MARK: - Names

    static let qualifiers: Set<String> = [
        "const", "uniform", "in", "out", "inout", "attribute", "varying", "flat", "smooth", "noperspective",
        "centroid", "sample", "patch", "highp", "mediump", "lowp", "invariant", "precise", "static", "shared",
        "point", "line", "triangle", "lineadj", "triangleadj", "nointerpolation", "linear", "row_major",
        "column_major", "readonly", "writeonly", "coherent", "volatile", "restrict",
    ]

    func type(named name: String) -> HLSLType? {
        HLSLType.named(name, structs: Set(structs.keys))
    }

    func isTypeName(_ name: String) -> Bool { type(named: name) != nil }

    func lookup(_ name: String) -> HLSLType? {
        for scope in scopes.reversed() {
            if let type = scope[name] { return type }
        }
        return HLSLBuiltins.variables[name]
    }

    func isDeclared(_ name: String) -> Bool {
        scopes.contains { $0[name] != nil }
    }

    mutating func declare(_ name: String, _ type: HLSLType?) {
        // An unknown type still shadows outer declarations of the name.
        scopes[scopes.count - 1][name] = type ?? .opaque("?")
    }

    // MARK: - Declarations first

    /// Structs and function signatures of the whole text, so calls before a definition resolve.
    mutating func collectDeclarations() {
        position = 0
        var depth = 0
        while position < tokens.count {
            let token = tokens[position]
            if token.kind == .punctuation {
                if token.text == "{" { depth += 1 }
                if token.text == "}" { depth -= 1 }
                position += 1
                continue
            }
            guard depth == 0 else { position += 1; continue }
            if token.text == "struct", position + 2 < tokens.count, tokens[position + 2].text == "{" {
                let name = tokens[position + 1].text
                position += 2
                if let members = try? structMembers() { structs[name] = members } // unparseable: unknown members
                continue
            }
            var index = position
            while index < tokens.count, Self.qualifiers.contains(tokens[index].text) { index += 1 }
            if index + 2 < tokens.count, tokens[index].kind == .identifier, tokens[index + 1].kind == .identifier,
               tokens[index + 2].text == "(" {
                let returnType = type(named: tokens[index].text)
                let name = tokens[index + 1].text
                position = index + 2
                if let parameters = try? parameterList() {
                    let signature = Signature(returnType: returnType, parameters: parameters)
                    let known = functions[name] ?? []
                    if !known.contains(where: { Self.sameParameters($0.parameters, parameters) }) {
                        functions[name, default: []].append(signature)
                    }
                }
                continue
            }
            position += 1
        }
        position = 0
    }

    static func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.type == $1.type }
    }

    /// `{ T a, b; U c[2]; }` at `position` (the `{`); leaves `position` after the `}`.
    mutating func structMembers() throws -> [String: HLSLType] {
        guard let close = closing(from: position) else { throw Failure() }
        var members: [String: HLSLType] = [:]
        position += 1
        while position < close {
            while position < close, Self.qualifiers.contains(tokens[position].text) { position += 1 }
            guard position < close else { break }
            let base = type(named: tokens[position].text)
            position += 1
            while position < close {
                guard tokens[position].kind == .identifier else { throw Failure() }
                let name = tokens[position].text
                position += 1
                members[name] = try arraySuffix(base)
                if isPunctuation(",") { position += 1; continue }
                // HLSL semantics (`float4 position : SV_POSITION`) end the declarator.
                if isPunctuation(":") { position += 2 }
                try expect(";")
                break
            }
        }
        position = close + 1
        return members
    }

    /// `[N]` after a declarator, if any: the array type.
    mutating func arraySuffix(_ base: HLSLType?) throws -> HLSLType? {
        var result = base
        while isPunctuation("[") {
            guard let close = closing(from: position) else { throw Failure() }
            let size = close == position + 2 ? Int(tokens[position + 1].text) : nil
            result = result.map { HLSLType.array($0, size) }
            position = close + 1
        }
        return result
    }

    /// `( params )` at `position`; leaves `position` after the `)`.
    mutating func parameterList() throws -> [Parameter] {
        guard isPunctuation("("), let close = closing(from: position) else { throw Failure() }
        var parameters: [Parameter] = []
        var start = position + 1
        var depth = 0
        for index in (position + 1)...close {
            let token = tokens[index]
            if token.text == "(" || token.text == "[" || token.text == "<" { depth += 1 }
            if token.text == ")" || token.text == "]" || token.text == ">" { depth -= 1 }
            guard (token.text == "," && depth == 0) || index == close else { continue }
            let range = start..<index
            start = index + 1
            let words = tokens[range]
            guard !words.isEmpty, !(words.count == 1 && words.first!.text == "void") else { continue }
            var qualifier = ""
            var parameterType: HLSLType?
            var name: String?
            var arraySize: Int??
            var tokenIndex = range.lowerBound
            while tokenIndex < range.upperBound {
                let word = tokens[tokenIndex].text
                if word == "in" || word == "out" || word == "inout" {
                    qualifier = word
                } else if parameterType == nil, let found = type(named: word) {
                    parameterType = found
                } else if tokens[tokenIndex].kind == .identifier, !Self.qualifiers.contains(word) {
                    name = word
                } else if word == "[" {
                    arraySize = tokenIndex + 1 < range.upperBound ? Int(tokens[tokenIndex + 1].text) : nil
                    break
                }
                tokenIndex += 1
            }
            if let size = arraySize { parameterType = parameterType.map { .array($0, size) } }
            if name == nil { parameterType = nil }
            parameters.append(Parameter(qualifier: qualifier, type: parameterType))
        }
        position = close + 1
        return parameters
    }

    /// Parameter names and types of the list at `position`, for declaring them in the body.
    func parameterNames(from open: Int, to close: Int) -> [(String, HLSLType?)] {
        var result: [(String, HLSLType?)] = []
        var start = open + 1
        var depth = 0
        for index in (open + 1)...close {
            let token = tokens[index]
            if token.text == "(" || token.text == "[" || token.text == "<" { depth += 1 }
            if token.text == ")" || token.text == "]" || token.text == ">" { depth -= 1 }
            guard (token.text == "," && depth == 0) || index == close else { continue }
            var base: HLSLType?
            var name: String?
            var isArray = false
            for tokenIndex in start..<index {
                let word = tokens[tokenIndex].text
                if word == "[" { isArray = true; break }
                if base == nil, let found = type(named: word) { base = found; continue }
                if tokens[tokenIndex].kind == .identifier, !Self.qualifiers.contains(word), type(named: word) == nil {
                    name = word
                }
            }
            if let name { result.append((name, isArray ? base.map { .array($0, nil) } : base)) }
            start = index + 1
        }
        return result
    }

    // MARK: - Top level

    mutating func translationUnit() {
        while position < tokens.count {
            let mark = edits.count
            let start = position
            do {
                try externalDeclaration()
            } catch {
                edits.rollBack(to: mark)
                position = start
                skipStatement()
                if isPunctuation("}") { position += 1 }
            }
            if position == start { position += 1 }
        }
    }

    mutating func externalDeclaration() throws {
        if isPunctuation(";") { position += 1; return }
        if peek() == "precision" { skipStatement(); return }
        if peek() == "layout", isPunctuation("(", at: 1), let close = closing(from: position + 1) {
            position = close + 1
            if isPunctuation(";") { position += 1 }
            return
        }
        while let word = peek(), Self.qualifiers.contains(word) { position += 1 }
        if peek() == "struct" {
            position += 1
            if current?.kind == .identifier { position += 1 }
            guard isPunctuation("{") else { throw Failure() }
            position = (closing(from: position) ?? tokens.count - 1) + 1
            try declaratorsOrEnd(nil)
            return
        }
        guard let first = current, first.kind == .identifier else { throw Failure() }
        // An interface block: `uniform Name { … } instance;`.
        if isPunctuation("{", at: 1) {
            position += 1
            let members = try structMembers()
            if current?.kind == .identifier {
                declare(tokens[position].text, nil)
                position += 1
            } else {
                for (name, type) in members { declare(name, type) }
            }
            try expect(";")
            return
        }
        let declared = type(named: first.text)
        position += 1
        guard let nameToken = current, nameToken.kind == .identifier else { throw Failure() }
        if isPunctuation("(", at: 1) {
            position += 1
            try functionDefinition(returnType: declared)
            return
        }
        try declaratorsOrEnd(declared)
    }

    /// The declarators of a global declaration, through its `;`.
    mutating func declaratorsOrEnd(_ base: HLSLType?) throws {
        if isPunctuation(";") { position += 1; return }
        try declarators(base)
    }

    mutating func functionDefinition(returnType declared: HLSLType?) throws {
        guard isPunctuation("("), let close = closing(from: position) else { throw Failure() }
        let parameters = parameterNames(from: position, to: close)
        position = close + 1
        // An HLSL semantic on the function (`: SV_TARGET`).
        if isPunctuation(":") { position += 2 }
        if isPunctuation(";") { position += 1; return }
        guard isPunctuation("{") else { throw Failure() }
        scopes.append([:])
        for (name, type) in parameters { declare(name, type) }
        returnType = declared
        defer {
            scopes.removeLast()
            returnType = nil
        }
        try block()
    }
}
