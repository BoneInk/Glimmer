import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// A model of the app for the router: two displays, a small library, a playlist.
@MainActor
private final class FakeAppModel: ControlAppModel {
    var displayList = [
        ControlDisplay(id: "1", name: "Built-in Display", isMain: true, isEnabled: true, width: 1512, height: 982, scale: 2, rule: "run"),
        ControlDisplay(id: "2", name: "Studio Display", isMain: false, isEnabled: true, width: 2560, height: 1440, scale: 2, rule: "pause"),
    ]
    var library: [ControlWallpaper] = [
        FakeAppModel.wallpaper("100", "Rainy Window", "scene", tags: ["Nature", "Relaxing"]),
        FakeAppModel.wallpaper("200", "City Lights", "video", tags: ["City"]),
        FakeAppModel.wallpaper("my-page", "Clock Page", "web", tags: ["Clock"], workshop: nil),
    ]
    var shown: [String: ControlWallpaper] = [:]
    var propertyList: [ControlUserProperty] = [
        ControlUserProperty(key: "speed", title: "Speed", type: "slider", value: "1", defaultValue: "1",
                            minimum: 0, maximum: 2, step: 0.1, fraction: true, editable: false, options: []),
        ControlUserProperty(key: "rain", title: "Rain", type: "bool", value: "true", defaultValue: "true",
                            minimum: 0, maximum: 1, step: nil, fraction: true, editable: false, options: []),
        ControlUserProperty(key: "mode", title: "Mode", type: "combo", value: "a", defaultValue: "a",
                            minimum: 0, maximum: 1, step: nil, fraction: true, editable: false,
                            options: [.init(label: "Calm", value: "a"), .init(label: "Storm", value: "b")]),
    ]
    var playbackState = ControlPlayback(paused: false, volume: 0.8)
    var playlistList: [ControlPlaylist] = []
    var setCalls: [(String, [String])] = []
    var propertyCalls: [(String, String)] = []
    var playedPlaylists: [(String, [String])] = []
    var openedEditors: [(ControlEditor, String)] = []

    static func wallpaper(_ id: String, _ title: String, _ type: String, tags: [String], workshop: String? = "") -> ControlWallpaper {
        ControlWallpaper(id: id, title: title, type: type, tags: tags, folder: URL(fileURLWithPath: "/library/\(id)"),
                         workshopID: workshop == "" ? id : workshop, description: "About \(title)", contentRating: "Everyone")
    }

    init() {
        playlistList = [ControlPlaylist(id: UUID(), name: "Evening", wallpapers: [library[0], library[1]], duration: 600,
                                        isActive: true, isRotating: false, shuffles: false, displays: ["1"])]
    }

    func displays() -> [ControlDisplay] { displayList }
    func wallpapers() -> [ControlWallpaper] { library }
    func wallpaper(onDisplay id: String) -> ControlWallpaper? { shown[id] }
    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty] { propertyList }
    var playback: ControlPlayback { playbackState }
    func playlists() -> [ControlPlaylist] { playlistList }

    func setWallpaper(_ wallpaper: ControlWallpaper, displays: [String]) throws {
        if wallpaper.type == "web" { throw ControlError(.refused, "untrusted") }
        setCalls.append((wallpaper.id, displays))
        for display in displays { shown[display] = wallpaper }
    }

    func setPaused(_ paused: Bool) {
        playbackState.paused = paused
        if !paused { playbackState.stopped = false }
    }
    func stop() { playbackState.stopped = true }
    func setVolume(_ volume: Double) { playbackState.volume = volume }
    func setMuted(_ muted: Bool) { playbackState.volume = muted ? 0 : 0.8 }

    func setUserProperty(_ key: String, to value: String, of wallpaper: ControlWallpaper) -> [String] {
        propertyCalls.append((key, value))
        return ["shared"]
    }

    func playPlaylist(_ playlist: ControlPlaylist, displays: [String]) { playedPlaylists.append((playlist.name, displays)) }

    func step(forward: Bool, displays: [String]) -> [String: ControlWallpaper?] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0, Optional(library[forward ? 1 : 0])) })
    }

    func importWallpapers(at url: URL) async throws -> ControlImportResult {
        ControlImportResult(imported: [library[0]], skipped: [(url.path, "a wallpaper with this folder name is in the library already")])
    }

    func openEditor(_ editor: ControlEditor, for wallpaper: ControlWallpaper) throws { openedEditors.append((editor, wallpaper.id)) }

    func snapshot(display: String) async throws -> ControlSnapshot {
        ControlSnapshot(display: display, wallpaper: shown[display], source: "preview", png: Data([1, 2, 3]), width: 4, height: 3)
    }
}

