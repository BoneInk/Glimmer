import Foundation

/// WE's shader dialect for the shader editor (docs.wallpaperengine.io › Shader Programming):
/// GLSL's keywords, types and functions, WE's portable macros (`texSample2D`, `mul`, `frac`,
/// `CAST3`, …), its headers' functions and constants, the engine's constants (`g_*`) and
/// attributes (`a_*`), and the completions it offers at a position of a shader.
public enum ShaderLanguage {
    public static let keywords: Set<String> = [
        "attribute", "uniform", "varying", "const", "in", "out", "inout", "break", "continue", "do", "for", "while",
        "if", "else", "switch", "case", "default", "return", "discard", "struct", "void", "true", "false",
        "precision", "highp", "mediump", "lowp", "invariant", "layout", "flat", "centroid",
    ]

    public static let types: Set<String> = [
        "float", "int", "uint", "bool", "vec2", "vec3", "vec4", "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4",
        "bvec2", "bvec3", "bvec4", "mat2", "mat3", "mat4", "mat2x2", "mat2x3", "mat2x4", "mat3x2", "mat3x3", "mat3x4",
        "mat4x2", "mat4x3", "mat4x4", "sampler2D", "sampler3D", "samplerCube", "sampler2DShadow", "sampler2DArray",
        // HLSL's names, which WE's compiler takes as well.
        "float2", "float3", "float4", "float2x2", "float3x3", "float4x4", "int2", "int3", "int4", "half", "half2", "half3", "half4",
    ]

    /// GLSL's built-in functions with their usual signature.
    static let glslFunctions: [(String, String)] = [
        ("abs", "genType abs(genType x)"), ("acos", "genType acos(genType x)"), ("all", "bool all(bvec x)"),
        ("any", "bool any(bvec x)"), ("asin", "genType asin(genType x)"), ("atan", "genType atan(genType y, genType x)"),
        ("ceil", "genType ceil(genType x)"), ("clamp", "genType clamp(genType x, genType min, genType max)"),
        ("cos", "genType cos(genType x)"), ("cross", "vec3 cross(vec3 x, vec3 y)"), ("degrees", "genType degrees(genType r)"),
        ("dFdx", "genType dFdx(genType p)"), ("dFdy", "genType dFdy(genType p)"), ("distance", "float distance(genType p0, genType p1)"),
        ("dot", "float dot(genType x, genType y)"), ("equal", "bvec equal(vec x, vec y)"), ("exp", "genType exp(genType x)"),
        ("exp2", "genType exp2(genType x)"), ("faceforward", "genType faceforward(genType n, genType i, genType nref)"),
        ("floor", "genType floor(genType x)"), ("fract", "genType fract(genType x)"), ("fwidth", "genType fwidth(genType p)"),
        ("greaterThan", "bvec greaterThan(vec x, vec y)"), ("inversesqrt", "genType inversesqrt(genType x)"),
        ("length", "float length(genType x)"), ("lessThan", "bvec lessThan(vec x, vec y)"), ("log", "genType log(genType x)"),
        ("log2", "genType log2(genType x)"), ("max", "genType max(genType x, genType y)"), ("min", "genType min(genType x, genType y)"),
        ("mix", "genType mix(genType x, genType y, genType a)"), ("mod", "genType mod(genType x, genType y)"),
        ("normalize", "genType normalize(genType x)"), ("not", "bvec not(bvec x)"), ("notEqual", "bvec notEqual(vec x, vec y)"),
        ("pow", "genType pow(genType x, genType y)"), ("radians", "genType radians(genType d)"),
        ("reflect", "genType reflect(genType i, genType n)"), ("refract", "genType refract(genType i, genType n, float eta)"),
        ("round", "genType round(genType x)"), ("sign", "genType sign(genType x)"), ("sin", "genType sin(genType x)"),
        ("smoothstep", "genType smoothstep(genType edge0, genType edge1, genType x)"), ("sqrt", "genType sqrt(genType x)"),
        ("step", "genType step(genType edge, genType x)"), ("tan", "genType tan(genType x)"),
        ("transpose", "mat transpose(mat m)"), ("trunc", "genType trunc(genType x)"),
    ]

    /// WE's portable spellings (Shader Syntax: Preprocessor, Type Casting).
    static let weFunctions: [(String, String)] = [
        ("texSample2D", "vec4 texSample2D(sampler2D sampler, vec2 uv)"),
        ("texSample2DLod", "vec4 texSample2DLod(sampler2D sampler, vec2 uv, float lod)"),
        ("mul", "mul(vector, matrix)"), ("frac", "genType frac(genType x)"), ("saturate", "genType saturate(genType x)"),
        ("lerp", "genType lerp(genType x, genType y, genType a)"), ("atan2", "genType atan2(genType y, genType x)"),
        ("ddx", "genType ddx(genType p)"), ("ddy", "genType ddy(genType p)"),
        ("CAST2", "vec2 CAST2(x)"), ("CAST3", "vec3 CAST3(x)"), ("CAST4", "vec4 CAST4(x)"), ("CAST3X3", "mat3 CAST3X3(x)"),
    ]

