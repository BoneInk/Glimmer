import Foundation

/// Rule 8 of the HLSL front end (`HLSLFrontEnd.link`): links a preprocessed vertex/fragment pair
/// the way WE's HLSL linkage does, and gives its Metal translation a fixed, predictable interface.
///
/// WE turns a stage's `attribute`s, `varying`s and loose uniforms into the `VS_INPUT`/`VS_OUTPUT`
/// structs and a cbuffer of one HLSL program, so a varying is matched between the stages by its
/// name, and an input is an ordinary parameter a shader may assign to. GLSL for SPIR-V matches by
/// location and makes inputs read-only. The rules, on the stages' top-level declarations as the
/// front end's tokenizer reads them (`GLSLTokenizer`), never on lines of text:
///
/// - **Uniforms** stay as WE declares them: glslang's relaxed Vulkan rules gather both stages'
///   into one std140 block `WEUniforms` at buffer 0 (`InProcessShaderCompiler.compilePairToMSL`).
///   A uniform the stages declare differently (`ShaderUniformDeclaration.stageLocalNames`) is
///   renamed in the fragment stage (`ShaderUniformDeclaration.fragmentSuffix`), so each stage reads
///   a member of its own.
/// - **Samplers**: `g_TextureN` is bound at texture/sampler N; any other sampler at 16 and up.
/// - **Varyings** get the same location in both stages, assigned by name in declaration order
///   (vertex outputs, then fragment inputs), each taking the locations its type occupies.
/// - A fragment input the vertex stage never writes is **declared as a vertex output**, as WE's
///   output struct would hold it (zero), instead of failing pipeline creation.
/// - A varying **declared with a different vector size** in each stage is read as the vertex
///   stage's type and truncated or zero-padded into a global of the fragment's type.
/// - A **written fragment input** (`v_TexCoord.y = 1.0 - v_TexCoord.y;`) is read into a global of
///   its name.
/// - **Vertex attributes** (`a_…` inputs of the vertex stage) get fixed locations
///   (`attributeLocations`, 15 for a name outside it); a written one is copied into a global.
/// - `out_FragColor` (the prelude's `gl_FragColor`) is at location 0.
enum HLSLLinkage {
    static let uniformBlockName = "WEUniforms"

    /// Locations for the vertex streams WE meshes provide; `ShaderVertexLayout` mirrors these.
    static let attributeLocations: [String: Int] = [
        "a_Position": 0, "a_PositionVec4": 0,
        "a_TexCoord": 1, "a_TexCoordVec4": 1,
        "a_Normal": 2, "a_Tangent4": 3, "a_Color": 4,
        "a_BlendIndices": 5, "a_BlendWeights": 6,
        "a_TexCoordVec4C1": 7, "a_TexCoordC2": 7,
        "a_TexCoordVec4C2": 8, "a_TexCoordVec3C2": 8,
        "a_TexCoordC3": 9, "a_TexCoordVec4C3": 9,
        "a_TexCoordC4": 10, "a_PositionC1": 11,
    ]

    /// The location of an attribute outside `attributeLocations`: no mesh stream feeds it.
    static let unknownAttributeLocation = 15
    /// The first slot of a sampler that isn't `g_TextureN`.
    static let firstExtraSamplerSlot = 16

    struct Result {
        let vertex: String
        let fragment: String
        /// `g_TextureN` slots the pair samples.
        let textureSlots: [Int]
        /// Attribute name → location, for the attributes the vertex stage reads.
        let attributes: [String: Int]
    }

    /// A top-level `in`, `out` or `uniform` declaration of one name without a `layout`:
    /// `[flat|smooth|noperspective] (in|out) [precision] type name [ [N] ];` or
    /// `uniform [precision] sampler… name;`.
    struct Declaration: Equatable {
        enum Storage: String { case input = "in", output = "out", uniform }

        let storage: Storage
        /// The interpolation qualifier with a trailing space (`"flat "`), or empty.
        let interpolation: String
        let type: String
        let name: String
        let arrayCount: Int?
        /// UTF-16 offsets of the declaration's first token and of the end of its `;`.
        let start: Int
        let end: Int

        var arraySuffix: String { arrayCount.map { "[\($0)]" } ?? "" }
    }

    /// One stage's text as tokens, with its interface declarations.
    struct Stage {
        let code: [UInt16]
        let tokens: [GLSLToken]
        let declarations: [Declaration]