@MainActor
final class MCPControlRouterTests: XCTestCase {
    private var model: FakeAppModel!
    private var router: ControlRequestRouter!

    override func setUp() async throws {
        model = FakeAppModel()
        router = ControlRequestRouter(model: model)
    }

    private func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: 9, method: method, params: params))
    }

    private func result(_ method: String, _ params: [String: JSONValue] = [:],
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let response = await call(method, params)
        XCTAssertNil(response.error, "\(method): \(response.error?.message ?? "")", file: file, line: line)
        XCTAssertEqual(response.id, 9, file: file, line: line)
        return try XCTUnwrap(response.result, file: file, line: line)
    }

    private func error(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlError? {
        await call(method, params).error
    }

    func testDisplaysAndStatus() async throws {
        model.shown["1"] = model.library[0]
        let displays = try await result("list_displays")["displays"]?.arrayValue ?? []
        XCTAssertEqual(displays.map { $0["id"] }, ["1", "2"])
        XCTAssertEqual(displays.first?["wallpaper"]?["title"], "Rainy Window")
        XCTAssertEqual(displays.last?["wallpaper"], .null)

        let status = try await result("get_status")
        XCTAssertEqual(status["paused"], false)
        XCTAssertEqual(status["volume"], 0.8)
        XCTAssertEqual(status["muted"], false)
        XCTAssertEqual(status["playlist"]?["name"], "Evening")
        // A display a playback rule pauses doesn't play.
        XCTAssertEqual(status["displays"]?.arrayValue?.map { $0["playing"] }, [true, false])

        let one = try await result("get_status", ["display": "2"])
        XCTAssertEqual(one["displays"]?.arrayValue?.count, 1)
        let missing = await error("get_status", ["display": "9"])
        XCTAssertEqual(missing?.code, .notFound)
        XCTAssertTrue(missing?.message.contains("Studio Display") ?? false, "lists the displays there are")
    }

    func testListWallpapersFiltersAndPages() async throws {
        let all = try await result("list_wallpapers")
        XCTAssertEqual(all["total"], 3)
        XCTAssertEqual(all["wallpapers"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["City Lights", "Clock Page", "Rainy Window"])
        XCTAssertEqual(all["wallpapers"]?.arrayValue?.first?["workshop_id"], "200")
        XCTAssertEqual(all["wallpapers"]?.arrayValue?.first?["folder"], "/library/200")

        let scenes = try await result("list_wallpapers", ["type": "scene"])
        XCTAssertEqual(scenes["wallpapers"]?.arrayValue?.map { $0["id"] }, ["100"])
        let tagged = try await result("list_wallpapers", ["tags": ["relaxing", "nature"]])
        XCTAssertEqual(tagged["total"], 1)
        let query = try await result("list_wallpapers", ["query": "clock"])
        XCTAssertEqual(query["wallpapers"]?.arrayValue?.map { $0["id"] }, ["my-page"])
        let page = try await result("list_wallpapers", ["limit": 1, "offset": 1])
        XCTAssertEqual(page["total"], 3)
        XCTAssertEqual(page["wallpapers"]?.arrayValue?.map { $0["id"] }, ["my-page"])

        let bad = await error("list_wallpapers", ["limit": "ten"])
        XCTAssertEqual(bad?.code, .invalidParams)
    }

    func testGetWallpaperByIdWorkshopIdOrPath() async throws {
        let byID = try await result("get_wallpaper", ["id": "100"])
        XCTAssertEqual(byID["wallpaper"]?["title"], "Rainy Window")
        XCTAssertEqual(byID["wallpaper"]?["description"], "About Rainy Window")
        let properties = byID["wallpaper"]?["properties"]?.arrayValue ?? []
        XCTAssertEqual(properties.map { $0["key"] }, ["speed", "rain", "mode"])
        XCTAssertEqual(properties.first?["max"], 2)
        XCTAssertEqual(properties.last?["options"]?.arrayValue?.count, 2)

        let byPath = try await result("get_wallpaper", ["id": "/library/my-page"])
        XCTAssertEqual(byPath["wallpaper"]?["id"], "my-page")
        let missing = await error("get_wallpaper", ["id": "nope"])
        XCTAssertEqual(missing?.code, .notFound)
        let noID = await error("get_wallpaper")
        XCTAssertEqual(noID?.code, .invalidParams)
    }

    func testSetWallpaperOnEveryShownDisplayOrOne() async throws {
        model.displayList[1].isEnabled = false
        let everywhere = try await result("set_wallpaper", ["id": "100"])
        XCTAssertEqual(everywhere["displays"], ["1"], "displays without wallpapers are left alone")
        let one = try await result("set_wallpaper", ["id": "200", "display": "2"])
        XCTAssertEqual(one["displays"], ["2"])
        XCTAssertEqual(model.setCalls.map(\.0), ["100", "200"])

        let refused = await error("set_wallpaper", ["id": "my-page"])
        XCTAssertEqual(refused?.code, .refused)
    }

    func testPlaybackAndVolume() async throws {
        var states: [JSONValue?] = []
        for method in ["pause", "toggle_playback", "toggle_playback", "resume"] {
            states.append(try await result(method)["paused"])
        }
        XCTAssertEqual(states, [true, false, true, false])

        let volume = try await result("set_volume", ["level": 0.25])
        XCTAssertEqual(volume["volume"], 0.25)
        let muted = try await result("set_muted", ["muted": true])
        XCTAssertEqual(muted["muted"], true)
        XCTAssertEqual(muted["volume"], 0)
        let outOfRange = await error("set_volume", ["level": 3])
        XCTAssertEqual(outOfRange?.code, .invalidParams)
    }

    func testStopAndResume() async throws {
        let stopped = try await result("stop")
        XCTAssertEqual(stopped["stopped"], true)
        XCTAssertEqual(stopped["paused"], false)
        let status = try await result("get_status")
        XCTAssertEqual(status["stopped"], true)
        XCTAssertEqual(status["displays"]?.arrayValue?.first?["playing"], false, "nothing plays while stopped")

        let toggled = try await result("toggle_playback")
        XCTAssertEqual(toggled["stopped"], false, "the toggle resumes from a stop")
        XCTAssertEqual(toggled["paused"], false)

        _ = try await result("pause")
        _ = try await result("stop")
        let resumed = try await result("resume")
        XCTAssertEqual(resumed["stopped"], false, "resume ends a stop")
        XCTAssertEqual(resumed["paused"], false, "and a pause")
    }

    func testUserPropertiesAreCheckedAgainstTheirType() async throws {
        let set = try await result("set_user_property", ["id": "100", "key": "speed", "value": 1.5])
        XCTAssertEqual(set["value"], "1.5")
        _ = try await result("set_user_property", ["id": "100", "key": "rain", "value": false])
        // A combo takes an option's value, or its label.
        _ = try await result("set_user_property", ["id": "100", "key": "mode", "value": "Storm"])
        XCTAssertEqual(model.propertyCalls.map(\.0), ["speed", "rain", "mode"])
        XCTAssertEqual(model.propertyCalls.map(\.1), ["1.5", "false", "b"])

        let tooFast = await error("set_user_property", ["id": "100", "key": "speed", "value": 5])
        XCTAssertEqual(tooFast?.code, .invalidParams)
        XCTAssertTrue(tooFast?.message.contains("from 0 to 2") ?? false, tooFast?.message ?? "")
        let notAnOption = await error("set_user_property", ["id": "100", "key": "mode", "value": "c"])
        XCTAssertTrue(notAnOption?.message.contains("\"b\" (Storm)") ?? false, notAnOption?.message ?? "")
        let unknown = await error("set_user_property", ["id": "100", "key": "colour", "value": "1 0 0"])
        XCTAssertEqual(unknown?.code, .notFound)
        XCTAssertTrue(unknown?.message.contains("mode, rain, speed") ?? false, unknown?.message ?? "")
        XCTAssertEqual(model.propertyCalls.count, 3, "nothing invalid reaches the app")
    }

    func testPlaylistsAndStepping() async throws {
        let playlists = try await result("list_playlists")["playlists"]?.arrayValue ?? []
        XCTAssertEqual(playlists.first?["name"], "Evening")
        XCTAssertEqual(playlists.first?["wallpapers"]?.arrayValue?.count, 2)

        let played = try await result("play_playlist", ["name": "evening", "display": "2"])
        XCTAssertEqual(played["playlist"], "Evening")
        XCTAssertEqual(model.playedPlaylists.first?.1, ["2"])
        let missing = await error("play_playlist", ["name": "Morning"])
        XCTAssertEqual(missing?.code, .notFound)
        XCTAssertTrue(missing?.message.contains("\"Evening\"") ?? false)

        let next = try await result("next_wallpaper", ["display": "1"])
        XCTAssertEqual(next["displays"]?.arrayValue?.first?["wallpaper"]?["id"], "200")
        let previous = try await result("previous_wallpaper")
        XCTAssertEqual(previous["displays"]?.arrayValue?.count, 2)
    }

    func testEditorsImportAndSnapshot() async throws {
        let opened = try await result("open_editor", ["id": "100", "editor": "wallpaper"])
        XCTAssertEqual(opened["editor"], "wallpaper")
        XCTAssertEqual(model.openedEditors.first?.0, .wallpaper)
        let video = await error("open_editor", ["id": "200", "editor": "scene"])
        XCTAssertEqual(video?.code, .unsupported)
        let badEditor = await error("open_editor", ["id": "100", "editor": "code"])
        XCTAssertEqual(badEditor?.code, .invalidParams)

        let imported = try await result("import_wallpaper", ["path": "/"])
        XCTAssertEqual(imported["imported"]?.arrayValue?.first?["id"], "100")
        XCTAssertEqual(imported["skipped"]?.arrayValue?.first?["path"], "/")
        let relative = await error("import_wallpaper", ["path": "relative/folder"])
        XCTAssertEqual(relative?.code, .invalidParams)
        let nowhere = await error("import_wallpaper", ["path": .string("/no/such/folder-\(UUID().uuidString)")])
        XCTAssertEqual(nowhere?.code, .notFound)

        let picture = try await result("snapshot")
        XCTAssertEqual(picture["display"], "1", "the main display by default")
        XCTAssertEqual(picture["png_base64"], .string(Data([1, 2, 3]).base64EncodedString()))
    }

    func testUnknownMethod() async {
        let unknown = await error("delete_wallpaper", ["id": "100"])
        XCTAssertEqual(unknown?.code, .unknownMethod)
    }

    /// owe-mcp finds the socket where the app puts it, for the user's app and an isolated copy.
    func testSocketLocationMatchesTheAppsSupportFolder() {
        for tag in [nil, "tests", "shots"] as [String?] {
            XCTAssertEqual(ControlSocketLocation.supportDirectory(isolationTag: tag).standardizedFileURL,
                           AppStorageLocation(isolationTag: tag).supportDirectory.standardizedFileURL)
        }
    }
}
