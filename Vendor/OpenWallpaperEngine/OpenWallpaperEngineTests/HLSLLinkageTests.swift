import XCTest
@testable import OpenWallpaperEngine

/// The HLSL front end's linkage rule (`HLSLLinkage`, rule 8), one test per rule: WE links a pair
/// as one HLSL program, so varyings match by name, inputs are writable parameters and samplers
/// bind by their `g_TextureN` register.
final class HLSLLinkageTests: XCTestCase {
    private let header = "#version 450\n"

    private func link(_ vertex: String, _ fragment: String, stageLocal: Set<String> = []) -> HLSLLinkage.Result {
        HLSLLinkage.link(vertex: header + vertex, fragment: header + fragment, stageLocal: stageLocal)
    }

    /// Varyings take one location in both stages, by name, whatever order each stage declares
    /// them in; a matrix takes one location per column.
    func testVaryingsAreLocatedByNameInBothStages() {
        let pair = link("out mat4x3 v_M;\nout vec2 v_A;\nflat out int v_B;\nvoid main() {}\n",
                        "flat in int v_B;\nin vec2 v_A;\nin mat4x3 v_M;\nvoid main() {}\n")
        XCTAssertTrue(pair.vertex.contains("layout(location = 0) out mat4x3 v_M;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("layout(location = 4) out vec2 v_A;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("layout(location = 5) flat out int v_B;"), pair.vertex)
        XCTAssertTrue(pair.fragment.contains("layout(location = 5) flat in int v_B;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(location = 4) in vec2 v_A;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(location = 0) in mat4x3 v_M;"), pair.fragment)
    }

    /// An array varying takes its element's locations once per element.
    func testArrayVaryingsTakeALocationPerElement() {
        let pair = link("out vec4 v_L[3];\nout vec2 v_A;\nvoid main() {}\n", "in vec4 v_L[3];\nin vec2 v_A;\nvoid main() {}\n")
        XCTAssertTrue(pair.fragment.contains("layout(location = 0) in vec4 v_L[3];"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(location = 3) in vec2 v_A;"), pair.fragment)
    }

    /// `g_TextureN` binds at N; any other sampler at 16 and up.
    func testSamplersBindAtTheirTextureRegister() {
        let pair = link("void main() {}\n",
                        "uniform sampler2D g_Texture3;\nuniform mediump sampler2D g_Noise;\nuniform sampler3D g_Texture1;\nvoid main() {}\n")
        XCTAssertTrue(pair.fragment.contains("layout(binding = 3) uniform sampler2D g_Texture3;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(binding = 16) uniform sampler2D g_Noise;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(binding = 1) uniform sampler3D g_Texture1;"), pair.fragment)
        XCTAssertEqual(pair.textureSlots, [1, 3])
    }

    /// A loose uniform stays as declared, for glslang's relaxed rules to gather.
    func testLooseUniformsAreLeftToGlslang() {
        let pair = link("uniform vec4 g_Color;\nvoid main() {}\n", "void main() {}\n")
        XCTAssertTrue(pair.vertex.contains("uniform vec4 g_Color;"), pair.vertex)
        XCTAssertFalse(pair.vertex.contains("layout"), pair.vertex)
    }

    /// Vertex attributes get the mesh streams' locations; a name no stream feeds gets 15.
    func testAttributesGetTheMeshStreamLocations() {
        let pair = link("in vec3 a_Position;\nin vec4 a_Color;\nin vec2 a_Custom;\nvoid main() {}\n", "void main() {}\n")
        XCTAssertTrue(pair.vertex.contains("layout(location = 0) in vec3 a_Position;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("layout(location = 4) in vec4 a_Color;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("layout(location = 15) in vec2 a_Custom;"), pair.vertex)
        XCTAssertEqual(pair.attributes, ["a_Position": 0, "a_Color": 4, "a_Custom": 15])
    }

    /// Only a vertex input is an attribute: a varying may be named `a_…` too (the default
    /// project dna_fragment's `a_TexCloudsCoord`).
    func testAVaryingNamedLikeAnAttributeLinks() {
        let pair = link("out vec2 a_TexCloudsCoord;\nvoid main() {}\n", "in vec2 a_TexCloudsCoord;\nvoid main() {}\n")
        XCTAssertTrue(pair.vertex.contains("layout(location = 0) out vec2 a_TexCloudsCoord;"), pair.vertex)
        XCTAssertTrue(pair.fragment.contains("layout(location = 0) in vec2 a_TexCloudsCoord;"), pair.fragment)
        XCTAssertEqual(pair.attributes, [:])
    }

    /// A written attribute is read into a global of its name, at the start of `main`; so is one
    /// that is only incremented.
    func testWrittenAttributesBecomeGlobals() {
        let pair = link("in vec3 a_Position;\nin float a_Size;\nvoid main(void) {\n a_Position.xy *= 2.0;\n a_Size++;\n}\n",
                        "void main() {}\n")
        XCTAssertTrue(pair.vertex.contains("layout(location = 0) in vec3 a_Position_weIn;\nvec3 a_Position;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("in float a_Size_weIn;\nfloat a_Size;"), pair.vertex)
        XCTAssertTrue(pair.vertex.contains("void main(void) {\na_Position = a_Position_weIn; a_Size = a_Size_weIn;\n"), pair.vertex)
    }

    /// Reads, comparisons and a member of something else of the same name are not writes.
    func testOnlyAssignmentsCountAsWrites() {
        let tokens = GLSLTokenizer.tokens(Array("x = v.y; s.v = 1.0; if (v == 2.0 || v <= 1.0) {} f(v);".utf16))
        XCTAssertFalse(HLSLLinkage.isAssigned("v", in: tokens))
        for write in ["v = 1.0;", "v.x += 1.0;", "--v;", "v %= 2.0;"] {
            XCTAssertTrue(HLSLLinkage.isAssigned("v", in: GLSLTokenizer.tokens(Array(write.utf16))), write)
        }
    }

    /// A varying each stage sizes differently is read as the vertex stage's type and converted.
    func testResizedVaryingsConvertToTheFragmentsType() {
        let pair = link("out vec4 v_A;\nout vec2 v_B;\nvoid main() {}\n",
                        "in vec2 v_A;\nin vec4 v_B;\nvoid main() {}\n")
        XCTAssertTrue(pair.fragment.contains("layout(location = 0) in vec4 v_A_weVarying;\nvec2 v_A;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("layout(location = 1) in vec2 v_B_weVarying;\nvec4 v_B;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("v_A = v_A_weVarying.xy; v_B = vec4(v_B_weVarying, 0.0, 0.0);"), pair.fragment)
    }

    /// A fragment input the vertex stage never writes is declared there, after the header.
    func testAFragmentInputTheVertexStageLacksIsDeclaredThere() {
        let pair = link("#extension GL_X : enable\n\nout vec2 v_A;\nvoid main() {}\n",
                        "in vec2 v_A;\nflat in int v_Missing;\nvoid main() {}\n")
        XCTAssertTrue(pair.vertex.hasPrefix("#version 450\n#extension GL_X : enable\n\nlayout(location = 1) flat out int v_Missing;\n"),
                      pair.vertex)
    }

    /// The prelude's `gl_FragColor` output is at location 0.
    func testFragColorIsAtLocationZero() {
        let pair = link("void main() {}\n", "out vec4 out_FragColor;\nvoid main() { out_FragColor = vec4(1.0); }\n")
        XCTAssertTrue(pair.fragment.contains("layout(location = 0) out vec4 out_FragColor;"), pair.fragment)
    }

    /// The fragment stage's copy of a stage-local uniform is renamed wherever it is named, but not
    /// a struct member of the same name.
    func testStageLocalUniformsAreRenamedInTheFragmentStage() {
        let pair = link("uniform float g_Speed;\nvoid main() { gl_Position = vec4(g_Speed); }\n",
                        "uniform float g_Speed;\nuniform sampler2D g_Speed2;\nvoid main() { float x = s.g_Speed + g_Speed; }\n",
                        stageLocal: ["g_Speed"])
        XCTAssertTrue(pair.fragment.contains("uniform float g_Speed_weFragment;"), pair.fragment)
        XCTAssertTrue(pair.fragment.contains("s.g_Speed + g_Speed_weFragment"), pair.fragment)
        XCTAssertTrue(pair.vertex.contains("vec4(g_Speed)"), pair.vertex)
    }

    /// Only file-scope declarations are interface: not struct members, parameters, or a
    /// declaration that already has a `layout`; one may span lines.
    func testOnlyFileScopeDeclarationsWithoutALayoutAreInterface() {
        let tokens = GLSLTokenizer.tokens(Array("""
            struct S { vec2 in_x; };
            layout(location = 3) in vec2 v_Fixed;
            void f(in vec2 a, out vec2 b) { b = a; }
            in
              vec2 v_Split; // a comment
            uniform float g_Value;
            """.utf16))
        let declarations = HLSLLinkage.declarations(in: tokens)
        XCTAssertEqual(declarations.map(\.name), ["v_Split"])
        XCTAssertEqual(declarations.first?.storage, .input)
    }

    /// End to end: a pair whose stages declare their varyings in different orders, with a written
    /// input, links and compiles.
    func testALinkedPairCompiles() throws {
        let vertex = ShaderSource(stage: .vertex, path: "v", text: """
            attribute vec3 a_Position;
            varying vec2 v_B;
            varying vec4 v_A;
            void main() { v_A = vec4(1.0); v_B = vec2(0.5); gl_Position = vec4(a_Position, 1.0); }
            """, combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "f", text: """
            uniform sampler2D g_Texture0;
            varying vec3 v_A;
            varying vec2 v_B;
            void main() { v_B.y = 1.0 - v_B.y; gl_FragColor = texSample2D(g_Texture0, v_B) * vec4(v_A, 1.0); }
            """, combos: [], uniforms: [])
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        XCTAssertEqual(variant.textureSlots, [0])
        XCTAssertEqual(variant.attributes, ["a_Position": 0])
    }
}
