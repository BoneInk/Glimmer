import XCTest
import AppKit
import simd
@testable import OpenWallpaperEngine

/// `_alias_lightCookie` (`SceneLightCookie`, docs/lighting-plan.md §2.2 step 4): the packer's last
/// cookie spot within the spot budget, its texture loaded per light, and the model materials that
/// read it under `LIGHTS_COOKIE`.
final class SceneLightCookieTests: XCTestCase {
    private func spot(cookie: Bool, name: String? = nil) -> SceneLight {
        var light = SceneLight(kind: .spot)
        light.useCookie = cookie
        if cookie { light.cookie = name ?? SceneLightDefaults.cookie }
        return light
    }

    private func entry(_ id: String, _ light: SceneLight, z: Float, visible: Bool = true) -> SceneLightPacker.Light {
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(0, 0, z, 1)
        return SceneLightPacker.Light(light: light, world: world, localOrigin: SIMD3(0, 0, z), visible: visible, id: id)
    }

    /// The packer walks cookie spots first (the flags key), nearer along the view first, and the
    /// alias ends on the last one it packs; a hidden spot and one past the spot budget don't count.
    func testTheAliasIsTheLastPackedCookieSpot() {
        let forward = SIMD3<Float>(0, 0, -1)
        let lights = [entry("plain", spot(cookie: false), z: -9),
                      entry("far", spot(cookie: true), z: -8),
                      entry("near", spot(cookie: true), z: -1),
                      entry("hidden", spot(cookie: true), z: -20, visible: false)]
        // Sorted: cookie spots by dot(origin, forward) ascending: near (1), far (8); then plain.
        XCTAssertEqual(SceneLightPacker.cookieLight(lights, budget: WELightConfig(spot: 3, spotCookie: 2), viewForward: forward), "far")
        XCTAssertEqual(SceneLightPacker.cookieLight(lights, budget: WELightConfig(spot: 1, spotCookie: 1), viewForward: forward), "near",
                       "the budget stops the walk")
        XCTAssertNil(SceneLightPacker.cookieLight([lights[0]], budget: WELightConfig(spot: 1), viewForward: forward))
        XCTAssertNil(SceneLightPacker.cookieLight(lights, budget: WELightConfig(point: 2), viewForward: forward), "no spot budget")
    }

    /// Each `usecookie` light gets its cookie, else WE's default; the key is the volumetrics' one.
    func testEachCookieLightLoadsItsTexture() {
        let lights = [SceneLightObject(id: "1", authored: WESceneLight(kind: .spot), light: spot(cookie: true, name: "cookie/mine")),
                      SceneLightObject(id: "2", authored: WESceneLight(kind: .spot), light: spot(cookie: true, name: "cookie/missing")),
                      SceneLightObject(id: "3", authored: WESceneLight(kind: .spot), light: spot(cookie: false))]
        var asked: [String] = []
        let cookies = SceneLightCookie.load(lights) { name, material in
            asked.append(name)
            XCTAssertEqual(material, SceneVolumetricsPlan.frontMaterial)
            return name == "cookie/missing" ? nil : .image(NSImage(size: NSSize(width: 2, height: 2)))
        }
        XCTAssertEqual(cookies["1"]?.key, "\(SceneVolumetricsPlan.frontMaterial)|cookie/mine")
        XCTAssertEqual(cookies["2"]?.key, "\(SceneVolumetricsPlan.frontMaterial)|\(SceneLightDefaults.cookie)", "WE's default")
        XCTAssertNil(cookies["3"])
        XCTAssertEqual(asked, ["cookie/mine", "cookie/missing", SceneLightDefaults.cookie])
    }

    /// The frame's lighting carries the alias light's cookie.
    func testTheFrameLightingCarriesTheAlias() {
        var content = SceneLightingContent()
        content.settings.lightConfig = WELightConfig(spot: 1, spotCookie: 1)
        content.lights = [SceneLightObject(id: "7", authored: WESceneLight(kind: .spot), light: spot(cookie: true))]
        content.cookies = ["7": SceneLightCookie(key: "k", source: .image(NSImage(size: NSSize(width: 2, height: 2))))]
        let input = SceneFrameLightingInput(
            local: { _ in SceneLocalTransform(origin: .zero, scale: SIMD2(repeating: 1), angle: 0) },
            parentWorld: { _ in SceneAffineTransform.identity }, isVisible: { _ in true }, sceneColor: { _ in nil },
            eyePosition: SIMD3(0, 0, 1), viewForward: SIMD3(0, 0, -1))
        XCTAssertEqual(SceneFrameLighting.frame(content, input: input).cookie?.key, "k")
        content.lights[0].light.useCookie = false
        XCTAssertNil(SceneFrameLighting.frame(content, input: input).cookie)
    }

    /// `generic4` under a cookie budget (`LIGHTS_COOKIE`) reads `_alias_lightCookie` as
    /// `g_Texture7`, which the renderer binds per frame.
    func testGeneric4BindsTheAliasUnderLightsCookie() throws {
        _ = try Fixtures.assets()
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-cookie-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let roots = [Fixtures.url("ModelMaterials"), ShaderVariantTests.weAssets]
        var materials = ModelMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in .image(NSImage(size: NSSize(width: 4, height: 4))) })
        materials.sceneEngineCombos = SceneEngineCombos(sceneOrtho: false, lightBudget: WELightConfig(spot: 1, spotCookie: 1))
        let plan = try materials.build(materialPath: "materials/generic4.json",
                                       mesh: ModelMeshCombos(mesh: MDLMesh(materials: [], flags: 0, format: MDLVertexFormat(rawValue: 0x7),
                                                                           vertexData: Data(), indexData: Data()),
                                                             bones: 0, morphTargets: false))
        let variant = try XCTUnwrap(plan.pass.variant)
        XCTAssertEqual(variant.combos["LIGHTS_COOKIE"], 1)
        guard case .fbo(SceneLightCookie.name)? = plan.pass.textures[7] else {
            return XCTFail("g_Texture7: \(String(describing: plan.pass.textures[7]))")
        }
    }
}
