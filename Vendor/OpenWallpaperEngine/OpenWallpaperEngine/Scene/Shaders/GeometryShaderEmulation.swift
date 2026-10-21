import Foundation

enum GeometryShaderEmulationError: Error, CustomStringConvertible {
    case missingMaxVertexCount(String)
    case unsupportedInput(String)
    case invalidMaxVertexCount(String)

    var description: String {
        switch self {
        case .missingMaxVertexCount(let path): return "\(path): no [maxvertexcount(...)]"
        case .unsupportedInput(let detail): return "unsupported geometry input: \(detail)"
        case .invalidMaxVertexCount(let expression): return "maxvertexcount \(expression) is not a count of at least 3"
        }
    }
}

/// Folds a Wallpaper Engine geometry stage (`.geom`) into its vertex stage, because Metal has no
/// geometry shaders.
///
/// WE geometry shaders are HLSL-flavoured: top-level `in` declarations become the `VS_OUTPUT`
/// struct read as `IN[0]`, `out` declarations become `PS_INPUT`, `[maxvertexcount(N)]` bounds the
/// output and `OUT.Append(v)` emits one vertex of a triangle strip (`OUT.RestartStrip()` starts
/// a new one). The input primitive is a point (`IN[1]`), which is what particles feed; WE's
/// `[input:triangles]` form is reported as unsupported.
///
/// The emulation draws every input point as one instance of `3 × (N − 2)` indices, a triangle
/// list covering every triangle the strip could hold. Each vertex runs the original vertex stage
/// (renamed, its varyings turned into globals), fills `IN[0]` from them, then runs the geometry
/// stage, which only records the strip vertex it stands for. So any geometry stage with a fixed
/// vertex bound works, whatever it emits, including workshop ones.
///
/// - A stage without `RestartStrip` (WE's own) is one strip: vertex `k` of `N` is strip vertex `k`,
///   and the indices (`stripIndices`) list each triangle's three, so the stage runs once per strip
///   vertex. A vertex past the emitted ones repeats the last, so the triangles past the strip have
///   no area and rasterise nothing.
/// - A stage with `RestartStrip` draws one vertex per list entry (`listIndices`); each records the
///   three strip vertices its triangle needs, and a triangle past the emitted vertices, or spanning
///   a restart, collapses to a point.
struct GeometryShaderEmulation {
    /// The vertex stage and the geometry stage as one WE-dialect vertex shader, ready for
    /// `ShaderSourceLoader`: includes are inlined, so it reads no other file.
    let vertexText: String
    /// The `[maxvertexcount(...)]` expression; it may use combos (`4 + TRAILSUBDIVISION * 2`).
    let maxVertexCountExpression: String
    /// Numeric `#define`s of the sources, the fallback for names in the expression.
    let defines: [String: Int]
    /// The geometry stage calls `OUT.RestartStrip()`: it is drawn one vertex per list entry.
    let restartsStrips: Bool

    /// Prefix of every name the emulation introduces.
    static let prefix = "owe_gs_"

    /// Strip vertices one instance can emit for these combos.
    func maxVertexCount(combos: [String: Int]) throws -> Int {
        let values = defines.merging(combos) { _, combo in combo }
        guard let count = Self.evaluate(maxVertexCountExpression, values: values), count >= 3 else {
            throw GeometryShaderEmulationError.invalidMaxVertexCount(maxVertexCountExpression)
        }
        return count
    }

    /// Indices each instance draws: every triangle the strip can hold, as a list.
    func vertexCountPerInstance(combos: [String: Int]) throws -> Int {
        3 * (try maxVertexCount(combos: combos) - 2)
    }

    /// The index list of a strip of `vertices` vertices: triangle `t` is `(t, t+1, t+2)`, its first
    /// two swapped when `t` is odd, keeping the winding.
    static func stripIndices(vertices: Int) -> [UInt32] {
        (0..<max(vertices - 2, 0)).flatMap { (t: Int) -> [UInt32] in
            let first = UInt32(t)
            return t % 2 == 0 ? [first, first + 1, first + 2] : [first + 1, first, first + 2]
        }
    }