        init(_ text: String) {
            code = Array(text.utf16)
            tokens = GLSLTokenizer.tokens(code)
            declarations = HLSLLinkage.declarations(in: tokens)
        }

        func varyings(_ storage: Declaration.Storage) -> [Declaration] {
            declarations.filter { $0.storage == storage && $0.name != "out_FragColor" }
        }
    }

    /// `stageLocal` names uniforms both stages declare differently: the fragment stage's are
    /// renamed. `label` names the pair in the log line for slots it had to guess.
    static func link(vertex vertexText: String, fragment fragmentText: String, stageLocal: Set<String> = [],
                     label: String = "") -> Result {
        let vertex = Stage(vertexText)
        let fragment = Stage(fragmentText)
        let renamed = Dictionary(uniqueKeysWithValues: stageLocal.map { ($0, $0 + ShaderUniformDeclaration.fragmentSuffix) })

        let vertexOutputs = vertex.varyings(.output)
        let fragmentInputs = fragment.varyings(.input).map { renaming($0, renamed) }
        var locations: [String: Int] = [:]
        var next = 0
        for varying in vertexOutputs + fragmentInputs where locations[varying.name] == nil {
            locations[varying.name] = next
            next += locationCount(type: varying.type) * (varying.arrayCount ?? 1)
        }
        let missing = fragmentInputs.filter { input in !vertexOutputs.contains { $0.name == input.name } }
        // name → (the type the fragment stage reads, the type its code uses).
        var resized: [String: (vertexType: String, fragmentType: String)] = [:]
        for input in fragmentInputs where input.arrayCount == nil {
            guard let output = vertexOutputs.first(where: { $0.name == input.name }), output.arrayCount == nil,
                  output.type != input.type, vectorSize(output.type) != nil, vectorSize(input.type) != nil else { continue }
            resized[input.name] = (output.type, input.type)
        }
        for input in fragmentInputs where input.arrayCount == nil && resized[input.name] == nil
            && isAssigned(input.name, in: fragment.tokens, renamed: renamed) {
            resized[input.name] = (input.type, input.type)
        }

        var slots = Set<Int>()
        var extraSamplers: [String] = []
        var attributes: [String: Int] = [:]

        func decorate(_ stage: Stage, _ kind: ShaderStage) -> String {
            let stageRenames = kind == .fragment ? renamed : [:]
            var edits = HLSLEdits(editableFrom: 0)
            var extraSampler = firstExtraSamplerSlot
            var writtenAttributes: [String] = []
            for original in stage.declarations {
                let declaration = renaming(original, stageRenames)
                let name = declaration.name, type = declaration.type
                let replacement: String
                switch declaration.storage {
                case .uniform:
                    let slot: Int
                    if name.hasPrefix("g_Texture"), let n = Int(name.dropFirst("g_Texture".count)) {
                        slot = n
                        slots.insert(n)
                    } else {
                        slot = extraSampler
                        extraSampler += 1
                        extraSamplers.append("\(name) → \(slot)")
                    }
                    replacement = "layout(binding = \(slot)) uniform \(type) \(name);"
                case .input where kind == .vertex && name.hasPrefix("a_"):
                    let location = attributeLocations[name] ?? unknownAttributeLocation
                    attributes[name] = location
                    if declaration.arrayCount == nil, isAssigned(name, in: stage.tokens, renamed: [:]) {
                        writtenAttributes.append(name)
                        replacement = "layout(location = \(location)) in \(type) \(name)_weIn;\n\(type) \(name);"
                    } else {
                        replacement = "layout(location = \(location)) in \(type) \(name)\(declaration.arraySuffix);"
                    }
                case .output where name == "out_FragColor":
                    replacement = "layout(location = 0) out \(type) \(name);"
                case .input, .output:
                    guard let location = locations[name] else { continue }
                    if kind == .fragment, let types = resized[name] {
                        replacement = "layout(location = \(location)) \(declaration.interpolation)in \(types.vertexType) \(name)_weVarying;\n\(type) \(name);"
                    } else {
                        replacement = "layout(location = \(location)) \(declaration.interpolation)\(declaration.storage.rawValue) \(type) \(name)\(declaration.arraySuffix);"
                    }
                }
                edits.replace(declaration.start, declaration.end, replacement)
            }
            // The fragment stage's copies of stage-local uniforms, wherever they are named.
            if !stageRenames.isEmpty {
                for (index, token) in stage.tokens.enumerated() where token.kind == .identifier {
                    guard let name = stageRenames[token.text], index == 0 || stage.tokens[index - 1].text != "." else { continue }
                    edits.replace(token.start, token.end, name)
                }
            }
            let entry: [String]
            if kind == .vertex {
                entry = writtenAttributes.map { "\($0) = \($0)_weIn;" }
            } else {
                entry = resized.sorted { $0.key < $1.key }.map { name, types in
                    let read = "\(name)_weVarying"
                    return "\(name) = \(types.vertexType == types.fragmentType ? read : convert(read, from: types.vertexType, to: types.fragmentType));"
                }
            }
            if !entry.isEmpty, let offset = mainBodyStart(stage.tokens) {
                edits.prefix(offset, "\n" + entry.joined(separator: " ") + "\n")
            }
            if kind == .vertex, !missing.isEmpty {
                let declarations = missing.map {
                    "layout(location = \(locations[$0.name]!)) \($0.interpolation)out \($0.type) \($0.name)\($0.arraySuffix);"
                }.joined(separator: "\n") + "\n"
                let offset = endOfHeader(stage.code)
                edits.prefix(offset, offset == stage.code.count ? "\n" + declarations : declarations + "\n")
            }
            guard edits.count > 0 else { return String(decoding: stage.code, as: UTF16.self) }
            return String(decoding: edits.apply(to: stage.code), as: UTF16.self)
        }

        let decoratedVertex = decorate(vertex, .vertex)
        let decoratedFragment = decorate(fragment, .fragment)
        let unknownAttributes = attributes.keys.filter { attributeLocations[$0] == nil }.sorted()
        if !unknownAttributes.isEmpty || !extraSamplers.isEmpty {
            OWELog.debug(.shader, "\(label): guessed slots: attributes \(unknownAttributes) at location \(unknownAttributeLocation) (no mesh stream feeds them), samplers \(extraSamplers)")
        }
        return Result(vertex: decoratedVertex, fragment: decoratedFragment, textureSlots: slots.sorted(),
                      attributes: attributes)
    }

