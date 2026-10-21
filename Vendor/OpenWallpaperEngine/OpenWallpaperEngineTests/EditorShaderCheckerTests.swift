import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The shader editor's translator: a pair the loader would translate passes, and a broken one
/// reports the step that failed, the text it compiled, and each error on the edited file's line,
/// past the prelude, the includes the loader inlines and the front end's edits.
final class EditorShaderCheckerTests: XCTestCase {
    private static let vertex = """
    uniform mat4 g_ModelViewProjectionMatrix;

    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;

    varying vec2 v_TexCoord;

    void main() {
    \tgl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
    \tv_TexCoord.xy = a_TexCoord;
    }
    """

    private static func fragment(body: String, header: String = "") -> String {
        """
        \(header)uniform sampler2D g_Texture0; // {"material":"framebuffer","label":"ui_editor_properties_framebuffer","hidden":true}
        uniform float u_Amount; // {"material":"Amount","default":1,"range":[0,1]}

        varying vec2 v_TexCoord;

        void main() {
        \tvec4 albedo = texSample2D(g_Texture0, v_TexCoord.xy);
        \(body)
        \tgl_FragColor = albedo;
        }
        """
    }

    private func check(fragment: String, assets: URL? = nil) async -> ShaderCheckResult {
        let translator = ShaderVariantTranslator(compiler: ShaderCompilerFactory.makeDefault(), cacheDirectory: nil, failureDirectory: nil)
        let checker = EditorShaderChecker(translator: translator, read: { path in
            guard let assets else { return nil }
            return (try? AssetPathResolver.data(path, in: assets)) ?? nil // Optional: a file the assets don't have.
        })
        let request = ShaderCheckRequest(shader: "effects/mine", effectDirectory: "effects/mine", files: [
            "effects/mine/shaders/effects/mine.vert": Self.vertex,
            "effects/mine/shaders/effects/mine.frag": fragment,
        ])
        return await checker.check(request)
    }

    func testAPairThatTranslatesHasNoProblems() async {
        let result = await check(fragment: Self.fragment(body: "\talbedo.rgb = mix(albedo.rgb, CAST3(dot(vec3(0.11, 0.59, 0.3), albedo.rgb)), u_Amount);"))
        XCTAssertTrue(result.isSuccess, "\(result.log)")
    }

    func testACompileErrorIsOnTheEditedLine() async throws {
        let result = await check(fragment: Self.fragment(body: "\talbedo.rgb *= notDeclaredAnywhere;"))
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.step, "compile")
        let diagnostic = try XCTUnwrap(result.diagnostics.first { $0.message.contains("notDeclaredAnywhere") }, "\(result.log)")
        XCTAssertEqual(diagnostic.stage, .fragment)
        XCTAssertEqual(diagnostic.line, 8, "the body's line in the file")
        let source = try XCTUnwrap(result.translatedSource)
        let line = try XCTUnwrap(result.translatedLine)
        XCTAssertTrue(source.components(separatedBy: "\n")[line - 1].contains("notDeclaredAnywhere"),
                      "View Errors marks the line of the text the compiler read")
    }

    func testAPreprocessorErrorIsOnTheEditedLine() async throws {
        let result = await check(fragment: Self.fragment(body: "#error stop here"))
        XCTAssertEqual(result.step, "preprocess")
        XCTAssertEqual(result.diagnostics.first?.line, 8, "\(result.log)")
    }

    func testLinesPastAnIncludeStillMap() async throws {
        let assets = try Fixtures.assets()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.appending(path: "shaders/common.h").path),
                          "WE's common.h isn't in the assets")
        let result = await check(fragment: Self.fragment(body: "\talbedo.rgb = hsv2rgb(albedo.rgb) * missingValue;",
                                                         header: "#include \"common.h\"\n\n"), assets: assets)
        let diagnostic = try XCTUnwrap(result.diagnostics.first { $0.message.contains("missingValue") }, "\(result.log)")
        XCTAssertEqual(diagnostic.line, 10, "two lines more for the include and its blank line")
    }

    func testErrorLinesAreRead() {
        let errors = EditorShaderChecker.parseErrors("""
        ERROR: shader.frag:12: 'foo' : undeclared identifier
        ERROR: shader.frag:12: '' : compilation terminated
        ERROR: 2 compilation errors.  No code generated.
        """)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first?.0, .fragment)
        XCTAssertEqual(errors.first?.1, 12)
        XCTAssertEqual(errors.first?.2, "'foo' : undeclared identifier")
    }
}
