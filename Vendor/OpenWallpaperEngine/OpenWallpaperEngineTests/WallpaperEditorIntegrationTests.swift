import XCTest
import OWEInspectorKit
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor in the app: its overlay applied where the scene loads, and Scene Edit /
/// Export left as it was (its edits, its keys, its pickers and its shortcut).
@MainActor
final class WallpaperEditorIntegrationTests: XCTestCase {
    private static let scene = Data("""
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 4, "image": "a.json", "origin": "0 0 0", "alpha": 1,
                  "effects": [{"file": "effects/blur/effect.json", "visible": true}]},
                 {"id": 5, "image": "b.json", "origin": "1 1 0"}]}
    """.utf8)

    private func object(_ id: Int, in data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [[String: Any]])
        return try XCTUnwrap(objects.first { ($0["id"] as? NSNumber)?.intValue == id })
    }

    // MARK: Loading

    func testTheLoaderAppliesTheOverlayUnderTheInspectorsEdits() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("100 100 0"), of: 4)
        overlay.setField("alpha", to: .number(0.5), of: 4)
        overlay.setEffectVisible(false, effect: 0, of: 4)
        overlay.setField("origin", to: .string("7 7 0"), of: 5)
        let resolved = try ScenePreparation.resolvedScene(Self.scene, edits: ["_owe_scene_object_5_origin": "9 9 0"],
                                                          overlay: overlay)
        let four = try object(4, in: resolved)
        XCTAssertEqual(four["origin"] as? String, "100 100 0")
        XCTAssertEqual((four["alpha"] as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual((four["effects"] as? [[String: Any]])?.first?["visible"] as? Bool, false)
        XCTAssertEqual(try object(5, in: resolved)["origin"] as? String, "9 9 0",
                       "the Inspector's edit is the user's own, on top of the edited scene")
        let decoded = try JSONDecoder().decode(WEScene.self, from: resolved)
        XCTAssertEqual(decoded.objects.first?.alpha, 0.5, "the scene model reads the edit")
    }

    /// Scene Edit / Export's JSON editor saves a whole object as scene.json authors it: the
    /// Wallpaper Editor's edits of that layer (an added effect, a field) apply over it, and the
    /// replacement keeps the object's id when it names none.
    func testTheOverlayAppliesOverAnObjectSceneEditExportReplaced() throws {
        let overlay = try JSONDecoder().decode(SceneEditOverlay.self, from: Data("""
        {"version": 2, "objects": {"4": {"fields": {"alpha": 0.5}, "effects": {},
          "addedEffects": {"+1": {"file": "effects/tint/effect.json", "visible": true}}}}}
        """.utf8))
        let replacement = #"{"image": "a.json", "origin": "3 3 0", "effects": [{"file": "effects/blur/effect.json", "visible": false}]}"#
        let resolved = try ScenePreparation.resolvedScene(Self.scene, edits: ["_owe_scene_object_4_json": replacement,
                                                                              "_owe_scene_object_4_scale": "2 2 1"],
                                                          overlay: overlay)
        let four = try object(4, in: resolved)
        let effects = four["effects"] as? [[String: Any]]
        XCTAssertEqual(effects?.compactMap { $0["file"] as? String }, ["effects/blur/effect.json", "effects/tint/effect.json"],
                       "the added effect over the replaced object's")
        XCTAssertEqual(effects?.first?["visible"] as? Bool, false, "the replacement's own value")
        XCTAssertEqual((four["alpha"] as? NSNumber)?.doubleValue, 0.5, "the overlay's field")
        XCTAssertEqual(four["origin"] as? String, "3 3 0")
        XCTAssertEqual(four["scale"] as? String, "2 2 1", "the Inspector's scale stays on top")
    }

    /// A layer only the Wallpaper Editor adds is replaced once it is in the scene.
    func testAnAddedLayerSceneEditExportReplacedTakesTheReplacement() throws {
        var overlay = SceneEditOverlay()
        overlay.added = [SceneEditOverlay.AddedObject(id: 9, object: .object(["image": .string("c.json"), "origin": .string("0 0 0")]))]
        let resolved = try ScenePreparation.resolvedScene(Self.scene, edits: ["_owe_scene_object_9_json": #"{"image": "d.json"}"#],
                                                          overlay: overlay)
        XCTAssertEqual(try object(9, in: resolved)["image"] as? String, "d.json")
    }

    func testWithoutAnOverlayTheInspectorsEditsResolveAsBefore() throws {
        let edits = ["_owe_scene_object_4_origin": "5 6 0", "_owe_scene_object_5_scale": "2 2 1"]
        let before = try ScenePreparation.resolvedScene(Self.scene, edits: edits)
        let after = try ScenePreparation.resolvedScene(Self.scene, edits: edits, overlay: SceneEditOverlay())
        XCTAssertEqual(try JSONSerialization.jsonObject(with: before) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: after) as? NSDictionary)
        XCTAssertEqual(try object(4, in: before)["origin"] as? String, "5 6 0")
        XCTAssertEqual(try object(5, in: before)["scale"] as? String, "2 2 1")
        let notAScene = Data("[1]".utf8)
        XCTAssertEqual(try ScenePreparation.resolvedScene(notAScene, edits: edits, overlay: SceneEditOverlay()), notAScene)
    }

    func testTheCacheKeyFollowsTheOverlaysSceneEdits() {
        func request(_ overlay: SceneEditOverlay?) -> ScenePreparation.Request {
            ScenePreparation.Request(directory: URL(fileURLWithPath: "/nonexistent"), sceneFile: "scene.json", edits: [:],
                                     userProperties: [:], settings: "", displays: [], overlay: overlay)
        }
        var edited = SceneEditOverlay()
        edited.setField("alpha", to: .number(0.5), of: 4)
        var locked = SceneEditOverlay()
        locked.setLocked(true, 4)
        XCTAssertEqual(request(nil).key, request(SceneEditOverlay()).key)
        XCTAssertEqual(request(nil).key, request(locked).key, "a lock doesn't change the scene")
        XCTAssertNotEqual(request(nil).key, request(edited).key)
        XCTAssertNil(request(nil).keyedEdits[ScenePreparation.overlayKey])
    }

    func testOverlayFilesSaveAndAnnounceTheChange() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "EditorOverlays-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SceneEditOverlayStore(directory: directory)
        let identity = WallpaperSettingsIdentity(rawValue: "workshop-42")
        let wallpaperDirectory = URL(fileURLWithPath: "/tmp/wallpapers/42")
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 4)
        let announced = expectation(forNotification: .sceneEditOverlayDidChange, object: nil) { notification in
            notification.userInfo?["wallpaperDirectory"] as? URL == wallpaperDirectory.standardizedFileURL
        }
        try SceneEditOverlayFiles.save(overlay, for: identity, wallpaperDirectory: wallpaperDirectory, store: store)
        wait(for: [announced], timeout: 1)
        XCTAssertEqual(SceneEditOverlayFiles.overlay(for: identity, store: store), overlay)
        try Data("not json".utf8).write(to: store.fileURL(for: identity.rawValue))
        XCTAssertNil(SceneEditOverlayFiles.overlay(for: identity, store: store), "an unreadable overlay runs the scene as authored")
    }

    // MARK: Scene Edit / Export stays as it was

    func testTheInspectorsBlendModesAreWEsInWEsOrder() {
        let labels = WallpaperEngineLabels()
        let options = SceneBlendModeOptions.options(labels: labels)
        XCTAssertEqual(options.map(\.value), SceneEffectParameters.blendModeOptions.map(\.value))
        XCTAssertEqual(options.first?.title, SceneEffectParameters.blendModeOptions.first?.english)
        let groups = InspectorOptionGroups.groups(options)
        XCTAssertEqual(groups.map(\.heading), [WEImageBlendModes.nativeGroup.english, WEImageBlendModes.emulatedGroup.english],
                       "two runs: Native (fast), then Emulated (slow)")
        XCTAssertEqual(SceneBlendModeOptions.title(labels: labels), String(localized: "Blend Mode"))
    }

    func testOptionGroupsKeepRunsInOrder() {
        let options = [InspectorOption(title: "a", value: 0), InspectorOption(title: "b", value: 1, group: "G"),
                       InspectorOption(title: "c", value: 2, group: "G"), InspectorOption(title: "d", value: 3)]
        let groups = InspectorOptionGroups.groups(options)
        XCTAssertEqual(groups.map(\.heading), [nil, "G", nil])
        XCTAssertEqual(groups.map { $0.options.map(\.value) }, [[0], [1, 2], [3]])
        XCTAssertEqual(groups.map(\.id), [0, 1, 2])
    }

    func testTheInspectorsEditsAndResetAreUntouched() {
        XCTAssertEqual(WallpaperPropertyReset.sceneInspectorPrefixes,
                       ["_owe_scene_object_", "_owe_scene_asset_", "_owe_authored_effect_"])
        XCTAssertFalse(WallpaperPropertyReset.isSceneInspectorEdit(ScenePreparation.overlayKey),
                       "the editor's edits aren't stored with the properties, so resetting them leaves the editor's")
        XCTAssertTrue(ScenePreparation.split(storedValues: [ScenePreparation.overlayKey: "x"]).edits.isEmpty)
    }

    func testTheEditorHasItsOwnWindowAndShortcut() {
        let inspector = AppShortcut[.sceneInspector], editor = AppShortcut[.wallpaperEditor]
        XCTAssertEqual(inspector.key, "i")
        XCTAssertEqual(inspector.modifiers, [.command, .option])
        XCTAssertNotEqual(inspector.combination, editor.combination)
        XCTAssertEqual(editor.menu, .window)
    }

    func testOnlySceneWallpapersOpenInTheEditor() {
        let directory = URL(fileURLWithPath: "/tmp/editor-kind")
        func wallpaper(_ type: String) -> WEWallpaper {
            WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: "T", type: type), where: directory)
        }
        XCTAssertTrue(WallpaperEditorController.canEdit(wallpaper("scene")))
        XCTAssertTrue(WallpaperEditorController.canEdit(wallpaper("Scene")))
        XCTAssertFalse(WallpaperEditorController.canEdit(wallpaper("video")))
        XCTAssertFalse(WallpaperEditorController.canEdit(wallpaper("web")))
    }
}
