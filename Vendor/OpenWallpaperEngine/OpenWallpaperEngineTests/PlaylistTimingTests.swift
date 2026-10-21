import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// When a playlist changes wallpaper (WE's "Change wallpaper") and its options: one step per
/// login, the first wallpaper at startup, the intro left out of the rotation, the timer standing
/// still while paused, the scheduled slot, and the settings as WE's dialog saves them.
@MainActor
final class PlaylistTimingTests: XCTestCase {
    private func wallpaper(_ name: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-timing/\(name)"))
    }

    private func model(items count: Int = 3, showing shown: Int? = nil,
                       configure: (inout WallpaperPlaylist) -> Void = { _ in }) -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        var playlist = WallpaperPlaylist(name: "p", items: (0..<count).map { WallpaperPlaylistItem(wallpaper: wallpaper("p\($0)")) })
        configure(&playlist)
        model.playlists = [playlist]
        model.activePlaylistID = playlist.id
        model.setWallpaper(shown.map { wallpaper("p\($0)") } ?? wallpaper("library"), for: model.selectedScreenIds)
        return model
    }

    private var shown: (WallpaperViewModel) -> String { { $0.currentWallpaper.project.title } }

    // MARK: - At launch

    func testWhenLoggingInMovesOnOneWallpaperPerLaunch() {
        let model = model(showing: 1) { $0.timing = .logon }
        model.playlistEnabled = true
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p2")
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p0")
    }

    func testAlwaysBeginWithTheFirstWallpaper() {
        let model = model(showing: 2) { $0.beginsWithFirst = true }
        model.playlistEnabled = true
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p0")
    }

    func testWithoutBeginWithFirstATimerPlaylistResumes() {
        let model = model(showing: 2)
        model.playlistEnabled = true
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p2")
    }

    func testTheTimersOptionsApplyOnlyOnATimer() {
        let model = model(showing: 2) { $0.timing = .never; $0.beginsWithFirst = true }
        model.playlistEnabled = true
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p2")
        var playlist = WallpaperPlaylist(name: "p", items: [])
        playlist.timing = .daytime
        playlist.beginsWithFirst = true
        playlist.playsFirstAtStartupOnly = true
        XCTAssertFalse(playlist.leavesOutFirstItem)
    }

    func testAPlaylistThatDoesntRotateDoesntStart() {
        let model = model(showing: 1) { $0.timing = .logon }
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p1")
    }

    // MARK: - The intro

    func testTheFirstWallpaperPlaysAtStartupOnly() {
        let model = model(items: 3, showing: 2) { $0.beginsWithFirst = true; $0.playsFirstAtStartupOnly = true }
        model.playlistEnabled = true
        model.startPlaylistAtLaunch()
        XCTAssertEqual(shown(model), "p0")
        model.nextPlaylistWallpaper()
        XCTAssertEqual(shown(model), "p1")
        model.nextPlaylistWallpaper()
        XCTAssertEqual(shown(model), "p2")
        model.nextPlaylistWallpaper()
        XCTAssertEqual(shown(model), "p1", "the rotation leaves the first wallpaper out")
        model.previousPlaylistWallpaper()
        XCTAssertEqual(shown(model), "p2", "Previous passes over it too")
    }

    func testTheIntroNeedsBeginWithFirst() {
        var playlist = WallpaperPlaylist(name: "p", items: (0..<3).map { WallpaperPlaylistItem(wallpaper: wallpaper("p\($0)")) })
        playlist.playsFirstAtStartupOnly = true
        playlist.normalizeSettings()
        XCTAssertFalse(playlist.playsFirstAtStartupOnly)
        XCTAssertFalse(playlist.leavesOutFirstItem)
    }

    // MARK: - Paused

    func testTheCountdownStandsStillWhilePaused() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        var countdown = PlaylistCountdown(duration: 60)
        XCTAssertNil(countdown.fireDate)
        countdown.run(at: start)
        XCTAssertEqual(countdown.fireDate, start.addingTimeInterval(60))
        countdown.pause(at: start.addingTimeInterval(20))
        XCTAssertNil(countdown.fireDate)
        XCTAssertEqual(countdown.remaining, 40)
        let resumed = start.addingTimeInterval(500)
        countdown.run(at: resumed)
        XCTAssertEqual(countdown.fireDate, resumed.addingTimeInterval(40))
        countdown.pause(at: resumed.addingTimeInterval(100))
        XCTAssertEqual(countdown.remaining, 0)
    }

    func testPauseIsTheStatusMenusPauseOrEveryDisplayPaused() {
        let model = model(showing: 0)
        XCTAssertFalse(model.isPlaylistPaused)
        model.playRate = 0
        XCTAssertTrue(model.isPlaylistPaused)
        model.playRate = 1
        XCTAssertFalse(model.isPlaylistPaused)
    }

    // MARK: - Scheduled

    func testATimeOfDayPlaylistShowsTheSlotsWallpaper() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        var now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9)) ?? Date()
        let model = model(items: 3, showing: 0) { playlist in
            playlist.timing = .daytime
            playlist.items[0].daytimeEnd = 8.0 / 24
            playlist.items[1].daytimeEnd = 20.0 / 24
        }
        model.playlistClock = { now }
        model.playlistCalendar = { calendar }
        model.playlistEnabled = true
        XCTAssertEqual(shown(model), "p1", "09:00 is the second slot")
        // Next stays until the slot changes.
        model.nextPlaylistWallpaper()
        XCTAssertEqual(shown(model), "p2")
        model.applyPlaylistSchedule()
        XCTAssertEqual(shown(model), "p2")
        now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 21)) ?? Date()
        model.applyPlaylistSchedule()
        XCTAssertEqual(shown(model), "p2")
        now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 2, hour: 0, minute: 1)) ?? Date()
        model.applyPlaylistSchedule()
        XCTAssertEqual(shown(model), "p0", "after midnight, the first slot")
    }

    func testWakingLooksAtTheSlotAgain() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        var now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 7, minute: 59)) ?? Date()
        let model = model(items: 3, showing: 2) { playlist in
            playlist.timing = .daytime
            playlist.items[0].daytimeEnd = 8.0 / 24
            playlist.items[1].daytimeEnd = 20.0 / 24
        }
        model.playlistClock = { now }
        model.playlistCalendar = { calendar }
        model.playlistEnabled = true
        XCTAssertEqual(shown(model), "p0")
        // Asleep across 08:00: the slot's timer never fired. Waking looks again.
        let observer = PlaylistClockObserver { [weak model] in model?.applyPlaylistSchedule() }
        now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9)) ?? Date()
        XCTAssertEqual(shown(model), "p0")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(shown(model), "p1", "09:00 after waking is the second slot")
        withExtendedLifetime(observer) {}
    }

    func testADayOfWeekPlaylistShowsTodaysWallpaper() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        calendar.firstWeekday = 2
        let wednesday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 3, hour: 12)) ?? Date()
        let model = model(items: 7, showing: 0) { $0.timing = .dayofweek }
        model.playlistClock = { wednesday }
        model.playlistCalendar = { calendar }
        model.playlistEnabled = true
        XCTAssertEqual(shown(model), "p2")
    }

    func testADayOfWeekPlaylistTakesSevenWallpapers() {
        let model = model(items: 7) { $0.timing = .dayofweek }
        model.addToPlaylist(wallpaper("eighth"))
        XCTAssertEqual(model.activePlaylist?.items.count, 7)
        model.updatePlaylistSettings { $0.timing = .timer }
        model.addToPlaylist(wallpaper("eighth"))
        XCTAssertEqual(model.activePlaylist?.items.count, 8)
        model.updatePlaylistSettings { $0.timing = .dayofweek }
        model.trimToDayOfWeekLimit()
        XCTAssertEqual(model.activePlaylist?.items.count, 7)
    }

    // MARK: - Settings

    func testEndsStayOnlyInATimeOfDayPlaylist() {
        let model = model(items: 3) { playlist in
            playlist.timing = .daytime
            playlist.items[0].daytimeEnd = 0.25
        }
        XCTAssertEqual(model.activePlaylist?.items[0].daytimeEnd, 0.25)
        model.updatePlaylistSettings { $0.timing = .timer }
        XCTAssertNil(model.activePlaylist?.items[0].daytimeEnd, "WE drops the ends outside Time of day")
    }

    func testSettingsAreStoredUnderWEsKeys() throws {
        var playlist = WallpaperPlaylist(name: "p", items: [WallpaperPlaylistItem(wallpaper: wallpaper("a")),
                                                            WallpaperPlaylistItem(wallpaper: wallpaper("b"))])
        playlist.timing = .daytime
        playlist.items[0].daytimeEnd = 0.5
        playlist.beginsWithFirst = true
        playlist.playsFirstAtStartupOnly = true
        playlist.changesWhilePaused = true
        playlist.transition = WallpaperTransitionSettings(choice: .random, pool: [.door, .zoom], milliseconds: 750)
        let data = try JSONEncoder().encode(playlist)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "daytime")
        XCTAssertEqual(json["beginfirst"] as? Bool, true)
        XCTAssertEqual(json["playintro"] as? Bool, true)
        XCTAssertEqual(json["updateonpause"] as? Bool, true)
        let transition = try XCTUnwrap(json["transition"] as? [String: Any])
        XCTAssertEqual(transition["transition"] as? String, "random")
        XCTAssertEqual(transition["transitionpool"] as? [String], ["11", "13"])
        XCTAssertEqual(transition["transitiontime"] as? Int, 750)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperPlaylist.self, from: data), playlist)
    }

    func testAPlaylistSavedBeforeTimingsRunsOnATimerWithoutTransition() throws {
        let saved = WallpaperPlaylist(name: "old", items: [WallpaperPlaylistItem(wallpaper: wallpaper("a"))])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for key in ["mode", "beginfirst", "playintro", "updateonpause", "transition"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(WallpaperPlaylist.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.timing, .timer)
        XCTAssertFalse(decoded.beginsWithFirst)
        XCTAssertEqual(decoded.transition, .unset)
        XCTAssertNil(decoded.transition.pick())
        XCTAssertEqual(WallpaperPlaylist(name: "new").transition, .playlistDefault)
    }
}
