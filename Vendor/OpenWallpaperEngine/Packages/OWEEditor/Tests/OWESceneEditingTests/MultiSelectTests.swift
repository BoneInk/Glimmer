import XCTest
@testable import OWESceneEditing

/// Selecting several layers and acting on them, and Wallpaper Engine's layer and effect context
/// menu commands (its editor UI's `callbackAssetContextMenu` and `contextMenuPropertyEffect`).
@MainActor
final class MultiSelectTests: XCTestCase {
    private var session: SceneEditSession!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    // MARK: Selection

    func testSelectingOneSeveralAndNone() {
        session.selection = 13
        XCTAssertEqual(session.selectedLayers, [13])
        session.select(14, extending: true)
        XCTAssertEqual(session.selectedLayers, [13, 14])
        XCTAssertEqual(session.selection, 14, "the inspector shows the one clicked last")
        session.select(14, extending: true)
        XCTAssertEqual(session.selectedLayers, [13], "an extending click on a selected layer takes it out")
        XCTAssertEqual(session.selection, 13)
        session.select([10, 13, 14])
        XCTAssertEqual(session.selection, 13, "the inspector keeps its layer when it stays selected")
        XCTAssertEqual(session.selectedIDs, [10, 13, 14], "in the scene's order")
        session.selection = 10
        XCTAssertEqual(session.selectedLayers, [10], "setting the selection alone selects that layer only")
        session.selection = nil
        XCTAssertTrue(session.selectedLayers.isEmpty)
    }

    func testDeletedLayersLeaveTheSelection() {
        session.select([13, 14], primary: 14)
        session.delete([14], actionName: "Delete")
        XCTAssertEqual(session.selectedLayers, [], "deleting the inspector's layer clears it")
        session.select([13, 10], primary: 10)
        session.delete([13], actionName: "Delete")
        XCTAssertEqual(session.selectedLayers, [10])
        XCTAssertEqual(session.selection, 10)
    }

    func testAClickGoesDownThroughStackedLayers() {
        // The background (10) and the logo (13, 200 × 100 at 1700, 900) overlap at the logo.
        let point = SIMD2<Double>(1700, 900)
        XCTAssertEqual(session.layers(at: point), [13, 10], "topmost first")
        XCTAssertEqual(session.layer(at: point, below: nil), 13)
        XCTAssertEqual(session.layer(at: point, below: 13), 10)
        XCTAssertEqual(session.layer(at: point, below: 10), 13, "wrapping to the top")
    }

    func testAMarqueeSelectsTheLayersItTouches() {
        let rect = SceneRect(minimum: SIMD2(1550, 820), maximum: SIMD2(1650, 880))
        XCTAssertEqual(session.layers(in: rect), [10, 13])
        XCTAssertEqual(session.layers(in: SceneRect(minimum: SIMD2(240, 240), maximum: SIMD2(260, 260))), [10, 14])
    }

    func testAGroupsMembersMoveWithItNotTwice() {
        session.select([10, 11, 13])
        XCTAssertEqual(session.selectedRoots, [10, 13], "the clock moves with its parent")
    }

    // MARK: Moving several

