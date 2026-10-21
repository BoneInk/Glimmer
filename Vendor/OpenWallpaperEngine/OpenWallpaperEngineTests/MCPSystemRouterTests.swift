import OWEControlProtocol
import XCTest
@testable import OpenWallpaperEngine

/// The library and properties the system requests look things up in.
@MainActor
private final class SystemFakeAppModel: ControlAppModel {
    var library: [ControlWallpaper] = [
        SystemFakeAppModel.wallpaper("100", "Rainy Window", "scene"),
        SystemFakeAppModel.wallpaper("200", "City Lights", "video"),
    ]
    var propertyList: [ControlUserProperty] = [
        ControlUserProperty(key: "rain", title: "Rain", type: "bool", value: "true", defaultValue: "true",
                            minimum: 0, maximum: 1, step: nil, fraction: true, editable: false, options: []),
        ControlUserProperty(key: "speed", title: "Speed", type: "slider", value: "1", defaultValue: "1",
                            minimum: 0, maximum: 2, step: 0.1, fraction: true, editable: false, options: []),
    ]

    static func wallpaper(_ id: String, _ title: String, _ type: String) -> ControlWallpaper {
        ControlWallpaper(id: id, title: title, type: type, tags: [], folder: URL(fileURLWithPath: "/library/\(id)"),
                         workshopID: id, description: nil, contentRating: nil)
    }

    func displays() -> [ControlDisplay] { [] }
    func wallpapers() -> [ControlWallpaper] { library }
    func wallpaper(onDisplay id: String) -> ControlWallpaper? { nil }
    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty] { propertyList }
    var playback: ControlPlayback { ControlPlayback(paused: false, volume: 1) }
    func playlists() -> [ControlPlaylist] { [] }
    func setWallpaper(_ wallpaper: ControlWallpaper, displays: [String]) throws {}
    func setPaused(_ paused: Bool) {}
    func stop() {}
    func setVolume(_ volume: Double) {}
    func setMuted(_ muted: Bool) {}
    func setUserProperty(_ key: String, to value: String, of wallpaper: ControlWallpaper) -> [String] { [] }
    func playPlaylist(_ playlist: ControlPlaylist, displays: [String]) {}
    func step(forward: Bool, displays: [String]) -> [String: ControlWallpaper?] { [:] }
    func importWallpapers(at url: URL) async throws -> ControlImportResult { ControlImportResult(imported: [], skipped: []) }
    func openEditor(_ editor: ControlEditor, for wallpaper: ControlWallpaper) throws {}
    func snapshot(display: String) async throws -> ControlSnapshot { throw ControlError(.unavailable, "none") }
}

/// The system features, kept in memory: what the router asked for and what it was answered.
@MainActor
private final class FakeSystemService: SystemControlService {
    var defaults = SystemExportDefaults(device: DeviceModel.model(id: "iPhone 16"), savesToPhotos: false,
                                        photosAlbum: "Open Wallpaper Engine", photosAccess: "not_determined")
    var size = SIMD2<Double>(1920, 1080)
    var exports: [SystemLivePhotoRequest] = []
    var photos = SystemLivePhotoResult.Photos.off
    var state = SystemScreenSaverState(pluginEnabled: false, selection: nil)
    var sceneLayers = [
        SystemSceneLayer(id: 1, name: "Background", kind: "image", authoredVisible: true),
        SystemSceneLayer(id: 4, name: "Clock", kind: "text", authoredVisible: true),
        SystemSceneLayer(id: 7, name: "Rain", kind: "particle", authoredVisible: false),
    ]
    var wallpaperOwn: [String: String] = ["rain": "true", "speed": "1"]
    var saved: [String: String]?
    var setAsScreenSaver: [String] = []
    var setFails = false
    var lock = SystemLockScreenState(enabled: true, mayChangeDesktopPicture: true,
                                     follows: SystemFakeAppModel.wallpaper("100", "Rainy Window", "scene"), displays: [])
    var refreshes = 0

    var exportDefaults: SystemExportDefaults { defaults }
    var androidExports: [SystemAndroidRequest] = []