    private static func renaming(_ declaration: Declaration, _ renamed: [String: String]) -> Declaration {
        guard let name = renamed[declaration.name] else { return declaration }
        return Declaration(storage: declaration.storage, interpolation: declaration.interpolation, type: declaration.type,
                           name: name, arrayCount: declaration.arrayCount, start: declaration.start, end: declaration.end)
    }

    // MARK: - Declarations

    private static let interpolations: Set<String> = ["flat", "smooth", "noperspective"]
    private static let precisions: Set<String> = ["lowp", "mediump", "highp"]

    /// The interface declarations among `tokens`, at file scope (outside every bracket) and each
    /// one a statement of its own.
    static func declarations(in tokens: [GLSLToken]) -> [Declaration] {
        var result: [Declaration] = []
        var depth = 0
        var statementStart = true
        var index = 0
        while index < tokens.count {
            if depth == 0, statementStart, let (declaration, end) = declaration(in: tokens, at: index) {
                result.append(declaration)
                index = end
                continue
            }
            let text = tokens[index].text
            if text == "(" || text == "[" || text == "{" { depth += 1 }
            if text == ")" || text == "]" || text == "}" { depth = max(depth - 1, 0) }
            statementStart = depth == 0 && (text == ";" || text == "}")
            index += 1
        }
        return result
    }

    /// The declaration starting at `start` and the index of the token after it.
    private static func declaration(in tokens: [GLSLToken], at start: Int) -> (Declaration, Int)? {
        var index = start
        func text(_ offset: Int = 0) -> String? { index + offset < tokens.count ? tokens[index + offset].text : nil }
        func identifier() -> String? {
            guard index < tokens.count, tokens[index].kind == .identifier else { return nil }
            defer { index += 1 }
            return tokens[index].text
        }
        var interpolation = ""
        if let qualifier = text(), interpolations.contains(qualifier) {
            interpolation = qualifier + " "
            index += 1
        }
        guard let word = text(), let storage = Declaration.Storage(rawValue: word),
              storage != .uniform || interpolation.isEmpty else { return nil }
        index += 1
        if let precision = text(), precisions.contains(precision) { index += 1 }
        guard let type = identifier(), let name = identifier() else { return nil }
        var arrayCount: Int?
        if storage != .uniform, text() == "[" {
            guard index + 2 < tokens.count, case .number = tokens[index + 1].kind, let count = Int(tokens[index + 1].text),
                  tokens[index + 2].text == "]" else { return nil }
            arrayCount = count
            index += 3
        }
        guard text() == ";" else { return nil }
        if storage == .uniform, !type.hasPrefix("sampler") { return nil }
        let declaration = Declaration(storage: storage, interpolation: interpolation, type: type, name: name,
                                      arrayCount: arrayCount, start: tokens[start].start, end: tokens[index].end)
        return (declaration, index + 1)
    }

