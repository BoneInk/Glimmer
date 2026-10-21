import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Names GLSL reserves but WE's HLSL-backed compiler accepts (`float common;` in a workshop
/// FXAA, `vec4 input` in WE's own blend effect) translate, with interface names kept intact.
final class GLSLReservedWordsTests: XCTestCase {
    private let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil,
                                                     failureDirectory: nil)

    /// The list is exactly what it claims: glslang rejects each word as a name.
    func testGlslangRejectsEveryListedWord() throws {
        let compiler = InProcessShaderCompiler()
        for word in GLSLReservedWords.words.sorted() {
            let text = "#version 450\nlayout(location = 0) out vec4 color;\nvoid main() { float \(word) = 1.0; color = vec4(\(word)); }\n"
            XCTAssertThrowsError(try compiler.compilePairToMSL(vertex: "#version 450\nvoid main() { gl_Position = vec4(0.0); }\n", fragment: text), word)
        }
    }

    /// Every listed word works as a varying, a local, a parameter, a function and a uniform, and
    /// the MSL its restored name ends up in compiles; a uniform keeps WE's name.
    func testEveryListedWordTranslatesAndCompilesInMetal() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for word in GLSLReservedWords.words.sorted() {
            let plain = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }"
            let pairs: [(vertex: String, fragment: String)] = [
                ("""
                 attribute vec3 a_Position;
                 varying vec4 \(word);
                 void main() { \(word) = vec4(a_Position, 1.0); gl_Position = \(word); }
                 """, """
                 varying vec4 \(word);
                 float f(float \(word)) { float x = \(word) * 2.0; return x; }
                 float g(float x) { float \(word) = x; return \(word); }
                 void main() { gl_FragColor = \(word) * f(\(word).x) * g(\(word).y); }
                 """),
                (plain, "float \(word)(float x) { return x * 2.0; }\nvoid main() { gl_FragColor = vec4(\(word)(0.5)); }"),
                (plain, "uniform float \(word);\nvoid main() { gl_FragColor = vec4(\(word)); }"),
            ]
            for (index, pair) in pairs.enumerated() {
                let vertex = ShaderSource(stage: .vertex, path: "v", text: pair.vertex, combos: [], uniforms: [])
                let fragment = ShaderSource(stage: .fragment, path: "f", text: pair.fragment, combos: [], uniforms: [])
                let label = "\(word) #\(index)"
                let variant: TranslatedShaderVariant
                do {
                    variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
                } catch {
                    XCTFail("\(label): \(error)")
                    continue
                }
                if index == 2 { XCTAssertNotNil(variant.uniforms?.members[word], label) }
                XCTAssertNoThrow(try device.makeLibrary(source: variant.vertexMSL, options: nil), label)
                XCTAssertNoThrow(try device.makeLibrary(source: variant.fragmentMSL, options: nil), label)
            }
        }
    }

    /// Names a GLSL reserved word only for glslang: the SPIR-V gets WE's name back, so the
    /// reflection carries it; SPIRV-Cross spells it its own way in the MSL (`_common`, as it does
    /// every GLSL keyword), and the toolchain renames it only where Metal can't take it (`half`).
    func testTheSPIRVCarriesWEsNames() throws {
        let vertex = ShaderSource(stage: .vertex, path: "v", text: "void main() { gl_Position = vec4(0.0); }",
                                  combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "f", text: """
            uniform float common;
            uniform float half;
            void main() { float sample = common; gl_FragColor = vec4(sample, half, 0.0, 1.0); }
            """, combos: [], uniforms: [])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        XCTAssertEqual(Set(try XCTUnwrap(variant.uniforms?.members).keys), ["common", "half"])
        XCTAssertTrue(variant.fragmentMSL.contains("float _common;"), variant.fragmentMSL)
        XCTAssertTrue(variant.fragmentMSL.contains("float we_half;"), variant.fragmentMSL)
        XCTAssertFalse(variant.fragmentMSL.contains("we_common"), variant.fragmentMSL)
        XCTAssertFalse(variant.fragmentMSL.contains("weSample"), variant.fragmentMSL)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNoThrow(try device.makeLibrary(source: variant.fragmentMSL, options: nil))
    }

    /// A uniform keeps WE's name in the block's layout, where material constants find it, and a
    /// varying links between the stages.
    func testInterfaceNamesStayBoundByWEsName() throws {
        let vertex = ShaderSource(stage: .vertex, path: "v", text: """
            attribute vec3 a_Position;
            uniform float filter;
            varying vec4 input;
            void main() { input = vec4(filter); gl_Position = vec4(a_Position, 1.0); }
            """, combos: [], uniforms: [])
        let fragment = ShaderSource(stage: .fragment, path: "f", text: """
            uniform float filter;
            uniform float g_Brightness;
            varying vec4 input;
            void main() { float common = filter * g_Brightness; gl_FragColor = input * common; }
            """, combos: [], uniforms: [])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: [:])
        let members = try XCTUnwrap(variant.uniforms?.members)
        XCTAssertEqual(Set(members.keys), ["filter", "g_Brightness"])
        XCTAssertEqual(members["filter"]?.name, "filter")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        XCTAssertNoThrow(try device.makeLibrary(source: variant.vertexMSL, options: nil))
        XCTAssertNoThrow(try device.makeLibrary(source: variant.fragmentMSL, options: nil))
    }

    /// WE's own blend effect names a local `input` when it writes alpha.
    func testBundledBlendTranslatesWhenWritingAlpha() throws {
        _ = try Fixtures.assets()
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let path = "effects/blend/shaders/effects/blend"
        let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
        XCTAssertEqual(fragment.preludeAnalysis.glslReservedNames, ["input"])
        let combos = ShaderVariantTranslator.resolveCombos(vertex: vertex, fragment: fragment,
                                                           overrides: [["WRITEALPHA": 1]], boundTextureSlots: [0, 1])
        XCTAssertNoThrow(try translator.variant(vertex: vertex, fragment: fragment, combos: combos))
    }

    /// Comments and string literals (`#include "common.h"`) are not names; a shader's own macro
    /// of the name is left to the preprocessor.
    func testOnlyNamesInCodeAreRenamed() {
        XCTAssertEqual(GLSLReservedWords.used(in: "#include \"common.h\"\n// input\n/* filter\n cast */ float x;"), [])
        XCTAssertEqual(GLSLReservedWords.used(in: "float common; /* x */ vec2 input;//\n"), ["common", "input"])
        let source = ShaderSource(stage: .fragment, path: "f", text: "#define filter 1.0\nfloat common = filter;",
                                  combos: [], uniforms: [])
        XCTAssertEqual(source.preludeAnalysis.glslReservedNames, ["common"])
        let prelude = ShaderPrelude.text(for: .fragment, combos: [:], analysis: source.preludeAnalysis)
        XCTAssertTrue(prelude.contains("#define common we_common\n"))
        XCTAssertFalse(prelude.contains("#define filter"))
    }

    /// `sample` is one of the list's keywords, renamed only where a shader names it.
    func testSampleIsRenamedOnlyWhereUsed() {
        XCTAssertTrue(GLSLReservedWords.words.contains("sample"))
        XCTAssertFalse(ShaderPrelude.text(for: .fragment, combos: [:], source: "float x;").contains("#define sample"))
        XCTAssertTrue(ShaderPrelude.text(for: .fragment, combos: [:], source: "float sample;").contains("#define sample we_sample\n"))
    }
}
