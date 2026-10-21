import XCTest
@testable import OpenWallpaperEngine

/// A uniform both stages declare differently reads each stage's own value, as WE's per-stage
/// constant buffers do (`ShaderUniformDeclaration.stageLocalNames`). Foliage sway declares
/// `g_Speed` as `speed` (default 1) in its vertex stage and `speeduv` (default 5) in its fragment
/// stage, and `g_Phase` with defaults 0 and 0.5; its UV mode (the default) animates in the
/// fragment stage, which read the vertex stage's slower, phase-less values before (WE's effect
/// gallery: motion 2.46 against our 0.46).
final class ShaderStageUniformTests: XCTestCase {
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources || FileManager.default.fileExists(
            atPath: ShaderVariantTests.weAssets.appending(path: "effects/foliagesway/effect.json").path), "WE assets not present")
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-stage-uniforms-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
    }

    private func declaration(_ type: String, _ name: String, _ annotation: [String: Any]) -> ShaderUniformDeclaration {
        ShaderUniformDeclaration(type: type, name: name, arrayCount: nil, annotation: annotation)
    }

    func testOnlyDifferingDeclarationsAreSplit() {
        let vertex = [declaration("float", "g_Speed", ["material": "speed", "default": 1]),
                      declaration("float", "g_Time", [:]),
                      declaration("float", "g_Same", ["material": "same", "default": 2]),
                      declaration("vec2", "g_Typed", ["material": "t", "default": "1 1"])]
        let fragment = [declaration("float", "g_Speed", ["material": "speeduv", "default": 5]),
                        declaration("float", "g_Time", [:]),
                        declaration("float", "g_Same", ["material": "same", "default": 2]),
                        declaration("vec4", "g_Typed", ["material": "t", "default": "1 1"])]
        XCTAssertEqual(ShaderUniformDeclaration.stageLocalNames(vertex: vertex, fragment: fragment), ["g_Speed", "g_Typed"])
        let merged = ShaderUniformDeclaration.merged(vertex: vertex, fragment: fragment)
        XCTAssertEqual(merged.map(\.name), ["g_Speed", "g_Time", "g_Same", "g_Typed", "g_Speed_weFragment", "g_Typed_weFragment"])
        XCTAssertEqual(merged.last?.type, "vec4")
    }

    func testLinkageRenamesTheFragmentStagesCopy() {
        let vertex = "#version 450\nuniform float g_Speed;\nvoid main() { gl_Position = vec4(g_Speed); }\n"
        let fragment = "#version 450\nuniform float g_Speed;\nuniform float g_SpeedUp;\nout vec4 out_FragColor;\n"
            + "void main() { out_FragColor = vec4(g_Speed + g_SpeedUp); }\n"
        let pair = HLSLLinkage.link(vertex: vertex, fragment: fragment, stageLocal: ["g_Speed"])
        XCTAssertTrue(pair.fragment.contains("uniform float g_Speed_weFragment;"))
        XCTAssertTrue(pair.fragment.contains("vec4(g_Speed_weFragment + g_SpeedUp)"))
        XCTAssertTrue(pair.vertex.contains("vec4(g_Speed)"))
    }

    func testFoliageSwayReadsEachStagesDefaults() throws {
        let root = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file":"effects/foliagesway/effect.json"}"#.utf8))
        let pass = try XCTUnwrap(builder.build(effect).passes.first)
        let members = try XCTUnwrap(pass.variant?.uniforms?.members)
        XCTAssertNotNil(members["g_Speed_weFragment"])
        XCTAssertEqual(pass.constants.staticValues["g_Speed"]?.components, [1])
        XCTAssertEqual(pass.constants.staticValues["g_Speed_weFragment"]?.components, [5])
        XCTAssertEqual(pass.constants.staticValues["g_Phase"]?.components, [0])
        XCTAssertEqual(pass.constants.staticValues["g_Phase_weFragment"]?.components, [0.5])
    }
}
