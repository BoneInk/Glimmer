import XCTest
@testable import OpenWallpaperEngine

/// A solid layer (`models/util/solidlayer.json`, WE's `flat` shader) with a `colorBlendMode`
/// composites its fill through WE's composite material with that blend mode; without one it
/// keeps its own draw. WE's capture of such a band blends (effect gallery EXTRAS.md item 3).
final class SceneSolidLayerBlendTests: XCTestCase {
    func testSolidLayerTakesItsBlendMode() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's shader sources aren't available")
        let directory = Fixtures.url("Scenes/solid-blend")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/solid-blend/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layers = Dictionary(uniqueKeysWithValues: content.layers.map { ($0.id, $0) })
        let plain = try XCTUnwrap(layers["1"])
        XCTAssertNil(plain.imageMaterial, "a solid layer without a blend mode keeps its own draw")
        let multiply = try XCTUnwrap(layers["2"])
        let plan = try XCTUnwrap(multiply.imageMaterial, "the blend mode needs WE's composite material")
        XCTAssertEqual(plan.materialPath, ImageMaterialPlanBuilder.blendCompositeMaterial)
        XCTAssertEqual(plan.pass.variant?.combos["BLENDMODE"], 2)
        XCTAssertTrue(plan.readsSceneSnapshot)
        XCTAssertEqual(multiply.solidFill, SIMD4(0.2, 0.6, 1, 1))
    }
}
