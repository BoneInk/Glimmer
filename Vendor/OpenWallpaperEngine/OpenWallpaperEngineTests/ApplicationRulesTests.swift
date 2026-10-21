import XCTest
@testable import OpenWallpaperEngine

/// Settings › Performance › Application Rules (`ApplicationRule`): evaluated with the other
/// playback rules (`PlaybackRules`), found on the desktop (`DesktopWindowLayout`), stored in the
/// settings, exported and imported.
@MainActor
final class ApplicationRulesTests: XCTestCase {
    private let displays = ["1", "2"]
    private let editor = "com.example.editor"
    private let game = "com.example.game"

    private func rule(_ bundle: String, _ condition: ApplicationRule.Condition, _ action: ApplicationRule.Action,
                      file: String? = nil, enabled: Bool = true) -> ApplicationRule {
        ApplicationRule(bundleIdentifier: bundle, name: bundle, condition: condition, action: action,
                        file: file, fileName: file, isEnabled: enabled)
    }

    private func playback(_ rules: PlaybackRules, _ conditions: [String: DisplayConditions] = [:],
                          running: Set<String> = [], audio: Set<String> = []) -> [String: DisplayPlayback] {
        rules.playback(displays: displays, conditions: conditions,
                       system: SystemPlaybackConditions(runningApplications: running, audioProcesses: audio))
    }

    private func load(_ rules: PlaybackRules, _ conditions: [String: DisplayConditions] = [:],
                      running: Set<String> = [], audio: Set<String> = []) -> ApplicationRuleLoad? {
        rules.load(conditions: conditions, system: SystemPlaybackConditions(runningApplications: running, audioProcesses: audio))
    }

    // MARK: Conditions and actions

    func testRunningActsOnEveryDisplay() {
        let rules = PlaybackRules(applicationRules: [rule(editor, .running, .pause)])
        XCTAssertEqual(playback(rules, running: [editor]), ["1": .pause, "2": .pause])
        XCTAssertEqual(playback(rules, running: [game]), ["1": .run, "2": .run])
    }

