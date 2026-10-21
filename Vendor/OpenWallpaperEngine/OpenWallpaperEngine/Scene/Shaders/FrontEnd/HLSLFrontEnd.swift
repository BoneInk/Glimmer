import Foundation

/// The front end that turns a WE shader stage into GLSL glslang accepts, by WE's own rules.
///
/// WE writes its shaders in GLSL syntax with HLSL's intrinsics and compiles them as HLSL:
/// `wallpaper64.exe` prepends `#define vec2 float2`, `#define mix lerp`,
/// `#define mod(x, y) ((x)-(y)*floor((x)/(y)))`, the `CAST*` C-style casts and the `texSample*`
/// mappings (0x486b10–0x487000), turns the interface into `VS_INPUT`/`VS_OUTPUT` structs and a
/// cbuffer, and calls `D3DCompile` (FXC, `d3dcompiler_47.dll`). So the semantics a shader relies
/// on are FXC's, and this front end applies them as rules, in order:
///
/// 1. **Includes and requires** (`ShaderSourceLoader.inlineIncludes`, `expandRequires`): headers
///    from the wallpaper's `shaders/` then WE's; `#require LightingV1` is WE's generated source.
/// 2. **Combos** (`ShaderVariantTranslator.resolveCombos`): `#define`s ahead of the source.
/// 3. **Intrinsic and type mapping** (`ShaderPrelude`): HLSL's names as GLSL macros and helpers
///    (`frac`, `lerp`, `saturate`, `float3`, `CAST3`, `texSample2D`, `clip`, …).
/// 4. **System values** (`builtInDeclarations`): declarations of `gl_InstanceID` and friends,
///    which HLSL declares as inputs, are dropped.
/// 5. **Scoping** (`loopBodyScopes`): HLSL lets a loop body redeclare the loop variable.
/// 6. **Implicit conversions and promotions** (`HLSLConversionPass`), typed: assignments,
///    initialisers, returns and arguments convert to their target (a scalar splats, a wider vector
///    truncates, kinds convert), operands of different vector sizes truncate to the narrower,
///    bools take part in arithmetic as 0 or 1, numbers are tested against zero, `%` on floats is
///    `fmod`, float subscripts truncate, intrinsics bring their arguments to one type, and HLSL's
///    component-wise vector comparisons become GLSL's functions.
/// 7. **`mul`** (`HLSLConversionPass.multiply`): operands swap for GLSL's column vectors, wider
///    vectors truncate, and a vector times a vector is a dot product. A `mul` the typed pass
///    couldn't reach still swaps (`expandRemainingMul`).
/// 8. **Linkage** (`HLSLLinkage`), on both stages at once: varyings matched by name, inputs a
///    shader assigns to, vertex attribute locations, sampler bindings and stage-local uniforms.
///
/// Everything else is glslang's relaxed Vulkan rules: loose uniforms gathered into one block
/// (`WEUniforms`) shared by both stages of the linked program.
enum HLSLFrontEnd {
    /// Rules 4–8 on a preprocessed vertex/fragment pair whose preludes end with
    /// `ShaderPrelude.endMarker`: the GLSL `ShaderCompiler.compilePairToMSL` takes. `stageLocal`
    /// names uniforms the stages declare differently (`ShaderUniformDeclaration.stageLocalNames`).
    static func translate(vertex: String, fragment: String, stageLocal: Set<String> = [],
                          label: String = "") -> HLSLLinkage.Result {
        HLSLLinkage.link(vertex: afterPreprocess(vertex), fragment: afterPreprocess(fragment),
                         stageLocal: stageLocal, label: label)
    }

    /// Rules 4–7 on a preprocessed stage whose prelude ends with `ShaderPrelude.endMarker`.
    static func afterPreprocess(_ text: String) -> String {
        let code = Array(text.utf16)
        let tokens = GLSLTokenizer.tokens(code)
        var edits = HLSLEdits(editableFrom: 0)
        ShaderPrelude.dropBuiltInDeclarations(code, tokens, into: &edits)
        scopeLoopBodies(tokens, from: endOfPrelude(tokens), into: &edits)
        let scoped = edits.count == 0 ? text : String(decoding: edits.apply(to: code), as: UTF16.self)
        let converted = HLSLConversionPass.apply(to: scoped, editableFrom: endOfPrelude(utf16In: scoped))
        return expandRemainingMul(converted)
    }

    // MARK: - End of the prelude

    /// The UTF-16 offset after the prelude's last line, `ShaderPrelude.endMarker`
    /// (`void weEndOfPrelude() {}` as tokens, however the preprocessor spaced it); 0 without one.
    /// Reads only as far as the marker.
    static func endOfPrelude(utf16In text: String) -> Int {
        var end = 0
        var matched = 0
        GLSLTokenizer.scan(Array(text.utf16)) { token in
            matched = advance(matched, token)
            if matched == endMarkerTokens.count { end = token.end; return false }
            return true
        }
        return end
    }

    /// The same in tokens already read.
    static func endOfPrelude(_ tokens: [GLSLToken]) -> Int {
        var matched = 0
        for token in tokens {
            matched = advance(matched, token)
            if matched == endMarkerTokens.count { return token.end }
        }
        return 0
    }

    private static let endMarkerTokens = ["void", "weEndOfPrelude", "(", ")", "{", "}"]

