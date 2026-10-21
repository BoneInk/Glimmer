import XCTest
@testable import OWESceneEditing

/// Switching off a layer whose `visible` a user property sets: an override in the overlay that
/// hides it whatever the property says, undone by showing it again; the binding itself stays.
@MainActor
final class BoundVisibilityTests: XCTestCase {
    /// A group a combo shows on its first option, hidden as authored (`value: false`), with a child
    /// bound the same way, and a group shown as authored.
    private static let sceneData = Data("""
    {
      "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
      "objects": [
        {"id": 1, "name": "Clock Layer 1", "image": "models/a.json", "size": "100 100", "origin": "100 100 0",
         "visible": {"user": {"name": "clocklocation", "condition": "1"}, "value": true}},
        {"id": 2, "name": "Clock Layer 2", "image": "models/a.json", "size": "100 100", "origin": "300 300 0",
         "visible": {"user": {"name": "clocklocation", "condition": "2"}, "value": false}},
        {"id": 3, "name": "Date", "parent": 2, "image": "models/a.json", "size": "10 10",
         "visible": {"user": {"name": "clocklocation", "condition": "2"}, "value": false}}
      ]
    }
    """.utf8)

    private var session: SceneEditSession!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Self.sceneData), undoManager: undoManager)
    }

    private func appliedVisible(_ id: Int, _ overlay: SceneEditOverlay) throws -> Any? {
        try Fixtures.object(id, in: try overlay.applied(to: Self.sceneData))["visible"]
    }

    func testHidingABoundLayerOverridesItsProperty() throws {
        XCTAssertEqual(session.visibilityProperty(of: 1), "clocklocation")
        XCTAssertFalse(session.isHiddenOverProperty(1))
        session.setVisible(false, 1, actionName: "Hide Layer")

        XCTAssertTrue(session.isHiddenOverProperty(1))
        XCTAssertFalse(session.isVisible(1))
        XCTAssertTrue(session.isEdited(1))
        XCTAssertEqual(session.binding("visible", of: 1), .userProperty("clocklocation"), "the binding stays")
        XCTAssertEqual(session.overlay.field("visible", of: 1), .bool(false))
        // The scene the renderer and Save as New Wallpaper read: a plain false, which no
        // property value shows.
        let visible = try appliedVisible(1, session.overlay)
        XCTAssertEqual(visible as? Bool, false)
        XCTAssertFalse(visible is [String: Any])
    }

    func testHidingALayerTheScenePutsAsHiddenIsStillAnOverride() throws {
        // Its authored `value` is false, but the property shows it on option 2.
        session.setVisible(false, 2, actionName: "Hide Layer")
        XCTAssertTrue(session.isHiddenOverProperty(2))
        XCTAssertEqual(try appliedVisible(2, session.overlay) as? Bool, false)
        XCTAssertTrue(session.isHiddenByParent(3), "hiding a group hides what's in it")
    }

    func testShowingItAgainHandsItBackToTheProperty() throws {
        session.setVisible(false, 1, actionName: "Hide Layer")
        session.setVisible(true, 1, actionName: "Show Layer")

        XCTAssertFalse(session.isHiddenOverProperty(1))
        XCTAssertFalse(session.isEdited(1))
        XCTAssertFalse(session.overlay.hasSceneEdits)
        let visible = try XCTUnwrap(try appliedVisible(1, session.overlay) as? [String: Any])
        XCTAssertEqual((visible["user"] as? [String: Any])?["name"] as? String, "clocklocation", "the property sets it again")
        XCTAssertEqual(visible["value"] as? Bool, true)
    }

    func testTheOverrideIsUndoneRedoneAndReverted() {
        session.setVisible(false, 1, actionName: "Hide Layer")
        XCTAssertEqual(session.undoManager.undoActionName, "Hide Layer")
        session.undo()
        XCTAssertFalse(session.isHiddenOverProperty(1))
        XCTAssertEqual(session.overlay, SceneEditOverlay())
        session.redo()
        XCTAssertTrue(session.isHiddenOverProperty(1))
        session.revert(to: SceneEditOverlay(), actionName: "Revert to Saved")
        XCTAssertFalse(session.isHiddenOverProperty(1))
        XCTAssertEqual(session.binding("visible", of: 1), .userProperty("clocklocation"))
    }

    func testAnUnboundHiddenEditOfABoundFieldIsItsFallbackNoMore() throws {
        // A plain false over a bound `visible` always means hidden, as the editor shows it.
        var overlay = SceneEditOverlay()
        overlay.setField("visible", to: .bool(false), of: 1)
        XCTAssertEqual(try appliedVisible(1, overlay) as? Bool, false)
        // Any other value edit of a bound field is still its fallback `value`.
        overlay.setField("visible", to: .bool(true), of: 2)
        let shown = try XCTUnwrap(try appliedVisible(2, overlay) as? [String: Any])
        XCTAssertEqual(shown["value"] as? Bool, true)
        XCTAssertNotNil(shown["user"])
    }

    func testSaveAsLocalWallpaperWritesTheOverride() throws {
        let root = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "3299228616", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"title": "Clocks", "type": "scene", "file": "scene.json"}"#.utf8)
            .write(to: source.appending(path: "project.json"))
        try Self.sceneData.write(to: source.appending(path: "scene.json"))
        session.setVisible(false, 1, actionName: "Hide Layer")

        let folder = try LocalWallpaperWriter().save(.init(directory: source, sceneFile: "scene.json"),
                                                     scene: try session.overlay.applied(to: Self.sceneData),
                                                     title: "Clocks (Edited)", into: root.appending(path: "Library"))
        let written = try Data(contentsOf: folder.appending(path: "scene.json"))
        XCTAssertEqual(try Fixtures.object(1, in: written)["visible"] as? Bool, false)
        XCTAssertNotNil(try Fixtures.object(2, in: written)["visible"] as? [String: Any], "untouched layers keep their binding")
    }
}
