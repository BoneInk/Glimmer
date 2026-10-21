import XCTest
@testable import OWESceneEditing

/// The canvas mapping, the layer rectangles and what dragging the gizmo's handles does.
final class GizmoMathTests: XCTestCase {
    private func assertEqual(_ a: SIMD2<Double>, _ b: SIMD2<Double>, accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Transforms

    func testTransformComposesAndInverts() throws {
        let parent = SceneTransform2D.layer(translation: SIMD2(100, 50), rotation: .pi / 2, scale: SIMD2(2, 2))
        let child = SceneTransform2D.layer(translation: SIMD2(10, 0), rotation: 0, scale: SIMD2(1, 1))
        let world = parent.concatenating(child)
        // The child's origin: 10 units along the parent's x, which points up after a quarter turn, times 2.
        assertEqual(world.apply(.zero), SIMD2(100, 70))
        let inverse = try XCTUnwrap(world.inverted)
        assertEqual(inverse.apply(world.apply(SIMD2(3, -7))), SIMD2(3, -7))
        XCTAssertNil(SceneTransform2D.layer(translation: .zero, rotation: 0, scale: SIMD2(0, 1)).inverted)
    }

    // MARK: Viewport

    func testViewportFitsTheSceneAndMapsBothWays() {
        let viewport = CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1008, 1000))
        XCTAssertEqual(viewport.scale, 0.5, accuracy: 1e-12, "960 points of width left after the margins")
        let rect = viewport.sceneRect
        assertEqual(rect.size, SIMD2(960, 540))
        assertEqual(rect.origin, SIMD2(24, 230))
        // Scene y is up: the scene's bottom-left corner is the rectangle's bottom-left.
        assertEqual(viewport.canvasPoint(.zero), SIMD2(24, 770))
        assertEqual(viewport.canvasPoint(SIMD2(1920, 1080)), SIMD2(984, 230))
        assertEqual(viewport.scenePoint(viewport.canvasPoint(SIMD2(123, 456))), SIMD2(123, 456))
    }

    func testZoomKeepsThePointUnderTheAnchor() {
        var viewport = CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1048, 1000))
        let anchor = SIMD2<Double>(300, 400)
        let before = viewport.scenePoint(anchor)
        viewport.zoom(to: 1.3, anchor: anchor)
        XCTAssertEqual(viewport.scale, 1.3, accuracy: 1e-12)
        assertEqual(viewport.scenePoint(anchor), before, accuracy: 1e-9)
    }

    func testZoomIsClampedAndSteps() {
        var viewport = CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1048, 1000))
        viewport.backingScale = 2
        viewport.zoom(to: 1000)
        XCTAssertEqual(viewport.scale, viewport.maximumScale)
        XCTAssertLessThanOrEqual(1920 * viewport.scale * 2, 16384 + 1e-6, "the drawable stays within Metal's limit")
        viewport.zoom(to: 0)
        XCTAssertEqual(viewport.scale, viewport.minimumScale)
        viewport.actualSize()
        XCTAssertEqual(viewport.zoomFactor, 1, accuracy: 1e-12, "one scene pixel per display pixel")
        viewport.zoomIn()
        XCTAssertEqual(viewport.zoomFactor, 1.5, accuracy: 1e-12)
        viewport.zoomOut()
        viewport.zoomOut()
        XCTAssertEqual(viewport.zoomFactor, 0.75, accuracy: 1e-12)
        viewport.fit()
        XCTAssertEqual(viewport.pan, .zero)
    }

    func testResizeKeepsAFittedViewFitted() {
        var viewport = CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1048, 1000))
        viewport.resize(canvas: SIMD2(1968, 2000))
        XCTAssertEqual(viewport.scale, 1, accuracy: 1e-12)
    }

    // MARK: Geometry

    func testCornersFollowRotationScaleAndAlignment() {
        let geometry = LayerGeometry(transform: LayerTransform(origin: SIMD3(100, 100, 0), scale: SIMD3(2, 1, 1),
                                                               angles: SIMD3(0, 0, .pi / 2)),
                                     size: SIMD2(10, 4))
        // 20 × 4 after scaling, then turned a quarter: 4 wide, 20 tall, about the origin.
        let corners = geometry.corners
        assertEqual(corners[0], SIMD2(102, 90), accuracy: 1e-9)
        assertEqual(corners[2], SIMD2(98, 110), accuracy: 1e-9)
        XCTAssertTrue(geometry.contains(SIMD2(101, 108)))
        XCTAssertFalse(geometry.contains(SIMD2(105, 100)))
        let left = LayerGeometry.anchorOffset(alignment: "topleft", size: SIMD2(10, 4))
        assertEqual(left, SIMD2(5, -2))
    }

    func testHandlesAreFoundBeforeTheBody() {
        let viewport = CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1968, 1128))
        XCTAssertEqual(viewport.scale, 1, accuracy: 1e-12)
        let geometry = LayerGeometry(transform: LayerTransform(origin: SIMD3(960, 540, 0)), size: SIMD2(200, 100))
        let topRight = viewport.canvasPoint(geometry.corners[2])
        XCTAssertEqual(LayerGizmo.handle(at: topRight + SIMD2(3, 3), geometry: geometry, viewport: viewport), .corner(2))
        let rotate = LayerGizmo.rotateHandle(geometry, in: viewport)
        // Above the top edge on screen (canvas y down).
        assertEqual(rotate, viewport.canvasPoint(SIMD2(960, 590)) - SIMD2(0, LayerGizmo.rotateHandleDistance))
        XCTAssertEqual(LayerGizmo.handle(at: rotate, geometry: geometry, viewport: viewport), .rotate)
        XCTAssertEqual(LayerGizmo.handle(at: viewport.canvasPoint(SIMD2(960, 540)), geometry: geometry, viewport: viewport), .body)
        XCTAssertNil(LayerGizmo.handle(at: viewport.canvasPoint(SIMD2(100, 100)), geometry: geometry, viewport: viewport))
    }

    // MARK: Dragging

    func testMoveFollowsThePointerInTheParentsSpace() {
        let parent = SceneTransform2D.layer(translation: SIMD2(500, 500), rotation: 0, scale: SIMD2(2, 2))
        let start = LayerGeometry(transform: LayerTransform(origin: SIMD3(10, 10, 3)), parent: parent, size: SIMD2(10, 10))
        let drag = LayerGizmo.Drag(handle: .body, start: start, startPoint: SIMD2(520, 520))
        let moved = drag.transform(at: SIMD2(560, 500))
        // 40 right and 20 down on the scene is 20 and -10 in a parent scaled twice.
        XCTAssertEqual(moved.origin, SIMD3(30, 0, 3))
    }

    func testRotateTurnsAboutTheOriginAndSnaps() {
        let start = LayerGeometry(transform: LayerTransform(origin: SIMD3(0, 0, 0)), size: SIMD2(10, 10))
        let drag = LayerGizmo.Drag(handle: .rotate, start: start, startPoint: SIMD2(0, 50))
        XCTAssertEqual(drag.transform(at: SIMD2(-50, 0)).angles.z, .pi / 2, accuracy: 1e-12, "counter-clockwise, y up")
        let snapped = drag.transform(at: SIMD2(-50, 46), snap: true).angles.z
        XCTAssertEqual(snapped, .pi / 4, accuracy: 1e-12, "Shift turns in 15° steps")
    }

    func testCornerScalesProportionallyOrFreely() {
        let start = LayerGeometry(transform: LayerTransform(origin: SIMD3(100, 100, 0), scale: SIMD3(1, 2, 1)),
                                  size: SIMD2(100, 50))
        let corner = start.corners[2]  // (150, 150)
        let drag = LayerGizmo.Drag(handle: .corner(2), start: start, startPoint: corner)
        let proportional = drag.transform(at: SIMD2(200, 200))
        XCTAssertEqual(proportional.scale.x, 2, accuracy: 1e-12)
        XCTAssertEqual(proportional.scale.y, 4, accuracy: 1e-12)
        let free = drag.transform(at: SIMD2(200, 125), free: true)
        XCTAssertEqual(free.scale.x, 2, accuracy: 1e-12)
        XCTAssertEqual(free.scale.y, 1, accuracy: 1e-12)
        let collapsed = drag.transform(at: SIMD2(100, 100))
        XCTAssertEqual(collapsed.scale.x, 0.01, accuracy: 1e-12, "a scale never reaches zero")
    }

    func testCornerOfARotatedLayerScalesInItsOwnFrame() {
        let start = LayerGeometry(transform: LayerTransform(origin: .zero, angles: SIMD3(0, 0, .pi / 2)), size: SIMD2(100, 50))
        let corner = start.corners[2]
        let drag = LayerGizmo.Drag(handle: .corner(2), start: start, startPoint: corner)
        let doubled = drag.transform(at: corner * 2)
        XCTAssertEqual(doubled.scale.x, 2, accuracy: 1e-9)
        XCTAssertEqual(doubled.scale.y, 2, accuracy: 1e-9)
        XCTAssertEqual(doubled.angles.z, .pi / 2, accuracy: 1e-12)
    }
}