    /// Tokens of the marker matched after `token`, given `matched` before it. `void` occurs only
    /// first, so a mismatch restarts at `void` or nothing.
    private static func advance(_ matched: Int, _ token: GLSLToken) -> Int {
        if token.text == endMarkerTokens[matched] { return matched + 1 }
        return token.text == endMarkerTokens[0] ? 1 : 0
    }

    // MARK: - Scoping

    /// `for (int s = …) { float s = …; … }`: HLSL scopes the loop variable outside the body, so the
    /// body may declare its own; the body's `s` becomes `s_weBody` from its declaration on.
    static func loopBodyScopes(_ text: String) -> String {
        let code = Array(text.utf16)
        var edits = HLSLEdits(editableFrom: 0)
        scopeLoopBodies(GLSLTokenizer.tokens(code), from: 0, into: &edits)
        return edits.count == 0 ? text : String(decoding: edits.apply(to: code), as: UTF16.self)
    }

    /// The renames of `loopBodyScopes` for loops from the UTF-16 offset `start` on. A loop is
    /// `for (<type> <name> = …) { … }`. The body's own `name` is a declaration (a scalar, vector or
    /// matrix type, then `name`) directly in the body: one in a nested block or statement is
    /// already a scope of its own, which GLSL allows. From that declaration to the body's end,
    /// every `name` that isn't a member (`.name`) is renamed.
    static func scopeLoopBodies(_ tokens: [GLSLToken], from start: Int, into edits: inout HLSLEdits) {
        var index = tokens.firstIndex { $0.start >= start } ?? tokens.count
        while index + 5 < tokens.count {
            defer { index += 1 }
            guard tokens[index].text == "for", tokens[index].kind == .identifier, tokens[index + 1].text == "(",
                  tokens[index + 2].kind == .identifier, tokens[index + 3].kind == .identifier,
                  tokens[index + 4].text == "=",
                  let headerClose = closing(tokens, from: index + 1, "(", ")"),
                  headerClose + 1 < tokens.count, tokens[headerClose + 1].text == "{",
                  let bodyClose = closing(tokens, from: headerClose + 1, "{", "}") else { continue }
            let name = tokens[index + 3].text
            var depth = 0
            var declaration: Int?
            for inner in (headerClose + 2)..<bodyClose {
                let token = tokens[inner].text
                if token == "(" || token == "[" || token == "{" { depth += 1 }
                if token == ")" || token == "]" || token == "}" { depth -= 1 }
                if depth == 0, token == name, inner > headerClose + 2, isValueType(tokens[inner - 1]) {
                    declaration = inner
                    break
                }
            }
            guard let declaration else { continue }
            for inner in declaration..<bodyClose where tokens[inner].text == name && tokens[inner - 1].text != "." {
                edits.replace(tokens[inner].start, tokens[inner].end, name + "_weBody")
            }
        }
    }

    /// A scalar, vector or matrix type name.
    private static func isValueType(_ token: GLSLToken) -> Bool {
        guard token.kind == .identifier, let type = HLSLType.named(token.text, structs: []) else { return false }
        switch type {
        case .scalar, .vector, .matrix: return true
        default: return false
        }
    }

    /// The token closing the bracket at `open`.
    private static func closing(_ tokens: [GLSLToken], from open: Int, _ opening: String, _ closing: String) -> Int? {
        var depth = 0
        for index in open..<tokens.count {
            if tokens[index].text == opening { depth += 1 }
            if tokens[index].text == closing {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    // MARK: - mul

    /// `mul(a, b)` → `((b) * (a))` for every call the typed pass left (one in a statement it
    /// couldn't type), unless the shader defines its own `mul`.
    static func expandRemainingMul(_ text: String) -> String {
        guard text.contains("mul") else { return text }
        let code = Array(text.utf16)
        let tokens = GLSLTokenizer.tokens(code)
        var edits = HLSLEdits(editableFrom: endOfPrelude(utf16In: text))
        let definesMul = tokens.indices.contains { index in
            index > 0 && index + 1 < tokens.count && tokens[index].text == "mul" && tokens[index + 1].text == "("
                && tokens[index - 1].kind == .identifier && tokens[index - 1].text != "return"
        }
        guard !definesMul else { return text }
        var index = 0
        while index + 1 < tokens.count {
            defer { index += 1 }
            guard tokens[index].text == "mul", tokens[index + 1].text == "(",
                  index == 0 || tokens[index - 1].text != "." else { continue }
            // Arguments: the two top-level comma-separated ranges up to the matching `)`.
            var depth = 0
            var comma: Int?
            var close: Int?
            for inner in (index + 1)..<tokens.count {
                let token = tokens[inner].text
                if token == "(" || token == "[" || token == "{" { depth += 1 }
                if token == ")" || token == "]" || token == "}" {
                    depth -= 1
                    if depth == 0 { close = inner; break }
                }
                if token == ",", depth == 1 {
                    if comma != nil { comma = nil; break }
                    comma = inner
                }
            }
            guard let comma, let close, comma > index + 2, close > comma + 1 else { continue }
            let first = String(decoding: code[tokens[index + 2].start..<tokens[comma - 1].end], as: UTF16.self)
            let second = String(decoding: code[tokens[comma + 1].start..<tokens[close - 1].end], as: UTF16.self)
            edits.replace(tokens[index].start, tokens[close].end, "((\(second)) * (\(first)))")
            index = close
        }
        guard edits.count > 0 else { return text }
        // Nested calls inside an argument are expanded by another round.
        return expandRemainingMul(String(decoding: edits.apply(to: code), as: UTF16.self))
    }
}
