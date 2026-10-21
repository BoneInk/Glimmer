import XCTest
@testable import OpenWallpaperEngine

/// Application rules at work: the loader's load and restore order (`ApplicationRuleLoader`), and
/// `DisplayPlaybackMonitor` following fake audio processes and window lists for the "is playing
/// audio" and "is maximized" conditions.
@MainActor
final class ApplicationRulesLoadTests: XCTestCase {
    /// Records what the loader asks for; its "screen" is one string.
    private final class FakeTarget: ApplicationRuleLoadTarget {
        var shown = "before"
        var calls: [String] = []
        var missing: Set<String> = []

        func restorePoint() -> String {
            calls.append("record \(shown)")
            return shown
        }

        func load(_ load: ApplicationRuleLoad) -> Bool {
            calls.append("load \(load.file)")
            guard !missing.contains(load.file) else { return false }
            shown = load.file
            return true
        }

        func restore(_ point: String) {
            calls.append("restore \(point)")
            shown = point
        }
    }

    private let editor = "com.example.editor"
    private let game = "com.example.game"

    // MARK: Loader

    func testRecordsBeforeTheFirstLoadAndRestoresWhenNoRuleMatches() {
        let target = FakeTarget()
        let loader = ApplicationRuleLoader(target: target)
        let a = ApplicationRuleLoad(kind: .wallpaper, file: "a")
        loader.update(a)
        XCTAssertEqual(target.calls, ["record before", "load a"], "the state is recorded before the load")
        loader.update(a)
        XCTAssertEqual(target.calls.count, 2, "the same load again does nothing")
        loader.update(nil)
        XCTAssertEqual(target.calls, ["record before", "load a", "restore before"])
        XCTAssertEqual(target.shown, "before")
        loader.update(nil)
        XCTAssertEqual(target.calls.count, 3, "nothing to restore twice")
        XCTAssertFalse(loader.isHoldingRestorePoint)
    }

    func testAnotherRulesLoadKeepsTheFirstRecord() {
        let target = FakeTarget()
        let loader = ApplicationRuleLoader(target: target)
        loader.update(ApplicationRuleLoad(kind: .wallpaper, file: "a"))
        loader.update(ApplicationRuleLoad(kind: .playlist, file: "p"))
        loader.update(nil)
        // Back to what was shown before any rule, not to the first rule's wallpaper.
        XCTAssertEqual(target.calls, ["record before", "load a", "load p", "restore before"])
        // A later match records afresh.
        target.shown = "chosen later"
        loader.update(ApplicationRuleLoad(kind: .profile, file: "Gaming"))
        XCTAssertEqual(target.calls.suffix(2), ["record chosen later", "load Gaming"])
    }

    func testAMissingTargetStillRestoresAfterwards() {
        let target = FakeTarget()
        target.missing = ["gone"]
        let loader = ApplicationRuleLoader(target: target)
        loader.update(ApplicationRuleLoad(kind: .playlist, file: "gone"))
        XCTAssertEqual(target.shown, "before")
        loader.update(nil)
        XCTAssertEqual(target.calls, ["record before", "load gone", "restore before"])
    }

    // MARK: Load profile

