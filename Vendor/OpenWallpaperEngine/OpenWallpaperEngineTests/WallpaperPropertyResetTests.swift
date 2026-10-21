import XCTest
@testable import OpenWallpaperEngine

/// The Details panel's Reset (WE's `callbackResetCurrentWallpaperProperties`): each property back
/// to project.json's value in the edited stores, with Scene Edit / Export's edits, applied live.
final class WallpaperPropertyResetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    /// One property of every type the sidebar edits, with the user's values differing from each.
    private static let project = """
    {"file": "scene.json", "title": "Reset Me", "type": "scene", "workshopid": "424242",
     "general": {"properties": {
       "rain": {"type": "bool", "text": "Rain", "value": true},
       "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1},
       "mode": {"type": "combo", "text": "Mode", "value": "b",
                "options": [{"label": "A", "value": "a"}, {"label": "B", "value": "b"}]},
       "firstmode": {"type": "combo", "text": "First", "options": [{"label": "X", "value": "x"}, {"label": "Y", "value": "y"}]},
       "schemecolor": {"type": "color", "text": "Color", "value": "0.1 0.2 0.3"},
       "caption": {"type": "textinput", "text": "Caption", "value": "Hello"},
       "picture": {"type": "file", "text": "Picture", "value": ""},
       "folder": {"type": "directory", "text": "Folder", "value": ""}
     }}}
    """

    private static let userValues: [String: String] = [
        "rain": "false", "speed": "0.9", "mode": "a", "firstmode": "y", "schemecolor": "1 0 0",
        "caption": "Changed", "picture": "/Users/someone/cat.png", "folder": "/Users/someone/Pictures",
        "speed_musicSync": "true", "speed_musicAmount": "0.4", "_owe_speed": "1.8", "_owe_hue": "0.5",
    ]

    /// Scene Edit / Export's edits: object visibility, JSON and an authored effect override.
    private static let inspectorEdits: [String: String] = [
        "_owe_scene_object_12_visible": "false",
        "_owe_scene_object_12_json": "{}",
        "_owe_scene_asset_materials/a.json_json": "{}",
        "_owe_authored_effect_12_0_speed": "3",
        "_owe_authored_effect_12_0_enabled": "false",
    ]

    override func setUpWithError() throws {
        suite = "owe-property-reset-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.project.utf8).write(to: directory.appending(path: "project.json"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper() throws -> WEWallpaper {
        WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(Self.project.utf8)), where: directory)
    }

    /// The defaults the sidebar resets to: each declared property's `defaultValue`, as
    /// `SceneUserPropertiesModel` builds its rows, plus two of the app's own settings.
    private func authorDefaults() throws -> [String: String] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Self.project.utf8)) as? [String: Any])
        var values = Dictionary(uniqueKeysWithValues: UserPropertyDefinition.all(projectJSON: root).map { ($0.key, $0.defaultValue) })
        values["_owe_speed"] = "1"
        values["_owe_hue"] = "0"
        return values
    }

    private func stored(_ targets: WallpaperPropertyTargets, _ scope: WallpaperPropertyScope) -> [String: String]? {
        defaults.dictionary(forKey: targets.identity.key(.userProperties, scope: scope)) as? [String: String]
    }

    private func save(_ values: [String: String], _ targets: WallpaperPropertyTargets, _ scope: WallpaperPropertyScope) {
        defaults.set(values, forKey: targets.identity.key(.userProperties, scope: scope))
        defaults.set(true, forKey: targets.identity.key(.explicitUserProperties, scope: scope))
    }

    // MARK: - Values

    func testEveryPropertyTypeGoesBackToItsProjectDefault() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.shared])
        save(Self.userValues.merging(Self.inspectorEdits) { $1 }, targets, .shared)
        var published: [String: [String: String]] = [:]

        let shown = targets.reset(to: try authorDefaults(), defaults: defaults) { published[$0] = $1 }

        let expected: [String: String] = [
            "rain": "true", "speed": "0.25", "mode": "b", "firstmode": "x", "schemecolor": "0.1 0.2 0.3",
            "caption": "Hello", "picture": "", "folder": "", "_owe_speed": "1", "_owe_hue": "0",
        ]
        XCTAssertEqual(shown, expected, "bool, slider, combo (authored and first option), colour, text, file and directory reset; music sync and inspector edits dropped")
        XCTAssertEqual(stored(targets, .shared), expected)
        XCTAssertTrue(defaults.bool(forKey: targets.identity.key(.explicitUserProperties, scope: .shared)))
        XCTAssertEqual(published, [directory.path: expected], "the running wallpaper gets the whole set at once")
    }

    func testTheInspectorsOwnResetClearsOnlyItsEdits() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.shared])
        save(Self.userValues.merging(Self.inspectorEdits) { $1 }, targets, .shared)

        let afterInspectorReset = targets.removeSceneInspectorEdits(defaults: defaults) { _, _ in }
        XCTAssertTrue(WallpaperPropertyReset.sceneInspectorEdits(in: afterInspectorReset).isEmpty)
        XCTAssertEqual(afterInspectorReset, Self.userValues, "the inspector's Reset keeps the properties")
    }

    /// The running store loses the inspector's keys, and those changes rebuild what they baked in:
    /// object and package JSON reload the scene, visibility and effect overrides rebuild content.
    func testDroppedInspectorEditsRebuildTheRunningScene() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.shared])
        let before = try authorDefaults().merging(Self.inspectorEdits) { $1 }
        save(before, targets, .shared)
        var running = SceneUserPropertyStores()
        running.set(before, for: directory.path, replacing: true)

        targets.reset(to: try authorDefaults(), defaults: defaults) { key, values in
            let changed = running.set(values, for: key, replacing: true)
            XCTAssertEqual(Set(changed), Set(Self.inspectorEdits.keys), "only the inspector's keys changed")
            XCTAssertEqual(SceneChangeImpact.aggregate(changed), .reloadScene)
        }
        XCTAssertTrue(WallpaperPropertyReset.sceneInspectorEdits(in: running.entry(for: directory.path).strings).isEmpty)

        let visibilityOnly = [sceneObjectVisibilityKey(objectID: 12), sceneAuthoredEffectEnabledKey(objectID: 12, effectIndex: 0)]
        XCTAssertEqual(SceneChangeImpact.aggregate(visibilityOnly), .rebuildContent,
                       "visibility and effect edits rebuild content without reloading the package")
    }

    func testClassifiesTheInspectorsKeysOnly() {
        XCTAssertTrue(WallpaperPropertyReset.isSceneInspectorEdit(sceneObjectVisibilityKey(objectID: 3)))
        XCTAssertTrue(WallpaperPropertyReset.isSceneInspectorEdit(sceneAuthoredEffectEnabledKey(objectID: 3, effectIndex: 1)))
        XCTAssertTrue(WallpaperPropertyReset.isSceneInspectorEdit(
            sceneAuthoredEffectOverrideKey(objectID: 3, effectIndex: 1, parameter: "Speed") + "_musicSync"))
        for key in ["_owe_speed", "_owe_text_4_font", "_owe_effect_enabled_parallax", "schemecolor", "speed_musicSync"] {
            XCTAssertFalse(WallpaperPropertyReset.isSceneInspectorEdit(key), key)
        }
    }

    // MARK: - Scopes

    func testSyncedPropertiesResetTheSharedStoreEveryDisplayRuns() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.shared])
        save(Self.userValues, targets, .shared)
        save(["mode": "a"], targets, .display("B"))
        var published: [String] = []

        targets.reset(to: try authorDefaults(), defaults: defaults) { key, _ in published.append(key) }

        XCTAssertEqual(stored(targets, .shared)?["mode"], "b")
        XCTAssertEqual(stored(targets, .display("B")), ["mode": "a"],
                       "a display's own store is only used once sync is off, and isn't touched")
        XCTAssertEqual(published, [directory.path])
    }

    func testPerDisplayPropertiesResetTheSelectedDisplaysOnly() throws {
        let wallpaper = try wallpaper()
        let one = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.display("A")])
        save(Self.userValues, one, .shared)
        save(Self.userValues, one, .display("A"))
        save(Self.userValues, one, .display("B"))

        one.reset(to: try authorDefaults(), defaults: defaults) { _, _ in }
        XCTAssertEqual(stored(one, .display("A"))?["caption"], "Hello")
        XCTAssertEqual(stored(one, .display("B"))?["caption"], "Changed", "an unselected display keeps its properties")
        XCTAssertEqual(stored(one, .shared)?["caption"], "Changed")

        let both = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.display("B"), .display("C")])
        var published: [String] = []
        both.reset(to: try authorDefaults(), defaults: defaults) { key, _ in published.append(key) }
        XCTAssertEqual(stored(both, .display("B"))?["caption"], "Hello")
        XCTAssertEqual(stored(both, .display("C"))?["caption"], "Hello", "a display without its own store gets one")
        XCTAssertEqual(published, [WallpaperPropertyScope.display("B").runtimeKey(directory: directory),
                                   WallpaperPropertyScope.display("C").runtimeKey(directory: directory)])
    }

    func testInspectorEditsAreClearedInTheResetScopesOnly() throws {
        let wallpaper = try wallpaper()
        let edited = Self.userValues.merging(Self.inspectorEdits) { $1 }
        let one = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.display("A")])
        save(edited, one, .shared)
        save(edited, one, .display("B"))

        one.reset(to: try authorDefaults(), defaults: defaults) { _, _ in }

        XCTAssertEqual(stored(one, .display("A")).map(WallpaperPropertyReset.sceneInspectorEdits), [:])
        XCTAssertEqual(stored(one, .display("B")).map(WallpaperPropertyReset.sceneInspectorEdits), Self.inspectorEdits,
                       "an unselected display keeps its inspector edits")
        XCTAssertEqual(stored(one, .shared).map(WallpaperPropertyReset.sceneInspectorEdits), Self.inspectorEdits)

        let synced = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared])
        synced.reset(to: try authorDefaults(), defaults: defaults) { _, _ in }
        XCTAssertEqual(stored(synced, .shared).map(WallpaperPropertyReset.sceneInspectorEdits), [:],
                       "synced: the store every display runs loses them")
        XCTAssertEqual(stored(synced, .display("B")).map(WallpaperPropertyReset.sceneInspectorEdits), Self.inspectorEdits)
    }

    func testTheResetNeverWritesTheAppsStore() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.shared, .display("A")])
        save(Self.userValues, targets, .shared)

        targets.reset(to: try authorDefaults(), defaults: defaults) { _, _ in }

        for scope: WallpaperPropertyScope in [.shared, .display("A")] {
            XCTAssertNil(UserDefaults.app.object(forKey: targets.identity.key(.userProperties, scope: scope)))
            XCTAssertNil(UserDefaults.standard.object(forKey: targets.identity.key(.userProperties, scope: scope)))
        }
    }

    // MARK: - Confirmation

    func testTheConfirmationNamesTheWallpaperAndTheDisplaysItReaches() {
        let synced = PropertyResetConfirmation.message(title: "Rainy Night", scopes: [.shared])
        XCTAssertTrue(synced.contains("Rainy Night"))
        XCTAssertNotEqual(synced, PropertyResetConfirmation.message(title: "Rainy Night", scopes: [.display("A")]))
        XCTAssertNotEqual(PropertyResetConfirmation.message(title: "Rainy Night", scopes: [.display("A")]),
                          PropertyResetConfirmation.message(title: "Rainy Night", scopes: [.display("A"), .display("B")]))
    }
}
