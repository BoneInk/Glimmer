import XCTest
import OWEControlProtocol
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The scene requests through the router, against the fixture scene and fake editors: every
/// tool group, the edit kinds of each area, and what is refused.
@MainActor
final class MCPSceneRouterTests: XCTestCase {
    private var fixture: MCPSceneFixture!
    private var editors: FakeSceneEditorControl!
    private var service: HeadlessSceneEditService!
    private var router: ControlRequestRouter!
    private var announced: [(URL, String)] = []

    override func setUp() async throws {
        fixture = try MCPSceneFixture()
        editors = FakeSceneEditorControl()
        announced = []
        service = fixture.service(announce: { [weak self] folder, name, _ in self?.announced.append((folder, name)) })
        let group = SceneControlRequests(service: service, editors: editors)
        router = ControlRequestRouter(model: MCPSceneAppModel([fixture.wallpaper]), groups: [group])
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: 3, method: method, params: params))
    }

    private func result(_ method: String, _ params: [String: JSONValue] = [:],
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let response = await call(method, params)
        XCTAssertNil(response.error, "\(method): \(response.error?.message ?? "")", file: file, line: line)
        return try XCTUnwrap(response.result, file: file, line: line)
    }

    private func error(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlError? {
        await call(method, params).error
    }

    private func apply(_ edits: [JSONValue], file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        try await result("scene_apply_edits", ["wallpaper_id": "fixture", "edits": .array(edits)], file: file, line: line)
    }

    /// The draft the client edits.
    private func overlay() throws -> SceneEditOverlay {
        try fixture.draftStore.overlay(for: fixture.identity.rawValue)
    }

    /// The wallpaper's saved overlay, which the displays run.
    private func savedOverlay() throws -> SceneEditOverlay {
        try fixture.draftStore.savedOverlay(for: fixture.identity.rawValue)
    }

    // MARK: Coverage

    func testEveryEditKindTheToolOffersIsAnswered() {
        let offered = Set(ControlSceneEdits.operations.map(\.name))
        XCTAssertEqual(Set(SceneEditOperations.all.keys), offered)
        XCTAssertEqual(offered.count, ControlSceneEdits.operations.count, "no edit kind listed twice")
    }

    // MARK: Reading

    func testSceneGetListsLayersEffectsAndProperties() async throws {
        let scene = try await result("scene_get", ["wallpaper_id": "fixture"])
        let layers = try XCTUnwrap(scene["layers"]?.arrayValue)
        XCTAssertEqual(layers.map { $0["id"] }, [4, 5, 6])
        XCTAssertEqual(layers.map { $0["kind"] }, ["image", "text", "particle"])
        XCTAssertEqual(layers[0]["fields"]?["origin"], "100 100 0")
        XCTAssertEqual(layers[0]["effects"]?[0]?["key"], "0")
        XCTAssertEqual(layers[0]["effects"]?.arrayValue?.first?["constants"]?["strength"], 2)
        XCTAssertEqual(layers[0]["puppet"], "none")
        XCTAssertEqual(layers[1]["text"], "Hello")
        XCTAssertEqual(layers[2]["particle"], "particles/test.json")
        XCTAssertEqual(scene["size"]?["width"], 1920)
        XCTAssertEqual(scene["user_properties"]?.arrayValue?.first?["key"], "speed")
        XCTAssertEqual(scene["undo"]?["can_undo"], false)
    }

    func testOnlySceneWallpapersAndKnownOnes() async {
        let missing = await error("scene_get", ["wallpaper_id": "nope"])
        XCTAssertEqual(missing?.code, .notFound)
        let video = ControlWallpaper(id: "clip", title: "Clip", type: "video", tags: [], folder: URL(fileURLWithPath: "/library/clip"),
                                     workshopID: nil, description: nil, contentRating: nil)
        router = ControlRequestRouter(model: MCPSceneAppModel([fixture.wallpaper, video]),
                                      groups: [SceneControlRequests(service: service, editors: editors)])
        let refused = await error("scene_get", ["wallpaper_id": "clip"])
        XCTAssertEqual(refused?.code, .unsupported)
    }

    // MARK: Layers

    func testLayerEditsAreOneUndoStepAndAnnounced() async throws {
        let applied = try await apply([
            ["op": "set_origin", "layer": 4, "value": "10 20 0"],
            ["op": "set_alpha", "layer": 4, "alpha": 0.5],
            ["op": "set_visible", "layer": 6, "visible": false],
            ["op": "set_text", "layer": 5, "text": "Bonjour"],
            ["op": "add_layer", "kind": "solid", "name": "Fill", "color": "1 0 0", "width": 100, "height": 50],
        ])
        let results = try XCTUnwrap(applied["results"]?.arrayValue)
        let added = try XCTUnwrap(results.last?["layer"]?.intValue)
        let stored = try overlay()
        XCTAssertEqual(stored.field("origin", of: 4), .string("10 20 0"))
        XCTAssertEqual(stored.field("alpha", of: 4), .number(0.5))
        XCTAssertEqual(stored.field("visible", of: 6), .bool(false))
        XCTAssertEqual(stored.addedObject(added)?.object["name"], .string("Fill"))
        XCTAssertEqual(applied["undo"]?["can_undo"], true)
        XCTAssertEqual(announced.count, 1, "one save for the whole list")
        XCTAssertEqual(announced.first?.1, HeadlessSceneDocument.defaultActionName)

        let undone = try await result("scene_undo", ["wallpaper_id": "fixture"])
        XCTAssertEqual(undone["done"], true)
        XCTAssertTrue(try overlay().isEmpty, "one undo takes the whole list back")
        let redone = try await result("scene_redo", ["wallpaper_id": "fixture"])
        XCTAssertEqual(redone["done"], true)
        XCTAssertEqual(try overlay().field("alpha", of: 4), .number(0.5))
    }

    func testAListThatFailsChangesNothing() async throws {
        let response = await call("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [
            ["op": "set_alpha", "layer": 4, "alpha": 0.25],
            ["op": "set_alpha", "layer": 99, "alpha": 0.5],
        ]])
        let failure = try XCTUnwrap(response.error)
        XCTAssertEqual(failure.code, .notFound)
        XCTAssertTrue(failure.message.contains("edits[1] (set_alpha)"), failure.message)
        XCTAssertTrue(failure.message.contains("Nothing was changed"), failure.message)
        XCTAssertTrue(try overlay().isEmpty)
        XCTAssertTrue(announced.isEmpty)

        let unknown = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [["op": "explode"]]])
        XCTAssertTrue(unknown?.message.contains("set_origin") ?? false, "lists the edits there are")
    }

    func testStructureEdits() async throws {
        let grouped = try await apply([["op": "group_layers", "layers": [4, 5], "name": "Both"]])
        let group = try XCTUnwrap(grouped["results"]?[0]?["layer"]?.intValue)
        let scene = try await result("scene_get", ["wallpaper_id": "fixture"])
        let layers = scene["layers"]?.arrayValue ?? []
        XCTAssertEqual(layers.first { $0["id"]?.intValue == 4 }?["parent"]?.intValue, group)
        _ = try await apply([["op": "duplicate_layers", "layers": [5]], ["op": "step_layer", "layer": 6, "position": "bottom"]])
        let order = try await result("scene_get", ["wallpaper_id": "fixture"])["layers"]?.arrayValue?.map { $0["id"]?.intValue }
        XCTAssertEqual(order?.first, 6, "sent to the back")
        _ = try await apply([["op": "remove_layers", "layers": [6]]])
        XCTAssertEqual(try overlay().removed, [6])
        let cycle = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [["op": "set_parent", "layers": .array([.number(Double(group))]), "parent": 4]]])
        XCTAssertEqual(cycle?.code, .refused)
    }

    // MARK: Effects

    func testEffectEditsCheckTheEffectsParameters() async throws {
        let added = try await apply([["op": "add_effect", "layer": 4, "effect": "effects/shake/effect.json"]])
        XCTAssertEqual(added["results"]?[0]?["effect"], "+1")
        _ = try await apply([
            ["op": "set_effect_constant", "layer": 4, "effect": "0", "constant": "Strength", "value": "5"],
            ["op": "set_effect_combo", "layer": 4, "effect": "0", "combo": "mode", "value": "1"],
            ["op": "set_effect_texture", "layer": 4, "effect": "0", "slot": 1, "texture": "masks/edge"],
            ["op": "set_effect_visible", "layer": 4, "effect": "+1", "visible": false],
        ])
        let edit = try XCTUnwrap(try overlay().effectEdit("0", of: 4))
        XCTAssertEqual(edit.constants["strength"], .number(5))
        XCTAssertEqual(edit.combos?["MODE"], 1)
        XCTAssertEqual(edit.textures?["1"], .string("masks/edge"))
        XCTAssertEqual(edit.combos?["MASK"], 1, "a mask slot switches its combo on, as WE does")
        let bad = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [
            ["op": "set_effect_combo", "layer": 4, "effect": "0", "combo": "MODE", "value": "7"],
        ]])
        XCTAssertTrue(bad?.message.contains("0 (Soft)") ?? false, bad?.message ?? "")
        let missing = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [
            ["op": "add_effect", "layer": 4, "effect": "effects/nothing/effect.json"],
        ]])
        XCTAssertEqual(missing?.code, .notFound)
        _ = try await apply([["op": "move_effect", "layer": 4, "effect": "+1", "index": 0], ["op": "remove_effect", "layer": 4, "effect": "0"]])
        XCTAssertEqual(try overlay().objects["4"]?.effectOrder, ["+1"])
    }

    // MARK: Particles

    func testParticleEditsUseTheParticleEditorsSchema() async throws {
        let system = try await result("particles_get", ["wallpaper_id": "fixture", "layer": 6])
        XCTAssertEqual(system["definition"], "particles/test.json")
        XCTAssertEqual(system["sections"]?["emitter"]?[0]?["rate"], 10)
        _ = try await apply([
            ["op": "set_particle_field", "layer": 6, "section": "emitter", "index": 0, "field": "rate", "value": "25"],
            ["op": "set_particle_field", "layer": 6, "section": "system", "field": "maxcount", "value": "500"],
            ["op": "set_particle_override", "layer": 6, "key": "count", "value": "2"],
        ])
        let stored = try overlay()
        let document = try XCTUnwrap(stored.particles?.assets["particles/test.json"])
        XCTAssertEqual(document["emitter"]?.arrayValueForTest?.first?["rate"], .number(25))
        XCTAssertEqual(document["maxcount"], .number(500))
        XCTAssertEqual(stored.field("instanceoverride", of: 6)?["count"], .number(2))
        let wrongField = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [
            ["op": "set_particle_field", "layer": 6, "section": "emitter", "index": 0, "field": "nonsense", "value": "1"],
        ]])
        XCTAssertEqual(wrongField?.code, .notFound)
        let onDisplays = try await result("particles_restart", ["wallpaper_id": "fixture", "layer": 6])
        XCTAssertEqual(onDisplays["in_editor"], false, "without an editor window, the displays restart it")
        editors.editorWindowOpen = true
        let inEditor = try await result("particles_restart", ["wallpaper_id": "fixture", "layer": 6])
        XCTAssertEqual(inEditor["in_editor"], true, "an open editor window's canvas restarts it")
        XCTAssertEqual(editors.restarted, [6, 6])
    }

    // MARK: Puppets

    func testPuppetEditsBuildARig() async throws {
        let noRig = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [["op": "puppet_add_bone", "layer": 4, "x": 0, "y": 0]]])
        XCTAssertEqual(noRig?.code, .unsupported)
        _ = try await apply([
            ["op": "puppet_create", "layer": 4],
            ["op": "puppet_add_bone", "layer": 4, "x": 0, "y": 30, "parent": 0, "name": "Arm"],
            ["op": "puppet_add_animation", "layer": 4, "name": "Wave", "frames": 30],
            ["op": "puppet_set_key", "layer": 4, "animation": 0, "bone": 1, "frame": 15, "angle": 45],
            ["op": "puppet_update_animation_layer", "layer": 4, "animation_layer": 0, "blend": 0.5],
        ])
        let rigs = try await result("puppets_list", ["wallpaper_id": "fixture"])
        let rig = try XCTUnwrap(rigs["puppets"]?.arrayValue?.first)
        XCTAssertEqual(rig["bones"]?.arrayValue?.count, 2)
        XCTAssertEqual(rig["bones"]?[1]?["name"], "Arm")
        XCTAssertEqual(rig["animations"]?[0]?["keys_by_bone"]?["1"], [15])
        XCTAssertEqual(rig["animation_layers"]?[0]?["blend"], 0.5)
        XCTAssertNotNil(try overlay().puppet(of: 4))
    }

    // MARK: Timeline

    func testTimelineEdits() async throws {
        _ = try await apply([
            ["op": "timeline_add_keyframe", "layer": 4, "field": "alpha", "frame": 0, "value": "1"],
            ["op": "timeline_add_keyframe", "layer": 4, "field": "alpha", "frame": 30, "value": "0"],
            ["op": "timeline_set_ease", "layer": 4, "field": "alpha", "frame": 30, "ease": "hold"],
            ["op": "timeline_move_keyframe", "layer": 4, "field": "alpha", "frame": 30, "to_frame": 60],
        ])
        let timelines = try await result("timeline_get", ["wallpaper_id": "fixture", "layer": 4])
        let track = try XCTUnwrap(timelines["layers"]?[0]?["tracks"]?[0])
        XCTAssertEqual(track["key"], "alpha")
        XCTAssertEqual(track["channels"]?[0]?.arrayValue?.map { $0["frame"] }, [0, 60])
        XCTAssertEqual(track["channels"]?[0]?[1]?["hold"], true)
        _ = try await apply([["op": "timeline_remove_track", "layer": 4, "field": "alpha"]])
        XCTAssertTrue(try overlay().timelines?.isEmpty ?? true)
        let notAnimatable = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [
            ["op": "timeline_add_keyframe", "layer": 4, "field": "name", "frame": 0],
        ]])
        XCTAssertEqual(notAnimatable?.code, .notFound)

        _ = try await result("timeline_preview", ["wallpaper_id": "fixture", "command": "seek", "seconds": 2])
        XCTAssertEqual(editors.timelineCommands.first?.1, "seek")
        editors.editorRunning = false
        let notRunning = await error("timeline_preview", ["wallpaper_id": "fixture", "command": "play"])
        XCTAssertEqual(notRunning?.code, .unavailable)
    }

    // MARK: Scripts and user properties

    func testScriptsAreCheckedBeforeTheyApply() async throws {
        let broken = await error("script_set", ["wallpaper_id": "fixture", "layer": 4, "field": "alpha", "script": "export function update( {"])
        XCTAssertEqual(broken?.code, .invalidParams)
        XCTAssertTrue(broken?.message.contains("line") ?? false, broken?.message ?? "")
        XCTAssertTrue(try overlay().isEmpty)

        let check = try await result("script_check", ["script": "export function update(value) { return value; }"])
        XCTAssertEqual(check["valid"], true)
        _ = try await result("script_set", ["wallpaper_id": "fixture", "layer": 4, "field": "alpha",
                                            "script": "export function update(value) { return value * 0.5; }"])
        let script = try await result("script_get", ["wallpaper_id": "fixture", "layer": 4, "field": "alpha"])
        XCTAssertEqual(script["script"], "export function update(value) { return value * 0.5; }")
        XCTAssertEqual(script["scripted_fields"], ["alpha"])
        _ = try await apply([["op": "remove_script", "layer": 4, "field": "alpha"]])
        let removed = try await result("script_get", ["wallpaper_id": "fixture", "layer": 4, "field": "alpha"])
        XCTAssertEqual(removed["script"], .null)
    }

    func testUserPropertiesAreDefinedAndBound() async throws {
        let added = try await apply([
            ["op": "add_user_property", "property_kind": "bool", "label": "Show rain", "key": "rain", "value": "true"],
            ["op": "bind_field", "layer": 6, "field": "visible", "property": "rain"],
            ["op": "update_user_property", "key": "speed", "max": 5],
        ])
        XCTAssertEqual(added["results"]?[0]?["key"], "rain")
        let properties = try await result("user_properties_get", ["wallpaper_id": "fixture"])
        let keys = properties["user_properties"]?.arrayValue?.map { $0["key"] }
        XCTAssertEqual(keys, ["speed", "rain"])
        XCTAssertEqual(properties["user_properties"]?[0]?["max"], 5)
        XCTAssertEqual(properties["bound_fields"]?["rain"]?[0]?["layer"], 6)
        let refused = await error("scene_apply_edits", ["wallpaper_id": "fixture", "edits": [["op": "set_visible", "layer": 6, "visible": true]]])
        XCTAssertEqual(refused?.code, .refused, "a bound field is the user property's")
        _ = try await apply([["op": "unbind_field", "layer": 6, "field": "visible"], ["op": "rename_user_property", "key": "rain", "new_key": "showRain"]])
        let renamed = try await result("user_properties_get", ["wallpaper_id": "fixture"])
        XCTAssertEqual(renamed["user_properties"]?[1]?["key"], "showRain")
    }

    // MARK: Saving and editors

    func testEditsStayInTheDraftUntilTheSaveTool() async throws {
        _ = try await apply([["op": "set_alpha", "layer": 4, "alpha": 0.5]])
        XCTAssertTrue(try savedOverlay().isEmpty, "the displays' overlay is untouched by an edit")
        let before = try await result("scene_get", ["wallpaper_id": "fixture"])
        XCTAssertEqual(before["unsaved"], true)
        let saved = try await result("wallpaper_editor_save", ["wallpaper_id": "fixture"])
        XCTAssertEqual(saved["saved"], true)
        XCTAssertEqual(saved["unsaved"], false)
        XCTAssertEqual(try savedOverlay().field("alpha", of: 4), .number(0.5))
        XCTAssertFalse(fixture.draftStore.hasDraft(for: fixture.identity.rawValue))
        let again = try await result("wallpaper_editor_save", ["wallpaper_id": "fixture"])
        XCTAssertEqual(again["saved"], false, "nothing left to save")
    }

    func testTheOlderSaveToolsStillWork() async throws {
        _ = try await apply([["op": "set_alpha", "layer": 4, "alpha": 0.5]])
        let saved = try await result("scene_save", ["wallpaper_id": "fixture"])
        XCTAssertEqual(saved["saved"], true, "scene_save saves the draft, as wallpaper_editor_save does")
        XCTAssertEqual(try savedOverlay().field("alpha", of: 4), .number(0.5))
        let copy = try await result("scene_save_as_local_wallpaper", ["wallpaper_id": "fixture", "title": "Old Name"])
        XCTAssertEqual(copy["title"], "Old Name")
        XCTAssertEqual(editors.savedCopies, ["Old Name"], "as wallpaper_editor_save_as_new does")
    }

    func testRevertToSavedAndSaveAsNew() async throws {
        _ = try await apply([["op": "set_alpha", "layer": 4, "alpha": 0.5]])
        _ = try await result("wallpaper_editor_save", ["wallpaper_id": "fixture"])
        _ = try await apply([["op": "set_alpha", "layer": 4, "alpha": 0.25]])
        let reverted = try await result("scene_revert", ["wallpaper_id": "fixture"])
        XCTAssertEqual(reverted["reverted"], true)
        XCTAssertEqual(try overlay().field("alpha", of: 4), .number(0.5), "back to the last save, not the original")
        _ = try await result("scene_undo", ["wallpaper_id": "fixture"])
        XCTAssertEqual(try overlay().field("alpha", of: 4), .number(0.25), "Revert to Saved is undoable")
        let copy = try await result("wallpaper_editor_save_as_new", ["wallpaper_id": "fixture", "title": "Mine"])
        XCTAssertEqual(copy["title"], "Mine")
        XCTAssertEqual(editors.savedCopies, ["Mine"])
        XCTAssertEqual(try savedOverlay().field("alpha", of: 4), .number(0.5), "Save as New leaves the wallpaper as saved")
        XCTAssertEqual(try overlay().field("alpha", of: 4), .number(0.25), "and its draft as it was")
    }

    func testEditorWindows() async throws {
        let tab = try await result("editor_set_tab", ["wallpaper_id": "fixture", "tab": "screen_saver"])
        XCTAssertEqual(tab["tab"], "screen_saver")
        XCTAssertEqual(editors.shown.first?.1, .screenSaver)
        let badTab = await error("editor_set_tab", ["wallpaper_id": "fixture", "tab": "nope"])
        XCTAssertEqual(badTab?.code, .invalidParams)
        let closed = try await result("editor_close", ["editor": "scene"])
        XCTAssertEqual(closed["closed"], true)
        _ = try await result("editor_close", ["editor": "wallpaper", "wallpaper_id": "fixture"])
        XCTAssertEqual(editors.closedWallpaperEditors, ["fixture"])
    }

    func testDepthMapsNeedThePlugin() async {
        let refused = await error("depth_generate", ["wallpaper_id": "fixture", "layer": 4])
        XCTAssertEqual(refused?.code, .unavailable)
        XCTAssertTrue(refused?.message.contains("Settings › Plugins") ?? false)
        let mask = await error("use_depth_map_as_mask", ["wallpaper_id": "fixture", "layer": 4, "effect": "0"])
        XCTAssertEqual(mask?.code, .unavailable)
        let noLayer = await error("use_depth_map_as_mask", ["wallpaper_id": "fixture", "effect": "0"])
        XCTAssertEqual(noLayer?.code, .invalidParams)
    }

    // MARK: Someone else's edits

    func testAnEditSavedElsewhereStartsAFreshHistory() async throws {
        _ = try await apply([["op": "set_alpha", "layer": 4, "alpha": 0.5]])
        var theirs = try overlay()
        theirs.setField("alpha", to: .number(0.75), of: 4)
        try fixture.draftStore.saveDraft(theirs, for: fixture.identity.rawValue)
        let scene = try await result("scene_get", ["wallpaper_id": "fixture"])
        XCTAssertEqual(scene["layers"]?[0]?["fields"]?["alpha"], 0.75, "the editor window's edit is read")
        XCTAssertEqual(scene["undo"]?["can_undo"], false, "and the client can't undo over it")
    }
}

private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let items = arrayValue, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

private extension SceneJSONValue {
    var arrayValueForTest: [SceneJSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}
