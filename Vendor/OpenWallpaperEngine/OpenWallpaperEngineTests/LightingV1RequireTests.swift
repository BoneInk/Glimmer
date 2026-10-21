import XCTest
import Metal
@testable import OpenWallpaperEngine

/// WP A1 (docs/lighting-plan.md §4.3): WE's generated `#require LightingV1` and the light combos
/// the engine sets. The oracle is `Scripts/lightingv1-reference.py`, whose output is checked in as
/// `Tests/Fixtures/LightingV1/expansions.json` (`./Scripts/lightingv1-reference.py fixture`).
final class LightingV1RequireTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let combos: [String: Int]
        let source: String
    }

    private func cases() throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: Fixtures.data("LightingV1/expansions.json"))
    }

    private func reference(_ name: String) throws -> String {
        try XCTUnwrap(cases().first { $0.name == name }, "no fixture case \(name)").source
    }

    // MARK: - The generator

    /// Every budget the library uses, the per-type 0/1/4/15 matrix, every shadow and cookie
    /// subset, the cascade quirk, subsets past their base count, and LIGHTING off or absent.
    func testGeneratorMatchesTheReferenceTextForText() throws {
        let cases = try cases()
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for fixture in cases {
            XCTAssertEqual(LightingV1Require.source(combos: fixture.combos), fixture.source, fixture.name)
        }
    }

    func testLightingOffOrAbsentEmitsNothing() throws {
        XCTAssertEqual(try reference("lighting-off"), "")
        XCTAssertEqual(try reference("lighting-absent"), "")
        XCTAssertEqual(LightingV1Require.source(combos: ["LIGHTING": 0, "LIGHTS_TUBE": 4]), "")
        XCTAssertEqual(LightingV1Require.source(combos: [:]), "")
    }

    /// With no light, the function returns black: the ambient term is the caller's
    /// (`CombineLighting`), and the 6th argument is f0, which the old stub multiplied in.
    func testNoLightsReturnsNoLight() {
        XCTAssertEqual(LightingV1Require.source(combos: ["LIGHTING": 1]), """
            vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient, float roughness, float metallic)
            {
            \tvec3 light = CAST3(0.0);
            \treturn light;
            }

            """)
    }

    /// Two shadowed directionals after one shadowed spot: WE's cascade base advances by 1, so the
    /// second light reads cascades 2…4, overlapping the first's 1…3.
    func testDirectionalCascadesKeepWEsQuirk() {
        let source = LightingV1Require.source(combos: ["LIGHTING": 1, "LIGHTS_SPOT": 1, "LIGHTS_SPOT_SHADOW": 1,
                                                       "LIGHTS_DIRECTIONAL": 2, "LIGHTS_DIRECTIONAL_SHADOW": 2])
        XCTAssertTrue(source.contains("uniform mat4 g_LFeature_ShadowProjection[7];\n"))
        XCTAssertTrue(source.contains("\tconst uint p1 = 1u;\n\tconst uint p2 = 2u;\n\tconst uint p3 = 3u;\n"))
        XCTAssertTrue(source.contains("\tconst uint p1 = 2u;\n\tconst uint p2 = 3u;\n\tconst uint p3 = 4u;\n"))
    }

    // MARK: - The source text

    func testRequireIsExpandedPerVariant() {
        let text = "uniform vec3 g_Color;\n#require LightingV1\nvoid main() {}\n"
        let lit = ShaderSourceLoader.expandRequires(in: text, combos: ["LIGHTING": 1, "LIGHTS_TUBE": 4])
        XCTAssertEqual(lit, "uniform vec3 g_Color;\n"
                       + LightingV1Require.source(combos: ["LIGHTING": 1, "LIGHTS_TUBE": 4]) + "\nvoid main() {}\n")
        XCTAssertEqual(ShaderSourceLoader.expandRequires(in: text, combos: ["LIGHTING": 0]),
                       "uniform vec3 g_Color;\n\nvoid main() {}\n")
    }

    /// Loading keeps `#require LightingV1` for the variant and comments out any other name.
    func testLoadingKeepsLightingV1AndCommentsUnknownRequires() throws {
        let text = "#require LightingV1\n#require Other\nvoid main() {}\n"
        let loaded = try ShaderSourceLoader.inlineIncludes(in: text, path: "t.frag") { _ in "" }
        XCTAssertEqual(loaded, "#require LightingV1\n// (unsupported) #require Other\nvoid main() {}\n")
    }

    /// The helpers `PerformLighting_V1` calls come before the `#require` in every shipped shader
    /// that has one.
    func testHeadersPrecedeTheRequire() throws {
        _ = try Fixtures.assets()
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        for path in Self.shipped {
            let text = try loader.load(path, stage: .fragment).text
            let require = try XCTUnwrap(text.range(of: "#require LightingV1"), path)
            let helper = try XCTUnwrap(text.range(of: "vec3 ComputePBRLightShadow("), path)
            XCTAssertLessThan(helper.lowerBound, require.lowerBound, path)
        }
    }

    // MARK: - Engine combos

    private static let lightNames = ["LIGHTS_POINT", "LIGHTS_SPOT", "LIGHTS_TUBE", "LIGHTS_DIRECTIONAL",
                                     "LIGHTS_SPOT_SHADOW_COOKIE", "LIGHTS_SPOT_SHADOW", "LIGHTS_SPOT_COOKIE",
                                     "LIGHTS_DIRECTIONAL_SHADOW", "LIGHTS_POINT_SHADOW"]

    /// Without a `lightconfig` WE's budget word is 0: a lit material gets every count at 0.
    func testLitMaterialWithoutBudgetGetsZeroCounts() {
        let combos = SceneEngineCombos(sceneOrtho: false).combos(for: ["LIGHTING": 1])
        XCTAssertEqual(combos, Dictionary(uniqueKeysWithValues: Self.lightNames.map { ($0, 0) }).merging(["REVERSEDEPTH": 1]) { $1 })
    }

    /// An unlit material gets no light combo: `SCENE_ORTHO` in an orthographic scene, and WE's
    /// `REVERSEDEPTH` everywhere.
    func testUnlitMaterialGetsOnlySceneOrthoAndReversedDepth() {
        let engine = SceneEngineCombos(sceneOrtho: true, lightBudget: WELightConfig(point: 4), shadowQuality: 2)
        XCTAssertEqual(engine.combos(for: ["LIGHTING": 0, "REFLECTION": 1]), ["SCENE_ORTHO": 1, "REVERSEDEPTH": 1])
        XCTAssertEqual(engine.combos(for: [:]), ["SCENE_ORTHO": 1, "REVERSEDEPTH": 1])
        XCTAssertEqual(SceneEngineCombos(sceneOrtho: false).combos(for: [:]), ["REVERSEDEPTH": 1])
        XCTAssertEqual(engine.applied(to: ["BLENDMODE": 3, "SCENE_ORTHO": 0]),
                       ["BLENDMODE": 3, "SCENE_ORTHO": 1, "REVERSEDEPTH": 1])
    }

    /// One piece girls (`{"tube":4}`), Hinata (`{"spot":1,"spotcookie":1}`) and Moon (`{"point":3}`).
    func testLibraryBudgets() throws {
        func combos(_ budget: WELightConfig) -> [String: Int] {
            SceneEngineCombos(sceneOrtho: true, lightBudget: budget, shadowQuality: 2).applied(to: ["LIGHTING": 1])
        }
        let tubes = combos(WELightConfig(tube: 4))
        XCTAssertEqual(tubes["LIGHTS_TUBE"], 4)
        XCTAssertEqual(tubes["SCENE_ORTHO"], 1)
        XCTAssertNil(tubes["LIGHTS_SHADOW_MAPPING"])
        XCTAssertNil(tubes["LIGHTS_COOKIE"])
        XCTAssertEqual(LightingV1Require.source(combos: tubes), try reference("one-piece-girls"))

        let spot = combos(WELightConfig(spot: 1, spotCookie: 1))
        XCTAssertEqual(spot["LIGHTS_COOKIE"], 1)
        XCTAssertNil(spot["LIGHTS_SHADOW_MAPPING"])
        XCTAssertEqual(LightingV1Require.source(combos: spot), try reference("hinata"))

        let points = combos(WELightConfig(point: 3))
        XCTAssertEqual(LightingV1Require.source(combos: points), try reference("moon"))
    }

    /// Shadow mapping follows the shadowed counts (not the cookie-only one) and takes the shadows
    /// setting as its quality; the cookie follows either cookie count.
    func testShadowMappingAndCookieFlags() {
        func combos(_ budget: WELightConfig, quality: Int = 3) -> [String: Int] {
            SceneEngineCombos(sceneOrtho: false, lightBudget: budget, shadowQuality: quality).combos(for: ["LIGHTING": 2])
        }
        for budget in [WELightConfig(spot: 1, spotShadow: 1), WELightConfig(point: 1, pointShadow: 1),
                       WELightConfig(directional: 1, directionalShadow: 1)] {
            XCTAssertEqual(combos(budget)["LIGHTS_SHADOW_MAPPING"], 1)
            XCTAssertEqual(combos(budget)["LIGHTS_SHADOW_MAPPING_QUALITY"], 3)
            XCTAssertNil(combos(budget)["LIGHTS_COOKIE"])
        }
        let both = combos(WELightConfig(spot: 1, spotShadowCookie: 1), quality: 4)
        XCTAssertEqual(both["LIGHTS_SHADOW_MAPPING"], 1)
        XCTAssertEqual(both["LIGHTS_SHADOW_MAPPING_QUALITY"], 4)
        XCTAssertEqual(both["LIGHTS_COOKIE"], 1)
        XCTAssertEqual(both["LIGHTS_SPOT_SHADOW_COOKIE"], 1)

        // Shadows disabled: the budget folds the shadowed cookie into the cookie count.
        let folded = combos(WELightConfig(spot: 1, spotShadowCookie: 1).withShadowsDisabled, quality: 0)
        XCTAssertNil(folded["LIGHTS_SHADOW_MAPPING"])
        XCTAssertEqual(folded["LIGHTS_COOKIE"], 1)
        XCTAssertEqual(folded["LIGHTS_SPOT_COOKIE"], 1)
    }

    // MARK: - Translation

    /// The shipped shaders with `#require LightingV1`.
    private static let shipped = ["genericimage4", "generic4", "genericparticle",
                                  "effects/fluidsimulation/shaders/effects/fluidsimulation_combine"]

    private static let budgets: [(String, WELightConfig?)] = [
        ("none", nil),
        ("tubes", WELightConfig(tube: 4)),
        ("spot cookie", WELightConfig(spot: 1, spotCookie: 1)),
        ("points", WELightConfig(point: 3)),
        ("one of each", WELightConfig(point: 1, spot: 1, tube: 1, directional: 1)),
        ("fifteen", WELightConfig(point: 15, spot: 15, tube: 15, directional: 15)),
    ]

    /// Translates every shipped lit shader under `budget` and builds its pipeline; returns the
    /// failures.
    private func translateShipped(_ budget: WELightConfig?, quality: Int = 2) throws -> [String] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil, failureDirectory: nil)
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        var failures: [String] = []
        for path in Self.shipped {
            let vertex = try loader.load(path, stage: .vertex), fragment = try loader.load(path, stage: .fragment)
            let engine = SceneEngineCombos(sceneOrtho: true, lightBudget: budget, shadowQuality: quality)
            let combos = engine.applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: [["LIGHTING": 1]], boundTextureSlots: [0]))
            do {
                let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
                _ = try ShaderVariantTests.makePipeline(variant, device: device)
                if let budget, budget.tube > 0, variant.uniforms?.members["g_LTube_OriginB"]?.count != budget.tube {
                    failures.append("\(path): g_LTube_OriginB isn't sized by the budget")
                }
            } catch {
                failures.append("\(path): \(error)")
            }
        }
        return failures
    }

    /// Every shipped lit shader translates and builds a pipeline under each budget, with the
    /// light arrays sized by it.
    func testLitShadersTranslateUnderEachBudget() throws {
        _ = try Fixtures.assets()
        for (label, budget) in Self.budgets {
            XCTAssertEqual(try translateShipped(budget), [], label)
        }
    }

    /// Shadowed lights read `_rt_shadowAtlas` through WE's comparison sampler
    /// (`sampler2DComparison`, `texSample2DCompare`): a Metal `depth2d` read with `sample_compare`
    /// (docs/models-plan.md §2.10).
    func testShadowBudgetsNeedTheShadowAtlas() throws {
        _ = try Fixtures.assets()
        for budget in [WELightConfig(spot: 1, spotShadow: 1), WELightConfig(point: 1, pointShadow: 1),
                       WELightConfig(directional: 2, directionalShadow: 2)] {
            XCTAssertEqual(try translateShipped(budget, quality: 4), [], "\(budget)")
        }
    }

    /// genericimage4 with lighting on and no light is `CombineLighting(0, ambient · albedo)`: the
    /// generated function is called, not the old stub's `color · f0`.
    func testGenericImage4CallsTheGeneratedFunction() throws {
        _ = try Fixtures.assets()
        let loader = ShaderSourceLoader(roots: [ShaderVariantTests.weAssets])
        let fragment = try loader.load("genericimage4", stage: .fragment)
        let combos = SceneEngineCombos(sceneOrtho: true).applied(to: ["LIGHTING": 1])
        let text = fragment.text(combos: combos)
        XCTAssertFalse(text.contains("#require"))
        XCTAssertFalse(text.contains("return color * ambient"))
        XCTAssertTrue(text.contains(LightingV1Require.source(combos: combos)))
        XCTAssertEqual(fragment.text(combos: ["LIGHTING": 0]).components(separatedBy: "PerformLighting_V1").count, 2,
                       "only the call, inside #if LIGHTING, is left")
    }
}
