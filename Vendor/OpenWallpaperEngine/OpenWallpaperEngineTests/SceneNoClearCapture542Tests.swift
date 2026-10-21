import XCTest
@testable import OpenWallpaperEngine

/// WE 2.8.0.42 capture 542: with `general.clearenabled` false the scene is never cleared, not even
/// to `clearcolor`: a 0.15 grey clear colour shows black behind the layers, and the frame keeps
/// what was drawn before (`SceneScriptRenderTests.testClearEnabledOffKeepsTheLastFrame`).
final class SceneNoClearCapture542Tests: XCTestCase {
    func testAnUnclearedSceneStartsBlackNotTheClearColour() throws {
        _ = try Fixtures.assets()
        var renderer = FixtureSceneRenderer(directory: Fixtures.url("Scenes/noclear-grey"))
        renderer.points = SIMD2(128, 64)
        let frame = try renderer.render()
        let background = frame.pixel(100, 32)
        XCTAssertEqual(background.x, 0, "black, not the 0.15 grey clear colour: \(background)")
        XCTAssertEqual(background.y, 0)
        XCTAssertEqual(background.z, 0)
        let square = frame.pixel(16, 32)
        XCTAssertGreaterThan(square.x, 200, "the layer draws: \(square)")
        XCTAssertLessThan(square.y, 30)
    }
}
