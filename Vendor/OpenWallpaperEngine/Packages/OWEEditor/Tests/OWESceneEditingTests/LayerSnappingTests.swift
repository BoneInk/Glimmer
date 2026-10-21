import XCTest
@testable import OWESceneEditing

/// Snapping a dragged layer to the scene and to other layers, and aligning to the scene.
@MainActor
final class LayerSnappingTests: XCTestCase {
    private let scene = SIMD2<Double>(1000, 500)

    func testSnapsToTheScenesCentreWithinTheThreshold() {
        let moving = SceneRect(minimum: SIMD2(100, 100), maximum: SIMD2(200, 150))
        // Centre at 150; dragged 347 right puts it at 497, 3 from the scene's centre (500).
        let result = LayerSnapping.snap(moving, delta: SIMD2(347, 0), to: LayerSnapping.targets(scene: scene, others: []),
                                        threshold: 5)
        XCTAssertEqual(result.delta.x, 350)
        XCTAssertEqual(result.delta.y, 0, "y: no line within 5")
        XCTAssertEqual(result.guides.count, 1)
        XCTAssertEqual(result.guides.first?.axis, 0)
        XCTAssertEqual(result.guides.first?.position, 500)
    }

    func testNoSnapOutsideTheThreshold() {
        let moving = SceneRect(minimum: SIMD2(100, 100), maximum: SIMD2(200, 150))
        let result = LayerSnapping.snap(moving, delta: SIMD2(340, 7), to: LayerSnapping.targets(scene: scene, others: []),
                                        threshold: 5)
        XCTAssertEqual(result.delta, SIMD2(340, 7))
        XCTAssertTrue(result.guides.isEmpty)
    }

    func testSnapsEdgesToAnotherLayerAndToTheNearestLine() {
        let other = SceneRect(minimum: SIMD2(600, 300), maximum: SIMD2(700, 400))
        let moving = SceneRect(minimum: SIMD2(0, 0), maximum: SIMD2(50, 50))
        // Left edge to 698 (2 from the other's right, 700), bottom to 302 (2 from its bottom, 300).
        let result = LayerSnapping.snap(moving, delta: SIMD2(698, 302), to: LayerSnapping.targets(scene: scene, others: [other]),
                                        threshold: 4)
        XCTAssertEqual(result.delta, SIMD2(700, 300))
        XCTAssertEqual(Set(result.guides.map(\.axis)), [0, 1])
        let vertical = result.guides.first { $0.axis == 0 }
        XCTAssertEqual(vertical?.from, 300, "the guide spans both layers")
        XCTAssertEqual(vertical?.to, 400)
    }

    func testAlignment() {
        let rect = SceneRect(minimum: SIMD2(10, 20), maximum: SIMD2(110, 70))
        let bounds = SceneRect(minimum: .zero, maximum: scene)
        XCTAssertEqual(LayerSnapping.alignment(rect, within: bounds, horizontal: 0, vertical: nil), SIMD2(-10, 0))
        XCTAssertEqual(LayerSnapping.alignment(rect, within: bounds, horizontal: 1, vertical: 1), SIMD2(440, 205))
        XCTAssertEqual(LayerSnapping.alignment(rect, within: bounds, horizontal: 2, vertical: 2), SIMD2(890, 430))
    }

    func testDistribution() {
        let rects = [SceneRect(minimum: SIMD2(0, 0), maximum: SIMD2(10, 10)),
                     SceneRect(minimum: SIMD2(80, 0), maximum: SIMD2(90, 10)),
                     SceneRect(minimum: SIMD2(15, 0), maximum: SIMD2(25, 10))]
        let deltas = LayerSnapping.distribution(rects, axis: 0)
        XCTAssertEqual(deltas[0].x, 0)
        XCTAssertEqual(deltas[1].x, 0, "the last stays")
        XCTAssertEqual(deltas[2].x, 25, "the middle one moves to even gaps of 30")
    }

    func testASnappedDragMovesTheLayerInItsParentsSpace() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData))
        let geometry = try XCTUnwrap(session.geometry(of: 13))
        // Logo: 200 × 100 at 1700, 900; its right edge at 1800. Dragged 118 right: 2 from the scene's edge.
        let drag = LayerGizmo.Drag(handle: .body, start: geometry, startPoint: SIMD2(1700, 900))
        let snapped = session.snappedMove(drag, layer: 13, to: SIMD2(1818, 900), threshold: 4)
        XCTAssertEqual(snapped.transform.origin.x, 1820, "its right edge on the scene's (1920)")
        XCTAssertFalse(snapped.guides.isEmpty)
        let free = session.snappedMove(drag, layer: 13, to: SIMD2(1818, 900), threshold: 0)
        XCTAssertEqual(free.transform.origin.x, 1818)
    }

    func testAlignToSceneIsOneUndoStep() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        session.alignToScene(13, horizontal: 1, vertical: 1, actionName: "Align")
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(960, 540, 0))
        session.undo()
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(1700, 900, 0))
    }
}