    private func wallpaper(_ folder: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: "scene"),
                    where: URL(filePath: "/tmp/owe-rule-profile-tests/\(folder)"))
    }

    /// Two displays showing "a" and "b" in the plain layout, and a saved profile "Gaming" that
    /// splits display 2 into "c" and "d".
    private func profileFixture() -> (WallpaperViewModel, DisplayProfiles, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ApplicationRulesLoadTests-\(UUID().uuidString)")
        let model = WallpaperViewModel(persistsWallpapers: false)
        let displays = [
            DisplayIdentity(screenId: "1", identity: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
            DisplayIdentity(screenId: "2", identity: "UUID-B", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
        ]
        model.connectedDisplays = { displays }
        model.audioOutputEnabled = false
        model.refreshDisplayLayout()
        let plain = model.displayLayout
        let profiles = DisplayProfiles(model: model, fileURL: folder.appending(path: "DisplayProfiles.json"))
        model.wallpapers = ["1": wallpaper("c"), "2": wallpaper("c")]
        model.split("2", DisplaySplit(direction: .vertical, position: 0.5))
        model.wallpapers["2/R"] = wallpaper("d")
        XCTAssertTrue(profiles.save(name: "Gaming"))
        model.displayLayout = plain
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b")]
        return (model, profiles, folder)
    }

    private func titles(_ model: WallpaperViewModel) -> [String: String] {
        model.wallpapers.mapValues(\.project.title)
    }

    func testALoadProfileRuleShowsTheProfileAndRestoresTheLayoutBefore() {
        let (model, profiles, folder) = profileFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = model.displayLayout
        let loader = ApplicationRuleLoader(target: WallpaperRuleLoadTarget(viewModel: model, library: { [] },
                                                                           profiles: { profiles }))
        loader.update(ApplicationRuleLoad(kind: .profile, file: "Gaming"))
        XCTAssertEqual(model.displayLayout, profiles.profile(named: "Gaming")?.layout)
        XCTAssertNotEqual(model.displayLayout, before)
        XCTAssertTrue(model.isSplitRegion("2/R"))
        XCTAssertEqual(titles(model)["2/R"], "d")
        loader.update(nil)
        XCTAssertEqual(model.displayLayout, before, "the layout from before the rule comes back")
        XCTAssertEqual(titles(model), ["1": "a", "2": "b"], "and the wallpapers, without the profile's regions")
        XCTAssertFalse(model.isSplitRegion("2/R"))
    }

    func testADeletedProfileIsSkipped() {
        let (model, profiles, folder) = profileFixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        profiles.delete(name: "Gaming")
        let before = model.displayLayout
        let loader = ApplicationRuleLoader(target: WallpaperRuleLoadTarget(viewModel: model, library: { [] },
                                                                           profiles: { profiles }))
        loader.update(ApplicationRuleLoad(kind: .profile, file: "Gaming"))
        XCTAssertEqual(model.displayLayout, before)
        XCTAssertEqual(titles(model), ["1": "a", "2": "b"])
        loader.update(nil)
        XCTAssertEqual(model.displayLayout, before)
        XCTAssertEqual(titles(model), ["1": "a", "2": "b"])
    }

    // MARK: Monitor with fake providers

    private final class Desktop: @unchecked Sendable {
        var windows: [DesktopWindow] = []
        var applications: [pid_t: String] = [:]
        var audio: Set<String> = []
        var audioChanged: (@Sendable () -> Void)?
        var audioObservationStopped = 0
        let displays = [
            DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055)),
            DesktopDisplay(id: "2", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 1920, y: 25, width: 1920, height: 1055)),
        ]
    }

    private var desktop = Desktop()
    private var applied: [[String: DisplayPlayback]] = []
    private var loads: [ApplicationRuleLoad?] = []
    private var monitor: DisplayPlaybackMonitor!

    override func setUp() {
        super.setUp()
        desktop = Desktop()
        applied = []
        loads = []
        let desktop = desktop
        let sources = DisplayPlaybackSources(
            windows: { desktop.windows }, displays: { desktop.displays }, frontmostPID: { nil }, ownPID: 1,
            otherApplicationPlayingAudio: { _ in false }, onBattery: { false },
            applications: { desktop.applications },
            audioProcesses: { desktop.audio },
            observeAudioProcesses: { changed in
                desktop.audioChanged = changed
                return { desktop.audioChanged = nil; desktop.audioObservationStopped += 1 }
            })
        monitor = DisplayPlaybackMonitor(sources: sources, scanQueue: nil, onLoad: { [weak self] in self?.loads.append($0) },
                                         apply: { [weak self] in self?.applied.append($0) })
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    func testPlayingAudioFollowsCoreAudioWithoutPolling() {
        let rules = PlaybackRules(applicationRules: [
            ApplicationRule(bundleIdentifier: game, name: "Game", condition: .playingAudio, action: .mute),
        ])
        monitor.setRules(rules)
        XCTAssertNotNil(desktop.audioChanged, "the audio processes are followed while the rule is on")
        XCTAssertFalse(monitor.isPolling, "and no timer looks at them")
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        // Core Audio says the game's helper started playing.
        desktop.audio = ["com.example.game.helper"]
        desktop.audioChanged?()
        spin { applied.last == ["1": .mute, "2": .mute] }
        XCTAssertEqual(applied.last, ["1": .mute, "2": .mute])
        desktop.audio = []
        desktop.audioChanged?()
        spin { applied.last == ["1": .run, "2": .run] }
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        monitor.setRules(PlaybackRules())
        XCTAssertNil(desktop.audioChanged)
        XCTAssertEqual(desktop.audioObservationStopped, 1, "it stops following once no rule needs it")
    }

    func testMaximizedPollsSlowlyOnlyWhileItsApplicationRuns() {
        let rules = PlaybackRules(applicationRules: [
            ApplicationRule(bundleIdentifier: editor, name: "Editor", condition: .maximized, action: .pause),
        ])
        monitor.setRules(rules)
        XCTAssertFalse(monitor.isPolling, "the editor isn't running")
        desktop.applications = [10: editor]
        desktop.windows = [DesktopWindow(ownerPID: 10, bounds: desktop.displays[1].visibleFrame)]
        monitor.evaluate()
        XCTAssertEqual(monitor.neededPollInterval, DisplayPlaybackMonitor.maximizedRulePollInterval)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(applied.last, ["1": .run, "2": .pause])
        // Unzoomed: no event, the slow poll notices.
        desktop.windows = [DesktopWindow(ownerPID: 10, bounds: CGRect(x: 2000, y: 100, width: 800, height: 600))]
        spin(until: { applied.last == ["1": .run, "2": .run] }, timeout: DisplayPlaybackMonitor.maximizedRulePollInterval * 4)
        XCTAssertEqual(applied.last, ["1": .run, "2": .run])
        desktop.applications = [:]
        desktop.windows = []
        monitor.evaluate()
        XCTAssertFalse(monitor.isPolling, "the editor quit")
    }

    func testLoadsAreHandedOnWhenTheyChange() {
        let rules = PlaybackRules(applicationRules: [
            ApplicationRule(bundleIdentifier: editor, name: "Editor", condition: .maximized, action: .loadWallpaper,
                            file: "/w/a", fileName: "A"),
            ApplicationRule(bundleIdentifier: game, name: "Game", condition: .running, action: .loadPlaylist, file: "p"),
        ])
        monitor.setRules(rules)
        XCTAssertEqual(loads, [], "nothing to load, nothing handed on")
        desktop.applications = [20: game]
        monitor.evaluate()
        XCTAssertEqual(loads, [ApplicationRuleLoad(kind: .playlist, file: "p")])
        // The editor, listed first, maximizes: its wallpaper wins.
        desktop.applications = [10: editor, 20: game]
        desktop.windows = [DesktopWindow(ownerPID: 10, bounds: desktop.displays[0].visibleFrame)]
        monitor.evaluate()
        monitor.evaluate()
        XCTAssertEqual(loads.last, ApplicationRuleLoad(kind: .wallpaper, file: "/w/a"))
        XCTAssertEqual(loads.count, 2)
        desktop.applications = [:]
        desktop.windows = []
        monitor.evaluate()
        XCTAssertEqual(loads.last, .some(nil), "no rule matches: the loader restores")
    }
}
