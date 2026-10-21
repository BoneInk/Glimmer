import XCTest
import OWEControlProtocol
@testable import OpenWallpaperEngine

/// A model of the app for the library requests: two displays, three wallpapers, one playlist.
@MainActor
private final class LibraryFakeAppModel: ControlAppModel {
    var displayList = [
        ControlDisplay(id: "1", name: "Built-in Display", isMain: true, isEnabled: true, width: 1512, height: 982, scale: 2, rule: "run"),
        ControlDisplay(id: "2", name: "Studio Display", isMain: false, isEnabled: true, width: 2560, height: 1440, scale: 2, rule: "run"),
    ]
    let library: [ControlWallpaper] = [
        LibraryFakeAppModel.wallpaper("100", "Rainy Window", "scene"),
        LibraryFakeAppModel.wallpaper("200", "City Lights", "video"),
        LibraryFakeAppModel.wallpaper("300", "Forest", "scene"),
    ]
    var playlistList: [ControlPlaylist] = []

    static func wallpaper(_ id: String, _ title: String, _ type: String) -> ControlWallpaper {
        ControlWallpaper(id: id, title: title, type: type, tags: [], folder: URL(fileURLWithPath: "/library/\(id)"),
                         workshopID: id, description: nil, contentRating: "Everyone")
    }

    init() {
        playlistList = [ControlPlaylist(id: UUID(), name: "Evening", wallpapers: [library[0], library[1]], duration: 300,
                                        isActive: true, isRotating: false, shuffles: false, displays: ["1"])]
    }

    func displays() -> [ControlDisplay] { displayList }
    func wallpapers() -> [ControlWallpaper] { library }
    func wallpaper(onDisplay id: String) -> ControlWallpaper? { id == "1" ? library[0] : nil }
    func properties(of wallpaper: ControlWallpaper) -> [ControlUserProperty] { [] }
    var playback: ControlPlayback { ControlPlayback(paused: false, volume: 1) }
    func playlists() -> [ControlPlaylist] { playlistList }
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
    func snapshot(display: String) async throws -> ControlSnapshot {
        throw ControlError(.unavailable, "no snapshot")
    }
}

/// The library service over the fake model: changes its playlists and displays, records the rest.
@MainActor
private final class FakeLibraryService: LibraryControlService {
    let model: LibraryFakeAppModel
    var videoEnds: [UUID: Bool] = [:]
    var playlistSettings: [UUID: ControlPlaylistSettings] = [:]
    var favorites: Set<String> = []
    var deleted: [(String, Bool)] = []
    var deleteFailure: ControlError?
    var moves: [Int] = []
    var values: [String: JSONValue] = ["fps": 30, "reflections": true, "shadows": "medium", "quality_preset": .null]
    var setCalls: [(String, JSONValue)] = []

    init(model: LibraryFakeAppModel) { self.model = model }

    private func index(_ id: UUID) throws -> Int {
        guard let index = model.playlistList.firstIndex(where: { $0.id == id }) else { throw ControlError(.notFound, "gone") }
        return index
    }

    func createPlaylist(named name: String, wallpapers: [ControlWallpaper]) throws -> UUID {
        for index in model.playlistList.indices { model.playlistList[index].isActive = false }
        let playlist = ControlPlaylist(id: UUID(), name: name, wallpapers: wallpapers, duration: 300, isActive: true,
                                       isRotating: false, shuffles: false, displays: [])
        model.playlistList.append(playlist)
        return playlist.id
    }

    func changesWhenVideoEnds(playlist id: UUID) -> Bool { videoEnds[id] ?? false }
    func setDuration(_ seconds: Double, playlist id: UUID) throws { model.playlistList[try index(id)].duration = seconds }
    func setChangesWhenVideoEnds(_ enabled: Bool, playlist id: UUID) throws { videoEnds[id] = enabled }
    func playlistSettings(playlist id: UUID) -> ControlPlaylistSettings { playlistSettings[id] ?? ControlPlaylistSettings() }
    func setPlaylistSettings(_ settings: ControlPlaylistSettings, playlist id: UUID) throws {
        _ = try index(id)
        playlistSettings[id] = settings
    }

    func add(_ wallpapers: [ControlWallpaper], toPlaylist id: UUID) throws {
        model.playlistList[try index(id)].wallpapers += wallpapers
    }

