import XCTest
@testable import OWESceneEditing

/// The outline the editor shows, and every edit with its undo and redo.
@MainActor
final class SceneEditSessionTests: XCTestCase {
    private var session: SceneEditSession!
    private var saved: [SceneEditOverlay] = []

    override func setUp() async throws {
        let undoManager = UndoManager()
        // No run loop turns in a test: groups are the session's own.
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        saved = []
        session.onChange = { [unowned self] in saved.append($0) }
    }

    // MARK: Outline

    func testOutlineReadsKindsParentsEffectsAndSize() throws {
        let outline = session.outline
        XCTAssertEqual(outline.size, SIMD2(1920, 1080))
        XCTAssertEqual(outline.layers.map(\.id), [10, 11, 2, 13, 14], "an object without an id is keyed by its index")
        XCTAssertEqual(outline.layers.map(\.kind), [.image, .text, .particle, .image, .image])
        XCTAssertEqual(outline.children(of: nil).map(\.id), [10, 2, 13, 14])
        XCTAssertEqual(outline.children(of: 10).map(\.id), [11])
        XCTAssertEqual(outline.ancestors(of: 11).map(\.id), [10])
        let background = try XCTUnwrap(outline.layer(10))
        XCTAssertEqual(background.effects.map(\.title), ["Waterripple", "Soft"])
        XCTAssertEqual(background.effects.first?.folderName, "waterripple")
        XCTAssertEqual(background.sourcePath, "models/bg.json")
    }