    /// The index list of a stage that restarts strips: every list entry its own vertex.
    static func listIndices(count: Int) -> [UInt32] {
        (0..<UInt32(max(count, 0))).map { $0 }
    }

    // MARK: - Building

    /// `vertex` and `geometry` are the stages' texts with includes inlined; a header both use must
    /// appear once, in the vertex text (see `sources`). `make` prepares a geometry stage for it.
    static func combine(vertex: String, geometry: String, path: String) throws -> GeometryShaderEmulation {
        if geometry.range(of: #"\[\s*input\s*:\s*(?!points?\s*\])\w+\s*\]"#, options: .regularExpression) != nil {
            throw GeometryShaderEmulationError.unsupportedInput("\(path) declares a non-point input primitive")
        }
        if geometry.range(of: #"\bIN\s*\[\s*[1-9]"#, options: .regularExpression) != nil {
            throw GeometryShaderEmulationError.unsupportedInput("\(path) reads more than one input vertex")
        }
        guard let maxMatch = maxVertexPattern.firstMatch(in: geometry, range: NSRange(geometry.startIndex..., in: geometry)),
              let expressionRange = Range(maxMatch.range(at: 1), in: geometry),
              let attributeRange = Range(maxMatch.range, in: geometry) else {
            throw GeometryShaderEmulationError.missingMaxVertexCount(path)
        }
        let expression = String(geometry[expressionRange]).trimmingCharacters(in: .whitespaces)
        let restartsStrips = restartPattern.firstMatch(in: geometry, range: NSRange(geometry.startIndex..., in: geometry)) != nil

        let geometryLines = topLevelLines(geometry)
        let inputs = geometryLines.compactMap { $0.declaration }.filter { $0.direction == "in" }

        // Vertex stage: its varyings become globals under a prefixed name, so they neither leave
        // the stage nor clash with the geometry stage's outputs of the same name.
        let vertexLines = topLevelLines(vertex)
        let vertexVaryings = vertexLines.compactMap { $0.declaration }.filter { $0.direction == "varying" || $0.direction == "out" }
        var renamed = Set(vertexVaryings.map(\.name))
        renamed.insert("gl_Position")
        renamed.formUnion(inputs.map(\.name))
        var vertexText = vertexLines.map { line -> String in
            guard let declaration = line.declaration, declaration.direction == "varying" || declaration.direction == "out" else {
                return line.text
            }
            return "\(declaration.type) \(declaration.name)\(declaration.array);"
        }.joined(separator: "\n")
        vertexText = rename(renamed, in: vertexText, to: { stageName($0) })
        vertexText = replace(mainPattern, in: vertexText, with: "void \(prefix)vertexMain(")

        // Inputs the vertex stage never declares read as zero, as unwritten varyings do.
        let declaredByVertex = Set(vertexVaryings.map(\.name))
        let undeclared = inputs.filter { $0.name != "gl_Position" && !declaredByVertex.contains($0.name) }
        // Declared ahead of the vertex stage, which writes them.
        var stageGlobals = "vec4 \(stageName("gl_Position"));\n"
        for input in uniqueByName(undeclared) {
            stageGlobals += "\(input.type) \(stageName(input.name))\(input.array);\n"
        }

        var interface = "struct VS_OUTPUT {\n" + conditional(geometryLines, direction: "in") { declaration in
            "\t\(declaration.type) \(declaration.name)\(declaration.array);"
        } + "\tvec4 owe_Position;\n};\n"
        interface += "struct PS_INPUT {\n" + conditional(geometryLines, direction: "out") { declaration in
            "\t\(declaration.type) \(declaration.name)\(declaration.array);"
        } + "\tvec4 owe_Position;\n};\n"
        interface += restartsStrips ? listEmitSupport : stripEmitSupport

        // Geometry stage: interface declarations go (they are the structs now), `gl_Position`
        // members get a legal name, and emission goes through the capture functions.
        var geometryText = geometryLines.map { line -> String in
            if let declaration = line.declaration, declaration.direction == "in"
                || (declaration.direction == "out" && declaration.name == "gl_Position") {
                return "// (geometry interface) " + line.text
            }
            return line.text
        }.joined(separator: "\n")
        if let range = geometryText.range(of: String(geometry[attributeRange])) {
            geometryText.replaceSubrange(range, with: "// (emulated) [maxvertexcount(\(expression))]")
        }
        geometryText = geometryText.replacingOccurrences(of: #"\[\s*input\s*:\s*\w+\s*\]"#, with: "",
                                                         options: .regularExpression)
        geometryText = replace(memberPositionPattern, in: geometryText, with: ".owe_Position")
        geometryText = replace(appendPattern, in: geometryText, with: "\(prefix)emit(")
        geometryText = replace(restartPattern, in: geometryText, with: "\(prefix)restartStrip()")
        geometryText = replace(mainPattern, in: geometryText, with: "void \(prefix)geometryMain(")

        let fill = conditional(geometryLines, direction: "in") { declaration in
            "\tIN[0].\(declaration.name) = \(stageName(declaration.name));"
        } + "\tIN[0].owe_Position = \(stageName("gl_Position"));\n"
        let copyOut = conditional(geometryLines, direction: "out") { declaration in
            "\t\(declaration.name) = \(prefix)vertex.\(declaration.name);"
        }
        let main = restartsStrips ? """
        void main() {
        \t\(prefix)vertexMain();
        \(fill)\t\(prefix)first = gl_VertexID / 3;
        \tint \(prefix)corner = gl_VertexID - \(prefix)first * 3;
        \t\(prefix)geometryMain();
        \tbool \(prefix)valid = \(prefix)emitted >= \(prefix)first + 3 && \(prefix)strip0 == \(prefix)strip2;
        \t// Odd triangles of a strip list their first two vertices swapped, keeping the winding.
        \tif (\(prefix)parity == 1 && \(prefix)corner < 2) { \(prefix)corner = 1 - \(prefix)corner; }
        \tPS_INPUT \(prefix)vertex = \(prefix)captured2;
        \tif (\(prefix)corner == 0) { \(prefix)vertex = \(prefix)captured0; }
        \telse if (\(prefix)corner == 1) { \(prefix)vertex = \(prefix)captured1; }
        \(copyOut)\tgl_Position = \(prefix)valid ? \(prefix)vertex.owe_Position : vec4(0.0, 0.0, 0.0, 0.0);
        }

        """
        : """
        void main() {
        \t\(prefix)vertexMain();
        \(fill)\t\(prefix)first = gl_VertexID;
        \t\(prefix)geometryMain();
        \tPS_INPUT \(prefix)vertex = \(prefix)captured;
        \(copyOut)\tgl_Position = \(prefix)emitted > 0 ? \(prefix)vertex.owe_Position : vec4(0.0, 0.0, 0.0, 0.0);
        }

        """

        let text = [stageGlobals, vertexText, "// (geometry emulation) interface", interface, geometryText,
                    "// (geometry emulation) entry point", main].joined(separator: "\n")
        return GeometryShaderEmulation(vertexText: text, maxVertexCountExpression: expression,
                                       defines: numericDefines(in: vertex + "\n" + geometry), restartsStrips: restartsStrips)
    }