    func remove(_ wallpapers: [ControlWallpaper], fromPlaylist id: UUID) throws {
        let folders = Set(wallpapers.map(\.folder))
        model.playlistList[try index(id)].wallpapers.removeAll { folders.contains($0.folder) }
    }

    func moveOnePlace(_ wallpaper: ControlWallpaper, by step: Int, inPlaylist id: UUID) throws {
        moves.append(step)
        let playlist = try index(id)
        guard let from = model.playlistList[playlist].wallpapers.firstIndex(where: { $0.folder == wallpaper.folder }) else { return }
        model.playlistList[playlist].wallpapers.swapAt(from, from + step)
    }

    func deletePlaylist(_ id: UUID) throws { model.playlistList.remove(at: try index(id)) }

    func isFavorite(_ wallpaper: ControlWallpaper) -> Bool { favorites.contains(wallpaper.id) }

    func setFavorite(_ favorite: Bool, for wallpaper: ControlWallpaper) throws {
        if favorite { favorites.insert(wallpaper.id) } else { favorites.remove(wallpaper.id) }
    }

    func delete(_ wallpaper: ControlWallpaper, toTrash: Bool) async throws {
        if let deleteFailure { throw deleteFailure }
        deleted.append((wallpaper.id, toTrash))
    }

    var installedFolders = InstalledFolderTree()
    func changeInstalledFolders(_ change: (inout InstalledFolderTree) -> Void) { change(&installedFolders) }
    func folderKey(of wallpaper: ControlWallpaper) -> String {
        wallpaper.workshopID.map { "workshop-\($0)" } ?? wallpaper.folder.path
    }

    func setDisplay(_ id: String, enabled: Bool) {
        if let index = model.displayList.firstIndex(where: { $0.id == id }) { model.displayList[index].isEnabled = enabled }
    }

    func value(of setting: LibrarySetting) -> JSONValue { values[setting.key] ?? .null }

    func set(_ value: JSONValue, of setting: LibrarySetting) throws {
        setCalls.append((setting.key, value))
        if case .action = setting.kind { return }
        values[setting.key] = value
    }

    var clearCachesCalls = 0

    func cacheSizes() async -> [ControlCacheSize] {
        [ControlCacheSize(id: "textures", bytes: 1_000_000), ControlCacheSize(id: "metal_shader_cache", bytes: 500)]
    }

    func clearCaches() async -> ControlCacheClearResult {
        clearCachesCalls += 1
        return ControlCacheClearResult(removedEntries: 3, removedBytes: 4096, metalCacheResetRequested: true)
    }

    func plugins() -> [ControlPluginStatus] {
        [
            ControlPluginStatus(id: "screen_saver", name: "Screen Saver", installed: true, enabled: true, version: nil,
                                updateAvailable: false, detail: nil),
            ControlPluginStatus(id: "mcp_server", name: "MCP Server", installed: true, enabled: nil, version: "1.0.0",
                                updateAvailable: false, detail: nil),
        ]
    }
}

@MainActor
final class MCPLibraryRouterTests: XCTestCase {
    private var model: LibraryFakeAppModel!
    private var service: FakeLibraryService!
    private var router: ControlRequestRouter!

    override func setUp() async throws {
        model = LibraryFakeAppModel()
        service = FakeLibraryService(model: model)
        router = ControlRequestRouter(model: model, groups: [LibraryControlRequests(service: service)])
    }

    private func result(_ method: String, _ params: [String: JSONValue] = [:],
                        file: StaticString = #filePath, line: UInt = #line) async throws -> JSONValue {
        let response = await router.handle(ControlRequest(id: 4, method: method, params: params))
        XCTAssertNil(response.error, "\(method): \(response.error?.message ?? "")", file: file, line: line)
        let result = try XCTUnwrap(response.result, file: file, line: line)
        XCTAssertNotNil(result["message"]?.stringValue, "\(method) says what happened", file: file, line: line)
        return result
    }

    private func error(_ method: String, _ params: [String: JSONValue] = [:]) async -> ControlError? {
        await router.handle(ControlRequest(id: 4, method: method, params: params)).error
    }

