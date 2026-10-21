import XCTest
@testable import OpenWallpaperEngine

/// Your Presets and Wallpaper Engine: its Share JSON both ways, Apply to All Wallpapers, and
/// importing the presets of a WE config.json (a synthetic fixture, `Presets/we-config-synthetic.json`).
final class WallpaperPresetCompatibilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    private static let project = """
    {"file": "scene.json", "title": "Preset Me", "type": "scene", "workshopid": "515151",
     "general": {"properties": {
       "rain": {"type": "bool", "text": "Rain", "value": true},
       "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1},
       "tint": {"type": "color", "text": "Tint", "value": "1 1 1"},
       "mode": {"type": "combo", "text": "Mode", "value": "1", "options": [{"label": "A", "value": "1"}, {"label": "B", "value": "2"}]},
       "caption": {"type": "textinput", "text": "Caption", "value": "hi"},
       "hotkey": {"type": "usershortcut", "text": "Key", "value": "x"}
     }}}
    """

    override func setUpWithError() throws {
        suite = "owe-preset-compat-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    /// A wallpaper folder named `id` with `project` (its Workshop id taken from the folder name).
    private func wallpaper(_ id: String, project: String = WallpaperPresetCompatibilityTests.project) throws -> WEWallpaper {
        let folder = directory.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = project.replacingOccurrences(of: "\"workshopid\": \"515151\"", with: "\"workshopid\": \"\(id)\"")
        try Data(json.utf8).write(to: folder.appending(path: "project.json"))
        return WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(json.utf8)), where: folder)
    }

    private func definitions() throws -> [String: UserPropertyDefinition] {
        WallpaperEngineShareJSON.definitions(in: try wallpaper("515151").wallpaperDirectory)
    }

    // MARK: - Share JSON

    func testShareJSONRoundTripsWithWEsTypes() throws {
        let definitions = try definitions()
        let values = ["rain": "false", "speed": "0.75", "tint": "0.2 0.3 0.4", "mode": "2", "caption": "Hello",
                      "hotkey": "y", "_owe_hue": "0.5"]
        let data = try WallpaperEngineShareJSON.encode(values, definitions: definitions)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["rain"] as? Bool, false, "a bool is a JSON bool")
        XCTAssertEqual(object["speed"] as? Double, 0.75, "a slider is a number")
        XCTAssertEqual(object["tint"] as? String, "0.2 0.3 0.4")
        XCTAssertEqual(object["mode"] as? String, "2")
        XCTAssertNil(object["hotkey"], "user shortcuts are left out, as WE does")
        XCTAssertNil(object["_owe_hue"], "only the wallpaper's own properties")
        let decoded = try WallpaperEngineShareJSON.decode(String(decoding: data, as: UTF8.self))
        var expected = values
        expected["hotkey"] = nil
        expected["_owe_hue"] = nil
        XCTAssertEqual(WallpaperEngineShareJSON.values(from: decoded, definitions: definitions), expected)
    }

    func testShareJSONFromWEIsReadPlainOrAsItsCopiedBase64() throws {
        let definitions = try definitions()
        let text = #"{"rain": true, "speed": 1, "mode": 2, "tint": "0 0.5 1", "unknown": 3, "caption": 4}"#
        let base64 = Data(text.utf8).base64EncodedString()
        for form in [text, base64, "  \(base64)\n"] {
            let values = WallpaperEngineShareJSON.values(from: try WallpaperEngineShareJSON.decode(form), definitions: definitions)
            XCTAssertEqual(values, ["rain": "true", "speed": "1", "mode": "2", "tint": "0 0.5 1"],
                           "known keys of a fitting type; a number where text belongs is dropped")
        }
        XCTAssertThrowsError(try WallpaperEngineShareJSON.decode("[1, 2]"))
        XCTAssertThrowsError(try WallpaperEngineShareJSON.decode("not json"))
    }

    func testMismatchedTypesAndComboValuesAreDropped() throws {
        let definitions = try definitions()
        let values = WallpaperEngineShareJSON.values(from: ["rain": 1, "speed": true, "mode": "9", "tint": "red", "RAIN": false],
                                                     definitions: definitions)
        XCTAssertEqual(values, ["rain": "false"], "only the case-insensitive key with a bool fits")
    }

    // MARK: - Apply to All Wallpapers

    func testApplyToAllSkipsCustomizedWallpapersByDefaultAndReplacesThemOtherwise() throws {
        let source = try wallpaper("515151")
        let fresh = try wallpaper("600001")
        let customized = try wallpaper("600002")
        let unrelated = try wallpaper("600003", project: """
        {"file": "scene.json", "title": "Other", "type": "scene", "workshopid": "600003",
         "general": {"properties": {"rain": {"type": "slider", "text": "Rain", "value": 0.2}, "glow": {"type": "bool", "value": true}}}}
        """)
        let customizedID = WallpaperSettingsIdentity.resolve(customized, defaults: defaults)
        defaults.set(["rain": "true", "speed": "0.1", "caption": "mine"], forKey: customizedID.key(.userProperties, scope: .shared))
        defaults.set(true, forKey: customizedID.key(.explicitUserProperties, scope: .shared))
        let unrelatedID = WallpaperSettingsIdentity.resolve(unrelated, defaults: defaults)

        let bulk = WallpaperPresetBulkApply(values: ["rain": "false", "speed": "0.9", "_owe_hue": "0.5"],
                                            sourceDefinitions: WallpaperEngineShareJSON.definitions(in: source.wallpaperDirectory),
                                            sourceIdentity: WallpaperSettingsIdentity.resolve(source, defaults: defaults))
        var published: [String: [String: String]] = [:]
        let all = [source, fresh, customized, unrelated]
        let first = bulk.apply(to: all, mode: .uncustomizedOnly, defaults: defaults) { published[$0] = $1 }
        XCTAssertEqual(first, .init(applied: 1, keptCustomized: 1, withoutMatch: 1))
        let freshID = WallpaperSettingsIdentity.resolve(fresh, defaults: defaults)
        let freshValues = defaults.object(forKey: freshID.key(.userProperties, scope: .shared)) as? [String: String]
        XCTAssertEqual(freshValues?["rain"], "false")
        XCTAssertEqual(freshValues?["speed"], "0.9")
        XCTAssertEqual(freshValues?["caption"], "hi", "its other properties keep their defaults")
        XCTAssertNil(freshValues?["_owe_hue"], "only project properties carry over")
        XCTAssertTrue(defaults.bool(forKey: freshID.key(.explicitUserProperties, scope: .shared)))
        XCTAssertEqual(published[fresh.wallpaperDirectory.path], ["rain": "false", "speed": "0.9"])
        XCTAssertEqual((defaults.object(forKey: customizedID.key(.userProperties, scope: .shared)) as? [String: String])?["speed"], "0.1",
                       "a customized wallpaper keeps its values by default")
        XCTAssertNil(defaults.object(forKey: unrelatedID.key(.userProperties, scope: .shared)),
                     "a wallpaper whose only same-named property has another type is untouched")

        let second = bulk.apply(to: all, mode: .replaceCustomizations, defaults: defaults) { _, _ in }
        XCTAssertEqual(second, .init(applied: 2, keptCustomized: 0, withoutMatch: 1))
        let replaced = defaults.object(forKey: customizedID.key(.userProperties, scope: .shared)) as? [String: String]
        XCTAssertEqual(replaced, ["rain": "false", "speed": "0.9", "caption": "mine"], "the preset's keys replace, the rest stays")
        XCTAssertNil(defaults.object(forKey: unrelatedID.key(.userProperties, scope: .shared)))
    }

    // MARK: - config.json

    func testSyntheticConfigEntriesMatchByWorkshopIDOnly() throws {
        let entries = try WallpaperEngineConfigImport.entries(in: Fixtures.data("Presets/we-config-synthetic.json"))
        XCTAssertEqual(entries.map(\.workshopID), ["515151", "515152", "999999"], "the default project has no Workshop id")
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.presets.map(\.name), ["Night", "Blue", nil], "presets, then the saved values once")
        XCTAssertEqual(WallpaperEngineConfigImport.workshopID(inPath: #"D:\Lib\steamapps\workshop\content\431960\42\a.pkg"#), "42")
        XCTAssertNil(WallpaperEngineConfigImport.workshopID(inPath: "C:/Users/me/431960x/1/scene.pkg"))
    }

    func testSyntheticConfigImportsIntoInstalledWallpapers() throws {
        let installed = try wallpaper("515151")
        let presetsDirectory = directory.appending(path: "presets", directoryHint: .isDirectory)
        let entries = try WallpaperEngineConfigImport.entries(in: Fixtures.data("Presets/we-config-synthetic.json"))
        let summary = try WallpaperEngineConfigImport.importEntries(
            entries, installed: [installed], savedValuesName: "Wallpaper Engine Settings",
            store: { WallpaperPresetStore(identity: $0, directory: presetsDirectory) }, defaults: defaults)
        XCTAssertEqual(summary, .init(presets: 3, wallpapers: 1, notInstalled: 2))
        let store = WallpaperPresetStore(identity: WallpaperSettingsIdentity(rawValue: "workshop-515151"), directory: presetsDirectory)
        let presets = try store.presets()
        XCTAssertEqual(presets.map(\.name), ["Night", "Blue", "Wallpaper Engine Settings"])
        XCTAssertEqual(presets[0].values, ["rain": "false", "speed": "0.75", "tint": "0.2 0.3 0.4", "mode": "2"])
        XCTAssertEqual(presets[1].values, ["rain": "true"], "a slider given text and an unknown combo value are dropped")
        XCTAssertEqual(presets[2].values, ["rain": "true", "speed": "0.5"])

        let again = try WallpaperEngineConfigImport.importEntries(
            entries, installed: [installed], savedValuesName: "Wallpaper Engine Settings",
            store: { WallpaperPresetStore(identity: $0, directory: presetsDirectory) }, defaults: defaults)
        XCTAssertEqual(again.presets, 3)
        XCTAssertEqual(try store.presets().map(\.name).suffix(3), ["Night 2", "Blue 2", "Wallpaper Engine Settings 2"],
                       "a second import numbers the names")
    }

    func testBadConfigInputIsAnError() {
        for text in ["", "[]", #"{"?installdirectory": "C:/x"}"#, "{not json"] {
            XCTAssertThrowsError(try WallpaperEngineConfigImport.entries(in: Data(text.utf8))) { error in
                XCTAssertEqual(error as? WallpaperPresetError, .notAConfigFile)
            }
        }
        let odd = #"{"u": {"general": {"wpresets": {"a/431960/1/s.pkg": {"presets": [3, {"name": 1}, {"properties": "x"}]}}}, "wproperties": 5}}"#
        XCTAssertEqual(try WallpaperEngineConfigImport.entries(in: Data(odd.utf8)), [], "malformed parts are skipped")
    }
}
