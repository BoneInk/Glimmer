import XCTest
@testable import OpenWallpaperEngine

/// WE's own install of Workshop preset 3332091404 "Pixels - Green Forest" over its base scene
/// 3122339805 "Pixels" (`Tests/Fixtures/Library/preset-item`, project.json files as installed;
/// the preset's `files/` holds one placeholder image, and the base has no scene package).
final class WorkshopPresetItemTests: XCTestCase {
    private let library = Fixtures.url("Library/preset-item")
    private let presetId = "3332091404"
    private let baseId = "3122339805"
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
    }

    private func preset(in directory: URL? = nil, hiding: Set<String> = []) throws -> WEWallpaper {
        try XCTUnwrap(InstalledLibrary.wallpapers(in: directory ?? library, hiding: hiding)
            .first { $0.isWorkshopPreset })
    }

    func testPresetIsDetectedWithoutTypeOrFile() throws {
        let root = try XCTUnwrap(WorkshopPresetItem.projectJSON(in: library.appending(path: presetId)))
        XCTAssertNil(root["type"])
        XCTAssertNil(root["file"])
        XCTAssertTrue(WorkshopPresetItem.isPreset(root))
        XCTAssertFalse(WorkshopPresetItem.isPreset(try XCTUnwrap(WorkshopPresetItem.projectJSON(in: library.appending(path: baseId)))))
    }

    /// WE lists it as an ordinary tile of its base's type, with its own title and preview.
    func testPresetIsListedAsItsBasesTypeAndPlaysFromTheBase() throws {
        let preset = try preset(hiding: [baseId])
        XCTAssertEqual(preset.presetDirectory?.lastPathComponent, presetId)
        XCTAssertEqual(preset.wallpaperDirectory.lastPathComponent, baseId)
        XCTAssertEqual(preset.project.type, "scene")
        XCTAssertEqual(preset.project.file, "scene.json")
        XCTAssertEqual(preset.project.title, "Pixels - Green Forest")
        XCTAssertEqual(preset.previewURL?.deletingLastPathComponent().lastPathComponent, presetId)
        XCTAssertEqual(WallpaperSettingsIdentity.resolve(preset).rawValue, "workshop-\(presetId)")
    }

    func testPresetValuesAreTheItemsDefaults() throws {
        let preset = try preset()
        let defaults = WorkshopPresetItem.defaultValues(for: preset)
        XCTAssertEqual(defaults["accentcolourdefault800080"], "0.23529411764705882 0.5372549019607843 0.10588235294117647")
        XCTAssertEqual(defaults["hidenumberswindow"], "true")
        XCTAssertEqual(defaults["leftimagewindowheader"], "CALM")
        // Unset (`null`) values and keys the base doesn't declare are left out.
        XCTAssertNil(defaults["_d0"])
        XCTAssertNil(defaults["wec_hue"])
        // Asset paths are the preset's own files.
        let image = library.appending(path: "\(presetId)/files/7b1bb67b642f2665a0709a26e57300e1.gif")
        XCTAssertEqual(defaults["customimageleft"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() },
                       image.resolvingSymlinksInPath())

        // The user's edit wins; untouched properties start from the preset, then the base.
        var stored = ["hidenumberswindow": "false"]
        stored.merge(defaults) { user, _ in user }
        let declared = (WorkshopPresetItem.projectJSON(in: preset.wallpaperDirectory)?["general"] as? [String: Any])?["properties"]
            as? [String: [String: Any]] ?? [:]
        let scene = try JSONDecoder().decode(WEScene.self, from: Data(
            #"{"camera":{},"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#.utf8))
        let values = SceneContentLoader.userPropertyValues(stored: stored, declared: declared, scene: scene)
        XCTAssertEqual(values["hidenumberswindow"], "false")
        XCTAssertEqual(values["leftimagewindowheader"], "CALM")
        XCTAssertEqual(values["city1"], "TYO")
    }

    func testMissingBaseStaysInItsFolderAndReportsTheDependency() throws {
        let copy = try Fixtures.temporaryCopy(of: "Library/preset-item")
        temporaryDirectories.append(copy)
        try FileManager.default.removeItem(at: copy.appending(path: baseId))
        let preset = try preset(in: copy)
        XCTAssertEqual(preset.wallpaperDirectory, preset.presetDirectory)
        XCTAssertEqual(preset.project.type, "scene")
        XCTAssertEqual(WorkshopDependencyResolver.projectDependencies(inItemAt: preset.wallpaperDirectory), [baseId])
        XCTAssertEqual(WorkshopPresetItem.defaultValues(for: preset), [:])
    }

    /// The preset and its base playing at once keep separate running stores.
    func testPresetHasItsOwnRunningStore() throws {
        let preset = try preset()
        let base = try XCTUnwrap(InstalledLibrary.wallpapers(in: library, hiding: []).first { !$0.isWorkshopPreset })
        XCTAssertNotEqual(WallpaperPropertyTargets(wallpaper: preset, scopes: []).runtimeKeys,
                          WallpaperPropertyTargets(wallpaper: base, scopes: []).runtimeKeys)
        XCTAssertEqual(WorkshopPresetItem.defaultValues(for: base), [:])
    }

    func testPresetSurvivesPersistence() throws {
        let preset = try preset()
        let restored = try XCTUnwrap(WEWallpaper(rawValue: preset.rawValue))
        XCTAssertEqual(restored.presetDirectory, preset.presetDirectory)
    }
}