    /// The functions and constants of WE's shader headers (Shader Headers).
    static let headerFunctions: [(String, String)] = [
        ("hsv2rgb", "vec3 hsv2rgb(vec3 hsv) — common.h"), ("rgb2hsv", "vec3 rgb2hsv(vec3 rgb) — common.h"),
        ("rotateVec2", "vec2 rotateVec2(vec2 v, float r) — common.h"), ("greyscale", "float greyscale(vec3 color) — common.h"),
        ("DecompressNormal", "vec3 DecompressNormal(vec4 texel) — common_fragment.h"),
        ("DecompressNormalWithMask", "vec4 DecompressNormalWithMask(vec4 texel) — common_fragment.h"),
        ("ConvertSampleR8", "float ConvertSampleR8(vec4 texel) — common_fragment.h"),
        ("ConvertTexture0Format", "vec4 ConvertTexture0Format(vec4 texel) — common_fragment.h"),
        ("BuildTangentSpace", "mat3 BuildTangentSpace(vec3 normal, vec4 signedTangent) — common_vertex.h"),
        ("ApplyBlending", "vec3 ApplyBlending(BLENDMODE, vec3 a, vec3 b, float blend) — common_blending.h"),
    ]
    static let headerConstants: [(String, String)] = [
        ("M_PI", "3.14159265359 — common.h"), ("M_PI_HALF", "1.57079632679 — common.h"), ("M_PI_2", "6.28318530718 — common.h"),
        ("SQRT_2", "1.41421356237 — common.h"), ("SQRT_3", "1.73205080756 — common.h"),
    ]

    /// The attributes WE gives a vertex shader (Shader Syntax: Input Attributes).
    static let attributes: [(String, String)] = [
        ("a_Position", "vec3"), ("a_PositionVec4", "vec4"), ("a_Normal", "vec3"), ("a_Tangent4", "vec4"),
        ("a_TexCoord", "vec2"), ("a_TexCoordVec3", "vec3"), ("a_TexCoordVec4", "vec4"), ("a_Color", "vec4"),
    ] + (1...5).flatMap { channel in [
        ("a_TexCoordC\(channel)", "vec2"), ("a_TexCoordVec3C\(channel)", "vec3"), ("a_TexCoordVec4C\(channel)", "vec4"),
    ] }

    static let outputs: [(String, String)] = [
        ("gl_Position", "vec4 — the vertex's position"), ("gl_FragColor", "vec4 — the pixel's colour"),
        ("gl_FragCoord", "vec4 — the pixel's window position"),
    ]

    /// The engine's constants Add Constant offers, by name (an array's `[n]` dropped).
    static let engineConstants: [(String, String)] = {
        var constants: [(String, String)] = []
        for uniform in ShaderSnippets.constantGroups.flatMap(\.constants) {
            let name = uniform.name.split(separator: "[").first.map(String.init) ?? uniform.name
            let array = uniform.name.contains("[") ? "[" + (uniform.name.split(separator: "[").last ?? "") : ""
            constants.append((name, "uniform \(uniform.type) \(name)\(array)"))
        }
        return constants
    }()

    private static let builtinNames = Set((glslFunctions + weFunctions + headerFunctions + headerConstants).map(\.0))
        .union(["texture2D", "texture2DLod", "texture", "textureLod", "fmod", "rsqrt", "log10"])
    private static let engineNames = Set((engineConstants + attributes + outputs).map(\.0))

    /// What a word is to the dialect, for highlighting.
    public static func kind(of word: String) -> ShaderToken.Kind {
        if keywords.contains(word) { return .keyword }
        if types.contains(word) { return .type }
        if builtinNames.contains(word) { return .builtin }
        if engineNames.contains(word) || word.hasPrefix("g_") || word.hasPrefix("gl_") { return .engine }
        return .identifier
    }

    // MARK: Completing

    /// What to suggest at `offset` (UTF-16) of `text`: the range of the partial word to replace
    /// and the suggestions starting with it, best first. Besides the dialect's words, the names
    /// the shader declares (its uniforms, varyings, functions and locals) are offered; nothing in
    /// a comment.
    public static func completions(in text: String, at offset: Int) -> (range: NSRange, items: [SceneScriptCompletion]) {
        let utf16 = Array(text.utf16)
        let end = max(0, min(offset, utf16.count))
        var start = end
        while start > 0, ShaderTokenizer.isIdentifier(utf16[start - 1]) { start -= 1 }
        let range = NSRange(location: start, length: end - start)
        let prefix = String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
        // In a comment (or after a `.`, a swizzle or a member): nothing.
        let tokens = ShaderTokenizer.tokens(in: text)
        if tokens.contains(where: { $0.kind == .comment && $0.range.location < start && NSMaxRange($0.range) >= end }) {
            return (range, [])
        }
        if start > 0, utf16[start - 1] == 0x2E { return (range, []) }

        var items: [SceneScriptCompletion] = []
        items += engineConstants.map { SceneScriptCompletion(label: $0.0, kind: .global, detail: $0.1) }
        items += attributes.map { SceneScriptCompletion(label: $0.0, kind: .global, detail: "attribute \($0.1) \($0.0)") }
        items += outputs.map { SceneScriptCompletion(label: $0.0, kind: .global, detail: $0.1) }
        items += (weFunctions + headerFunctions + glslFunctions).map { SceneScriptCompletion(label: $0.0, kind: .function, detail: $0.1) }
        items += headerConstants.map { SceneScriptCompletion(label: $0.0, kind: .property, detail: $0.1) }
        items += (keywords.sorted() + types.sorted()).map { SceneScriptCompletion(label: $0, kind: .keyword, detail: $0) }
        // The shader's own names: every identifier but the one being typed.
        let source = text as NSString
        for token in tokens where token.kind == .identifier && token.range.location != start {
            let word = source.substring(with: token.range)
            if word.count > 1 { items.append(SceneScriptCompletion(label: word, kind: .property, detail: word)) }
        }
        return (range, SceneScriptAPICatalog.filter(items, prefix: prefix).filter { $0.label != prefix || prefix.isEmpty })
    }
}