    func testAPerspectiveSceneHasNoSize() throws {
        let data = Data(#"{"general": {}, "objects": [{"id": 1, "image": "a.json"}]}"#.utf8)
        XCTAssertNil(try SceneOutline(sceneData: data).size)
        let auto = Data(#"{"general": {"orthogonalprojection": {"auto": true}}, "objects": [{"id": 1, "image": "a.json", "size": "800 600"}]}"#.utf8)
        XCTAssertEqual(try SceneOutline(sceneData: auto).size, SIMD2(800, 600))
    }

    // MARK: Reading

    func testValuesComeFromTheEditThenTheScene() {
        XCTAssertEqual(session.transform(of: 10).origin, SIMD3(960, 540, 0))
        XCTAssertEqual(session.transform(of: 14).origin, SIMD3(300, 300, 0), "a driven field shows its starting value")
        XCTAssertTrue(session.isVisible(13))
        XCTAssertFalse(session.isEditable("visible", of: 13), "a user property sets it")
        XCTAssertEqual(session.binding("visible", of: 13), .userProperty("showlogo"))
        XCTAssertEqual(session.binding("origin", of: 14), .driven)
    }

    func testGeometryIncludesTheParentsTransform() throws {
        let clock = try XCTUnwrap(session.geometry(of: 11))
        XCTAssertEqual(clock.pivot, SIMD2(1060, 590), "100, 50 from its parent's origin")
        XCTAssertGreaterThan(clock.size.x, 0)
        XCTAssertNil(session.geometry(of: 2), "particles have no rectangle")
    }

    func testPicksTheTopmostVisibleUnlockedLayer() {
        XCTAssertEqual(session.layer(at: SIMD2(1700, 900)), 13)
        XCTAssertEqual(session.layer(at: SIMD2(100, 100)), 10)
        session.setLocked(true, 13, actionName: "Lock")
        XCTAssertEqual(session.layer(at: SIMD2(1700, 900)), 10, "a locked layer can't be picked")
        session.setVisible(false, 10, actionName: "Hide")
        XCTAssertNil(session.layer(at: SIMD2(100, 100)))
    }

    // MARK: Edits, undo and redo

    func testEveryEditIsUndoneAndRedone() throws {
        session.setValue(.number(0.5), for: "alpha", of: 10, actionName: "Change Opacity")
        session.setVisible(false, 11, actionName: "Hide Layer")
        session.setTransform(LayerTransform(origin: SIMD3(1, 2, 0), scale: SIMD3(2, 2, 1), angles: SIMD3(0, 0, 1)),
                             of: 10, actionName: "Move Layer")
        session.setEffectVisible(false, effect: try XCTUnwrap(session.outline.layer(10)?.effects.first), of: 10,
                                 actionName: "Turn Effect Off")
        session.setLocked(true, 14, actionName: "Lock Layer")
        let edited = session.overlay
        XCTAssertEqual(session.undoManager.undoActionName, "Lock Layer")

        for _ in 0..<5 { session.undo() }
        XCTAssertEqual(session.overlay, SceneEditOverlay(), "undo goes back to the scene as authored")
        XCTAssertFalse(session.canUndo)
        for _ in 0..<5 { session.redo() }
        XCTAssertEqual(session.overlay, edited)
        XCTAssertEqual(saved.last, edited, "undo and redo are saved and applied like any edit")
    }

    func testAnEditBackToTheAuthoredValueIsNoEdit() {
        session.setValue(.number(0.5), for: "alpha", of: 10, actionName: "Change Opacity")
        XCTAssertTrue(session.isEdited(10))
        session.setValue(.number(1), for: "alpha", of: 10, actionName: "Change Opacity")
        XCTAssertFalse(session.isEdited(10))
        session.setValue(.string("960 540 0"), for: "origin", of: 10, actionName: "Move")
        XCTAssertFalse(session.isEdited(10), "the same numbers written differently")
        session.setVisible(true, 2, actionName: "Show")
        XCTAssertFalse(session.isEdited(2), "visible is WE's default")
    }

    func testASliderDragIsOneUndoStep() {
        for value in [0.9, 0.7, 0.5, 0.3] {
            session.setValue(.number(value), for: "alpha", of: 10, actionName: "Change Opacity", coalescing: true)
        }
        session.setValue(.number(0.5), for: "alpha", of: 11, actionName: "Change Opacity", coalescing: true)
        session.undo()
        XCTAssertNil(session.overlay.field("alpha", of: 11))
        XCTAssertEqual(session.value("alpha", of: 10)?.doubleValue ?? 0, 0.3, accuracy: 1e-9)
        session.undo()
        XCTAssertNil(session.overlay.field("alpha", of: 10), "the whole drag undoes at once")
        session.redo()
        XCTAssertEqual(session.value("alpha", of: 10)?.doubleValue ?? 0, 0.3, accuracy: 1e-9, "redo restores where it ended")
    }

    func testAGizmoDragCommitsOnce() {
        var transform = session.transform(of: 10)
        for step in 1...5 {
            transform.origin.x = 960 + Double(step) * 10
            session.dragPreview = (10, transform)
        }
        XCTAssertTrue(saved.isEmpty, "nothing is saved while dragging")
        XCTAssertEqual(session.transform(of: 10).origin.x, 1010, "the preview is drawn")
        session.endDrag(actionName: "Move Layer")
        XCTAssertNil(session.dragPreview)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(session.overlay.field("origin", of: 10), .string("1010 540 0"))
        XCTAssertNil(session.overlay.field("scale", of: 10), "unchanged fields aren't written")
        session.undo()
        XCTAssertEqual(session.transform(of: 10).origin.x, 960)
    }

    func testRevertToSavedGoesBackToTheSavedOverlayAndUndoes() {
        session.setValue(.number(0.5), for: "alpha", of: 10, actionName: "Change Opacity")
        let saved = session.overlay
        session.setValue(.number(0.25), for: "alpha", of: 10, actionName: "Change Opacity")
        session.setLocked(true, 11, actionName: "Lock")
        session.revert(to: saved, actionName: "Revert to Saved")
        XCTAssertEqual(session.overlay, saved, "nothing unsaved is left, the lock included")
        XCTAssertEqual(session.value("alpha", of: 10), .number(0.5))
        XCTAssertFalse(session.isLocked(11))
        session.undo()
        XCTAssertEqual(session.value("alpha", of: 10), .number(0.25))
        XCTAssertTrue(session.isLocked(11))
    }

    func testAppliedSceneMatchesWhatTheSessionShows() throws {
        session.setTransform(LayerTransform(origin: SIMD3(5, 6, 0), scale: SIMD3(1, 1, 1), angles: SIMD3(0, 0, 0)),
                             of: 14, actionName: "Move")
        let applied = try session.overlay.applied(to: Fixtures.sceneData)
        let reread = try SceneOutline(sceneData: applied)
        let fresh = SceneEditSession(outline: reread)
        XCTAssertEqual(fresh.transform(of: 14).origin, SIMD3(5, 6, 0), "the loader sees what the editor showed")
    }
}