    func exportAndroid(_ request: SystemAndroidRequest) async throws -> AndroidExportBatch {
        androidExports.append(request)
        let folder = request.outputFolder ?? URL(fileURLWithPath: "/cache/AndroidExport")
        var batch = AndroidExportBatch(folder: folder)
        for wallpaper in request.wallpapers {
            guard wallpaper.type == "scene" || wallpaper.type == "video" else {
                batch.skipped.append(.init(wallpaperID: wallpaper.id, title: wallpaper.title,
                                           reason: "Wallpaper type not supported on Android devices"))
                continue
            }
            batch.outputs.append(.init(wallpaperID: wallpaper.id, title: wallpaper.title, type: wallpaper.type,
                                       mode: wallpaper.type == "scene" ? request.options.mode : nil,
                                       url: folder.appending(path: "\(wallpaper.title).mpkg"), size: 1000, previewURL: nil))
        }
        return batch
    }

    var wifiSends: [SystemAndroidSendRequest] = []

    func sendAndroidOverWiFi(_ request: SystemAndroidSendRequest) async throws -> SystemAndroidSendResult {
        wifiSends.append(request)
        var batch: AndroidExportBatch?
        if let export = request.export { batch = try await exportAndroid(export) }
        let files = batch.map(AndroidWiFiFile.files(of:)) ?? request.packages.enumerated().map { index, url in
            AndroidWiFiFile(index: index, title: url.deletingPathExtension().lastPathComponent, kind: .sceneDynamic, url: url,
                            size: 10, previewURL: nil, downloadName: url.lastPathComponent)
        }
        return SystemAndroidSendResult(url: URL(string: "http://192.168.1.2:50000/token/")!, expiry: Date().addingTimeInterval(900),
                                       files: files, addresses: ["192.168.1.2"], batch: batch)
    }

    func sceneSize(of wallpaper: ControlWallpaper) throws -> SIMD2<Double> { size }

    func exportLivePhoto(_ request: SystemLivePhotoRequest) async throws -> SystemLivePhotoResult {
        exports.append(request)
        let folder = request.outputFolder ?? URL(fileURLWithPath: "/cache/LivePhoto/x")
        return SystemLivePhotoResult(
            photo: folder.appending(path: "Rainy Window.HEIC"), movie: folder.appending(path: "Rainy Window.MOV"),
            isInCache: request.outputFolder == nil,
            crop: LivePhotoCrop(sceneSize: size, outputPixels: request.device.pixelSize, zoom: request.zoom, center: request.center),
            clip: LivePhotoClip(start: request.clipStart ?? 2, length: request.clipLength),
            clipIsAutomatic: request.clipStart == nil, photos: photos)
    }

    var screenSaver: SystemScreenSaverState { state }

    func layers(of wallpaper: ControlWallpaper) throws -> [SystemSceneLayer] { sceneLayers }

    func screenSaverValues(of wallpaper: ControlWallpaper) throws -> SystemScreenSaverValues {
        saved.map { SystemScreenSaverValues(values: $0, isOwn: true) } ?? SystemScreenSaverValues(values: wallpaperOwn, isOwn: false)
    }

    func setScreenSaverValues(_ values: [String: String], of wallpaper: ControlWallpaper) throws -> Bool {
        if saved == nil, values == wallpaperOwn { return false }
        saved = values
        return true
    }

    func setScreenSaver(_ wallpaper: ControlWallpaper) async throws -> SystemScreenSaverSet {
        if setFails { throw ControlError(.failed, "couldn't be set") }
        setAsScreenSaver.append(wallpaper.id)
        let selection = SystemScreenSaverSelection(wallpaper: wallpaper, folder: wallpaper.folder.path,
                                                   kind: .live,
                                                   picked: Date(timeIntervalSince1970: 1_800_000_000))
        let enabled = !state.pluginEnabled
        state = SystemScreenSaverState(pluginEnabled: true, selection: selection)
        return SystemScreenSaverSet(selection: selection, enabledPlugin: enabled)
    }

    func stopUsingScreenSaver() { state.selection = nil }

    var lockScreen: SystemLockScreenState { lock }
    func setLockScreenEnabled(_ enabled: Bool) { lock.enabled = enabled }
    func refreshLockScreen() { refreshes += 1 }
}

