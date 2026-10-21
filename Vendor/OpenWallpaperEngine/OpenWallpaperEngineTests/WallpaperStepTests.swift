import XCTest
@testable import OpenWallpaperEngine

/// Next and Previous Wallpaper: the per-display history, the random pick and the routing between
/// the playlist and the library.
@MainActor
final class WallpaperStepTests: XCTestCase {
    private func wallpaper(_ name: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: "scene"),
                    where: URL(fileURLWithPath: "/tmp/owe-step/\(name)"))
    }

    private func names(_ wallpapers: [WEWallpaper]) -> [String] {
        wallpapers.map(\.project.title)
    }

    // MARK: - History

    func testHistoryPushAndBack() {
        var history = WallpaperHistory()
        let (a, b, c) = (wallpaper("a"), wallpaper("b"), wallpaper("c"))
        history.push(a, for: "1")
        history.push(b, for: "1")
        history.push(b, for: "1") // already on top
        history.push(c, for: "1")
        XCTAssertEqual(history.previous(for: "1", showing: c)?.project.title, "b")
        XCTAssertEqual(history.back(for: "1", showing: c)?.project.title, "b")
        XCTAssertEqual(history.back(for: "1", showing: b)?.project.title, "a")
        XCTAssertNil(history.back(for: "1", showing: a))
        XCTAssertNil(history.previous(for: "1", showing: a))
    }

    func testHistoryIsPerDisplay() {
        var history = WallpaperHistory()
        history.push(wallpaper("a"), for: "1")
        history.push(wallpaper("b"), for: "1")
        XCTAssertNil(history.previous(for: "2", showing: wallpaper("b")))
        XCTAssertEqual(history.previous(for: "1", showing: wallpaper("b"))?.project.title, "a")
    }

    func testHistoryKeepsTheNewestTwenty() {
        var history = WallpaperHistory()
        for index in 0..<30 { history.push(wallpaper("\(index)"), for: "1") }
        XCTAssertEqual(history.stacks["1"]?.count, WallpaperHistory.capacity)
        XCTAssertEqual(history.stacks["1"]?.first?.project.title, "10")
        XCTAssertEqual(history.stacks["1"]?.last?.project.title, "29")
    }

    func testHistoryIgnoresTheMissingWallpaperPlaceholder() {
        var history = WallpaperHistory()
        history.push(WallpaperViewModel.defaultWallpaper, for: "1")
        XCTAssertNil(history.stacks["1"])
    }

    // MARK: - Random pick

    func testRandomPickNeverReturnsTheCurrentWallpaper() {
        let shown = [wallpaper("a"), wallpaper("b"), wallpaper("c")]
        for index in 0..<2 {
            let pick = WallpaperViewModel.randomPick(from: shown, excluding: shown[1], random: { _ in index })
            XCTAssertNotEqual(pick?.project.title, "b")
        }
        XCTAssertNil(WallpaperViewModel.randomPick(from: [shown[1]], excluding: shown[1]))
        XCTAssertNil(WallpaperViewModel.randomPick(from: [], excluding: shown[1]))
    }

    func testRandomPickSkipsTheShownFolderWhateverItsSpelling() {
        let project = WEProject(file: "scene.json", preview: "p.jpg", title: "same", type: "scene")
        let listed = WEWallpaper(using: project, where: URL(fileURLWithPath: "/tmp/lib/same", isDirectory: false))
        let stored = WEWallpaper(using: project, where: URL(string: "file:///tmp/lib/same/")!)
        XCTAssertNil(WallpaperViewModel.randomPick(from: [listed], excluding: stored))
    }

    func testRandomPickComesFromTheShownList() {
        let shown = [wallpaper("x"), wallpaper("y")]
        var seen: Set<String> = []
        for index in 0..<2 {
            let pick = WallpaperViewModel.randomPick(from: shown, excluding: wallpaper("other"), random: { _ in index })
            seen.insert(pick?.project.title ?? "")
        }
        XCTAssertEqual(seen, ["x", "y"])
    }

    // MARK: - Routing

    private func model(showing current: WEWallpaper) -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.setWallpaper(current, for: model.selectedScreenIds)
        return model
    }

    func testOutsideAPlaylistNextPicksRandomlyAndPreviousGoesBack() {
        let (a, b, c) = (wallpaper("a"), wallpaper("b"), wallpaper("c"))
        let model = model(showing: a)
        XCTAssertFalse(model.stepsThroughPlaylist)
        XCTAssertFalse(model.canStepToPreviousWallpaper)

        model.stepToNextWallpaper(shown: [a, b, c], random: { $0.lowerBound })
        XCTAssertEqual(model.currentWallpaper.project.title, "b")
        XCTAssertTrue(model.canStepToPreviousWallpaper)

        model.stepToNextWallpaper(shown: [a, b, c], random: { $0.upperBound - 1 })
        XCTAssertEqual(model.currentWallpaper.project.title, "c")

        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "b")
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "a")
        XCTAssertFalse(model.canStepToPreviousWallpaper)
        XCTAssertFalse(model.canStepToNextWallpaper(shown: [a]))
        XCTAssertTrue(model.canStepToNextWallpaper(shown: [a, b]))
    }

    func testInAPlaylistNextAndPreviousStepThroughIt() {
        let items = (0..<3).map { wallpaper("p\($0)") }
        let model = model(showing: wallpaper("library"))
        model.playlists = [WallpaperPlaylist(name: "p", items: items.map { WallpaperPlaylistItem(wallpaper: $0) })]
        model.activePlaylistID = model.playlists[0].id
        model.playlistEnabled = true
        XCTAssertTrue(model.stepsThroughPlaylist)
        XCTAssertTrue(model.canStepToPreviousWallpaper)

        model.stepToNextWallpaper(shown: [wallpaper("library"), wallpaper("other")])
        XCTAssertEqual(model.currentWallpaper.project.title, "p1")
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "p0")
    }

    private func playlistModel(rotating: Bool, shuffle: Bool = false, repeats: Bool = true)
        -> (WallpaperViewModel, [WEWallpaper]) {
        let items = (0..<3).map { wallpaper("p\($0)") }
        let model = model(showing: wallpaper("library"))
        model.playlists = [WallpaperPlaylist(name: "p", items: items.map { WallpaperPlaylistItem(wallpaper: $0) })]
        model.activePlaylistID = model.playlists[0].id
        model.playlistShuffle = shuffle
        model.playlistRepeats = repeats
        model.playlistEnabled = rotating
        return (model, items)
    }

    func testShowingAPlaylistItemStepsThroughThePlaylistWhenNotRotating() {
        let (model, items) = playlistModel(rotating: false)
        model.setWallpaper(items[0], for: model.selectedScreenIds)
        XCTAssertTrue(model.stepsThroughPlaylist)
        let shown = [wallpaper("library"), wallpaper("other")]
        model.stepToNextWallpaper(shown: shown, random: { $0.lowerBound })
        XCTAssertEqual(model.currentWallpaper.project.title, "p1")
        model.stepToNextWallpaper(shown: shown, random: { $0.lowerBound })
        XCTAssertEqual(model.currentWallpaper.project.title, "p2")
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "p1")
    }

    func testShowingAWallpaperOutsideThePlaylistUsesRandomAndHistory() {
        let (model, _) = playlistModel(rotating: false)
        XCTAssertFalse(model.stepsThroughPlaylist)
        let (library, other) = (wallpaper("library"), wallpaper("other"))
        model.stepToNextWallpaper(shown: [library, other], random: { $0.lowerBound })
        XCTAssertEqual(model.currentWallpaper.project.title, "other")
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "library")
    }

    func testMenuStepsMatchThePlaylistButtons() {
        let (menu, _) = playlistModel(rotating: true)
        let (buttons, _) = playlistModel(rotating: true)
        for _ in 0..<4 {
            menu.stepToNextWallpaper(shown: [])
            buttons.nextPlaylistWallpaper()
            XCTAssertEqual(menu.currentWallpaper.project.title, buttons.currentWallpaper.project.title)
        }
        for _ in 0..<4 {
            menu.stepToPreviousWallpaper()
            buttons.previousPlaylistWallpaper()
            XCTAssertEqual(menu.currentWallpaper.project.title, buttons.currentWallpaper.project.title)
        }
    }

    func testPlaylistRepeatWrapsAtTheEnds() {
        let (model, _) = playlistModel(rotating: true, repeats: true)
        model.stepToPreviousWallpaper() // 0 -> 2
        XCTAssertEqual(model.currentWallpaper.project.title, "p2")
        model.stepToNextWallpaper(shown: []) // 2 -> 0
        XCTAssertEqual(model.currentWallpaper.project.title, "p0")
    }

    func testPlaylistWithoutRepeatStopsAtTheEnd() {
        let (model, _) = playlistModel(rotating: true, repeats: false)
        model.stepToNextWallpaper(shown: [])
        model.stepToNextWallpaper(shown: [])
        XCTAssertEqual(model.currentWallpaper.project.title, "p2")
        model.stepToNextWallpaper(shown: [wallpaper("library"), wallpaper("other")])
        XCTAssertEqual(model.currentWallpaper.project.title, "p2")
        XCTAssertFalse(model.playlistEnabled)
    }

    func testShuffledPlaylistNextStaysInThePlaylist() {
        let (model, items) = playlistModel(rotating: true, shuffle: true)
        let titles = Set(names(items))
        for _ in 0..<10 {
            model.stepToNextWallpaper(shown: [wallpaper("library"), wallpaper("other")])
            XCTAssertTrue(titles.contains(model.currentWallpaper.project.title))
        }
    }

    // MARK: - Every step changes the wallpaper

    private func five() -> [WEWallpaper] { (0..<5).map { wallpaper("w\($0)") } }

    private func playlistModel(of items: [WEWallpaper], shuffle: Bool) -> WallpaperViewModel {
        let model = model(showing: items[0])
        model.playlists = [WallpaperPlaylist(name: "p", items: items.map { WallpaperPlaylistItem(wallpaper: $0) })]
        model.activePlaylistID = model.playlists[0].id
        model.playlistShuffle = shuffle
        model.playlistEnabled = true
        return model
    }

    private func assertEveryStepChanges(_ model: WallpaperViewModel, steps: Int = 20,
                                        file: StaticString = #filePath, line: UInt = #line,
                                        _ step: () -> Void) {
        for index in 0..<steps {
            let before = model.currentWallpaper.identityPath
            step()
            XCTAssertNotEqual(model.currentWallpaper.identityPath, before, "step \(index)", file: file, line: line)
        }
    }

    func testTwentyNextsInPlaylistOrderEachChangeTheWallpaper() {
        let model = playlistModel(of: five(), shuffle: false)
        var titles: [String] = []
        assertEveryStepChanges(model) {
            model.stepToNextWallpaper(shown: [])
            titles.append(model.currentWallpaper.project.title)
        }
        XCTAssertEqual(Array(titles.prefix(6)), ["w1", "w2", "w3", "w4", "w0", "w1"])
        assertEveryStepChanges(model) { model.stepToPreviousWallpaper() }
    }

    func testTwentyNextsInAShuffledPlaylistEachChangeTheWallpaper() {
        let model = playlistModel(of: five(), shuffle: true)
        assertEveryStepChanges(model) { model.stepToNextWallpaper(shown: []) }
        assertEveryStepChanges(model) { model.stepToPreviousWallpaper() }
    }

    func testTwentyRandomNextsFromTheLibraryEachChangeTheWallpaper() {
        let shown = five()
        let model = model(showing: shown[0])
        assertEveryStepChanges(model) { model.stepToNextWallpaper(shown: shown) }
        // Even with a pick that always takes the first candidate.
        assertEveryStepChanges(model) { model.stepToNextWallpaper(shown: shown, random: { $0.lowerBound }) }
        assertEveryStepChanges(model, steps: 5) { model.stepToPreviousWallpaper() }
    }

    func testShuffleNeverRepeatsTheCurrentItem() {
        let list = WallpaperPlaylist(name: "p", items: five().map { WallpaperPlaylistItem(wallpaper: $0) })
        for current in 0..<5 {
            for pick in 0..<4 {
                let next = list.nextIndex(after: current, shuffle: true, repeats: true, isSkipped: { _ in false },
                                          random: { _ in pick })
                XCTAssertNotEqual(next, current)
            }
        }
        let single = WallpaperPlaylist(name: "p", items: [WallpaperPlaylistItem(wallpaper: wallpaper("only"))])
        XCTAssertEqual(single.nextIndex(after: 0, shuffle: true, repeats: true, isSkipped: { _ in false }), 0)
    }

    /// Steps aren't coalesced: each applies at once, and the next one reads what it applied.
    func testARapidDoubleNextStepsTwice() {
        let items = five()
        let playlist = playlistModel(of: items, shuffle: false)
        playlist.stepToNextWallpaper(shown: [])
        playlist.stepToNextWallpaper(shown: [])
        XCTAssertEqual(playlist.currentWallpaper.project.title, "w2")

        let library = model(showing: items[0])
        library.stepToNextWallpaper(shown: items, random: { $0.lowerBound }) // w0 -> w1
        library.stepToNextWallpaper(shown: items, random: { $0.lowerBound }) // w1 -> w0
        XCTAssertEqual(library.currentWallpaper.project.title, "w0")
        XCTAssertEqual(library.wallpaperHistory.stacks[library.selectedScreenId]?.map(\.project.title),
                       ["w0", "w1", "w0"])
    }

    func testAnItemAppliedByHandMovesThePlaylistPosition() {
        let items = five()
        let model = playlistModel(of: items, shuffle: false)
        model.setWallpaper(items[1], for: model.selectedScreenIds) // the position still says w0
        model.stepToNextWallpaper(shown: [])
        XCTAssertEqual(model.currentWallpaper.project.title, "w2")
        model.setWallpaper(items[4], for: model.selectedScreenIds)
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "w3")
    }

    func testAFolderListedTwiceIsNotSteppedToAgain() {
        let (a, b) = (wallpaper("a"), wallpaper("b"))
        let aWithSlash = WEWallpaper(using: a.project, where: URL(fileURLWithPath: "/tmp/owe-step/a/", isDirectory: true))
        let model = playlistModel(of: [a, aWithSlash, b], shuffle: false)
        model.stepToNextWallpaper(shown: [])
        XCTAssertEqual(model.currentWallpaper.project.title, "b")
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.identityPath, a.identityPath)
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.currentWallpaper.project.title, "b")
    }

    func testTheSameFolderSpelledDifferentlyIsNotADifferentWallpaper() {
        let a = wallpaper("a")
        let aWithSlash = WEWallpaper(using: a.project, where: URL(fileURLWithPath: "/tmp/owe-step/a/", isDirectory: true))
        XCTAssertNil(WallpaperViewModel.randomPick(from: [aWithSlash], excluding: a))
        var history = WallpaperHistory()
        history.push(wallpaper("b"), for: "1")
        history.push(a, for: "1")
        XCTAssertEqual(history.back(for: "1", showing: aWithSlash)?.project.title, "b")
    }

    func testAPresetIsNotItsBaseWallpaper() {
        let base = wallpaper("base")
        var preset = base
        preset.presetDirectory = URL(fileURLWithPath: "/tmp/owe-step/preset")
        XCTAssertFalse(preset.isSameWallpaper(as: base))
        XCTAssertEqual(WallpaperViewModel.randomPick(from: [base, preset], excluding: base)?.presetDirectory,
                       preset.presetDirectory)
    }

    func testNextSkipsInvalidAndUntrustedWallpapers() {
        let (a, b) = (wallpaper("a"), wallpaper("b"))
        let invalid = WEWallpaper(using: .invalid, where: URL(fileURLWithPath: "/tmp/owe-step/invalid"))
        let web = WEWallpaper(using: WEProject(file: "index.html", preview: "p.jpg", title: "web", type: "Web"),
                              where: URL(fileURLWithPath: "/tmp/owe-step/untrusted-web-\(UUID().uuidString)"))
        XCTAssertTrue(WallpaperViewModel.needsTrust(web))
        let model = model(showing: a)
        XCTAssertFalse(model.canStepToNextWallpaper(shown: [a, invalid, web]))
        model.stepToNextWallpaper(shown: [a, invalid, web])
        XCTAssertEqual(model.currentWallpaper.project.title, "a")
        assertEveryStepChanges(model, steps: 10) { model.stepToNextWallpaper(shown: [invalid, web, a, b]) }
    }

    func testDisplaysStepIndependently() {
        let shown = five()
        let model = model(showing: shown[0])
        model.setWallpaper(shown[1], for: "2")
        model.selectScreen("2", extendingSelection: false)
        assertEveryStepChanges(model) { model.stepToNextWallpaper(shown: shown, random: { $0.lowerBound }) }
        XCTAssertEqual(model.wallpaper(for: "preview").project.title, "w0")
        model.selectScreen("preview", extendingSelection: false)
        XCTAssertFalse(model.canStepToPreviousWallpaper) // display 2's history isn't this one's
        model.stepToPreviousWallpaper()
        XCTAssertEqual(model.wallpaper(for: "preview").project.title, "w0")
    }

    /// A caller that selects displays without the UI's selected one (MCP's next_wallpaper) still
    /// moves away from what those displays show, not from what the UI's display shows.
    func testNextChangesTheDisplaysItActsOnNotTheUIDisplay() {
        let shown = five()
        let model = model(showing: shown[0])
        model.setWallpaper(shown[1], for: "2")
        model.selectedScreenIds = ["2"]
        for _ in 0..<20 {
            let before = model.wallpaper(for: "2").identityPath
            model.stepToNextWallpaper(shown: shown, random: { $0.lowerBound })
            XCTAssertNotEqual(model.wallpaper(for: "2").identityPath, before)
            XCTAssertEqual(model.wallpaper(for: "preview").project.title, "w0")
        }
    }

    func testNextOnTwoDisplaysChangesBoth() {
        let shown = five()
        let model = model(showing: shown[0])
        model.setWallpaper(shown[1], for: "2")
        model.selectedScreenIds = ["preview", "2"]
        for _ in 0..<20 {
            let before = (model.wallpaper(for: "preview").identityPath, model.wallpaper(for: "2").identityPath)
            model.stepToNextWallpaper(shown: shown)
            XCTAssertNotEqual(model.wallpaper(for: "preview").identityPath, before.0)
            XCTAssertNotEqual(model.wallpaper(for: "2").identityPath, before.1)
        }
        // When they show the only two there are, a pick still changes one of them.
        XCTAssertNotNil(WallpaperViewModel.randomPick(from: Array(shown.prefix(2)), excluding: [shown[0], shown[1]]))
    }
}
