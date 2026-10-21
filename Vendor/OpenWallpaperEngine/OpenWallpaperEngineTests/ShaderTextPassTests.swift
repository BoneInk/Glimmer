import XCTest
@testable import OpenWallpaperEngine

/// The Swift text passes around glslang (prelude analysis, the front end's linkage).
final class ShaderTextPassTests: XCTestCase {
    func testIdentifierTokensAreMaximalASCIIRuns() {
        let tokens = ShaderPrelude.identifierTokens(in: "vec2 or=a_b1;é new\nthis")
        XCTAssertEqual(tokens, ["vec2", "or", "a_b1", "new", "this"])
    }

    /// Every copy of a source shares one analysis, and it equals the one from the text.
    func testSourceAnalysisIsComputedFromTheText() {
        let source = ShaderSource(stage: .fragment, path: "x.frag", text: "#define A 1\nfloat log10(float x) { return x; }\nvoid main() { vec2 or = vec2(0.0); }",
                                  combos: [], uniforms: [])
        let copy = source
        XCTAssertEqual(copy.preludeAnalysis.macros, ["A"])
        XCTAssertEqual(source.preludeAnalysis.functions, ["log10", "main"])
        XCTAssertEqual(ShaderPrelude.text(for: .fragment, combos: ["X": 1], analysis: source.preludeAnalysis),
                       ShaderPrelude.text(for: .fragment, combos: ["X": 1], source: source.text))
    }

    /// Declarations go after `#version`/`#extension` and blank lines, as their own line: a
    /// varying the fragment stage reads and the vertex stage never writes.
    func testLinkageInsertsDeclarationsAfterTheHeader() {
        let vertex = "#version 450\n#extension GL_X : enable\n\nvoid main() { gl_Position = vec4(0.0); }"
        let result = HLSLLinkage.link(vertex: vertex, fragment: "#version 450\nin vec2 v_X;\nvoid main() {}")
        XCTAssertTrue(result.vertex.hasPrefix("#version 450\n#extension GL_X : enable\n\nlayout(location = 0) out vec2 v_X;\n"),
                      result.vertex)
        XCTAssertFalse(result.vertex.contains("WEUniforms"), "loose uniforms are left to glslang's relaxed rules")
    }

    /// WE's GLSL backend leaves `HLSL`/`HLSL_SM30` undefined, so `#ifdef HLSL` branches (D3D
    /// screen-space flips and half-texel offsets) are not taken.
    func testPreludeLeavesHLSLUndefined() throws {
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:])
        XCTAssertFalse(prelude.contains("#define HLSL"), prelude)
        let source = "#ifdef HLSL\nFLIPPED\n#endif\n#if HLSL_SM30\nSM30\n#endif\n"
        let text = try InProcessShaderCompiler().preprocess(prelude + source, stage: .fragment)
        XCTAssertFalse(text.contains("FLIPPED"))
        XCTAssertFalse(text.contains("SM30"))
    }
}
