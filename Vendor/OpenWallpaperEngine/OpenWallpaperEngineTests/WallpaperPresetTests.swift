import XCTest
@testable import OpenWallpaperEngine

/// "Your Presets": save, apply, rename, delete, and export/import round trips.
final class WallpaperPresetTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!
    private var presetsDirectory: URL!

    private static let project = """
    {"file": "scene.json", "title": "Preset Me", "type": "scene", "workshopid": "515151",
     "general": {"properties": {
       "rain": {"type": "bool", "text": "Rain", "value": true},
       "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1}
     }}}
    """

    private static let userValues: [String: String] = [
        "rain": "false", "speed": "0.9", "_owe_hue": "0.5",
        "_owe_scene_object_12_visible": "false", "_owe_authored_effect_12_0_speed": "3",
    ]

    override func setUpWithError() throws {
        suite = "owe-presets-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        presetsDirectory = directory.appending(path: "presets", directoryHint: .isDirectory)
        let wallpaperDirectory = directory.appending(path: "515151", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wallpaperDirectory, withIntermediateDirectories: true)
        try Data(Self.project.utf8).write(to: wallpaperDirectory.appending(path: "project.json"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper() throws -> WEWallpaper {
        WEWallpaper(using: try decodeTolerant(WEProject.self, from: Data(Self.project.utf8)),
                    where: directory.appending(path: "515151", directoryHint: .isDirectory))
    }

    private func store(identity: String = "workshop-515151") -> WallpaperPresetStore {
        WallpaperPresetStore(identity: WallpaperSettingsIdentity(rawValue: identity), directory: presetsDirectory)
    }

    // MARK: - Save

    func testSaveKeepsTheValuesAndPersists() throws {
        let saved = try store().save(name: "  Rainy  ", values: Self.userValues)
        XCTAssertEqual(saved.name, "Rainy", "the name is trimmed")

        let reloaded = try store().presets()
        XCTAssertEqual(reloaded, [saved], "a new store reads the file back")
        XCTAssertEqual(reloaded.first?.values, Self.userValues, "Scene edits are kept with the properties")
        XCTAssertTrue(FileManager.default.fileExists(atPath: presetsDirectory.appending(path: "workshop-515151.json").path))
    }

    func testSavingUnderAnExistingNameReplacesItsValues() throws {
        let first = try store().save(name: "Night", values: ["rain": "true"])
        let second = try store().save(name: "night", values: ["rain": "false"])
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(try store().presets().map(\.values), [["rain": "false"]])
    }

    func testSaveRefusesAnEmptyName() {
        XCTAssertThrowsError(try store().save(name: "   ", values: [:])) {
            XCTAssertEqual($0 as? WallpaperPresetError, .emptyName)
        }
    }

    func testPresetsAreKeptPerWallpaper() throws {
        try store().save(name: "Mine", values: ["rain": "false"])
        XCTAssertTrue(try store(identity: "workshop-1").presets().isEmpty)
    }

    // MARK: - Apply

    func testApplyReplacesEveryEditedStoreAndPublishesIt() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.display("A"), .display("B")])
        for scope in targets.scopes {
            defaults.set(["rain": "true", "speed": "0.1", "_owe_scene_asset_x_json": "{}"],
                         forKey: targets.identity.key(.userProperties, scope: scope))
        }
        let preset = try store().save(name: "Storm", values: Self.userValues)
        var published: [String: [String: String]] = [:]

        let shown = targets.apply(preset: preset.values, defaults: defaults) { published[$0] = $1 }

        XCTAssertEqual(shown, Self.userValues)
        for scope in targets.scopes {
            XCTAssertEqual(defaults.dictionary(forKey: targets.identity.key(.userProperties, scope: scope)) as? [String: String],
                           Self.userValues, "\(scope) takes the preset, and the inspector edit it lacks is dropped")
            XCTAssertTrue(defaults.bool(forKey: targets.identity.key(.explicitUserProperties, scope: scope)))
        }
        XCTAssertEqual(Set(published.keys), Set(targets.runtimeKeys), "each running wallpaper gets the whole set")
        XCTAssertEqual(published.values.first, Self.userValues)
    }

    /// WE leaves user shortcuts out of presets: applying one keeps each store's own binding, and
    /// a preset that names one (a hand-made file) can't bind it.
    func testApplyKeepsEachStoresUserShortcuts() throws {
        let targets = WallpaperPropertyTargets(wallpaper: try wallpaper(), scopes: [.display("A"), .display("B")])
        for (scope, binding) in zip(targets.scopes, ["cmd:a1b2c3:say a", ""]) {
            defaults.set(["rain": "true", "go": binding], forKey: targets.identity.key(.userProperties, scope: scope))
        }
        _ = targets.apply(preset: ["rain": "false", "go": "cmd:a1b2c3:say preset"], keeping: ["go"], defaults: defaults) { _, _ in }
        let stored: [[String: String]] = targets.scopes.map {
            defaults.dictionary(forKey: targets.identity.key(.userProperties, scope: $0)) as? [String: String] ?? [:]
        }
        XCTAssertEqual(stored, [["rain": "false", "go": "cmd:a1b2c3:say a"], ["rain": "false", "go": ""]])
    }

    // MARK: - Rename and delete

    func testRename() throws {
        let preset = try store().save(name: "Old", values: ["rain": "true"])
        try store().rename(preset.id, to: "New")
        XCTAssertEqual(try store().presets().map(\.name), ["New"])
        XCTAssertEqual(try store().presets().first?.values, ["rain": "true"])
    }

    func testRenameRefusesATakenOrEmptyName() throws {
        let a = try store().save(name: "A", values: [:])
        try store().save(name: "B", values: [:])
        XCTAssertThrowsError(try store().rename(a.id, to: "b")) {
            XCTAssertEqual($0 as? WallpaperPresetError, .duplicateName("b"))
        }
        XCTAssertThrowsError(try store().rename(a.id, to: "")) {
            XCTAssertEqual($0 as? WallpaperPresetError, .emptyName)
        }
        try store().rename(a.id, to: "a")
        XCTAssertEqual(try store().presets().map(\.name), ["a", "B"], "a preset may change its own name's case")
    }

    func testDelete() throws {
        let a = try store().save(name: "A", values: [:])
        let b = try store().save(name: "B", values: [:])
        try store().delete(a.id)
        XCTAssertEqual(try store().presets().map(\.id), [b.id])
        try store().delete(b.id)
        XCTAssertTrue(try store().presets().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store().fileURL.path), "the last delete removes the file")
        XCTAssertThrowsError(try store().delete(b.id)) { XCTAssertEqual($0 as? WallpaperPresetError, .notFound) }
    }

    // MARK: - Export and import

    func testExportImportRoundTrip() throws {
        let preset = try store().save(name: "Shared", values: Self.userValues)
        let file = directory.appending(path: "Shared.json")
        try store().exportData(preset.id).write(to: file)

        let otherMac = store()
        try otherMac.delete(preset.id)
        let imported = try otherMac.importData(Data(contentsOf: file))

        XCTAssertEqual(imported.name, "Shared")
        XCTAssertEqual(imported.values, Self.userValues)
        XCTAssertEqual(try otherMac.presets(), [imported])
    }

    func testImportingATakenNameNumbersIt() throws {
        let preset = try store().save(name: "Shared", values: ["rain": "true"])
        let data = try store().exportData(preset.id)
        XCTAssertEqual(try store().importData(data).name, "Shared 2")
        XCTAssertEqual(try store().importData(data).name, "Shared 3")
        XCTAssertEqual(Set(try store().presets().map(\.id)).count, 3, "each import is a preset of its own")
    }

    func testImportRefusesOtherWallpapersAndOtherFiles() throws {
        let preset = try store().save(name: "Mine", values: [:])
        let data = try store().exportData(preset.id)
        XCTAssertThrowsError(try store(identity: "workshop-1").importData(data)) {
            XCTAssertEqual($0 as? WallpaperPresetError, .otherWallpaper)
        }
        XCTAssertThrowsError(try store().importData(Data(#"{"general": {}}"#.utf8))) {
            XCTAssertEqual($0 as? WallpaperPresetError, .notAPresetFile)
        }
        var newer = try WallpaperPresetTransfer.decode(data)
        newer.version = WallpaperPresetTransfer.currentVersion + 1
        XCTAssertThrowsError(try store().importData(newer.encoded())) {
            XCTAssertEqual($0 as? WallpaperPresetError, .notAPresetFile)
        }
    }

    func testSuggestedFileNameDropsPathCharacters() {
        let transfer = WallpaperPresetTransfer(wallpaper: "x", preset: WallpaperPreset(name: "Day/Night: v2", values: [:]))
        XCTAssertEqual(transfer.suggestedFileName, "Day-Night- v2.json")
    }
}