    /// A shader's vertex and geometry stage texts, includes inlined; a header both include is
    /// inlined once, in the vertex stage, where the geometry stage sees it too.
    struct Sources {
        let vertex: String
        let geometry: String
        /// `<shader>.geom`, for logs.
        let path: String

        /// Both stages, for reading their `[COMBO]` and uniform declarations.
        var declarations: String { vertex + "\n" + geometry }
    }

    /// Loads `<shader>.vert` and `<shader>.geom`. Nil when the shader has no geometry stage.
    static func sources(_ shader: String, readFile: @escaping (String) -> Data?) throws -> Sources? {
        func read(_ candidates: [String]) throws -> String? {
            for candidate in candidates {
                guard let data = readFile(candidate) else { continue }
                guard let text = String(data: data, encoding: .utf8) else { throw ShaderSourceError.unreadable(candidate) }
                return text
            }
            return nil
        }
        let base = shader.hasSuffix(".vert") ? String(shader.dropLast(5)) : shader
        guard let geometry = try read(["\(base).geom", "shaders/\(base).geom"]) else { return nil }
        guard let vertex = try read(["\(base).vert", "shaders/\(base).vert"]) else {
            throw ShaderSourceError.notFound("\(base).vert")
        }
        func header(_ name: String) throws -> String {
            guard let text = try read(["shaders/\(name)", name]) else { throw ShaderSourceError.notFound(name) }
            return text
        }
        var included = Set<String>()
        let vertexText = try ShaderSourceLoader.inlineIncludes(in: vertex, path: "\(base).vert") { name in
            included.insert(name)
            return try header(name)
        }
        let geometryText = try ShaderSourceLoader.inlineIncludes(in: geometry, path: "\(base).geom") { name in
            included.contains(name) ? "" : try header(name)
        }
        return Sources(vertex: vertexText, geometry: geometryText, path: "\(base).geom")
    }

