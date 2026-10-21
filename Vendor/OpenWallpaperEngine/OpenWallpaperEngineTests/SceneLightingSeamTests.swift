import XCTest
@testable import OpenWallpaperEngine

/// The lighting and post-processing seams (docs/lighting-plan.md §4.3 L0) change nothing yet:
/// no engine combo, no packed light, and the composite of before. The user's quality settings
/// default to what the app always drew.
final class SceneLightingSeamTests: XCTestCase {
    // MARK: - Engine combos

    /// The light combos are in (A1, `LightingV1RequireTests`); HDR sets `HDR=1` on every material
    /// (B2), and an LDR material doesn't see the name (`common_blending.h` tests `#ifdef HDR`).
    func testEngineCombosSetHDROnlyInHDR() {
        let combos = SceneEngineCombos(hdr: true, sceneOrtho: false, lightBudget: WELightConfig(point: 4, tube: 2),
                                       shadowQuality: 4)
        XCTAssertEqual(combos.combos(for: ["LIGHTING": 1, "REFLECTION": 1])["HDR"], 1)
        XCTAssertEqual(combos.applied(to: ["LIGHTING": 0, "BLENDMODE": 3]),
                       ["LIGHTING": 0, "BLENDMODE": 3, "HDR": 1, "REVERSEDEPTH": 1])
        XCTAssertEqual(combos.applied(to: ["HDR": 0])["HDR"], 1, "the engine's value wins")
        let ldr = SceneEngineCombos(hdr: false, sceneOrtho: false)
        XCTAssertEqual(ldr.applied(to: ["LIGHTING": 0, "BLENDMODE": 3]), ["LIGHTING": 0, "BLENDMODE": 3, "REVERSEDEPTH": 1])
        XCTAssertNil(ldr.combos(for: ["LIGHTING": 1])["HDR"])
    }

    /// HDR is on only for `bloom` and `hdr` with post-processing "ultra" or "displayhdr".
    func testHDRNeedsBloomHDRAndUltra() {
        func hdr(bloom: Bool, hdr: Bool, _ quality: GSPostProcessingQuality) -> Bool {
            var settings = SceneRenderSettings()
            settings.postProcessing = quality
            var hdrSettings = SceneHDRBloomSettings()
            hdrSettings.enabled = hdr
            let bloomSettings = SceneBloomSettings(enabled: bloom, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1),
                                                   hdr: hdrSettings)
            return SceneEngineCombos(bloom: bloomSettings, lighting: SceneLightingSettings(), orthographic: true,
                                     settings: settings).hdr
        }
        XCTAssertTrue(hdr(bloom: true, hdr: true, .ultra))
        XCTAssertTrue(hdr(bloom: true, hdr: true, .displayhdr))
        XCTAssertFalse(hdr(bloom: true, hdr: true, .enabled))
        XCTAssertFalse(hdr(bloom: true, hdr: true, .disabled))
        XCTAssertFalse(hdr(bloom: false, hdr: true, .ultra))
        XCTAssertFalse(hdr(bloom: true, hdr: false, .ultra))
    }

    func testShadowsSettingFoldsTheBudget() {
        var lighting = SceneLightingSettings()
        lighting.lightConfig = WELightConfig(spot: 2, spotShadow: 1, spotShadowCookie: 1)
        let bloom = SceneBloomSettings(enabled: false, strength: 2, threshold: 0.65, tint: SIMD3(repeating: 1))
        var settings = SceneRenderSettings()
        XCTAssertEqual(SceneEngineCombos(bloom: bloom, lighting: lighting, orthographic: true, settings: settings).lightBudget,
                       lighting.lightConfig)
        settings.shadows = .disabled
        let off = SceneEngineCombos(bloom: bloom, lighting: lighting, orthographic: false, settings: settings)
        XCTAssertEqual(off.lightBudget, WELightConfig(spot: 2, spotCookie: 1))
        XCTAssertEqual(off.shadowQuality, 0)
        XCTAssertFalse(off.sceneOrtho)
    }

    // MARK: - Frame lighting

    /// The scene colours come from `general`, a script's colour winning; a light without
    /// `lightconfig` packs no `LightingV1` array (`SceneLightPackerTests` has the packing).
    func testFrameLightingCarriesTheSceneColours() {
        var content = SceneLightingContent()
        content.settings.ambient = SIMD3(0.3, 0.2, 0.1)
        content.settings.skylight = SIMD3(repeating: 0.4)
        content.lights = [SceneLightObject(id: "7", authored: WESceneLight(kind: .tube), light: SceneLight(kind: .tube))]
        var input = SceneFrameLightingInput(local: { _ in .identity }, parentWorld: { _ in .identity }, isVisible: { _ in true },
                                            sceneColor: { _ in nil }, eyePosition: .zero, viewForward: SIMD3(0, 0, -1))
        let lighting = SceneFrameLighting.frame(content, input: input)
        XCTAssertEqual(lighting.ambient, SIMD3(0.3, 0.2, 0.1))
        XCTAssertEqual(lighting.skylight, SIMD3(repeating: 0.4))
        XCTAssertNil(lighting.arrays["g_LTube_Color"], "no lightconfig, no LightingV1 light")
        input.sceneColor = { $0 == .ambientcolor ? SIMD3(1, 0, 0) : nil }
        XCTAssertEqual(SceneFrameLighting.frame(content, input: input).ambient, SIMD3(1, 0, 0), "a script's colour wins")
    }

    // MARK: - Content

    /// The loader hands the renderer every light in scene order, draws none of them, and keeps
    /// their transforms in the hierarchy.
    func testContentCarriesTheLights() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/lights")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/lights/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        XCTAssertEqual(content.lighting.lights.map(\.id), ["116", "516", "39", "285", "2", "5", "900", "901"])
        XCTAssertEqual(content.lighting.lights.map(\.light.kind),
                       [.tube, .spot, .point, .point, .legacyPoint, .legacyPoint, .directional, .point])
        XCTAssertEqual(content.lighting.settings.lightConfig, WELightConfig(spot: 1, spotCookie: 1))
        XCTAssertEqual(content.lighting.lights[0].depth, SceneLightDepth(originZ: 250), "the tube's own z")
        let spot = content.lighting.lights[1].depth
        XCTAssertEqual(spot.originZ, -421.09644, accuracy: 1e-3, "the spot's own z")
        XCTAssertEqual(spot.anglesXY.x, -0.14119, accuracy: 1e-6, "and its tilt")
        XCTAssertEqual(spot.anglesXY.y, 0.58229, accuracy: 1e-6)
        XCTAssertEqual(content.layers.map(\.id), ["1"], "lights draw nothing")
        XCTAssertEqual(content.transforms.nodes["285"]?.parentID, "1")
        XCTAssertNotNil(content.motions["116"], "a light moves like any other object")
        XCTAssertEqual(content.engineCombos, SceneEngineCombos(hdr: false, lightBudget: WELightConfig(spot: 1, spotCookie: 1),
                                                               shadowQuality: 2),
                       "HDR needs post-processing ultra; the default is enabled")
    }
}