    func testDraggingSeveralIsOneUndoStep() throws {
        session.select([13, 10])
        let start = [13: session.transform(of: 13), 10: session.transform(of: 10)]
        session.groupDragPreview = session.transforms(moving: [10, 13], bySceneOffset: SIMD2(10, -20), from: start)
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(1710, 880, 0), "the drag shows before it commits")
        XCTAssertEqual(session.previewOverlay.field("origin", of: 10), SceneVector.value([970, 520, 0]))
        XCTAssertNil(session.overlay.field("origin", of: 13))
        session.endGroupDrag(actionName: "Move Layer")
        XCTAssertTrue(session.groupDragPreview.isEmpty)
        XCTAssertEqual(session.transform(of: 10).origin, SIMD3(970, 520, 0))
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(1710, 880, 0))
        XCTAssertEqual(session.undoManager.undoActionName, "Move Layer")
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits, "both moves were one step")
    }

    // MARK: Transforms

    func testRotateCopyAndPasteTransforms() {
        session.rotate([13, 10], by: -.pi / 2, actionName: "Rotate Layer")
        XCTAssertEqual(session.transform(of: 13).angles.z, -.pi / 2, accuracy: 1e-6, "CW is −90° about z")
        XCTAssertEqual(session.transform(of: 10).angles.z, -.pi / 2, accuracy: 1e-6)
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits)
        let copied = session.copiedTransform(of: 13)
        session.pasteTransform(copied, onto: [10, 14], actionName: "Paste Transforms")
        XCTAssertEqual(session.transform(of: 10), copied)
        XCTAssertEqual(session.transform(of: 14), copied, "a scripted origin's starting value")
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits, "one undo step")
    }

    func testCenterAndAlignWithBackground() {
        session.center([13, 11], actionName: "Center")
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(960, 540, 0), "the origin to the scene's centre")
        XCTAssertEqual(session.transform(of: 11).origin, SIMD3(0, 0, 0), "a layer in a group to its parent's origin")
        session.center([13], offset: { _ in SIMD2(0, -123.5) }, actionName: "Align")
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(960, 416.5, 0), "plus where its image was cropped from")
    }

    func testMoveToCustomPosition() {
        XCTAssertEqual(session.listRows, [14, 13, 2, 10, 11], "topmost first, members after their group")
        session.moveToListPosition(14, position: 3, actionName: "Reorder")
        XCTAssertEqual(session.listRows, [13, 2, 14, 10, 11])
        session.moveToListPosition(10, position: 1, actionName: "Reorder")
        XCTAssertEqual(session.listRows, [10, 11, 13, 2, 14], "the group moves with its members")
        session.moveToListPosition(14, position: 2, actionName: "Reorder")
        XCTAssertEqual(session.listRows.first(where: { $0 == 14 }).flatMap { session.listRows.firstIndex(of: $0) }, 2,
                       "a row inside a group goes to the next top-level row")
        session.moveToListPosition(11, position: 1, actionName: "Reorder")
        XCTAssertEqual(session.listRows.firstIndex(of: 11), session.listRows.firstIndex(of: 10).map { $0 + 1 },
                       "a layer in a group isn't moved")
    }

    // MARK: Effects

    func testCopyPasteAndDuplicateEffects() throws {
        let ripple = try XCTUnwrap(session.effectConfig("0", of: 10))
        guard case .object(let object) = ripple else { return XCTFail("an object") }
        XCTAssertEqual(object["file"], .string("effects/waterripple/effect.json"))
        XCTAssertNil(object[SceneEditOverlay.effectKeyMarker])
        XCTAssertEqual(session.effectConfigs(of: 10).count, 2)

        let pasted = session.addEffects([ripple], to: 13, actionName: "Paste Effect")
        XCTAssertEqual(pasted, ["+1"])
        XCTAssertEqual(session.outline.layer(13)?.effects.map(\.file), ["effects/waterripple/effect.json"])
        XCTAssertEqual(session.outline.layer(13)?.effects.first?.constants["Speed"], .number(1.5), "its settings come along")

        let copy = session.addEffects([ripple], to: 10, after: "0", actionName: "Duplicate Effect")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["0", "+1", "1"], "a duplicate goes just after its effect")
        XCTAssertEqual(copy, ["+1"])
        session.undo()
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["0", "1"])
        session.addEffects(session.effectConfigs(of: 10), to: 14, actionName: "Paste Effects")
        XCTAssertEqual(session.outline.layer(14)?.effects.map(\.key), ["+1", "+2"])
    }

    func testPasteEffectSettingsOntoTheSameEffect() throws {
        session.setEffectConstant("Speed", to: .number(3), effect: "0", of: 10, actionName: "Speed")
        session.setEffectCombo("MASK", to: 1, effect: "0", of: 10, defaultValue: 0, actionName: "Mask")
        session.setEffectVisible(false, effect: try XCTUnwrap(session.outline.layer(10)?.effects.first), of: 10, actionName: "Off")
        let copied = try XCTUnwrap(session.effectConfig("0", of: 10))
        let key = try XCTUnwrap(session.addEffects([try XCTUnwrap(session.effectConfig("1", of: 10))], to: 13, actionName: "Paste").first)
        let target = try XCTUnwrap(session.addEffects([.object(["file": .string("effects/waterripple/effect.json"), "visible": .bool(true)])],
                                                      to: 13, actionName: "Paste").first)
        session.applyEffectSettings(copied, onto: key, of: 13, actionName: "Paste Effect Settings")
        XCTAssertNil(session.effectConstant("Speed", effect: key, of: 13), "another effect's settings don't paste")
        session.applyEffectSettings(copied, onto: target, of: 13, actionName: "Paste Effect Settings")
        XCTAssertEqual(session.effectConstant("Speed", effect: target, of: 13), .number(3))
        XCTAssertEqual(session.effectCombo("MASK", effect: target, of: 13, default: 0), 1)
        let effect = try XCTUnwrap(session.outline.layer(13)?.effects.first { $0.key == target })
        XCTAssertTrue(session.isEffectVisible(effect, of: 13), "its visibility stays")
        session.undo()
        XCTAssertNil(session.effectConstant("Speed", effect: target, of: 13), "one undo step")
    }
}
