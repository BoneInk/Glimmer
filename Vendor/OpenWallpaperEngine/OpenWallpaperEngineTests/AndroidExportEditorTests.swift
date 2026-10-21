import AVFoundation
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's Android Export mode: the device table, the custom size, the preview's
/// shape, the crop, the isolation from the desktop, the pre-rendered loop and the Dynamic bake;
/// and WE's preset table and sound-file rule the `.mpkg` writer follows.
@MainActor
final class AndroidExportEditorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var directory: URL!

    private static let project = """
    {"file": "scene.json", "title": "Android Me", "type": "scene", "preview": "preview.jpg",
     "tags": ["Anime", "1920 x 1080"],
     "general": {"properties": {
       "speed": {"type": "slider", "text": "Speed", "value": 0.25, "min": 0, "max": 1},
       "clock": {"type": "bool", "text": "Clock", "value": true},
       "style": {"type": "combo", "text": "Style", "value": 1, "options": [{"label": "A", "value": 1}, {"label": "B", "value": 2}]},
       "name": {"type": "textinput", "text": "Name", "value": "cat"}
     }}}
    """

    private static let scene = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"clearcolor": "0 0 0", "orthogonalprojection": {"width": 1600, "height": 900}},
     "objects": [
       {"id": 1, "name": "Back", "image": "models/back.json", "origin": "800 450 0", "visible": {"user": "clock", "value": true},
        "effects": [
          {"file": "effects/tint/effect.json", "id": 10,
           "passes": [{"constantshadervalues": {"Alpha": 0.5, "color": {"value": "1 0 0", "animation": {"c0": []}}, "bound": {"user": "speed", "value": 0.1}},
                       "combos": {"MODE": 0}}]},
          {"file": "effects/shake/effect.json", "id": 11}
        ]},
       {"id": 2, "name": "Front", "image": "models/front.json", "origin": "100 100 0"},
       {"id": 3, "name": "Music", "sound": ["sounds/song.mp3"], "volume": 1}
     ],
     "version": 1}
    """

    override func setUpWithError() throws {
        suite = "owe-android-editor-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "sounds"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appending(path: "models"), withIntermediateDirectories: true)
        try Data(Self.project.utf8).write(to: directory.appending(path: "project.json"))
        try Data(Self.scene.utf8).write(to: directory.appending(path: "scene.json"))
        try Data(#"{"material": "materials/back.json"}"#.utf8).write(to: directory.appending(path: "models/back.json"))
        try Data([1, 2, 3]).write(to: directory.appending(path: "sounds/song.mp3"))
        try Data([4, 5]).write(to: directory.appending(path: "sounds/drop.WAV"))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory) // scratch cleanup
    }

    private func wallpaper() throws -> WEWallpaper {
        try XCTUnwrap(InstalledLibrary.wallpaper(at: directory, hiding: []))
    }

    private func save(_ values: [String: String], _ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) {
        let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
        defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
        defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
    }

    private func stored(_ scope: WallpaperPropertyScope, of wallpaper: WEWallpaper) -> [String: String]? {
        defaults.dictionary(forKey: WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults).key(.userProperties, scope: scope))
            as? [String: String]
    }

    private func model(sceneSize: SIMD2<Double> = SIMD2(1600, 900)) throws -> AndroidExportEditorModel {
        let session = IsolatedSceneEditSession(wallpaper: try wallpaper(), purpose: "android-editor-test-\(UUID().uuidString)",
                                               seededFrom: [.shared], defaults: defaults)
        addTeardownBlock { @MainActor in session.end() }
        return AndroidExportEditorModel(session: session, sceneSize: sceneSize, defaults: defaults)
    }

    // MARK: Device table

    func testDeviceTableIsUniquePositiveSortedAndSourced() throws {
        let devices = AndroidDevice.all
        XCTAssertGreaterThanOrEqual(devices.count, 60)
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count, "unique ids")
        XCTAssertEqual(devices.count, AndroidDevice.table.count)
        for device in devices {
            XCTAssertGreaterThan(device.pixelSize.x, 0, device.id)
            XCTAssertGreaterThan(device.pixelSize.y, 0, device.id)
            XCTAssertTrue((2018...2027).contains(device.year), device.id)
            XCTAssertTrue(device.source.hasPrefix("https://"), "\(device.id) cites its spec page")
            XCTAssertNotNil(URL(string: device.source), device.id)
            if device.kind != .foldable {
                XCTAssertLessThan(device.pixelSize.x, device.pixelSize.y, "\(device.id) is portrait")
            }
            XCTAssertEqual(device.screen != nil, device.kind == .foldable, device.id)
            XCTAssertEqual(device.landscapePixelSize != nil, device.kind == .tablet, device.id)
        }
        // By kind (phones, foldables, tablets), then newest first.
        let order = AndroidDeviceKind.allCases
        for (earlier, later) in zip(devices, devices.dropFirst()) {
            let a = order.firstIndex(of: earlier.kind)!, b = order.firstIndex(of: later.kind)!
            XCTAssertTrue(a < b || (a == b && earlier.year >= later.year), "\(earlier.id) before \(later.id)")
        }
        // Every maker asked for, foldables with both screens, and the whole Tab S9 family.
        for brand in ["Samsung", "Google", "OnePlus", "Xiaomi", "Motorola", "Nothing", "Sony", "OPPO", "vivo"] {
            XCTAssertTrue(devices.contains { $0.brand.caseInsensitiveCompare(brand) == .orderedSame }, brand)
        }
        let foldables = Dictionary(grouping: devices.filter { $0.kind == .foldable }, by: { "\($0.brand) \($0.name)" })
        XCTAssertFalse(foldables.isEmpty)
        for (name, screens) in foldables {
            XCTAssertEqual(Set(screens.compactMap(\.screen)), [.main, .cover], name)
        }
        let tabS9: [String: SIMD2<Int>] = ["Galaxy Tab S9": SIMD2(1600, 2560), "Galaxy Tab S9+": SIMD2(1752, 2800),
                                           "Galaxy Tab S9 Ultra": SIMD2(1848, 2960), "Galaxy Tab S9 FE": SIMD2(1440, 2304),
                                           "Galaxy Tab S9 FE+": SIMD2(1600, 2560)]
        for (name, size) in tabS9 {
            let device = try XCTUnwrap(devices.first { $0.brand == "Samsung" && $0.name == name }, name)
            XCTAssertEqual(device.kind, .tablet, name)
            XCTAssertEqual(device.pixelSize, size, name)
            XCTAssertEqual(device.landscapePixelSize, SIMD2(size.y, size.x), name)
        }
        XCTAssertEqual(AndroidDevice.defaultDevice.kind, .phone)
    }

    func testSearchMatchesNameKindYearAndResolution() throws {
        let all = AndroidDevice.all
        XCTAssertTrue(AndroidDeviceSearch.filter(all, query: "tab s9 ultra").allSatisfy { $0.name.contains("Tab S9 Ultra") })
        XCTAssertFalse(AndroidDeviceSearch.filter(all, query: "tab s9 ultra").isEmpty)
        XCTAssertTrue(AndroidDeviceSearch.filter(all, query: "1848 × 2960").contains { $0.name == "Galaxy Tab S9 Ultra" })
        XCTAssertTrue(AndroidDeviceSearch.filter(all, query: "pixel").allSatisfy { $0.displayName.lowercased().contains("pixel") })
        XCTAssertEqual(AndroidDeviceSearch.filter(all, query: "").count, all.count)
        let groups = AndroidDeviceSearch.groups(all)
        XCTAssertEqual(groups.map(\.kind), AndroidDeviceKind.allCases)
    }

    // MARK: Custom size

    func testCustomSizeIsValidatedAndShowsItsAspect() {
        XCTAssertEqual(AndroidCustomSize.validate(width: "1080", height: " 2400 "), .success(SIMD2(1080, 2400)))
        XCTAssertEqual(AndroidCustomSize.validate(width: "320", height: "8192"), .success(SIMD2(320, 8192)))
        XCTAssertEqual(AndroidCustomSize.validate(width: "319", height: "2400"), .failure(.tooSmall))
        XCTAssertEqual(AndroidCustomSize.validate(width: "1080", height: "8193"), .failure(.tooLarge))
        XCTAssertEqual(AndroidCustomSize.validate(width: "", height: "2400"), .failure(.notANumber))
        XCTAssertEqual(AndroidCustomSize.validate(width: "10.5", height: "2400"), .failure(.notANumber))
        XCTAssertEqual(AndroidCustomSize.aspectText(SIMD2(1080, 2400)), "9:20")
        XCTAssertEqual(AndroidCustomSize.aspectText(SIMD2(1440, 3120)), "6:13")
        XCTAssertEqual(AndroidCustomSize.aspectText(SIMD2(1000, 2170)), "1:2.17")
        XCTAssertEqual(AndroidCustomSize.aspectText(SIMD2(2170, 1000)), "2.17:1")
    }

    func testCustomSizeFieldsKeepTheLastValidSize() throws {
        let model = try model()
        model.choose(nil)
        model.setCustom(width: "1200", height: "2000")
        XCTAssertNil(model.customIssue)
        XCTAssertEqual(model.screenPixels, SIMD2(1200, 2000))
        model.setCustom(width: "100", height: "2000")
        XCTAssertEqual(model.customIssue, .tooSmall)
        XCTAssertEqual(model.screenPixels, SIMD2(1200, 2000), "an invalid entry keeps the last valid size")
        XCTAssertEqual(model.customWidth, "100", "the field shows what was typed")
        // Kept across launches.
        let again = try self.model()
        XCTAssertNil(again.device)
        XCTAssertEqual(again.screenPixels, SIMD2(1200, 2000))
    }

    // MARK: Preview

    func testPreviewTakesTheChosenDevicesShape() throws {
        let model = try model()
        let tablet = try XCTUnwrap(AndroidDevice.all.first { $0.name == "Galaxy Tab S9 Ultra" })
        let phone = try XCTUnwrap(AndroidDevice.all.first { $0.kind == .phone })
        let cover = try XCTUnwrap(AndroidDevice.all.first { $0.kind == .foldable && $0.screen == .cover })
        func check(_ expected: SIMD2<Int>, _ label: String) {
            XCTAssertEqual(model.screenPixels, expected, label)
            let aspect = Double(expected.x) / Double(expected.y)
            XCTAssertEqual(model.aspect, aspect, accuracy: 1e-9, label)
            XCTAssertEqual(model.crop.cropRect.width / model.crop.cropRect.height, aspect, accuracy: 0.01, label)
            let layout = LockScreenPreview.layout(window: model.crop.cropRect, sceneSize: model.sceneSize,
                                                  in: CGSize(width: 900, height: 700))
            XCTAssertEqual(layout.frame.width / layout.frame.height, aspect, accuracy: 0.01, "the preview's frame: \(label)")
        }
        model.choose(phone)
        check(phone.pixelSize, phone.id)
        model.choose(tablet)
        check(tablet.pixelSize, tablet.id)
        model.setLandscape(true)
        check(SIMD2(tablet.pixelSize.y, tablet.pixelSize.x), "\(tablet.id) landscape")
        model.choose(cover)
        XCTAssertFalse(model.isLandscape, "only a tablet turns")
        check(cover.pixelSize, cover.id)
        model.choose(nil)
        model.setCustom(width: "2000", height: "1000")
        check(SIMD2(2000, 1000), "custom")
        // The video follows the screen, even-sided, at the preset's short side.
        model.choose(phone)
        model.setVideoSize(.fullHD)
        XCTAssertEqual(min(model.outputPixels.x, model.outputPixels.y), 1080)
        XCTAssertEqual(model.outputPixels.x % 2, 0)
        XCTAssertEqual(model.outputPixels.y % 2, 0)
        XCTAssertEqual(model.crop.outputPixels, model.outputPixels)
    }

    // MARK: Crop

    func testCropReachesTheScenesEdgeOnAllFourSides() throws {
        let model = try model()
        let scene = model.sceneSize
        let tablet = try XCTUnwrap(AndroidDevice.all.first { $0.kind == .tablet })
        let cases: [(AndroidDevice?, Bool)] = [(AndroidDevice.defaultDevice, false), (tablet, true), (nil, false)]
        for (device, landscape) in cases {
            model.choose(device)
            model.setLandscape(landscape)
            model.zoom = 2
            let label = device?.id ?? "custom"
            model.pan(by: SIMD2(-100_000, 0))
            XCTAssertEqual(model.crop.cropRect.minX, 0, accuracy: 1e-9, "left: \(label)")
            model.pan(by: SIMD2(100_000, 0))
            XCTAssertEqual(model.crop.cropRect.maxX, scene.x, accuracy: 1e-9, "right: \(label)")
            model.pan(by: SIMD2(0, -100_000))
            XCTAssertEqual(model.crop.cropRect.minY, 0, accuracy: 1e-9, "top: \(label)")
            model.pan(by: SIMD2(0, 100_000))
            XCTAssertEqual(model.crop.cropRect.maxY, scene.y, accuracy: 1e-9, "bottom: \(label)")
        }
    }

    // MARK: Isolation

    func testEditsStayInTheModeAndNeverReachTheDesktop() throws {
        let wallpaper = try wallpaper()
        let shared: [String: String] = ["speed": "0.25", sceneObjectVisibilityKey(objectID: 2): "true"]
        save(shared, .shared, of: wallpaper)
        let sharedKey = WallpaperPropertyScope.shared.runtimeKey(directory: wallpaper.settingsDirectory)
        WallpaperServices.shared.setUserProperties(shared, wallpaper: sharedKey, replacing: true)
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: AndroidExportEditorModel.purpose,
                                               seededFrom: [.shared], defaults: defaults)
        let model = AndroidExportEditorModel(session: session, sceneSize: SIMD2(1600, 900), defaults: defaults)
        XCTAssertNotEqual(AndroidExportEditorModel.purpose, LivePhotoExportModel.purpose)

        session.setLayerVisible(false, objectID: 2)
        session.setValues(["speed": "0.9"])
        model.chooseMode(.preRendered)
        let item = model.item
        XCTAssertEqual(item.properties["speed"], "0.9", "the pre-render renders the mode's values")
        XCTAssertEqual(item.properties[sceneObjectVisibilityKey(objectID: 2)], "false")

        XCTAssertEqual(stored(.shared, of: wallpaper), shared, "the desktop's stored values are untouched")
        XCTAssertEqual(WallpaperServices.shared.userProperties(wallpaper: sharedKey), shared, "and its running values")
        XCTAssertNil(session.instances.instance(for: WallpaperInstanceKey(wallpaper)))
        session.end()
        XCTAssertNil(stored(session.scope, of: wallpaper))
        XCTAssertEqual(stored(.shared, of: wallpaper), shared)
        WallpaperServices.shared.setUserProperties([:], wallpaper: sharedKey, replacing: true)
    }

    // MARK: Export item

    func testDynamicIsTheDefaultAndPreRenderedCarriesTheFraming() throws {
        let model = try model()
        XCTAssertEqual(model.options.mode, .balanced, "the tab exports the live scene (Balanced) by default, as the sheet does")
        XCTAssertNil(model.item.framing)
        model.chooseMode(.preRendered)
        XCTAssertEqual(model.options.frameRate, 30)
        XCTAssertEqual(model.seconds, 30)
        model.zoom = 2
        model.pan(by: SIMD2(-100_000, 0))
        model.setParallaxPosition(SIMD2(0.2, 0.7))
        let item = model.item
        let framing = try XCTUnwrap(item.framing)
        XCTAssertEqual(framing.crop, model.crop)
        XCTAssertEqual(framing.pointer, SIMD2(0.2, 0.7))
        XCTAssertNil(item.bakedValues)
        let job = AndroidExporter.videoJob(item, framing: framing, output: directory.appending(path: "v.mp4"))
        XCTAssertEqual(job.pointerPosition, SIMD2(0.2, 0.7))
        XCTAssertEqual(job.crop, framing.crop)
        XCTAssertEqual(job.frameCount, 30 * 30)
        XCTAssertEqual(job.bitRate, model.options.videoBitRate(pixelSize: model.outputPixels), "the bit rate scales with the pixels")
        let roundTrip = try JSONDecoder().decode(AndroidVideoJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(roundTrip.crop, framing.crop, "the helper gets the zoomed crop")
        XCTAssertEqual(roundTrip.pointerPosition, SIMD2(0.2, 0.7))
        // A library export's job (no pointer, no zoom) still decodes, centred and unzoomed.
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any] ?? [:]
        old["pointer"] = nil
        old["zoom"] = nil
        let decoded = try JSONDecoder().decode(AndroidVideoJob.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.pointerPosition, LivePhotoParallax.centre)
        XCTAssertEqual(decoded.crop?.zoom, 1)

        model.chooseMode(.balanced)
        let dynamic = model.item
        XCTAssertNil(dynamic.framing)
        XCTAssertEqual(dynamic.bakedValues, model.session.values)
    }

    // MARK: Dynamic bake

    private func entries(_ options: AndroidExportOptions, baking: [String: String]?) async throws -> [String: Data] {
        let wallpaper = try wallpaper()
        let entries = try await Task.detached {
            try AndroidPackageBuilder.dynamicEntries(wallpaper, options: options, baking: baking)
        }.value
        var files: [String: Data] = [:]
        for entry in entries {
            switch entry.source {
            case .data(let data): files[entry.path] = data
            case .file(let url): files[entry.path] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    func testSceneAssetOverrideKeyKeepsItsStoredFormat() {
        XCTAssertEqual(sceneAssetOverrideKey(path: "models/back.json"), "_owe_scene_asset_models/back.json_json")
        XCTAssertEqual(sceneAssetOverridePath(fromKey: "_owe_scene_asset_models/back.json_json"), "models/back.json")
        XCTAssertNil(sceneAssetOverridePath(fromKey: "_owe_scene_asset__json"), "no path")
        XCTAssertNil(sceneAssetOverridePath(fromKey: "_owe_scene_object_1_json"))
    }

    func testDynamicBakesTheModesEditsIntoSceneAndProjectJSON() async throws {
        let values: [String: String] = [
            sceneObjectVisibilityKey(objectID: 1): "false",
            "_owe_scene_object_2_origin": "300 200 0",
            "_owe_scene_object_2_scale": "2 2 1",
            sceneAuthoredEffectEnabledKey(objectID: 1, effectIndex: 1): "false",
            sceneAuthoredEffectOverrideKey(objectID: 1, effectIndex: 0, parameter: "alpha"): "0.8",
            sceneAuthoredEffectOverrideKey(objectID: 1, effectIndex: 0, parameter: "color"): "0 1 0",
            sceneAuthoredEffectOverrideKey(objectID: 1, effectIndex: 0, parameter: "bound"): "0.9",
            sceneAuthoredEffectOverrideKey(objectID: 1, effectIndex: 0, parameter: SceneEffectParameters.comboOverrideKey("MODE")): "2",
            "_owe_scene_asset_models/back.json_json": #"{"material": "materials/edited.json"}"#,
            "speed": "0.75", "clock": "false", "style": "2", "name": "dog", "undeclared": "x",
        ]
        let files = try await entries(AndroidExportOptions(mode: .balanced), baking: values)
        let scene = try json(files["scene.json"])
        let objects = try XCTUnwrap(scene["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.count, 3, "nothing is stripped")
        XCTAssertEqual(objects[0]["visible"] as? Bool, false, "a hidden layer is hidden in the package")
        XCTAssertEqual(objects[1]["origin"] as? String, "300 200 0")
        XCTAssertEqual(objects[1]["scale"] as? String, "2 2 1")
        let effects = try XCTUnwrap(objects[0]["effects"] as? [[String: Any]])
        XCTAssertEqual(effects[1]["visible"] as? Bool, false)
        let pass = try XCTUnwrap((effects[0]["passes"] as? [[String: Any]])?.first)
        let constants = try XCTUnwrap(pass["constantshadervalues"] as? [String: Any])
        XCTAssertEqual(constants["Alpha"] as? Double, 0.8, "the authored key's spelling is kept")
        XCTAssertNil(constants["alpha"])
        let color = try XCTUnwrap(constants["color"] as? [String: Any])
        XCTAssertEqual(color["value"] as? String, "0 1 0", "an animated value keeps its animation")
        XCTAssertNotNil(color["animation"])
        XCTAssertEqual((constants["bound"] as? [String: Any])?["user"] as? String, "speed", "a user-bound value keeps its binding")
        XCTAssertEqual((pass["combos"] as? [String: Any])?["MODE"] as? Int, 2)
        XCTAssertEqual((scene["general"] as? [String: Any])?["texturereduction"] as? Int, 2, "Balanced's texture reduction")
        XCTAssertEqual(try json(files["models/back.json"])["material"] as? String, "materials/edited.json", "a replaced file")

        let properties = try XCTUnwrap(((try json(files["project.json"]))["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["speed"]?["value"] as? Double, 0.75)
        XCTAssertEqual(properties["clock"]?["value"] as? Bool, false)
        XCTAssertEqual(properties["style"]?["value"] as? Int, 2)
        XCTAssertEqual(properties["name"]?["value"] as? String, "dog")
        XCTAssertNil(properties["undeclared"], "only declared properties")

        // Without edits the scene goes as it is (but its texture reduction).
        let plain = try json(try await entries(AndroidExportOptions(mode: .balanced), baking: nil)["scene.json"])
        XCTAssertNotNil((plain["objects"] as? [[String: Any]])?.first?["visible"] as? [String: Any])
    }

    // MARK: WE's package rules

    func testDynamicLeavesOutOnlyTheSoundFilesAndWritesTheTextureReduction() async throws {
        for (mode, expected) in [(AndroidExportOptions.Mode.highQuality, 1), (.balanced, 2)] {
            let files = try await entries(AndroidExportOptions(mode: mode), baking: nil)
            XCTAssertNil(files["sounds/song.mp3"], "WE drops the music")
            XCTAssertNil(files["sounds/drop.WAV"])
            XCTAssertNotNil(files["models/back.json"])
            let scene = try json(files["scene.json"])
            XCTAssertEqual((scene["general"] as? [String: Any])?["texturereduction"] as? Int, expected, "\(mode)")
            let sound = (scene["objects"] as? [[String: Any]])?.last?["sound"] as? [String]
            XCTAssertEqual(sound, ["sounds/song.mp3"], "the sound layer still names its file")
        }
        var advanced = AndroidExportOptions(mode: .highQuality)
        advanced.textureReduction = .quarter
        let files = try await entries(advanced, baking: nil)
        XCTAssertEqual((try json(files["scene.json"])["general"] as? [String: Any])?["texturereduction"] as? Int, 4)

        let video = directory.appending(path: "wallpaper.mp4")
        try Data([0]).write(to: video)
        let wallpaper = try wallpaper()
        let preRendered = try AndroidPackageBuilder.preRenderedEntries(wallpaper, video: video)
        XCTAssertEqual(Set(preRendered.map(\.path)), ["wallpaper.mp4", "scene.json", "project.json"], "no sound file")
    }

    func testQualityButtonsFollowWEsPresetTable() {
        typealias Options = AndroidExportOptions
        let table: [(Options.Mode, Options.ResolutionClass, Bool, Options.TextureReduction)] = [
            (.highQuality, .pixel, true, .original), (.highQuality, .normal, false, .original), (.highQuality, .uhd, false, .half),
            (.balanced, .pixel, false, .original), (.balanced, .normal, false, .half), (.balanced, .uhd, false, .quarter),
            (.preRendered, .pixel, false, .half), (.preRendered, .normal, false, .quarter), (.preRendered, .uhd, false, .quarter),
        ]
        for (mode, column, pixelArt, reduction) in table {
            let options = Options(mode: mode, resolution: column)
            XCTAssertEqual(options.pixelArt, pixelArt, "\(mode) \(column)")
            XCTAssertEqual(options.textureReduction, reduction, "\(mode) \(column)")
        }
        XCTAssertEqual(Options(mode: .balanced, resolution: .uhd).sceneTextureReduction, 4, "a 4K scene's Balanced")
        // The column: resolution tags above 1920×1080 are 4K; scenes all under 640×480 are pixel art.
        XCTAssertEqual(Options.ResolutionClass.of(tags: ["Anime", "3840 x 2160"], sceneSizes: []), .uhd)
        XCTAssertEqual(Options.ResolutionClass.of(tags: ["Ultrawide 3440 x 1440"], sceneSizes: []), .uhd)
        XCTAssertEqual(Options.ResolutionClass.of(tags: ["1920 x 1080"], sceneSizes: [SIMD2(1920, 1080)]), .normal)
        XCTAssertEqual(Options.ResolutionClass.of(tags: [], sceneSizes: [SIMD2(320, 180), SIMD2(480, 270)]), .pixel)
        XCTAssertEqual(Options.ResolutionClass.of(tags: [], sceneSizes: [SIMD2(320, 180), SIMD2(1920, 1080)]), .normal)
        XCTAssertEqual(Options.ResolutionClass.of(tags: ["1920 x 1080"], sceneSizes: [SIMD2(320, 180)]), .normal)
    }

    func testMCPCanOpenTheAndroidExportTab() {
        XCTAssertEqual(SceneControlRequests.tabs["android_export"], .androidExport)
        XCTAssertEqual(Set(SceneControlRequests.tabs.values).count, SceneInspectorMode.allCases.count)
    }

    // MARK: Pre-render

    /// A layer hidden in the mode is absent from the loop: the fixture's blue solid layer fills
    /// the frame when shown and is gone when hidden.
    func testHiddenLayerIsAbsentFromThePreRenderedLoop() async throws {
        _ = try Fixtures.assets()
        let fixture = try Fixtures.temporaryCopy(of: "Scenes/layers")
        defer {
            Fixtures.removeStoredSettings(for: fixture)
            try? FileManager.default.removeItem(at: fixture) // scratch cleanup
        }
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture, hiding: []))
        let session = IsolatedSceneEditSession(wallpaper: wallpaper, purpose: "android-editor-render-test", seededFrom: [.shared],
                                               defaults: defaults)
        defer { session.end() }
        let model = AndroidExportEditorModel(session: session, sceneSize: try AndroidPackageBuilder.sceneSize(wallpaper),
                                             defaults: defaults)
        model.choose(nil)
        model.setCustom(width: "320", height: "568")
        model.chooseMode(.preRendered)
        session.setValues(["showtitle": "false"])

        func blue(hidden: Bool) async throws -> Double {
            session.setLayerVisible(!hidden, objectID: 2)
            var item = model.item
            item.framing?.seconds = 1
            let output = directory.appending(path: "loop-\(hidden).mp4")
            let job = AndroidExporter.videoJob(item, framing: try XCTUnwrap(item.framing), output: output)
            XCTAssertEqual(job.properties[sceneObjectVisibilityKey(objectID: 2)], hidden ? "false" : "true")
            try await AndroidVideoRenderer.render(job, wallpaper: wallpaper, crop: try XCTUnwrap(job.crop)) { _ in }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(value: 15, timescale: 30)).image
            XCTAssertEqual(frame.width, 320)
            return Self.meanBlue(frame)
        }
        let shown = try await blue(hidden: false)
        let hidden = try await blue(hidden: true)
        XCTAssertGreaterThan(shown, 0.3, "the solid layer is blue")
        XCTAssertLessThan(hidden, shown / 3, "hidden in the mode, it is absent from the loop")
    }

    private static func meanBlue(_ image: CGImage) -> Double {
        let width = 32, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let blues = stride(from: 2, to: pixels.count, by: 4).map { Double(pixels[$0]) / 255 }
        return blues.reduce(0, +) / Double(blues.count)
    }
}