@MainActor
final class MCPSystemRouterTests: XCTestCase {
    private var model: SystemFakeAppModel!
    private var service: FakeSystemService!
    private var router: ControlRequestRouter!

    override func setUp() async throws {
        model = SystemFakeAppModel()
        service = FakeSystemService()
        router = ControlRequestRouter(model: model, groups: [SystemControlRequests(service: service)])
    }

    private func result(_ method: String, _ params: [String: JSONValue] = [:],
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let response = await router.handle(ControlRequest(id: 3, method: method, params: params))
        XCTAssertNil(response.error, "\(method): \(response.error?.message ?? "")", file: file, line: line)
        let result = try XCTUnwrap(response.result, file: file, line: line)
        XCTAssertFalse(result["message"]?.stringValue?.isEmpty ?? true, "\(method) says what happened", file: file, line: line)
        return result
    }

    private func error(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlError? {
        await router.handle(ControlRequest(id: 3, method: method, params: params)).error
    }

    // MARK: - iPhone & iPad Export

    func testDevicesAreTheModesOwnAndSearchLikeIt() async throws {
        let all = try await result("devices_list")
        XCTAssertEqual(all["total"]?.intValue, DeviceModel.all.count)
        let found = try await result("devices_list", ["query": "17 pro max"])
        let devices = try XCTUnwrap(found["devices"]?.arrayValue)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0]["name"], "iPhone 17 Pro Max")
        XCTAssertEqual(devices[0]["family"], "iPhone")
        XCTAssertEqual(devices[0]["width"]?.intValue, 1320)
        XCTAssertEqual(devices[0]["height"]?.intValue, 2868)
        XCTAssertEqual(devices[0]["year"]?.intValue, 2025)
        let byResolution = try await result("devices_list", ["query": "2064x2752"])
        let iPads = byResolution["devices"]?.arrayValue ?? []
        XCTAssertTrue(iPads.allSatisfy { $0["family"] == "iPad" })
        XCTAssertFalse(iPads.isEmpty)
    }

    func testExportSettingsAndSceneSize() async throws {
        let settings = try await result("export_settings_get")
        XCTAssertEqual(settings["device"]?["name"], "iPhone 16")
        XCTAssertEqual(settings["save_to_photos"], false)
        XCTAssertEqual(settings["photos_access"], "not_determined")
        XCTAssertNil(settings["scene"])
        let withScene = try await result("export_settings_get", ["wallpaper_id": "100"])
        XCTAssertEqual(withScene["scene"]?["width"]?.doubleValue, 1920)
        let video = await error("export_settings_get", ["wallpaper_id": "200"])
        XCTAssertEqual(video?.code, .unsupported)
    }

    func testExportTakesTheModesSettings() async throws {
        let folder = FileManager.default.temporaryDirectory
        let exported = try await result("export_live_photo", [
            "wallpaper_id": "100", "device": "ipad pro 13-inch (m5)",
            "crop": ["zoom": 2, "center_x": 600],
            "clip": ["start": 4.5, "length": 2],
            "settings": ["quality": "smaller", "save_to_photos": false],
            "output_folder": .string(folder.path),
        ])
        let request = try XCTUnwrap(service.exports.last)
        XCTAssertEqual(request.device.name, "iPad Pro 13-inch (M5)")
        XCTAssertEqual(request.zoom, 2)
        XCTAssertEqual(request.center, SIMD2<Double>(600, 540))
        XCTAssertEqual(request.clipStart, 4.5)
        XCTAssertEqual(request.clipLength, 2)
        XCTAssertEqual(request.quality, .smaller)
        XCTAssertFalse(request.savesToPhotos)
        XCTAssertEqual(request.outputFolder?.path, folder.standardizedFileURL.path)
        XCTAssertEqual(exported["in_cache"], false)
        XCTAssertEqual(exported["quality"], "smaller")
        XCTAssertEqual(exported["clip"]?["automatic"], false)
        XCTAssertEqual(exported["photos"]?["status"], "off")
        XCTAssertTrue(exported["photo"]?.stringValue?.hasSuffix(".HEIC") ?? false)
        XCTAssertTrue(exported["movie"]?.stringValue?.hasSuffix(".MOV") ?? false)
    }

    func testExportDefaultsToTheRememberedDeviceAndTheMostMotion() async throws {
        service.defaults.savesToPhotos = true
        service.photos = .needsAccess(album: "Open Wallpaper Engine", access: "not_determined")
        let exported = try await result("export_live_photo", ["wallpaper_id": "100"])
        let request = try XCTUnwrap(service.exports.last)
        XCTAssertEqual(request.device.name, "iPhone 16")
        XCTAssertEqual(request.zoom, 1)
        XCTAssertNil(request.center)
        XCTAssertNil(request.clipStart)
        XCTAssertEqual(request.clipLength, LivePhotoClip.duration)
        XCTAssertEqual(request.quality, .best)
        XCTAssertTrue(request.savesToPhotos)
        XCTAssertNil(request.outputFolder)
        XCTAssertEqual(exported["in_cache"], true)
        XCTAssertEqual(exported["clip"]?["automatic"], true)
        XCTAssertEqual(exported["photos"]?["status"], "needs_access")
        let message = exported["message"]?.stringValue ?? ""
        XCTAssertTrue(message.contains("cache"), message)
        XCTAssertTrue(message.contains("Also Save to Photos Album"), message)
    }

    func testExportRefusals() async {
        let video = await error("export_live_photo", ["wallpaper_id": "200"])
        XCTAssertEqual(video?.code, .unsupported)
        let unknown = await error("export_live_photo", ["wallpaper_id": "100", "device": "Galaxy"])
        XCTAssertEqual(unknown?.code, .notFound)
        let ambiguous = await error("export_live_photo", ["wallpaper_id": "100", "device": "iPad Pro"])
        XCTAssertEqual(ambiguous?.code, .invalidParams)
        let relative = await error("export_live_photo", ["wallpaper_id": "100", "output_folder": "exports"])
        XCTAssertEqual(relative?.code, .invalidParams)
        let missing = await error("export_live_photo", ["wallpaper_id": "100", "output_folder": "/no/such/folder"])
        XCTAssertEqual(missing?.code, .notFound)
        let quality = await error("export_live_photo", ["wallpaper_id": "100", "settings": ["quality": "huge"]])
        XCTAssertEqual(quality?.code, .invalidParams)
        XCTAssertTrue(service.exports.isEmpty)
    }

    // MARK: - Screen saver

    func testScreenSaverStateAndAWallpapersVersion() async throws {
        let state = try await result("screensaver_get", ["wallpaper_id": "100"])
        XCTAssertEqual(state["plugin_enabled"], false)
        XCTAssertEqual(state["selection"], .null)
        XCTAssertEqual(state["same_as_wallpaper"], true, "Screen Saver Same as Wallpaper: nothing is set")
        XCTAssertNil(state["schedule"], "no daily re-recording: the screen saver is live")
        let version = try XCTUnwrap(state["wallpaper"])
        XCTAssertEqual(version["eligible"], true)
        XCTAssertEqual(version["own_choices"], false)
        let layers = version["layers"]?.arrayValue ?? []
        XCTAssertEqual(layers.map { $0["visible"]?.boolValue ?? true }, [true, true, false])
        XCTAssertEqual(version["properties"]?["rain"], "true")
        XCTAssertTrue(state["message"]?.stringValue?.contains("System Settings › Screen Saver") ?? false)

        let video = try await result("screensaver_get", ["wallpaper_id": "200"])
        XCTAssertEqual(video["wallpaper"]?["eligible"], false)
    }

    func testSetLayersSavesTheScreenSaversOwnChoices() async throws {
        let changed = try await result("screensaver_set_layers", [
            "wallpaper_id": "100",
            "layers": [["layer": "clock", "visible": false], ["layer": "7", "visible": true]],
            "properties": [["key": "speed", "value": "1.5"]],
        ])
        XCTAssertEqual(changed["saved"], true)
        let saved = try XCTUnwrap(service.saved)
        XCTAssertEqual(saved[sceneObjectVisibilityKey(objectID: 4)], "false")
        XCTAssertEqual(saved[sceneObjectVisibilityKey(objectID: 7)], "true")
        XCTAssertEqual(saved["speed"], "1.5")
        XCTAssertEqual(saved["rain"], "true", "the other values stay")
        let layers = changed["layers"]?.arrayValue ?? []
        XCTAssertEqual(layers.map { $0["visible"]?.boolValue ?? false }, [true, false, true])

        let state = try await result("screensaver_get", ["wallpaper_id": "100"])
        XCTAssertEqual(state["wallpaper"]?["own_choices"], true)
    }

    func testSetLayersToTheWallpapersOwnValuesSavesNothing() async throws {
        let same = try await result("screensaver_set_layers", ["wallpaper_id": "100", "properties": [["key": "rain", "value": "true"]]])
        XCTAssertEqual(same["saved"], false)
        XCTAssertNil(service.saved)
    }

    func testSetLayersRefusals() async {
        let nothing = await error("screensaver_set_layers", ["wallpaper_id": "100"])
        XCTAssertEqual(nothing?.code, .invalidParams)
        let video = await error("screensaver_set_layers", ["wallpaper_id": "200", "layers": [["layer": "1", "visible": true]]])
        XCTAssertEqual(video?.code, .unsupported)
        let layer = await error("screensaver_set_layers", ["wallpaper_id": "100", "layers": [["layer": "Snow", "visible": true]]])
        XCTAssertEqual(layer?.code, .notFound)
        let property = await error("screensaver_set_layers", ["wallpaper_id": "100", "properties": [["key": "fog", "value": "1"]]])
        XCTAssertEqual(property?.code, .notFound)
        let range = await error("screensaver_set_layers", ["wallpaper_id": "100", "properties": [["key": "speed", "value": "9"]]])
        XCTAssertEqual(range?.code, .invalidParams)
        XCTAssertNil(service.saved)
    }

    func testSetLayersNeedsAnIdForATwiceUsedName() async {
        service.sceneLayers.append(SystemSceneLayer(id: 9, name: "clock", kind: "text", authoredVisible: true))
        let twice = await error("screensaver_set_layers", ["wallpaper_id": "100", "layers": [["layer": "Clock", "visible": false]]])
        XCTAssertEqual(twice?.code, .invalidParams)
        XCTAssertTrue(twice?.message.contains("4, 9") ?? false)
    }

    func testSetAndStopUsing() async throws {
        let set = try await result("screensaver_set", ["wallpaper_id": "100"])
        XCTAssertEqual(service.setAsScreenSaver, ["100"])
        XCTAssertEqual(set["enabled_plugin"], true)
        XCTAssertEqual(set["selection"]?["kind"], "live")
        XCTAssertNotEqual(set["selection"]?["picked"], .null)
        XCTAssertNil(set["selection"]?["width"], "drawn live at each display's size")
        XCTAssertEqual(set["selection"]?["wallpaper"]?["id"], "100")
        XCTAssertTrue(set["message"]?.stringValue?.contains("drawn live") ?? false)
        XCTAssertTrue(set["message"]?.stringValue?.contains("turned it on") ?? false)
        XCTAssertEqual(set["same_as_wallpaper"], false)
        let picked = try await result("screensaver_get")
        XCTAssertEqual(picked["same_as_wallpaper"], false, "derived from the selection")

        let video = try await result("screensaver_set", ["wallpaper_id": "200"])
        XCTAssertEqual(video["selection"]?["kind"], "live", "a video is drawn live too")
        XCTAssertTrue(video["message"]?.stringValue?.contains("drawn live by the app") ?? false)

        let stopped = try await result("screensaver_stop_using")
        XCTAssertEqual(stopped["stopped"], true)
        XCTAssertEqual(stopped["same_as_wallpaper"], true)
        XCTAssertNil(service.state.selection)
        let again = try await result("screensaver_stop_using")
        XCTAssertEqual(again["stopped"], false)
    }

    func testSetTakesWebWallpapersButNotApplications() async throws {
        model.library.append(SystemFakeAppModel.wallpaper("300", "Neon Page", "web"))
        model.library.append(SystemFakeAppModel.wallpaper("400", "Desktop App", "application"))
        let web = try await result("screensaver_set", ["wallpaper_id": "300"])
        XCTAssertEqual(service.setAsScreenSaver, ["300"])
        XCTAssertEqual(web["selection"]?["kind"], "live")
        XCTAssertTrue(web["message"]?.stringValue?.contains("Chromium") ?? false)

        let application = await error("screensaver_set", ["wallpaper_id": "400"])
        XCTAssertEqual(application?.code, .unsupported)
        XCTAssertEqual(service.setAsScreenSaver, ["300"], "an application never reaches the service")
    }

    func testSetRefusals() async {
        service.setFails = true
        let failed = await error("screensaver_set", ["wallpaper_id": "100"])
        XCTAssertEqual(failed?.code, .failed)
        XCTAssertNil(service.state.selection)
    }

    func testTheRecordingToolsAreGone() async {
        for tool in ["screensaver_record", "screensaver_schedule_get", "screensaver_schedule_set"] {
            let gone = await error(tool, [:])
            XCTAssertEqual(gone?.code, .unknownMethod, tool)
        }
    }

    // MARK: - Lock screen

    func testLockScreen() async throws {
        service.lock.displays = [SystemLockScreenState.Display(
            id: "1", name: "Built-in Display", wallpaper: model.library[0],
            picture: URL(fileURLWithPath: "/snapshots/lock-1-a.heic"), isLockScreenPicture: true)]
        let state = try await result("lock_screen_get")
        XCTAssertEqual(state["enabled"], true)
        XCTAssertEqual(state["may_change_desktop_picture"], true)
        XCTAssertEqual(state["follows"]?["id"], "100")
        XCTAssertEqual(state["displays"]?.arrayValue?.first?["is_lock_screen_picture"], true)
        XCTAssertEqual(state["displays"]?.arrayValue?.first?["picture"], "/snapshots/lock-1-a.heic")

        let refreshed = try await result("lock_screen_refresh")
        XCTAssertEqual(service.refreshes, 1)
        XCTAssertTrue(refreshed["message"]?.stringValue?.contains("Rainy Window") ?? false)

        let off = try await result("lock_screen_set", ["enabled": false])
        XCTAssertEqual(off["enabled"], false)
        let refused = await error("lock_screen_refresh")
        XCTAssertEqual(refused?.code, .refused)
        XCTAssertEqual(service.refreshes, 1)
    }

    func testLockScreenRefreshForAVideoAndInAnIsolatedCopy() async throws {
        service.lock.follows = model.library[1]
        _ = try await result("lock_screen_refresh")
        XCTAssertEqual(service.refreshes, 1, "a video's frame is a picture too")
        service.lock.mayChangeDesktopPicture = false
        let isolated = await error("lock_screen_refresh")
        XCTAssertEqual(isolated?.code, .unavailable)
    }

    // MARK: - Android

    func testSendOverWiFiServesPackagesOrExportsFirst() async throws {
        let sent = try await result("android_send_wifi", ["wallpaper_ids": ["100", "200"], "mode": "pre_rendered"])
        XCTAssertEqual(sent["url"], "http://192.168.1.2:50000/token/")
        XCTAssertNotNil(sent["expires_at"]?.stringValue)
        XCTAssertEqual(sent["files"]?.arrayValue?.map { $0["title"] }, ["Rainy Window", "City Lights"])
        XCTAssertEqual(service.wifiSends.last?.export?.options.mode, .preRendered)
        let packages = try await result("android_send_wifi", ["package_paths": ["/tmp/A.mpkg"], "address": "192.168.1.2"])
        XCTAssertEqual(packages["files"]?.arrayValue?.count, 1)
        XCTAssertEqual(service.wifiSends.last?.packages, [URL(fileURLWithPath: "/tmp/A.mpkg")])
        XCTAssertEqual(service.wifiSends.last?.address, "192.168.1.2")
        let both = await error("android_send_wifi", ["package_paths": ["/tmp/A.mpkg"], "wallpaper_id": "100"])
        XCTAssertEqual(both?.code, .invalidParams)
        let neither = await error("android_send_wifi")
        XCTAssertEqual(neither?.code, .invalidParams)
        let relative = await error("android_send_wifi", ["package_paths": ["A.mpkg"]])
        XCTAssertEqual(relative?.code, .invalidParams)
    }
}