    private func titles(_ result: JSONValue) -> [String] {
        result["playlist"]?["wallpapers"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
    }

    // MARK: - Playlists

    func testCreatePlaylist() async throws {
        let created = try await result("playlist_create", ["name": "  Night  ", "wallpaper_ids": ["300", "100", "300"]])
        XCTAssertEqual(created["playlist"]?["name"], "Night")
        XCTAssertEqual(titles(created), ["Forest", "Rainy Window"], "in order, without repeats")
        XCTAssertEqual(created["playlist"]?["active"], true)
        XCTAssertEqual(created["playlist"]?["duration_seconds"], 300)
        XCTAssertEqual(model.playlistList.count, 2)

        let taken = await error("playlist_create", ["name": "evening"])
        XCTAssertEqual(taken?.code, .refused)
        XCTAssertTrue(taken?.message.contains("Evening") ?? false)
        let unknown = await error("playlist_create", ["name": "Other", "wallpaper_ids": ["999"]])
        XCTAssertEqual(unknown?.code, .notFound)
        XCTAssertEqual(model.playlistList.count, 2, "nothing is created when a wallpaper is missing")
        let blank = await error("playlist_create", ["name": "   "])
        XCTAssertEqual(blank?.code, .invalidParams)
    }

    func testUpdatePlaylistSnapsDurationAndSetsVideoEnds() async throws {
        let updated = try await result("playlist_update", ["playlist": "EVENING", "duration_seconds": 97, "change_when_video_ends": true])
        // 97 s snaps to the view's 15 s steps from a minute on.
        XCTAssertEqual(updated["playlist"]?["duration_seconds"], 90)
        XCTAssertEqual(updated["playlist"]?["change_when_video_ends"], true)

        let byID = try await result("playlist_update", ["playlist": .string(model.playlistList[0].id.uuidString), "duration_seconds": 12])
        XCTAssertEqual(byID["playlist"]?["duration_seconds"], 10)

        let nothing = await error("playlist_update", ["playlist": "Evening"])
        XCTAssertEqual(nothing?.code, .invalidParams)
        XCTAssertTrue(nothing?.message.contains("rename") ?? false, "says a name can't be changed")
        let tooLong = await error("playlist_update", ["playlist": "Evening", "duration_seconds": 4000])
        XCTAssertEqual(tooLong?.code, .invalidParams)
        let missing = await error("playlist_update", ["playlist": "Morning", "duration_seconds": 60])
        XCTAssertEqual(missing?.code, .notFound)
    }

    func testUpdatePlaylistSetsWhenItChangesAndItsTransition() async throws {
        let updated = try await result("playlist_update", [
            "playlist": "Evening", "change_wallpaper": "daytime", "daytime_ends": ["07:30", ""],
            "transition": "random", "transition_pool": ["door", "zoom", "door"], "transition_time_ms": 1234,
        ])
        let settings = updated["playlist"]?["settings"]
        XCTAssertEqual(settings?["change_wallpaper"], "daytime")
        XCTAssertEqual(settings?["transition"], "random")
        XCTAssertEqual(settings?["transition_pool"], ["door", "zoom"])
        XCTAssertEqual(settings?["transition_time_ms"], 1250, "snapped to the slider's 50 ms")
        XCTAssertEqual(settings?["daytime_slots"]?.arrayValue?[0]["end"], "07:30")
        XCTAssertEqual(settings?["daytime_slots"]?.arrayValue?[1]["start"], "07:30")
        XCTAssertEqual(settings?["daytime_slots"]?.arrayValue?[1]["end"], "24:00")
        let stored = service.playlistSettings(playlist: model.playlistList[0].id)
        XCTAssertEqual(stored.timing, .daytime)
        XCTAssertEqual(stored.transition.pool, [.door, .zoom])
        XCTAssertEqual(stored.daytimeEnds, [7.5 / 24, nil])

        let options = try await result("playlist_update", [
            "playlist": "Evening", "change_wallpaper": "timer", "begin_with_first_wallpaper": true,
            "first_wallpaper_at_startup_only": true, "change_while_paused": true, "transition": "glass_shatter",
        ])
        XCTAssertEqual(options["playlist"]?["settings"]?["first_wallpaper_at_startup_only"], true)
        XCTAssertEqual(options["playlist"]?["settings"]?["transition"], "glass_shatter")

        let week = try await result("playlist_update", ["playlist": "Evening", "change_wallpaper": "dayofweek"])
        XCTAssertEqual(week["playlist"]?["settings"]?["weekdays"]?.arrayValue?.count, 2, "two wallpapers share the week")
    }

    func testUpdatePlaylistRefusesSettingsItCantKeep() async throws {
        let badTiming = await error("playlist_update", ["playlist": "Evening", "change_wallpaper": "hourly"])
        XCTAssertEqual(badTiming?.code, .invalidParams)
        let badKind = await error("playlist_update", ["playlist": "Evening", "transition_pool": ["wobble"]])
        XCTAssertEqual(badKind?.code, .invalidParams)
        let backwards = await error("playlist_update", ["playlist": "Evening", "daytime_ends": ["25:00", ""]])
        XCTAssertEqual(backwards?.code, .invalidParams)
        let count = await error("playlist_update", ["playlist": "Evening", "daytime_ends": ["08:00"]])
        XCTAssertEqual(count?.code, .invalidParams, "one per wallpaper")
        let intro = await error("playlist_update", ["playlist": "Evening", "first_wallpaper_at_startup_only": true])
        XCTAssertEqual(intro?.code, .invalidParams, "needs begin_with_first_wallpaper")
    }

    func testEveryTransitionTheToolNamesIsOne() {
        XCTAssertEqual(ControlPlaylistOptions.transitionKinds.count, WallpaperTransitionKind.allCases.count)
        for kind in WallpaperTransitionKind.allCases {
            XCTAssertEqual(ControlPlaylistSettings.kind(named: ControlPlaylistSettings.name(of: kind)), kind)
        }
        for name in ControlPlaylistOptions.transitionChoices {
            XCTAssertNotNil(ControlPlaylistSettings.choice(named: name), name)
        }
        for name in ControlPlaylistOptions.timings {
            XCTAssertNotNil(ControlPlaylistSettings.timing(named: name), name)
        }
        XCTAssertEqual(ControlPlaylistOptions.timings.count, PlaylistTiming.allCases.count)
    }

    func testAddAndRemoveItems() async throws {
        let added = try await result("playlist_add_items", ["playlist": "Evening", "wallpaper_ids": ["300", "100"]])
        XCTAssertEqual(titles(added), ["Rainy Window", "City Lights", "Forest"], "one already there is left in place")
        XCTAssertTrue(added["message"]?.stringValue?.contains("1 already in it") ?? false)

        let removed = try await result("playlist_remove_items", ["playlist": "Evening", "wallpaper_ids": ["100", "200"]])
        XCTAssertEqual(titles(removed), ["Forest"])

        let notThere = await error("playlist_remove_items", ["playlist": "Evening", "wallpaper_ids": ["100"]])
        XCTAssertEqual(notThere?.code, .notFound)
        let empty = await error("playlist_add_items", ["playlist": "Evening", "wallpaper_ids": []])
        XCTAssertEqual(empty?.code, .invalidParams)
    }

    func testMoveItemOnePlaceAtATime() async throws {
        _ = try await result("playlist_add_items", ["playlist": "Evening", "wallpaper_ids": ["300"]])
        let moved = try await result("playlist_move_item", ["playlist": "Evening", "wallpaper_id": "300", "offset": -2])
        XCTAssertEqual(titles(moved), ["Forest", "Rainy Window", "City Lights"])
        XCTAssertEqual(service.moves, [-1, -1], "as the view's Move Up button, twice")

        let outOfRange = await error("playlist_move_item", ["playlist": "Evening", "wallpaper_id": "300", "offset": -1])
        XCTAssertEqual(outOfRange?.code, .invalidParams)
        let notThere = await error("playlist_move_item", ["playlist": "Evening", "wallpaper_id": "999", "offset": 1])
        XCTAssertEqual(notThere?.code, .notFound)
    }

    func testDeletePlaylistNeedsConfirmation() async throws {
        let unconfirmed = await error("playlist_delete", ["playlist": "Evening"])
        XCTAssertEqual(unconfirmed?.code, .refused)
        XCTAssertTrue(unconfirmed?.message.contains("confirm: true") ?? false)
        let declined = await error("playlist_delete", ["playlist": "Evening", "confirm": false])
        XCTAssertEqual(declined?.code, .refused)
        XCTAssertEqual(model.playlistList.count, 1)

        let deleted = try await result("playlist_delete", ["playlist": "Evening", "confirm": true])
        XCTAssertEqual(deleted["deleted"]?["name"], "Evening")
        XCTAssertTrue(model.playlistList.isEmpty)
    }

    // MARK: - Wallpapers

    func testSetFavorite() async throws {
        let on = try await result("wallpaper_set_favorite", ["id": "100", "favorite": true])
        XCTAssertEqual(on["favorite"], true)
        XCTAssertEqual(on["wallpaper"]?["title"], "Rainy Window")
        let again = try await result("wallpaper_set_favorite", ["id": "100", "favorite": true])
        XCTAssertEqual(again["message"], "\"Rainy Window\" was a favourite already.")
        let off = try await result("wallpaper_set_favorite", ["id": "100", "favorite": false])
        XCTAssertEqual(off["favorite"], false)
        let missing = await error("wallpaper_set_favorite", ["id": "100"])
        XCTAssertEqual(missing?.code, .invalidParams)
    }

    func testDeleteWallpaper() async throws {
        let unconfirmed = await error("wallpaper_delete", ["id": "200"])
        XCTAssertEqual(unconfirmed?.code, .refused)
        XCTAssertTrue(service.deleted.isEmpty)

        let trashed = try await result("wallpaper_delete", ["id": "200", "confirm": true])
        XCTAssertEqual(trashed["to_trash"], true, "the Trash by default")
        XCTAssertEqual(trashed["deleted"]?["id"], "200")
        _ = try await result("wallpaper_delete", ["id": "300", "confirm": true, "to_trash": false])
        XCTAssertEqual(service.deleted.map(\.0), ["200", "300"])
        XCTAssertEqual(service.deleted.map(\.1), [true, false])

        service.deleteFailure = ControlError(.failed, "disk")
        let failed = await error("wallpaper_delete", ["id": "100", "confirm": true])
        XCTAssertEqual(failed?.code, .failed)
        let unknown = await error("wallpaper_delete", ["id": "999", "confirm": true])
        XCTAssertEqual(unknown?.code, .notFound)
    }

    // MARK: - Installed folders

    func testFolderCreateListAndMove() async throws {
        let games = try await result("folder_create", ["name": "Games"])
        let gamesID = try XCTUnwrap(games["folder"]?["id"]?.stringValue)
        let retro = try await result("folder_create", ["name": "Retro", "parent": "games"])
        XCTAssertEqual(retro["folder"]?["path"], "Games / Retro", "the parent by name, ignoring case")
        let missing = await error("folder_create", ["name": "X", "parent": "Nope"])
        XCTAssertEqual(missing?.code, .notFound)

        _ = try await result("wallpaper_move_to_folder", ["wallpaper_ids": ["100", "200"], "folder": "Games/Retro"])
        _ = try await result("wallpaper_move_to_folder", ["wallpaper_ids": ["200"], "folder": .string(gamesID)])
        let listed = try await result("folders_list")
        XCTAssertEqual(listed["top_level_wallpaper_count"], 1, "Forest stays at the top level")
        let top = try XCTUnwrap(listed["folders"]?.arrayValue?.first)
        XCTAssertEqual(top["name"], "Games")
        XCTAssertEqual(top["wallpaper_ids"], ["200"], "a wallpaper is in one folder: moving it took it out of Retro")
        XCTAssertEqual(top["subfolders"]?.arrayValue?.first?["wallpaper_ids"], ["100"])

        _ = try await result("wallpaper_move_to_folder", ["wallpaper_ids": ["100", "200"]])
        XCTAssertTrue(service.installedFolders.filedKeys.isEmpty, "no folder is the top level")
        XCTAssertEqual(service.installedFolders.allFolders().count, 2, "the folders stay")
        let unknown = await error("wallpaper_move_to_folder", ["wallpaper_ids": ["999"]])
        XCTAssertEqual(unknown?.code, .notFound)
    }

    // MARK: - Displays

    func testDisplaySettings() async throws {
        let all = try await result("display_settings_get")
        XCTAssertEqual(all["displays"]?.arrayValue?.map { $0["id"] }, ["1", "2"])
        XCTAssertEqual(all["displays"]?.arrayValue?.first?["wallpaper"]?["title"], "Rainy Window")

        let off = try await result("display_settings_set", ["display": "Studio Display", "enabled": false])
        XCTAssertEqual(off["display"]?["enabled"], false)
        XCTAssertEqual(model.displayList[1].isEnabled, false)
        let one = try await result("display_settings_get", ["display": "2"])
        XCTAssertEqual(one["displays"]?.arrayValue?.count, 1)

        let missing = await error("display_settings_set", ["display": "9", "enabled": true])
        XCTAssertEqual(missing?.code, .notFound)
        let noValue = await error("display_settings_set", ["display": "1"])
        XCTAssertEqual(noValue?.code, .invalidParams)
    }

    // MARK: - Settings

    func testSettingsGetListsTheAllowList() async throws {
        let all = try await result("settings_get")
        let settings = all["settings"]?.arrayValue ?? []
        XCTAssertEqual(settings.count, LibrarySetting.all.count)
        let fps = try XCTUnwrap(settings.first { $0["key"] == "fps" })
        XCTAssertEqual(fps["value"], 30)
        XCTAssertEqual(fps["type"], "integer")
        XCTAssertEqual(fps["maximum"], 240)
        let shadows = try XCTUnwrap(settings.first { $0["key"] == "shadows" })
        XCTAssertEqual(shadows["values"]?.arrayValue?.count, 5)
        XCTAssertFalse(settings.contains { $0["key"] == "auto_start" || $0["key"] == "language" })

        let some = try await result("settings_get", ["keys": ["reflections"]])
        XCTAssertEqual(some["message"], "reflections is on.")
        let refused = await error("settings_get", ["keys": ["language"]])
        XCTAssertEqual(refused?.code, .refused)
    }

    func testSettingsSetChecksValues() async throws {
        let fps = try await result("settings_set", ["key": "fps", "value": "60"])
        XCTAssertEqual(fps["setting"]?["value"], 60)
        let shadows = try await result("settings_set", ["key": "Shadows", "value": "HIGH"])
        XCTAssertEqual(shadows["setting"]?["value"], "high")
        _ = try await result("settings_set", ["key": "reflections", "value": false])
        _ = try await result("settings_set", ["key": "quality_preset", "value": "ultra"])
        XCTAssertEqual(service.setCalls.map(\.0), ["fps", "shadows", "reflections", "quality_preset"])
        XCTAssertEqual(service.setCalls.map(\.1), [60, "high", false, "ultra"])

        let outOfRange = await error("settings_set", ["key": "fps", "value": "500"])
        XCTAssertEqual(outOfRange?.code, .invalidParams)
        let fraction = await error("settings_set", ["key": "fps", "value": "30.5"])
        XCTAssertEqual(fraction?.code, .invalidParams)
        let badChoice = await error("settings_set", ["key": "shadows", "value": "extreme"])
        XCTAssertEqual(badChoice?.code, .invalidParams)
        let badBool = await error("settings_set", ["key": "reflections", "value": "maybe"])
        XCTAssertEqual(badBool?.code, .invalidParams)
        XCTAssertEqual(service.setCalls.count, 4, "nothing is set when the value doesn't fit")
    }

    func testSettingsSetRefusesSecurityAndSystemSettings() async {
        for key in ["auto_start", "launch_at_login", "language", "log_level", "restart_after_crashing", "screen_saver",
                    "lock_screen_picture", "web_wallpaper_trust", "update_channel", "mcp_server"] {
            let refused = await error("settings_set", ["key": .string(key), "value": "true"])
            XCTAssertEqual(refused?.code, .refused, key)
            XCTAssertFalse(refused?.message.isEmpty ?? true, key)
        }
        let unknown = await error("settings_set", ["key": "warp_speed", "value": "true"])
        XCTAssertEqual(unknown?.code, .notFound)
        XCTAssertTrue(unknown?.message.contains("fps") ?? false, "lists the keys there are")
        XCTAssertTrue(service.setCalls.isEmpty)
    }

    // MARK: - Plugins

    func testPluginStatus() async throws {
        let status = try await result("plugin_status")
        let plugins = status["plugins"]?.arrayValue ?? []
        XCTAssertEqual(plugins.map { $0["id"] }, ["screen_saver", "mcp_server"])
        XCTAssertEqual(plugins.first?["enabled"], true)
        XCTAssertEqual(plugins.last?["version"], "1.0.0")
        XCTAssertEqual(plugins.last?["enabled"], .null)
    }

    // MARK: - Caches

    func testCachesGetAddsUpEachCache() async throws {
        let caches = try await result("caches_get")
        XCTAssertEqual(caches["total_bytes"], 1_000_500)
        XCTAssertEqual(caches["caches"]?.arrayValue?.map { $0["id"] }, ["textures", "metal_shader_cache"])
    }

    func testCachesClearNeedsConfirmation() async throws {
        let refused = await error("caches_clear", [:])
        XCTAssertEqual(refused?.code, .refused)
        XCTAssertEqual(service.clearCachesCalls, 0)
        let cleared = try await result("caches_clear", ["confirm": true])
        XCTAssertEqual(service.clearCachesCalls, 1)
        XCTAssertEqual(cleared["removed_entries"], 3)
        XCTAssertEqual(cleared["metal_shader_cache_cleared_at_next_launch"], true)
    }
}