    // MARK: - Uses

    private static let assignments: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

    /// Whether the name `name` (or a swizzle or member of it) is assigned to, incremented or
    /// decremented. `renamed` maps names as they are in `tokens` to the names they become.
    static func isAssigned(_ name: String, in tokens: [GLSLToken], renamed: [String: String] = [:]) -> Bool {
        for (index, token) in tokens.enumerated() where token.kind == .identifier && (renamed[token.text] ?? token.text) == name {
            if index > 0, tokens[index - 1].text == "." { continue }
            if index > 0, tokens[index - 1].text == "++" || tokens[index - 1].text == "--" { return true }
            var next = index + 1
            if next + 1 < tokens.count, tokens[next].text == ".", tokens[next + 1].kind == .identifier { next += 2 }
            guard next < tokens.count else { continue }
            let operation = tokens[next].text
            if assignments.contains(operation) || operation == "++" || operation == "--" { return true }
        }
        return false
    }

    /// The UTF-16 offset just inside `main`'s opening brace.
    private static func mainBodyStart(_ tokens: [GLSLToken]) -> Int? {
        for index in tokens.indices where tokens[index].text == "main" && index > 0 && tokens[index - 1].text == "void" {
            var next = index + 1
            guard next < tokens.count, tokens[next].text == "(" else { continue }
            next += 1
            if next < tokens.count, tokens[next].text == "void" { next += 1 }
            guard next + 1 < tokens.count, tokens[next].text == ")", tokens[next + 1].text == "{" else { continue }
            return tokens[next + 1].end
        }
        return nil
    }

    /// The UTF-16 offset after the `#version`/`#extension` lines and blank lines at the top: where
    /// a declaration goes as a line of its own. The end of the text when every line is header.
    static func endOfHeader(_ code: [UInt16]) -> Int {
        let newline: UInt16 = 10, space: UInt16 = 32, tab: UInt16 = 9
        func hasPrefix(_ prefix: String, at start: Int, end: Int) -> Bool {
            let units = Array(prefix.utf16)
            return end - start >= units.count && Array(code[start..<(start + units.count)]) == units
        }
        var lineStart = 0
        while lineStart < code.count {
            let lineEnd = code[lineStart...].firstIndex(of: newline) ?? code.count
            let blank = code[lineStart..<lineEnd].allSatisfy { $0 == space || $0 == tab }
            guard blank || hasPrefix("#version", at: lineStart, end: lineEnd)
                    || hasPrefix("#extension", at: lineStart, end: lineEnd) else { return lineStart }
            lineStart = lineEnd + 1
        }
        return code.count
    }

    // MARK: - Types

    /// Components of a float scalar/vector type; nil for anything else.
    static func vectorSize(_ type: String) -> Int? {
        switch HLSLType.named(type, structs: []) {
        case .scalar(.float): return 1
        case .vector(.float, let n): return n
        default: return nil
        }
    }

    /// Truncates or zero-pads `expression` from one float vector type to another.
    static func convert(_ expression: String, from source: String, to target: String) -> String {
        let from = vectorSize(source)!, to = vectorSize(target)!
        if to < from { return "\(expression).\("xyzw".prefix(to))" }
        return "\(target)(\(expression)\(String(repeating: ", 0.0", count: to - from)))"
    }

    /// Interface locations a varying of this type occupies: one per matrix column (GLSL 4.50
    /// §4.4.1), else one.
    static func locationCount(type: String) -> Int {
        if case .matrix(let columns, _) = HLSLType.named(type, structs: []) { return columns }
        return 1
    }
}
