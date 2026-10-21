import XCTest
@testable import OWESceneEditing

/// Layers added, duplicated, deleted, renamed, reordered, grouped and parented: each one undo
/// step, each kept in the overlay and applied to scene.json the way the loader reads it.
@MainActor
final class SceneStructureEditTests: XCTestCase {
    private var session: SceneEditSession!
    private var saved: [SceneEditOverlay] = []

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        saved = []
        session.onChange = { [unowned self] in saved.append($0) }
    }

    private func applied() throws -> [[String: Any]] {
        let data = try session.overlay.applied(to: Fixtures.sceneData)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["objects"] as? [[String: Any]])
    }

    private func ids(_ objects: [[String: Any]]) -> [Int] {
        objects.enumerated().map { SceneObjects.objectID($1, index: $0) }
    }

    /// The overlay survives its file, and a fresh session over it shows the same scene.
    private func assertRoundTrips(file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try session.overlay.encoded()
        let decoded = try SceneEditOverlay.decoded(from: data)
        XCTAssertEqual(decoded, session.overlay, file: file, line: line)
        let fresh = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), overlay: decoded)
        XCTAssertEqual(fresh.outline.layers.map(\.id), session.outline.layers.map(\.id), file: file, line: line)
        XCTAssertEqual(fresh.outline.layers.map(\.parentID), session.outline.layers.map(\.parentID), file: file, line: line)
    }

    // MARK: Adding

    func testAddedLayersAreAppliedWithNewIDsOnTop() throws {
        let solid = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(1, 0, 0), size: SIMD2(1920, 1080),
                                                             origin: SIMD2(960, 540)), actionName: "Add Solid Color Layer")
        XCTAssertEqual(solid, 15, "above every id the scene uses")
        XCTAssertEqual(session.selection, solid)
        let text = session.addLayer(SceneLayerFactory.text(name: "Hello", value: "Hi", font: "systemfont_arial", pointSize: 48,
                                                           origin: SIMD2(100, 100)), actionName: "Add Text Layer")
        let sound = session.addLayer(SceneLayerFactory.sound(name: "Rain", files: ["sounds/editor/rain-1.mp3"]),
                                     actionName: "Add Sound Layer")
        let fullscreen = session.addLayer(SceneLayerFactory.fullscreen(name: "FX"), actionName: "Add Fullscreen Layer")
        let composition = session.addLayer(SceneLayerFactory.composition(name: "Comp", size: SIMD2(200, 200), origin: SIMD2(5, 5)),
                                           actionName: "Add Composition Layer")
        let objects = try applied()
        XCTAssertEqual(ids(objects).suffix(5), [solid, text, sound, fullscreen, composition],
                       "each goes above the one selected, the last added")
        let fill = try XCTUnwrap(objects.first { ($0["id"] as? NSNumber)?.intValue == solid })
        XCTAssertEqual(fill["image"] as? String, "models/util/solidlayer.json")
        XCTAssertEqual(fill["color"] as? String, "1 0 0")
        XCTAssertEqual(session.outline.layer(solid)?.imageRole, .solid)
        XCTAssertEqual(session.outline.layer(text)?.kind, .text)
        XCTAssertEqual(session.outline.layer(sound)?.kind, .sound)
        XCTAssertEqual(session.outline.layer(fullscreen)?.imageRole, .fullscreen)
        XCTAssertNil(session.geometry(of: fullscreen), "a fullscreen layer has no rectangle to grab")
        XCTAssertEqual(session.outline.layer(composition)?.imageRole, .composition)
        XCTAssertNotNil(session.geometry(of: text))
        XCTAssertTrue(session.overlay.needsVersion2)
        XCTAssertTrue(String(decoding: try session.overlay.encoded(), as: UTF8.self).contains("\"version\" : 2"))
        try assertRoundTrips()
        for _ in 0..<5 { session.undo() }
        XCTAssertEqual(session.overlay, SceneEditOverlay())
        XCTAssertEqual(session.outline.layers.count, 5)
    }

    func testAnEditOfAnAddedLayerIsAnEditOfIt() throws {
        let id = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(1, 1, 1), size: SIMD2(10, 10),
                                                          origin: SIMD2(5, 5)), actionName: "Add")
        session.setValue(.number(0.5), for: "alpha", of: id, actionName: "Opacity")
        session.setValue(.number(1), for: "alpha", of: id, actionName: "Opacity")
        XCTAssertNil(session.overlay.field("alpha", of: id), "its own value is its authored one")
        session.setTransform(LayerTransform(origin: SIMD3(50, 60, 0)), of: id, actionName: "Move")
        let object = try XCTUnwrap(try applied().first { ($0["id"] as? NSNumber)?.intValue == id })
        XCTAssertEqual(object["origin"] as? String, "50 60 0")
    }

    // MARK: Duplicating and deleting

    func testDuplicateCopiesTheLayerWithItsChildrenAndEdits() throws {
        session.setValue(.number(0.25), for: "alpha", of: 10, actionName: "Opacity")
        session.setEffectVisible(false, effect: try XCTUnwrap(session.outline.layer(10)?.effects.first), of: 10, actionName: "Off")
        let copies = session.duplicate([10], copyName: { "\($0) Copy" }, actionName: "Duplicate Layer")
        XCTAssertEqual(copies.count, 1)
        let copy = try XCTUnwrap(copies.first)
        XCTAssertEqual(session.outline.layer(copy)?.name, "Background Copy")
        let child = try XCTUnwrap(session.outline.children(of: copy).first)
        XCTAssertEqual(child.name, "Clock", "the layers under it are copied under the copy")
        XCTAssertNotEqual(child.id, 11)
        let objects = try applied()
        let copied = try XCTUnwrap(objects.first { ($0["id"] as? NSNumber)?.intValue == copy })
        XCTAssertEqual((copied["alpha"] as? NSNumber)?.doubleValue, 0.25, "the copy has the edits")
        XCTAssertEqual(((copied["effects"] as? [[String: Any]])?.first?["visible"]) as? Bool, false)
        XCTAssertEqual(ids(objects).firstIndex(of: copy), ids(objects).firstIndex(of: 11)! + 1,
                       "drawn just above the original and its children")
        try assertRoundTrips()
        session.undo()
        XCTAssertNil(session.outline.layer(copy))
    }

    func testDeleteRemovesTheLayerAndItsChildren() throws {
        session.setValue(.number(0.5), for: "alpha", of: 11, actionName: "Opacity")
        session.selection = 11
        session.delete([10], actionName: "Delete Layer")
        XCTAssertNil(session.outline.layer(10))
        XCTAssertNil(session.outline.layer(11), "its children go with it")
        XCTAssertNil(session.selection)
        XCTAssertEqual(session.overlay.removed, [10, 11])
        XCTAssertNil(session.overlay.objects["11"], "a deleted layer's edits go")
        XCTAssertEqual(ids(try applied()), [2, 13, 14], "an object without an id keeps its index as one")
        try assertRoundTrips()
        session.undo()
        XCTAssertNotNil(session.outline.layer(11))
        XCTAssertEqual(session.overlay.field("alpha", of: 11), .number(0.5))
    }

    /// A wallpaper in another process than the editor's reads the same base the session holds.
    func testTheBaseOutlineCanBeReadFromTheSceneAndOverlayAlone() throws {
        session.setValue(.number(0.5), for: "alpha", of: 11, actionName: "Opacity")
        session.delete([13], actionName: "Delete Layer")
        let base = try SceneEditSession.baseOutline(sceneData: Fixtures.sceneData, overlay: session.overlay)
        XCTAssertEqual(base.layers.map(\.id), session.baseOutline.layers.map(\.id))
        XCTAssertEqual(base.layer(11)?.fields["alpha"], session.baseOutline.layer(11)?.fields["alpha"],
                       "the base holds the structure, not the value edits")
    }

    func testDeletingAnAddedLayerLeavesNothing() {
        let id = session.addLayer(SceneLayerFactory.fullscreen(name: "FX"), actionName: "Add")
        session.delete([id], actionName: "Delete")
        XCTAssertNil(session.overlay.added)
        XCTAssertNil(session.overlay.removed)
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    // MARK: Naming and order

    func testRename() throws {
        session.rename(13, to: "  Brand  ", actionName: "Rename Layer")
        XCTAssertEqual(session.outline.layer(13)?.name, "Brand")
        XCTAssertEqual(try applied()[3]["name"] as? String, "Brand")
        session.rename(13, to: "Logo", actionName: "Rename Layer")
        XCTAssertFalse(session.isEdited(13), "its own name again")
    }

    func testReorderMovesTheLayerWithItsChildren() throws {
        session.move([13], relativeTo: 10, above: false, actionName: "Reorder Layers")
        XCTAssertEqual(session.outline.layers.map(\.id), [13, 10, 11, 2, 14])
        session.move([10], relativeTo: 14, above: true, actionName: "Reorder Layers")
        XCTAssertEqual(session.outline.layers.map(\.id), [13, 2, 14, 10, 11], "a group moves with its children")
        XCTAssertEqual(ids(try applied()), [13, 2, 14, 10, 11])
        try assertRoundTrips()
        session.step(13, by: 1, actionName: "Bring Forward")
        XCTAssertEqual(session.outline.layers.map(\.id), [2, 13, 14, 10, 11])
        session.undo(); session.undo(); session.undo()
        XCTAssertNil(session.overlay.order, "back to the scene's order")
    }

    func testAnOrderBackToTheScenesIsNoEdit() {
        session.move([13], relativeTo: 2, above: false, actionName: "Reorder")
        session.move([13], relativeTo: 2, above: true, actionName: "Reorder")
        XCTAssertNil(session.overlay.order)
    }

    func testOrderKeepsLayersTheWallpaperGainedSince() {
        let objects: [[String: Any]] = [["id": 1], ["id": 2], ["id": 9], ["id": 3]]
        let ordered = SceneEditOverlay.ordered(objects, by: [3, 2, 1])
        XCTAssertEqual(ordered.map { ($0["id"] as? Int) ?? -1 }, [3, 2, 9, 1], "9 stays after 2, which it followed")
    }

    /// An object without an `id` is known by its index, in the order as everywhere else.
    func testAnObjectWithoutAnIDIsOrderedByItsIndex() {
        let objects: [[String: Any]] = [["id": 3], ["name": "unnamed"], ["id": 2]]
        XCTAssertEqual(SceneObjects.objectID(objects[0], index: 0), 3)
        XCTAssertEqual(SceneObjects.objectID(objects[1], index: 1), 1)
        let ordered = SceneEditOverlay.ordered(objects, by: [2, 1, 3])
        XCTAssertEqual(ordered.map { ($0["id"] as? Int) ?? -1 }, [2, -1, 3], "the object at index 1 is placed as id 1")
    }

    // MARK: Parents

    func testUnparentKeepsTheLayerWhereItIs() throws {
        let before = session.worldTransform(of: 11).apply(.zero)
        session.setParent([11], to: nil, actionName: "Move Out of Group")
        XCTAssertNil(session.outline.layer(11)?.parentID)
        XCTAssertEqual(session.worldTransform(of: 11).apply(.zero), before)
        XCTAssertEqual(session.transform(of: 11).origin, SIMD3(1060, 590, 0))
        let clock = try XCTUnwrap(try applied().first { ($0["id"] as? NSNumber)?.intValue == 11 })
        XCTAssertNil(clock["parent"], "the field is taken out")
        try assertRoundTrips()
        session.undo()
        XCTAssertEqual(session.outline.layer(11)?.parentID, 10)
    }

    func testParentKeepsTheLayerWhereItIsUnderARotatedScaledParent() throws {
        session.setTransform(LayerTransform(origin: SIMD3(960, 540, 0), scale: SIMD3(2, 2, 1), angles: SIMD3(0, 0, .pi / 2)),
                             of: 10, actionName: "Transform")
        let world = session.worldTransform(of: 13)
        session.setParent([13], to: 10, actionName: "Move Into Group")
        XCTAssertEqual(session.outline.layer(13)?.parentID, 10)
        let after = session.worldTransform(of: 13)
        for (a, b) in [(after.tx, world.tx), (after.ty, world.ty), (after.a, world.a), (after.d, world.d)] {
            XCTAssertEqual(a, b, accuracy: 1e-6)
        }
        XCTAssertEqual(session.transform(of: 13).scale.x, 0.5, accuracy: 1e-9)
    }

    func testALayerCantGoUnderItself() {
        XCTAssertFalse(session.canParent(10, to: 11), "11 is under 10")
        XCTAssertFalse(session.canParent(10, to: 10))
        XCTAssertTrue(session.canParent(13, to: 10))
        session.setParent([10], to: 11, actionName: "Parent")
        XCTAssertFalse(session.canUndo)
    }

    func testGroupAndUngroup() throws {
        let worlds = [13, 14].map { session.worldTransform(of: $0).apply(.zero) }
        let group = try XCTUnwrap(session.group([13, 14], name: "Group", actionName: "Group Layers"))
        XCTAssertEqual(session.outline.children(of: group).map(\.id).sorted(), [13, 14])
        XCTAssertEqual(session.outline.layer(group)?.kind, .group)
        XCTAssertEqual(session.transform(of: group).origin.x, (1700 + 300) / 2, "at the layers' centre")
        XCTAssertEqual([13, 14].map { session.worldTransform(of: $0).apply(.zero) }, worlds)
        XCTAssertNotNil(session.overlay.field("origin", of: 14), "a driven origin gets a new start")
        try assertRoundTrips()
        XCTAssertEqual(session.undoManager.undoActionName, "Group Layers")
        session.ungroup(group, actionName: "Ungroup")
        XCTAssertNil(session.outline.layer(group), "an empty group goes")
        XCTAssertNil(session.outline.layer(13)?.parentID)
        XCTAssertEqual(session.transform(of: 13).origin, SIMD3(1700, 900, 0))
        XCTAssertFalse(session.overlay.hasSceneEdits, "grouping and ungrouping leave the scene as it was")
    }

    func testDecomposeIsTheInverseOfComposing() {
        let transform = SceneTransform2D.layer(translation: SIMD2(3, 4), rotation: 0.7, scale: SIMD2(2, -0.5))
        let parts = SceneEditSession.decompose(transform)
        XCTAssertEqual(parts.translation, SIMD2(3, 4))
        XCTAssertEqual(parts.rotation, 0.7, accuracy: 1e-12)
        XCTAssertEqual(parts.scale.x, 2, accuracy: 1e-12)
        XCTAssertEqual(parts.scale.y, -0.5, accuracy: 1e-12)
    }

    // MARK: Compatibility

    func testAVersionOneFileStillReadsAndSimpleEditsStayVersionOne() throws {
        let v1 = Data(#"{"version": 1, "objects": {"10": {"fields": {"alpha": 0.5}, "effects": {}}}}"#.utf8)
        let overlay = try SceneEditOverlay.decoded(from: v1)
        XCTAssertEqual(overlay.field("alpha", of: 10), .number(0.5))
        XCTAssertTrue(String(decoding: try overlay.encoded(), as: UTF8.self).contains("\"version\" : 1"),
                      "an older app still reads edits it knows")
    }
}
