import XCTest
@testable import OWESceneEditing

/// Scripts and user-property bindings attached in the editor: kept in the overlay, undoable, and
/// written into scene.json where the wallpaper loads (and into a saved local copy).
@MainActor
final class SceneFieldDriverTests: XCTestCase {
    private var session: SceneEditSession!
    private var saved: [SceneEditOverlay] = []

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        saved = []
        session.onChange = { [unowned self] in saved.append($0) }
    }

    private func applied() throws -> Data { try session.overlay.applied(to: Fixtures.sceneData) }

    // MARK: Bindings

    func testBindingAFieldWritesWEsUserBinding() throws {
        session.bind("alpha", of: 10, to: SceneUserBinding(name: "fade"), actionName: "Bind")
        XCTAssertEqual(session.binding("alpha", of: 10), .userProperty("fade"))
        XCTAssertFalse(session.isEditable("alpha", of: 10), "the property sets it now")
        let background = try Fixtures.object(10, in: applied())
        let alpha = try XCTUnwrap(background["alpha"] as? [String: Any])
        XCTAssertEqual(alpha["user"] as? String, "fade")
        XCTAssertEqual((alpha["value"] as? NSNumber)?.doubleValue, 1, "the authored value stays the fallback")
        XCTAssertEqual(saved.count, 1, "saved and applied once")

        session.undo()
        XCTAssertEqual(session.binding("alpha", of: 10), .literal)
        XCTAssertEqual((try Fixtures.object(10, in: applied())["alpha"] as? NSNumber)?.doubleValue, 1)
        session.redo()
        XCTAssertEqual(session.binding("alpha", of: 10), .userProperty("fade"))
    }

    func testBindingAFieldTheSceneDoesntHaveStartsFromItsValue() throws {
        session.setValue(.number(0.4), for: "alpha", of: 13, actionName: "Opacity")
        session.bind("alpha", of: 13, to: SceneUserBinding(name: "logoalpha"), actionName: "Bind")
        let alpha = try XCTUnwrap(try Fixtures.object(13, in: applied())["alpha"] as? [String: Any])
        XCTAssertEqual(alpha["user"] as? String, "logoalpha")
        XCTAssertEqual((alpha["value"] as? NSNumber)?.doubleValue, 0.4)
    }

    func testAFlagCanFollowACombosValue() throws {
        session.bind(.effect(0), of: 10, to: SceneUserBinding(name: "style", condition: "rain"), actionName: "Bind")
        let effects = try XCTUnwrap(try Fixtures.object(10, in: applied())["effects"] as? [[String: Any]])
        let visible = try XCTUnwrap(effects[0]["visible"] as? [String: Any])
        XCTAssertEqual(visible["user"] as? [String: String], ["name": "style", "condition": "rain"])
        XCTAssertEqual(visible["value"] as? Bool, true)
        XCTAssertEqual(session.effectBinding(session.outline.layer(10)!.effects[0], of: 10), .userProperty("style"))
        XCTAssertEqual(SceneUserBinding(json: .object(["name": .string("style"), "condition": .number(2)]))?.condition, "2")
    }

    func testUnbindingAnAuthoredBindingLeavesItsValue() throws {
        // The fixture's logo visibility is authored as `{"user": "showlogo", "value": true}`.
        session.unbind("visible", of: 13, actionName: "Unbind")
        XCTAssertEqual(session.binding("visible", of: 13), .literal)
        XCTAssertEqual(try Fixtures.object(13, in: applied())["visible"] as? Bool, true)
        XCTAssertTrue(session.isEditable("visible", of: 13))
        session.setVisible(false, 13, actionName: "Hide")
        XCTAssertEqual(try Fixtures.object(13, in: applied())["visible"] as? Bool, false)
    }

    func testRebindingKeepsAnAuthoredScript() throws {
        session.bind("text", of: 11, to: SceneUserBinding(name: "caption"), actionName: "Bind")
        let text = try XCTUnwrap(try Fixtures.object(11, in: applied())["text"] as? [String: Any])
        XCTAssertEqual(text["user"] as? String, "caption")
        XCTAssertNotNil(text["script"], "binding a scripted field keeps its script, as WE allows both")
        XCTAssertEqual(text["value"] as? String, "12:00")
    }

    // MARK: Scripts

    func testAttachingAScriptWritesItWithItsValue() throws {
        let source = "export function update(value) { return value + 0.1; }"
        session.attachScript(SceneScriptAttachment(source: source), to: "alpha", of: 10, actionName: "Add Script")
        XCTAssertEqual(session.drivers("alpha", of: 10).script?.source, source)
        XCTAssertEqual(session.binding("alpha", of: 10), .driven)
        XCTAssertEqual(session.scriptedFields(of: 10), ["alpha"])
        let alpha = try XCTUnwrap(try Fixtures.object(10, in: applied())["alpha"] as? [String: Any])
        XCTAssertEqual(alpha["script"] as? String, source)
        XCTAssertEqual((alpha["value"] as? NSNumber)?.doubleValue, 1)

        // An edit of the field's value after the script is its start value.
        session.setValue(.number(0.5), for: "alpha", of: 10, actionName: "Opacity")
        let edited = try XCTUnwrap(try Fixtures.object(10, in: applied())["alpha"] as? [String: Any])
        XCTAssertEqual(edited["script"] as? String, source)
        XCTAssertEqual((edited["value"] as? NSNumber)?.doubleValue, 0.5)
    }

    func testApplyReplacesTheScriptTheSceneRuns() throws {
        // "Apply" of a new version of the clock's authored script.
        let updated = "export function update(value) { return 'hot'; }"
        session.attachScript(SceneScriptAttachment(source: updated, scriptProperties: ["use24h": .bool(false)]),
                             to: "text", of: 11, actionName: "Edit Script")
        let text = try XCTUnwrap(try Fixtures.object(11, in: applied())["text"] as? [String: Any])
        XCTAssertEqual(text["script"] as? String, updated)
        XCTAssertEqual(text["scriptproperties"] as? [String: Bool], ["use24h": false])
        XCTAssertEqual(text["value"] as? String, "12:00")
        let before = session.overlay.digest
        session.attachScript(SceneScriptAttachment(source: updated + "\n"), to: "text", of: 11, actionName: "Edit Script")
        XCTAssertNotEqual(session.overlay.digest, before, "a new script is a new scene: the wallpaper reloads it")
        session.undo()
        XCTAssertEqual(session.overlay.digest, before)
    }

    func testRemovingScripts() throws {
        // An authored one: the field keeps its value as a plain value.
        session.removeScript("origin", of: 14, actionName: "Remove Script")
        XCTAssertEqual(try Fixtures.object(14, in: applied())["origin"] as? String, "300 300 0")
        XCTAssertTrue(session.scriptedFields(of: 14).isEmpty)
        // One added in the editor: nothing is left of it.
        session.attachScript(SceneScriptAttachment(source: "export function update(v) { return v; }"),
                             to: .objectScript, of: 10, actionName: "Add Script")
        session.removeScript(.objectScript, of: 10, actionName: "Remove Script")
        XCTAssertNil(session.overlay.authoring?.driverEdit(.objectScript, of: 10))
        XCTAssertNil(try Fixtures.object(10, in: applied())["visible"], "the scene had no visible; it still has none")
    }

    func testAnObjectScriptRunsOnVisibility() throws {
        session.attachScript(SceneScriptAttachment(source: "export function update(v) { return v; }"),
                             to: .objectScript, of: 2, actionName: "Add Script")
        let visible = try XCTUnwrap(try Fixtures.object(2, in: applied())["visible"] as? [String: Any])
        XCTAssertEqual(visible["value"] as? Bool, true, "WE's default, so the layer stays shown")
        XCTAssertNotNil(visible["script"])
    }

    func testScriptedFieldsAreInWEsRunOrder() {
        for field in ["text", "alpha", "visible"] {
            session.attachScript(SceneScriptAttachment(source: "export function update(v) { return v; }"),
                                 to: SceneFieldPath(field), of: 10, actionName: "Add Script")
        }
        session.attachScript(SceneScriptAttachment(source: "export function update(v) { return v; }"),
                             to: .effect(1), of: 10, actionName: "Add Script")
        XCTAssertEqual(session.scriptedFields(of: 10).map(\.description), ["visible", "alpha", "text", "effects.1.visible"])
    }

    // MARK: Overlay

    func testOverlaysWithAuthoringRoundTripAndOldOnesStillRead() throws {
        session.bind("alpha", of: 10, to: SceneUserBinding(name: "fade"), actionName: "Bind")
        session.attachScript(SceneScriptAttachment(source: "export function update(v) { return v; }"),
                             to: "origin", of: 13, actionName: "Add Script")
        let data = try session.overlay.encoded()
        XCTAssertEqual(try SceneEditOverlay.decoded(from: data), session.overlay)
        let old = Data(#"{"version": 1, "objects": {"10": {"fields": {"alpha": 0.5}, "effects": {}}}}"#.utf8)
        let decoded = try SceneEditOverlay.decoded(from: old)
        XCTAssertNil(decoded.authoring)
        XCTAssertEqual(decoded.field("alpha", of: 10), .number(0.5))
    }

    func testRevertDropsScriptsAndBindings() {
        session.bind("alpha", of: 10, to: SceneUserBinding(name: "fade"), actionName: "Bind")
        session.revert(to: SceneEditOverlay(), actionName: "Revert to Saved")
        XCTAssertNil(session.overlay.authoring)
        XCTAssertTrue(session.overlay.isEmpty)
        session.undo()
        XCTAssertEqual(session.binding("alpha", of: 10), .userProperty("fade"))
    }

    func testAnEffectTheSceneNoLongerHasIsSkipped() throws {
        var overlay = SceneEditOverlay()
        var authoring = SceneAuthoring()
        authoring.setDriverEdit(SceneFieldDriverEdit(user: SceneUserBinding(name: "x")), .effect(9), of: 10)
        authoring.setDriverEdit(SceneFieldDriverEdit(user: SceneUserBinding(name: "x")), "alpha", of: 99)
        overlay.authoring = authoring
        let scene = try overlay.applied(to: Fixtures.sceneData)
        let effects = try XCTUnwrap(try Fixtures.object(10, in: scene)["effects"] as? [[String: Any]])
        XCTAssertEqual(effects.count, 2)
    }

    // MARK: Field paths

    func testFieldPathsReadAndWriteNestedFields() {
        var object: [String: Any] = ["alpha": 1, "effects": [["visible": true], ["visible": false]]]
        XCTAssertEqual(SceneFieldPath.effect(1).value(in: object) as? Bool, false)
        SceneFieldPath.effect(1).set(["user": "x"], in: &object)
        XCTAssertEqual((SceneFieldPath("effects.1.visible").value(in: object) as? [String: String])?["user"], "x")
        SceneFieldPath.effect(5).set(true, in: &object)
        XCTAssertEqual((object["effects"] as? [Any])?.count, 2, "a missing effect isn't created")
        SceneFieldPath("alpha").set(nil, in: &object)
        XCTAssertNil(object["alpha"])
        XCTAssertEqual(SceneFieldPath("effects.2.visible").effectIndex, 2)
        XCTAssertNil(SceneFieldPath("alpha").effectIndex)
    }

    func testDriverEditsCollapseToPlainValues() {
        var edit = SceneFieldDriverEdit()
        edit.unbind(authored: true)
        XCTAssertEqual(edit.applied(to: .object(["user": .string("x"), "value": .number(2)])), .number(2))
        edit = SceneFieldDriverEdit()
        edit.detachScript(authored: true)
        XCTAssertEqual(edit.applied(to: .object(["script": .string("s"), "scriptproperties": .object([:]),
                                                 "animation": .object([:]), "value": .number(2)])),
                       .object(["animation": .object([:]), "value": .number(2)]), "an animation still drives it")
    }
}