    /// Combines `sources` for one combo set. The geometry stage is preprocessed on its own first;
    /// HLSL's conversions and scoping are applied to the folded stage by the front end
    /// (`HLSLFrontEnd`), which types each name in its own scope.
    static func make(_ sources: Sources, combos: [String: Int], compiler: ShaderCompiler) throws -> GeometryShaderEmulation {
        let header = (["#version 450", "#define GLSL 1"] + combos.sorted { $0.key < $1.key }.map { "#define \($0.key) \($0.value)" })
            .joined(separator: "\n") + "\n"
        let preprocessed = try compiler.preprocess(header + sources.geometry, stage: .vertex)
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        // HLSL attributes (`[maxvertexcount(4)]`) go ahead of the stage.
        var body = preprocessed
        var attributes = ""
        for match in attributePattern.matches(in: preprocessed, range: NSRange(preprocessed.startIndex..., in: preprocessed)).reversed() {
            guard let range = Range(match.range, in: body) else { continue }
            attributes = body[range] + "\n" + attributes
            body.replaceSubrange(range, with: "")
        }
        return try combine(vertex: sources.vertex, geometry: attributes + body, path: sources.path)
    }

    private static let attributePattern = NSRegularExpression.shader(#"\[\s*(?:maxvertexcount\s*\([^\]]*\)|input\s*:\s*\w+)\s*\]"#)

    // MARK: - Emission capture

    /// Globals and the function `OUT.Append` becomes, for a stage that never restarts its strip.
    /// `first` is this vertex's strip index; `captured` ends as that strip vertex, or the last one
    /// emitted when the stage emits fewer.
    private static let stripEmitSupport = """
    VS_OUTPUT IN[1];
    int \(prefix)first = 0;
    int \(prefix)emitted = 0;
    PS_INPUT \(prefix)captured;
    void \(prefix)emit(PS_INPUT v) {
    \tif (\(prefix)emitted <= \(prefix)first) { \(prefix)captured = v; }
    \t\(prefix)emitted = \(prefix)emitted + 1;
    }

    """

    /// Globals and functions `OUT.Append` / `OUT.RestartStrip` become. `first` is the strip index
    /// of this vertex's triangle; `strip0`/`strip2` tell whether its first and last vertex are in
    /// the same strip; `parity` is the triangle's position within its strip.
    private static let listEmitSupport = """
    VS_OUTPUT IN[1];
    int \(prefix)first = 0;
    int \(prefix)emitted = 0;
    int \(prefix)strip = 0;
    int \(prefix)stripStart = 0;
    int \(prefix)strip0 = -1;
    int \(prefix)strip2 = -2;
    int \(prefix)parity = 0;
    PS_INPUT \(prefix)captured0;
    PS_INPUT \(prefix)captured1;
    PS_INPUT \(prefix)captured2;
    void \(prefix)emit(PS_INPUT v) {
    \tint k = \(prefix)emitted - \(prefix)first;
    \tif (k == 0) { \(prefix)captured0 = v; \(prefix)strip0 = \(prefix)strip; \(prefix)parity = (\(prefix)emitted - \(prefix)stripStart) - ((\(prefix)emitted - \(prefix)stripStart) / 2) * 2; }
    \telse if (k == 1) { \(prefix)captured1 = v; }
    \telse if (k == 2) { \(prefix)captured2 = v; \(prefix)strip2 = \(prefix)strip; }
    \t\(prefix)emitted = \(prefix)emitted + 1;
    }
    void \(prefix)restartStrip() {
    \t\(prefix)strip = \(prefix)strip + 1;
    \t\(prefix)stripStart = \(prefix)emitted;
    }

    """

    // MARK: - Text passes

    struct Declaration {
        /// `in`, `out`, `varying` (vertex stage).
        let direction: String
        let type: String
        let name: String
        /// `[N]` or empty.
        let array: String
    }

    struct Line {
        let text: String
        /// Set for a top-level interface declaration.
        let declaration: Declaration?
        /// A preprocessor conditional (`#if…`, `#else`, `#elif`, `#endif`) or a top-level
        /// `#define`/`#undef`; replayed around generated code so it sees the same declarations.
        let isStructuralDirective: Bool
    }

    private static let maxVertexPattern = NSRegularExpression.shader(#"\[\s*maxvertexcount\s*\(([^\]]*)\)\s*\]"#)
    private static let declarationPattern = NSRegularExpression.shader(
        #"^[ \t]*(in|out|varying)[ \t]+(?:(?:lowp|mediump|highp)[ \t]+)?(\w+)[ \t]+(\w+)[ \t]*(\[[ \t]*\w+[ \t]*\])?[ \t]*;"#,
        options: [.anchorsMatchLines])
    private static let mainPattern = NSRegularExpression.shader(#"\bvoid\s+main\s*\("#)
    private static let memberPositionPattern = NSRegularExpression.shader(#"\.\s*gl_Position\b"#)
    private static let appendPattern = NSRegularExpression.shader(#"\bOUT\s*\.\s*Append\s*\("#)
    private static let restartPattern = NSRegularExpression.shader(#"\bOUT\s*\.\s*RestartStrip\s*\(\s*\)"#)
    private static let conditionalPattern = NSRegularExpression.shader(#"^[ \t]*#[ \t]*(if|ifdef|ifndef|elif|else|endif)\b"#, options: [.anchorsMatchLines])
    private static let definePattern = NSRegularExpression.shader(#"^[ \t]*#[ \t]*(define|undef)\b"#, options: [.anchorsMatchLines])
    private static let numericDefinePattern = NSRegularExpression.shader(#"(?m)^[ \t]*#[ \t]*define[ \t]+(\w+)[ \t]+\(?[ \t]*(-?\d+)[ \t]*\)?[ \t]*$"#)

    /// Splits `text` into lines, marking top-level declarations and structural directives.
    static func topLevelLines(_ text: String) -> [Line] {
        var depth = 0
        return text.components(separatedBy: "\n").map { raw in
            let code = raw.components(separatedBy: "//").first ?? raw
            let range = NSRange(raw.startIndex..., in: raw)
            var declaration: Declaration?
            if depth == 0, let match = declarationPattern.firstMatch(in: raw, range: range) {
                let group = { (index: Int) in Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? "" }
                declaration = Declaration(direction: group(1), type: group(2), name: group(3),
                                          array: group(4).replacingOccurrences(of: " ", with: ""))
            }
            let structural = conditionalPattern.firstMatch(in: raw, range: range) != nil
                || (depth == 0 && definePattern.firstMatch(in: raw, range: range) != nil)
            depth = max(0, depth + code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count)
            return Line(text: raw, declaration: declaration, isStructuralDirective: structural)
        }
    }

    /// One generated line per declaration of `direction`, inside the same conditionals.
    /// `gl_Position` is skipped: the structs carry it as `owe_Position`, handled by the caller.
    private static func conditional(_ lines: [Line], direction: String,
                                    _ generate: (Declaration) -> String) -> String {
        var result = ""
        for line in lines {
            if line.isStructuralDirective {
                result += line.text.trimmingCharacters(in: .whitespaces) + "\n"
            } else if let declaration = line.declaration, declaration.direction == direction,
                      declaration.name != "gl_Position" {
                result += generate(declaration) + "\n"
            }
        }
        return result
    }

    private static func stageName(_ name: String) -> String { "\(prefix)\(name)" }

    private static func uniqueByName(_ declarations: [Declaration]) -> [Declaration] {
        var seen = Set<String>()
        return declarations.filter { seen.insert($0.name).inserted }
    }

    /// Renames whole identifiers, leaving member accesses (`x.name`) alone.
    private static func rename(_ names: Set<String>, in text: String, to newName: (String) -> String) -> String {
        guard !names.isEmpty else { return text }
        let alternatives = names.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = NSRegularExpression.shader(#"(?<![\w.])("# + alternatives + #")\b"#)
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: newName(String(result[range])))
        }
        return result
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with replacement: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                         withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }

    static func numericDefines(in text: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for match in numericDefinePattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let name = Range(match.range(at: 1), in: text).map({ String(text[$0]) }),
                  let value = Range(match.range(at: 2), in: text).flatMap({ Int(text[$0]) }),
                  result[name] == nil else { continue }
            result[name] = value
        }
        return result
    }

    // MARK: - Expressions

    /// Integer arithmetic over `+ - * /`, parentheses, literals and names; an unknown name is 0,
    /// as in a preprocessor `#if`.
    static func evaluate(_ expression: String, values: [String: Int]) -> Int? {
        var tokens: [String] = []
        var current = ""
        for character in expression {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
                continue
            }
            if !current.isEmpty { tokens.append(current); current = "" }
            if "+-*/()".contains(character) { tokens.append(String(character)) }
            else if !character.isWhitespace { return nil }
        }
        if !current.isEmpty { tokens.append(current) }
        var index = 0
        func primary() -> Int? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            index += 1
            switch token {
            case "(":
                guard let value = sum(), index < tokens.count, tokens[index] == ")" else { return nil }
                index += 1
                return value
            case "-": return primary().map { -$0 }
            case "+": return primary()
            default:
                if let literal = Int(token) { return literal }
                guard token.first.map({ $0.isLetter || $0 == "_" }) == true else { return nil }
                return values[token] ?? 0
            }
        }
        func product() -> Int? {
            guard var value = primary() else { return nil }
            while index < tokens.count, tokens[index] == "*" || tokens[index] == "/" {
                let op = tokens[index]
                index += 1
                guard let rhs = primary() else { return nil }
                if op == "*" { value *= rhs } else { guard rhs != 0 else { return nil }; value /= rhs }
            }
            return value
        }
        func sum() -> Int? {
            guard var value = product() else { return nil }
            while index < tokens.count, tokens[index] == "+" || tokens[index] == "-" {
                let op = tokens[index]
                index += 1
                guard let rhs = product() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }
        let result = sum()
        return index == tokens.count ? result : nil
    }
}
