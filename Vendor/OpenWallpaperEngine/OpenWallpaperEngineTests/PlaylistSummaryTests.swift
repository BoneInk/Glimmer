import XCTest
@testable import OpenWallpaperEngine

/// The Playlists tab's cover, item durations, round length and transition name, and the
/// drag-to-reorder and rename it does through the view model.
@MainActor
final class PlaylistSummaryTests: XCTestCase {
    private func wallpaper(_ name: String, preview: String = "preview.jpg") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: preview, title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-summary/\(name)"))
    }

    private func playlist(_ names: [String], configure: (inout WallpaperPlaylist) -> Void = { _ in }) -> WallpaperPlaylist {
        var playlist = WallpaperPlaylist(name: "p", items: names.map { WallpaperPlaylistItem(wallpaper: wallpaper($0)) })
        configure(&playlist)
        return playlist
    }

    // MARK: - Cover

    func testCoverTakesTheFirstFourPreviews() {
        let playlist = playlist(["a", "b", "c", "d", "e"])
        XCTAssertEqual(PlaylistSummary.coverURLs(of: playlist), playlist.items.prefix(4).compactMap(\.wallpaper.previewURL))
    }

    func testCoverShowsAWallpaperListedTwiceOnce() {
        var playlist = playlist(["a", "b"])
        playlist.items.insert(WallpaperPlaylistItem(wallpaper: wallpaper("a")), at: 1)
        XCTAssertEqual(PlaylistSummary.coverURLs(of: playlist).count, 2)
    }

    func testCoverOfAnEmptyPlaylistIsEmpty() {
        XCTAssertEqual(PlaylistSummary.coverURLs(of: playlist([])), [])
    }

    func testRemoteWallpaperCoverIsItsOwnURL() {
        let remote = WEWallpaper(using: WEProject(file: "https://example.com/v.mp4", preview: "", title: "r", type: "remote-video"),
                                 where: URL(fileURLWithPath: "/tmp/owe-summary/r"))
        XCTAssertEqual(PlaylistSummary.previewURL(for: remote), URL(string: "https://example.com/v.mp4"))
    }

    // MARK: - Durations

    func testTimerItemsShowForThePlaylistsDuration() {
        let playlist = playlist(["a", "b", "c"]) { $0.duration = 120 }
        XCTAssertEqual(PlaylistSummary.share(ofItemAt: 1, in: playlist), .duration(120))
        XCTAssertEqual(PlaylistSummary.totalDuration(of: playlist), 360)
    }

    func testIntroPlayedAtStartupOnlyIsLeftOutOfTheRound() {
        let playlist = playlist(["a", "b", "c"]) {
            $0.duration = 60
            $0.beginsWithFirst = true
            $0.playsFirstAtStartupOnly = true
        }
        XCTAssertEqual(PlaylistSummary.share(ofItemAt: 0, in: playlist), .untimed)
        XCTAssertEqual(PlaylistSummary.totalDuration(of: playlist), 120)
    }

    func testTimeOfDayItemsShowForTheirSlot() {
        let playlist = playlist(["a", "b"]) {
            $0.timing = .daytime
            $0.items[0].daytimeEnd = 0.25
        }
        XCTAssertEqual(PlaylistSummary.share(ofItemAt: 0, in: playlist), .duration(6 * 3600))
        XCTAssertEqual(PlaylistSummary.share(ofItemAt: 1, in: playlist), .duration(18 * 3600))
        XCTAssertEqual(PlaylistSummary.totalDuration(of: playlist), 86_400)
    }

    func testDayOfWeekItemsShareTheWeek() {
        let playlist = playlist(["a", "b", "c"]) { $0.timing = .dayofweek }
        XCTAssertEqual((0..<3).map { PlaylistSummary.share(ofItemAt: $0, in: playlist) }, [.days(2), .days(2), .days(3)])
        XCTAssertEqual(PlaylistSummary.totalDuration(of: playlist), 7 * 86_400)
    }

    func testLoginAndNeverAreNotTimed() {
        for timing in [PlaylistTiming.logon, .never] {
            let playlist = playlist(["a"]) { $0.timing = timing }
            XCTAssertEqual(PlaylistSummary.share(ofItemAt: 0, in: playlist), .untimed)
            XCTAssertNil(PlaylistSummary.totalDuration(of: playlist))
        }
        XCTAssertNil(PlaylistSummary.totalDuration(of: playlist([])))
    }

    // MARK: - Transition

    func testTransitionTitle() {
        XCTAssertNil(PlaylistSummary.transitionTitle(.unset))
        XCTAssertNotNil(PlaylistSummary.transitionTitle(.playlistDefault))
        XCTAssertNotNil(PlaylistSummary.transitionTitle(WallpaperTransitionSettings(choice: .random, pool: nil, milliseconds: 500)))
    }

    // MARK: - Reorder and rename

    private func model(_ names: [String]) -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        let playlist = playlist(names)
        model.playlists = [playlist]
        model.activePlaylistID = playlist.id
        return model
    }

    private func order(_ model: WallpaperViewModel) -> [String] {
        model.activePlaylist?.items.map(\.wallpaper.project.title) ?? []
    }

    func testDraggingAnItemDownMovesItBeforeTheDestination() {
        let model = model(["a", "b", "c", "d"])
        let a = model.activePlaylist!.items[0].id
        model.movePlaylistItem(itemID: a, toOffset: 3)
        XCTAssertEqual(order(model), ["b", "c", "a", "d"])
        model.movePlaylistItem(itemID: a, toOffset: 4)
        XCTAssertEqual(order(model), ["b", "c", "d", "a"])
    }

    func testDraggingAnItemUp() {
        let model = model(["a", "b", "c", "d"])
        let d = model.activePlaylist!.items[3].id
        model.movePlaylistItem(itemID: d, toOffset: 1)
        XCTAssertEqual(order(model), ["a", "d", "b", "c"])
        model.movePlaylistItem(itemID: d, toOffset: 1)
        XCTAssertEqual(order(model), ["a", "d", "b", "c"])
    }

    func testRenameTrimsAndKeepsTheOldNameWhenEmpty() {
        let model = model(["a"])
        let id = model.activePlaylistID!
        model.renamePlaylist(id, to: "  Evening  ")
        XCTAssertEqual(model.activePlaylist?.name, "Evening")
        model.renamePlaylist(id, to: "   ")
        XCTAssertEqual(model.activePlaylist?.name, "Evening")
    }
}