    func testFocusedActsOnTheWindowsDisplay() {
        let rules = PlaybackRules(applicationRules: [rule(editor, .focused, .mute)])
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(focused: true, focusedApplication: editor)]),
                       ["1": .run, "2": .mute])
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(focused: true, focusedApplication: game)]),
                       ["1": .run, "2": .run])
    }

    func testFullscreenActsOnTheFilledDisplay() {
        let rules = PlaybackRules(applicationRules: [rule(game, .fullscreen, .stop)])
        XCTAssertEqual(playback(rules, ["1": DisplayConditions(fullscreen: true, fullscreenApplications: [game])]),
                       ["1": .stop, "2": .run])
    }

    func testMaximizedActsOnTheDisplayItFills() {
        let rules = PlaybackRules(applicationRules: [rule(game, .maximized, .pause)])
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(maximized: true, maximizedApplications: [game])]),
                       ["1": .run, "2": .pause])
        // Full screen is its own condition, as in WE.
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(fullscreen: true, fullscreenApplications: [game])]),
                       ["1": .run, "2": .run])
        let fullscreen = PlaybackRules(applicationRules: [rule(game, .fullscreen, .pause)])
        XCTAssertEqual(playback(fullscreen, ["2": DisplayConditions(maximized: true, maximizedApplications: [game])]),
                       ["1": .run, "2": .run])
    }

    func testPlayingAudioActsOnEveryDisplay() {
        let rules = PlaybackRules(applicationRules: [rule(game, .playingAudio, .mute)])
        XCTAssertEqual(playback(rules, running: [game]), ["1": .run, "2": .run], "running without sound")
        XCTAssertEqual(playback(rules, running: [game], audio: [game]), ["1": .mute, "2": .mute])
        // A helper process playing the application's sound counts; another application doesn't.
        XCTAssertEqual(playback(rules, audio: ["com.example.game.helper"]), ["1": .mute, "2": .mute])
        XCTAssertEqual(playback(rules, audio: ["com.example.gamebar", editor]), ["1": .run, "2": .run])
        // Pause on "is playing audio" pauses every display, as WE's (no per-display pause there).
        let pause = PlaybackRules(applicationRules: [rule(game, .playingAudio, .pause)])
        XCTAssertEqual(playback(pause, audio: [game]), ["1": .pause, "2": .pause])
    }

    func testEachAction() {
        for (action, expected) in [(ApplicationRule.Action.mute, DisplayPlayback.mute), (.pause, .pause), (.stop, .stop)] {
            let rules = PlaybackRules(applicationRules: [rule(game, .fullscreen, action)])
            XCTAssertEqual(playback(rules, ["1": DisplayConditions(fullscreenApplications: [game])]),
                           ["1": expected, "2": .run], "\(action)")
        }
        // Pause All from one display's window pauses both.
        let all = PlaybackRules(applicationRules: [rule(game, .focused, .pauseAll)])
        XCTAssertEqual(playback(all, ["1": DisplayConditions(focusedApplication: game)]), ["1": .pause, "2": .pause])
        // Stop All from one display's window stops both; Stop stops only that display.
        let stopAll = PlaybackRules(applicationRules: [rule(game, .maximized, .stopAll)])
        XCTAssertEqual(playback(stopAll, ["2": DisplayConditions(maximizedApplications: [game])]), ["1": .stop, "2": .stop])
        let stop = PlaybackRules(applicationRules: [rule(game, .maximized, .stop)])
        XCTAssertEqual(playback(stop, ["2": DisplayConditions(maximizedApplications: [game])]), ["1": .run, "2": .stop])
    }

    func testDisabledAndKeepRunningRulesDoNothing() {
        let rules = PlaybackRules(applicationRules: [rule(editor, .running, .stop, enabled: false),
                                                     rule(game, .running, .keepRunning)])
        XCTAssertTrue(rules.applicationRules.isEmpty)
        XCTAssertFalse(rules.watchesApplications)
        XCTAssertEqual(playback(rules, running: [editor, game]), ["1": .run, "2": .run])
    }

    func testWhatWEOffersPerCondition() {
        XCTAssertFalse(ApplicationRule.Condition.playingAudio.offersStop)
        XCTAssertTrue(ApplicationRule.Condition.running.offersStop)
        for condition in ApplicationRule.Condition.allCases {
            XCTAssertEqual(condition.actsPerDisplay, [.focused, .maximized, .fullscreen].contains(condition), "\(condition)")
        }
    }

    // MARK: Combining

    func testCombinesWithThePlaybackSettingsMostRestrictiveWins() {
        // "Other application fullscreen: mute" and a rule pausing while the editor runs.
        let rules = PlaybackRules(fullscreen: .mute, applicationRules: [rule(editor, .running, .pause)])
        let result = playback(rules, ["2": DisplayConditions(fullscreen: true)], running: [editor])
        XCTAssertEqual(result, ["1": .pause, "2": .pause])
        // A stricter global rule keeps its stop on its display.
        let strict = PlaybackRules(fullscreen: .stop, applicationRules: [rule(editor, .running, .mute)])
        XCTAssertEqual(playback(strict, ["2": DisplayConditions(fullscreen: true)], running: [editor]),
                       ["1": .mute, "2": .stop])
    }

    func testSeveralRulesTheStricterWins() {
        let rules = PlaybackRules(applicationRules: [rule(editor, .running, .mute), rule(game, .fullscreen, .stop)])
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(fullscreenApplications: [game])], running: [editor, game]),
                       ["1": .mute, "2": .stop])
        // The order of the list doesn't matter for playback: the stricter wins either way.
        let ordered = PlaybackRules(applicationRules: [rule(game, .playingAudio, .pause), rule(game, .running, .mute)])
        XCTAssertEqual(playback(ordered, running: [game], audio: [game]), ["1": .pause, "2": .pause])
        let reversed = PlaybackRules(applicationRules: [rule(game, .running, .mute), rule(game, .playingAudio, .pause)])
        XCTAssertEqual(playback(reversed, running: [game], audio: [game]), ["1": .pause, "2": .pause])
    }

    func testWhichRulesReadTheWindowListAndCoreAudio() {
        XCTAssertFalse(PlaybackRules(applicationRules: [rule(editor, .running, .pause)]).applicationRulesWatchWindows)
        XCTAssertTrue(PlaybackRules(applicationRules: [rule(editor, .focused, .pause)]).applicationRulesWatchWindows)
        XCTAssertTrue(PlaybackRules(applicationRules: [rule(editor, .maximized, .pause)]).applicationRulesWatchWindows)
        // Application rules never turn on the poll that the window settings use.
        XCTAssertFalse(PlaybackRules(applicationRules: [rule(editor, .fullscreen, .pause)]).watchesWindows)
        XCTAssertTrue(PlaybackRules(applicationRules: [rule(game, .playingAudio, .mute)]).applicationRulesWatchAudio)
        XCTAssertFalse(PlaybackRules(applicationRules: [rule(game, .running, .mute)]).applicationRulesWatchAudio)
        XCTAssertFalse(PlaybackRules(playingAudio: .mute).applicationRulesWatchAudio, "the Playback setting has its own read")
        let maximized = PlaybackRules(applicationRules: [rule(game, .maximized, .mute), rule(editor, .focused, .mute)])
        XCTAssertEqual(maximized.maximizedRuleApplications, [game])
    }

    // MARK: Load actions

    func testTheFirstMatchingLoadRuleInTheListWins() {
        let rules = PlaybackRules(applicationRules: [
            rule(editor, .running, .loadWallpaper, file: "/w/a"),
            rule(game, .running, .loadPlaylist, file: "p-1"),
            rule(game, .playingAudio, .loadProfile, file: "Gaming"),
        ])
        XCTAssertEqual(load(rules, running: [editor, game]), ApplicationRuleLoad(kind: .wallpaper, file: "/w/a"))
        XCTAssertEqual(load(rules, running: [game], audio: [game]), ApplicationRuleLoad(kind: .playlist, file: "p-1"))
        XCTAssertEqual(load(rules, audio: [game]), ApplicationRuleLoad(kind: .profile, file: "Gaming"))
        XCTAssertNil(load(rules))
    }

    func testAWindowConditionLoadsFromAnyDisplay() {
        let rules = PlaybackRules(applicationRules: [rule(game, .maximized, .loadWallpaper, file: "/w/b")])
        XCTAssertEqual(load(rules, ["2": DisplayConditions(maximizedApplications: [game])]),
                       ApplicationRuleLoad(kind: .wallpaper, file: "/w/b"))
        XCTAssertNil(load(rules, ["2": DisplayConditions(fullscreenApplications: [game])]))
    }

    func testLoadRulesDontChangePlaybackAndCombineWithOthers() {
        let rules = PlaybackRules(applicationRules: [rule(game, .running, .loadWallpaper, file: "/w/a"),
                                                     rule(game, .running, .mute)])
        XCTAssertEqual(playback(rules, running: [game]), ["1": .mute, "2": .mute])
        XCTAssertEqual(load(rules, running: [game]), ApplicationRuleLoad(kind: .wallpaper, file: "/w/a"))
        // A load rule alone keeps the wallpapers running.
        let loadOnly = PlaybackRules(applicationRules: [rule(game, .running, .loadPlaylist, file: "p")])
        XCTAssertEqual(playback(loadOnly, running: [game]), ["1": .run, "2": .run])
    }

    func testALoadRuleNeedsSomethingToLoad() {
        let rules = PlaybackRules(applicationRules: [rule(game, .running, .loadWallpaper),
                                                     rule(game, .running, .loadProfile, file: "")])
        XCTAssertTrue(rules.applicationRules.isEmpty)
        XCTAssertNil(load(rules, running: [game]))
    }

    // MARK: The desktop

    func testWindowLayoutNamesTheFocusedAndFullscreenApplications() {
        let display = DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055))
        let windows = [
            DesktopWindow(ownerPID: 10, bounds: CGRect(x: 100, y: 100, width: 800, height: 600)),
            DesktopWindow(ownerPID: 20, bounds: display.frame),
        ]
        let conditions = DesktopWindowLayout.conditions(windows: windows, displays: [display], frontmostPID: 10,
                                                        ignoredPIDs: [1], bundleIdentifiers: [10: editor, 20: game])
        XCTAssertEqual(conditions["1"]?.focusedApplication, editor)
        XCTAssertEqual(conditions["1"]?.fullscreenApplications, [game])
        XCTAssertEqual(conditions["1"]?.maximizedApplications, [])
    }

    func testWindowLayoutTellsMaximizedFromFullscreen() {
        let main = DesktopDisplay(id: "1", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1000))
        let side = DesktopDisplay(id: "2", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                                  visibleFrame: CGRect(x: 1920, y: 25, width: 1920, height: 1055))
        let windows = [
            // Zoomed on the main display: the visible frame, with tiling's few points of margin.
            DesktopWindow(ownerPID: 10, bounds: main.visibleFrame.insetBy(dx: 4, dy: 4)),
            // Full screen on the side display.
            DesktopWindow(ownerPID: 20, bounds: side.frame),
            // Half the side display: neither.
            DesktopWindow(ownerPID: 30, bounds: CGRect(x: 1920, y: 25, width: 960, height: 1055)),
        ]
        let conditions = DesktopWindowLayout.conditions(windows: windows, displays: [main, side], frontmostPID: nil,
                                                        ignoredPIDs: [1],
                                                        bundleIdentifiers: [10: editor, 20: game, 30: "com.example.notes"])
        XCTAssertEqual(conditions["1"]?.maximizedApplications, [editor])
        XCTAssertEqual(conditions["1"]?.fullscreenApplications, [])
        XCTAssertEqual(conditions["2"]?.fullscreenApplications, [game])
        XCTAssertEqual(conditions["2"]?.maximizedApplications, [])
        let rules = PlaybackRules(applicationRules: [rule(editor, .maximized, .pause), rule(game, .fullscreen, .mute)])
        XCTAssertEqual(playback(rules, conditions), ["1": .pause, "2": .mute])
    }

    // MARK: Storage

    func testSettingsRoundTripKeepsTheRules() throws {
        var settings = GlobalSettings()
        settings.applicationRules = [rule(editor, .focused, .mute), rule(game, .fullscreen, .stop, enabled: false),
                                     rule(game, .playingAudio, .loadPlaylist, file: UUID().uuidString),
                                     rule(editor, .maximized, .stopAll)]
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.applicationRules, settings.applicationRules)
        XCTAssertEqual(PlaybackRules(decoded).applicationRules.map(\.bundleIdentifier), [editor, game, editor])
    }

    func testRulesSavedBeforeTheLoadActionsStillRead() throws {
        // The stored actions were `GSPlayback` values; they read as the same actions.
        let json = """
        {"applicationRules": [
          {"bundleIdentifier": "com.example.editor", "condition": "fullscreen", "action": "pauseAll"},
          {"bundleIdentifier": "com.example.game", "condition": "running", "action": "stop", "isEnabled": false}
        ]}
        """
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.applicationRules.map(\.action), [.pauseAll, .stop])
        XCTAssertEqual(settings.applicationRules.map(\.file), [nil, nil])
    }

    func testAnUnreadableRuleDoesNotDropTheOthers() throws {
        let json = """
        {"applicationRules": [
          {"bundleIdentifier": "com.example.editor", "condition": "focused", "action": "mute"},
          {"condition": "running"},
          "not a rule",
          {"bundleIdentifier": "com.example.game", "condition": "someday", "action": "stop"}
        ]}
        """
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.applicationRules.map(\.bundleIdentifier), [editor, game])
        XCTAssertEqual(settings.applicationRules[0].condition, .focused)
        XCTAssertEqual(settings.applicationRules[1].condition, .running, "an unknown condition keeps the default")
        XCTAssertEqual(settings.applicationRules[1].action, .stop)
    }

    func testExportImportRoundTrip() throws {
        var settings = GlobalSettings()
        settings.applicationRules = [rule(editor, .running, .pauseAll), rule(game, .focused, .loadWallpaper, file: "/w/a")]
        let suite = "owe-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let exported = SettingsTransfer.export(settings: settings, defaults: defaults, updates: nil, appVersion: "test")
        let imported = try SettingsTransfer.decode(exported.encoded())
        XCTAssertEqual(imported.settings.applicationRules, settings.applicationRules)
    }

    func testResetClearsTheRules() {
        var settings = GlobalSettings()
        settings.applicationRules = [rule(editor, .running, .pause)]
        XCTAssertTrue(SettingsTab.performance.fields.contains { $0.isChanged(settings) })
        XCTAssertEqual(SettingsTab.performance.resetting(settings).applicationRules, [])
        XCTAssertEqual(GlobalSettings().applicationRules, [])
    }
}
