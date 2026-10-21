import XCTest
@testable import OpenWallpaperEngine

/// Roadmap §8.13: a text's `anchor` moves nothing, as in WE's output.
///
/// WE decodes the ten names (0x14025a22b: none, center, top, topright, right, bottomright, bottom,
/// bottomleft, left, topleft) and a text's draw translates its model matrix by the render
/// context's floats +0x100…+0x10c for its anchor (0x1402585c0). The context's constructor zeroes
/// them (0x14017c7c3), and nothing in `wallpaper64.exe` writes +0x100 or +0x104. WE's text
/// captures (effect gallery extras, all `center`) match the unanchored layout: moving them by half
/// a unit, as a camera-centre reading of +0x108/+0x10c would, made every one of them worse
/// (plain 0.27 → 0.37 mean abs). This guards against an anchor offset coming back as a guess.
final class SceneTextAnchorTests: XCTestCase {
    func testAnAnchoredTextDrawsWhereTheUnanchoredOneDoes() throws {
        let directory = Fixtures.url("Scenes/text-retina")
        let plain = try FixtureSceneRenderer(directory: directory).render()
        let anchored = try FixtureSceneRenderer(directory: directory, sceneFile: "anchored.json").render()
        XCTAssertEqual(plain.pixels, anchored.pixels)
    }
}
