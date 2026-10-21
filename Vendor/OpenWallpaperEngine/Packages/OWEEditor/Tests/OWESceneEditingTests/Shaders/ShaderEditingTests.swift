import XCTest
@testable import OWESceneEditing

/// The shader editor's text tools: WE's Snippets insertions (combos, includes, uniforms, each in
/// its block), the sampler slots, the dialect's highlighting and completions, and the line map
/// that puts the translator's errors on the edited lines.
final class ShaderEditingTests: XCTestCase {
    private static let fragment = """

    uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}

    varying vec2 v_TexCoord;

    void main() {
    \tvec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
    \tgl_FragColor = albedo;
    }
    """

    // MARK: Snippets

    func testUniformGoesAfterTheUniforms() {
        let text = ShaderSnippets.addingUniform(.init(type: "float", name: "g_Time", annotation: nil), to: Self.fragment)
        XCTAssertEqual(text.components(separatedBy: "\n").prefix(4), [
            "", #"uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}"#,
            "uniform float g_Time;", "",
        ])
        XCTAssertEqual(ShaderSnippets.addingUniform(.init(type: "float", name: "g_Time", annotation: nil), to: text), text,
                       "nothing is added twice")
    }

    func testIncludeAndComboGoAboveTheUniforms() {
        var text = ShaderSnippets.addingInclude("common.h", to: Self.fragment)
        text = ShaderSnippets.addingCombo(ShaderSnippets.Variable.comboCheckbox.combo!, to: text)
        let lines = text.components(separatedBy: "\n")
        // WE keeps the shader's leading empty line and puts each block below it.
        XCTAssertEqual(lines[0], "")
        XCTAssertEqual(lines[1], #"// [COMBO] {"material":"My Combo Name","combo":"USERCOMBOIDENTIFIER","type":"options","default":0}"#)
        XCTAssertEqual(lines[2], "")
        XCTAssertEqual(lines[3], "#include \"common.h\"")
        XCTAssertEqual(lines[4], "")
        XCTAssertTrue(lines[5].hasPrefix("uniform sampler2D g_Texture0;"))
        let more = ShaderSnippets.addingInclude("common_blending.h", to: text).components(separatedBy: "\n")
        XCTAssertEqual(more[4], "#include \"common_blending.h\"", "after the includes already there")
        XCTAssertEqual(more[5], "")
    }

    func testAVariableIsWEsAnnotatedUniform() {
        let text = ShaderSnippets.addingUniform(ShaderSnippets.Variable.uvPicker.uniform!, to: Self.fragment)
        XCTAssertTrue(text.contains(#"uniform vec2 u_userNewPosition; // {"material":"My new position","position":true,"default":"0.5 0.5"}"#))
    }

    func testSamplersTakeTheNextSlotUpToTen() throws {
        let text = try ShaderSnippets.addingSampler(ShaderSnippets.samplers[1], to: Self.fragment)
        XCTAssertTrue(text.contains(#"uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_opacity","mode":"opacitymask","paintdefaultcolor":"0 0 0 1"}"#))
        XCTAssertEqual(ShaderSnippets.nextTextureSlot(in: "g_Texture7Resolution g_Texture2"), 8)
        XCTAssertThrowsError(try ShaderSnippets.addingSampler(ShaderSnippets.samplers[0], to: "uniform sampler2D g_Texture9;")) { error in
            XCTAssertEqual(error as? ShaderSnippets.SamplerError, .tooMany(limit: 10))
        }
    }

    func testAnEmptyShaderGetsTheLine() {
        XCTAssertEqual(ShaderSnippets.addingInclude("common.h", to: ""), "#include \"common.h\"\n\n")
        XCTAssertEqual(ShaderSnippets.replacement("\nvoid main() {}\n"), "void main() {}\n")
    }

    // MARK: Language

    func testTokensFollowTheDialect() {
        let source = "#include \"common.h\"\nuniform float g_Time; // {\"default\":1}\nvoid main() { vec4 c = texSample2D(g_Texture0, v.xy) * 1.5e-3; }"
        let text = source as NSString
        let kinds = ShaderTokenizer.tokens(in: source).map { (text.substring(with: $0.range), $0.kind) }
        func kind(_ word: String) -> ShaderToken.Kind? { kinds.first { $0.0 == word }?.1 }
        XCTAssertEqual(kind("#include \"common.h\""), .preprocessor)
        XCTAssertEqual(kind("uniform"), .keyword)
        XCTAssertEqual(kind("float"), .type)
        XCTAssertEqual(kind("g_Time"), .engine)
        XCTAssertEqual(kind("// {\"default\":1}"), .comment)
        XCTAssertEqual(kind("texSample2D"), .builtin)
        XCTAssertEqual(kind("1.5e-3"), .number)
        XCTAssertEqual(kind("v"), .identifier)
    }

    func testCompletionsOfferTheDialectAndTheShadersNames() {
        let source = "uniform float u_Amount;\nvoid main() { float x = u_A"
        let result = ShaderLanguage.completions(in: source, at: (source as NSString).length)
        XCTAssertEqual(result.range.length, 3)
        XCTAssertEqual(result.items.first?.label, "u_Amount")
        let engine = ShaderLanguage.completions(in: "g_Ti", at: 4).items.map(\.label)
        XCTAssertTrue(engine.contains("g_Time"))
        XCTAssertTrue(ShaderLanguage.completions(in: "texS", at: 4).items.contains { $0.label == "texSample2D" })
        XCTAssertTrue(ShaderLanguage.completions(in: "// g_T", at: 6).items.isEmpty, "nothing in a comment")
        XCTAssertTrue(ShaderLanguage.completions(in: "v.x", at: 3).items.isEmpty, "a swizzle")
    }

    // MARK: Line map

    func testLinesMapBackThroughInsertedAndEditedLines() {
        let written = ["a", "b", "c", "d"]
        let compiled = ["prelude", "a", "inserted", "B!", "c", "d"]
        let map = ShaderLineMap(from: written, to: compiled)
        XCTAssertNil(map.line(1), "before any shared line")
        XCTAssertEqual(map.line(2), 1)
        XCTAssertEqual(map.line(3), 1, "a new line goes with the shared line before it")
        XCTAssertEqual(map.line(4), 2, "an edited line with the line it replaced")
        XCTAssertEqual(map.line(5), 3)
        XCTAssertEqual(map.line(6), 4)
        XCTAssertTrue(map.isShared(5, from: written, to: compiled))
        XCTAssertFalse(map.isShared(3, from: written, to: compiled))
    }
}
