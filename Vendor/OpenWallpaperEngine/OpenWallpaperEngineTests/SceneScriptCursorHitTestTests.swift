import simd
import XCTest
@testable import OpenWallpaperEngine

/// A world matrix as WE builds one: translation · rotation about z · scale, column-major.
func sceneScriptCursorMatrix(translation: SIMD2<Float>, degrees: Float = 0, scale: SIMD2<Float> = SIMD2(1, 1)) -> simd_float4x4 {
    let radians = degrees * .pi / 180
    let c = cos(radians), s = sin(radians)
    return simd_float4x4(SIMD4(c * scale.x, s * scale.x, 0, 0), SIMD4(-s * scale.y, c * scale.y, 0, 0),
                         SIMD4(0, 0, 1, 0), SIMD4(translation.x, translation.y, 0, 1))
}

/// WE's quad hit test (wallpaper64.exe 0x14019dbb0 / 0x14019d5a0): world transform, parallax
/// offset, local position from the top-left with y down, edges inclusive, no alpha.
final class SceneScriptCursorHitTestTests: XCTestCase {
    private func layer(_ matrix: simd_float4x4, size: SIMD2<Float> = SIMD2(100, 50)) -> SceneScriptCursorLayer {
        SceneScriptCursorLayer(slot: 0, worldMatrix: matrix, size: size)
    }

    private func assertLocal(_ result: SceneScriptCursorHitTest.Result, _ expected: SIMD2<Float>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.localPosition.x, expected.x, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(result.localPosition.y, expected.y, accuracy: 1e-3, file: file, line: line)
    }

    func testAnAxisAlignedQuadReportsLocalPositionFromItsTopLeft() {
        let quad = layer(sceneScriptCursorMatrix(translation: SIMD2(200, 100)))
        let centre = SceneScriptCursorHitTest.test(quad, cursor: SIMD2(200, 100), offset: .zero)
        XCTAssertTrue(centre.isInside)
        assertLocal(centre, SIMD2(50, 25))
        // Scene y is up; local y runs down from the top edge.
        assertLocal(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(151, 76), offset: .zero), SIMD2(1, 49))
        let topLeft = SceneScriptCursorHitTest.test(quad, cursor: SIMD2(150, 125), offset: .zero)
        XCTAssertTrue(topLeft.isInside, "edges are inside")
        assertLocal(topLeft, .zero)
        XCTAssertTrue(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(250, 75), offset: .zero).isInside)
        let outside = SceneScriptCursorHitTest.test(quad, cursor: SIMD2(251, 100), offset: .zero)
        XCTAssertFalse(outside.isInside)
        assertLocal(outside, SIMD2(101, 25))
    }

    func testRotationTurnsTheQuad() {
        let quad = layer(sceneScriptCursorMatrix(translation: .zero, degrees: 90))
        let hit = SceneScriptCursorHitTest.test(quad, cursor: SIMD2(0, 45), offset: .zero)
        XCTAssertTrue(hit.isInside, "the 100-wide side now runs along y")
        assertLocal(hit, SIMD2(95, 25))
        XCTAssertFalse(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(45, 0), offset: .zero).isInside)
    }

    func testScaleGrowsTheQuadButNotItsLocalUnits() {
        let quad = layer(sceneScriptCursorMatrix(translation: .zero, scale: SIMD2(2, 2)))
        let hit = SceneScriptCursorHitTest.test(quad, cursor: SIMD2(90, 40), offset: .zero)
        XCTAssertTrue(hit.isInside)
        assertLocal(hit, SIMD2(95, 5))
        XCTAssertFalse(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(101, 0), offset: .zero).isInside)
    }

    func testAParentsTransformApplies() {
        let parent = sceneScriptCursorMatrix(translation: SIMD2(1000, 0), degrees: 90)
        let child = parent * sceneScriptCursorMatrix(translation: SIMD2(100, 0))
        let quad = layer(child)
        XCTAssertTrue(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(1000, 100), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(1100, 0), offset: .zero).isInside)
    }

    func testCameraParallaxMovesTheQuadByTheObjectsOwnOriginAndDepth() {
        let sceneSize = SIMD2<Float>(1920, 1080)
        let parallax = SceneScriptCursorFrame.Parallax(state: SceneCameraParallax(sceneSize: sceneSize), amount: 0.5)
        var quad = layer(sceneScriptCursorMatrix(translation: SIMD2(1160, 540)), size: SIMD2(10, 10))
        quad.origin = SIMD2(1160, 540)
        quad.parallaxDepth = SIMD2(1, 2)
        let frame = SceneScriptCursorFrame(cursorWorldPosition: .zero, leftButtonDown: false, parallax: parallax, layers: [quad])
        let offset = frame.parallaxOffset(of: quad)
        XCTAssertEqual(offset, SIMD2(100, 0), "0.5 · ((1160, 540) − (960, 540)) · (1, 2)")
        XCTAssertTrue(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(1260, 540), offset: offset).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(quad, cursor: SIMD2(1160, 540), offset: offset).isInside)
        let still = SceneScriptCursorFrame(cursorWorldPosition: .zero, leftButtonDown: false, layers: [quad])
        XCTAssertEqual(still.parallaxOffset(of: quad), .zero, "no offset without parallax")
    }

    func testAnEdgeOnQuadIsNeverHit() {
        let flat = layer(sceneScriptCursorMatrix(translation: .zero, scale: SIMD2(0, 1)))
        XCTAssertEqual(SceneScriptCursorHitTest.test(flat, cursor: .zero, offset: .zero),
                       SceneScriptCursorHitTest.Result(isInside: false, localPosition: .zero))
        let empty = layer(sceneScriptCursorMatrix(translation: .zero), size: .zero)
        XCTAssertFalse(SceneScriptCursorHitTest.test(empty, cursor: .zero, offset: .zero).isInside)
    }
}
