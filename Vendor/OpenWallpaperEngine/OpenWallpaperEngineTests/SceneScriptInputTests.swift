import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// `input` (docs/scenescript-plan.md §1.5, §4.8): screen pixels in, scene units out, through the
/// same placement the composite draws with.
final class SceneScriptInputTests: XCTestCase {
    private func world(_ screen: SIMD2<Double>, placement: WallpaperPlacement,
                       screenResolution: SIMD2<Double> = SIMD2(2000, 1000),
                       canvas: SIMD2<Double> = SIMD2(1000, 1000), pixelsPerPoint: Double = 1) -> SIMD2<Double> {
        let environment = SceneScriptEngineEnvironment(screenResolution: screenResolution, canvasSize: canvas,
                                                       placement: placement, pixelsPerPoint: pixelsPerPoint)
        return SceneScriptInput(cursorScreenPosition: screen).cursorWorldPosition(in: environment)
    }

    func testStretchMapsTheScreenOntoTheCanvasWithYUp() {
        XCTAssertEqual(world(SIMD2(0, 0), placement: .stretch), SIMD2(0, 1000), "top-left of the screen is the scene's top-left")
        XCTAssertEqual(world(SIMD2(2000, 1000), placement: .stretch), SIMD2(1000, 0))
        XCTAssertEqual(world(SIMD2(500, 250), placement: .stretch), SIMD2(250, 750))
    }

    func testFillCropsAndFitLetterboxes() {
        // Fill scales a square canvas by 2 onto a 2000×1000 screen: only its middle half-height shows.
        XCTAssertEqual(world(SIMD2(1000, 500), placement: .fill), SIMD2(500, 500))
        XCTAssertEqual(world(SIMD2(0, 0), placement: .fill), SIMD2(0, 750))
        // Fit scales it by 1 and centres it: 500 px bars left and right, outside the canvas.
        XCTAssertEqual(world(SIMD2(500, 0), placement: .fit), SIMD2(0, 1000))
        XCTAssertEqual(world(SIMD2(100, 500), placement: .fit), SIMD2(-400, 500))
    }

    func testCenterShowsOneUnitPerPoint() {
        XCTAssertEqual(world(SIMD2(1000, 500), placement: .center, pixelsPerPoint: 2), SIMD2(500, 500))
        XCTAssertEqual(world(SIMD2(1200, 500), placement: .center, pixelsPerPoint: 2), SIMD2(600, 500))
    }

    /// WE shakes the camera's eye, so the scene point under the cursor moves with the shake.
    func testTheWorldPositionIncludesTheCameraShake() {
        let environment = SceneScriptEngineEnvironment(screenResolution: SIMD2(2000, 1000), canvasSize: SIMD2(1000, 1000),
                                                       placement: .stretch)
        let input = SceneScriptInput(cursorScreenPosition: SIMD2(500, 250), shakeOffset: SIMD2(3, -2))
        XCTAssertEqual(input.cursorWorldPosition(in: environment), SIMD2(253, 748))
    }

    func testScriptsSeeTheCursorAsFreshVectors() throws {
        _ = try Fixtures.assets()
        let environment = SceneScriptEngineEnvironment(screenResolution: SIMD2(2000, 1000), canvasSize: SIMD2(1000, 1000),
                                                       placement: .stretch)
        let fixture = try SceneScriptEngineTestFixture(environment: environment)
        defer { fixture.removeStorage() }
        fixture.add("cursor", """
            shared.log = [];
            function update() {
                const w = input.cursorWorldPosition, s = input.cursorScreenPosition;
                shared.log.push([w instanceof Vec3, w.toString(), s instanceof Vec2, s.toString(), input.cursorLeftDown].join('|'));
                w.x = -1;
            }
            """)
        fixture.runtime.load()
        fixture.engine.input = SceneScriptInput(cursorScreenPosition: SIMD2(500, 250), cursorLeftDown: true)
        fixture.frames(1)
        fixture.engine.input.cursorLeftDown = false
        fixture.frames(1)
        XCTAssertEqual(fixture.takeLog(), ["true|250 750 0|true|500 250|true", "true|250 750 0|true|500 250|false"])
    }
}
