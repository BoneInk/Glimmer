import XCTest
@testable import OpenWallpaperEngine

/// Settings › Performance › Playback evaluated per display (`PlaybackRules`): the rules about
/// other applications' windows act on the window's display, WE's "Pause all" and the system rules
/// on every display.
final class PlaybackRulesTests: XCTestCase {
    private let displays = ["1", "2"]

    private func playback(_ rules: PlaybackRules, _ conditions: [String: DisplayConditions] = [:],
                          system: SystemPlaybackConditions = SystemPlaybackConditions()) -> [String: DisplayPlayback] {
        rules.playback(displays: displays, conditions: conditions, system: system)
    }

    func testAFocusedAppPausesOnlyItsDisplay() {
        let rules = PlaybackRules(focused: .pause)
        XCTAssertEqual(playback(rules, ["1": DisplayConditions(focused: true)]), ["1": .pause, "2": .run])
    }

    func testNothingOnADisplayKeepsItsWallpaperPlaying() {
        let rules = PlaybackRules(focused: .pause, maximized: .pause, fullscreen: .stop)
        XCTAssertEqual(playback(rules), ["1": .run, "2": .run])
    }

    func testPauseAllPausesEveryDisplay() {
        let rules = PlaybackRules(maximized: .pauseAll)
        XCTAssertEqual(playback(rules, ["2": DisplayConditions(maximized: true)]), ["1": .pause, "2": .pause])
    }

    func testMuteAndStopActOnTheirDisplay() {
        let rules = PlaybackRules(focused: .mute, fullscreen: .stop)
        let result = playback(rules, ["1": DisplayConditions(focused: true), "2": DisplayConditions(fullscreen: true)])
        XCTAssertEqual(result, ["1": .mute, "2": .stop])
    }

    func testTheMostRestrictiveRuleWins() {
        let rules = PlaybackRules(focused: .mute, fullscreen: .pause)
        let result = playback(rules, ["1": DisplayConditions(focused: true, fullscreen: true)])
        XCTAssertEqual(result["1"], .pause)
        // "Pause all" from one display doesn't loosen a stop on another.
        let stopped = playback(PlaybackRules(focused: .pauseAll, fullscreen: .stop),
                               ["1": DisplayConditions(focused: true), "2": DisplayConditions(fullscreen: true)])
        XCTAssertEqual(stopped, ["1": .pause, "2": .stop])
    }

    func testKeepRunningIgnoresTheCondition() {
        let rules = PlaybackRules(focused: .keepRunning, maximized: .keepRunning, fullscreen: .keepRunning)
        XCTAssertEqual(playback(rules, ["1": DisplayConditions(focused: true, maximized: true, fullscreen: true)]),
                       ["1": .run, "2": .run])
    }

    /// A locked screen or a switched-away session pauses every display, with no setting, and
    /// doesn't loosen a stricter rule.
    func testAnInactiveSessionPausesEveryDisplay() {
        let inactive = SystemPlaybackConditions(sessionInactive: true)
        XCTAssertEqual(playback(PlaybackRules(), system: inactive), ["1": .pause, "2": .pause])
        XCTAssertEqual(playback(PlaybackRules(focused: .mute), ["1": DisplayConditions(focused: true)], system: inactive),
                       ["1": .pause, "2": .pause])
        XCTAssertEqual(playback(PlaybackRules(fullscreen: .stop), ["2": DisplayConditions(fullscreen: true)], system: inactive),
                       ["1": .pause, "2": .stop])
        var asleep = inactive
        asleep.displaysAsleep = true
        XCTAssertEqual(playback(PlaybackRules(displayAsleep: .stop), system: asleep), ["1": .stop, "2": .stop])
    }

    func testSystemRulesActOnEveryDisplay() {
        XCTAssertEqual(playback(PlaybackRules(playingAudio: .mute), system: SystemPlaybackConditions(otherApplicationPlayingAudio: true)),
                       ["1": .mute, "2": .mute])
        XCTAssertEqual(playback(PlaybackRules(onBattery: .pause), system: SystemPlaybackConditions(onBattery: true)),
                       ["1": .pause, "2": .pause])
        XCTAssertEqual(playback(PlaybackRules(displayAsleep: .stop), system: SystemPlaybackConditions(displaysAsleep: true)),
                       ["1": .stop, "2": .stop])
        // A system rule and a display's own rule: the stricter one per display.
        let mixed = playback(PlaybackRules(focused: .pause, playingAudio: .mute), ["2": DisplayConditions(focused: true)],
                             system: SystemPlaybackConditions(otherApplicationPlayingAudio: true))
        XCTAssertEqual(mixed, ["1": .mute, "2": .pause])
    }

    func testWhatHasToBeWatched() {
        XCTAssertFalse(PlaybackRules().watchesWindows)
        XCTAssertFalse(PlaybackRules().watchesAudio)
        XCTAssertFalse(PlaybackRules(onBattery: .pause).watchesWindows)
        XCTAssertTrue(PlaybackRules(maximized: .mute).watchesWindows)
        XCTAssertTrue(PlaybackRules(playingAudio: .pause).watchesAudio)
        XCTAssertTrue(PlaybackRules(onBattery: .stop).watchesPower)
    }

    func testTheRulesComeFromTheSettings() {
        var settings = GlobalSettings()
        settings.otherApplicationFocused = .pauseAll
        settings.otherApplicationMaximized = .mute
        settings.otherApplicationFullscreen = .stop
        settings.otherApplicationPlayingAudio = .pause
        settings.displayAsleep = .stop
        settings.laptopOnBattery = .pause
        XCTAssertEqual(PlaybackRules(settings), PlaybackRules(focused: .pauseAll, maximized: .mute, fullscreen: .stop,
                                                              playingAudio: .pause, displayAsleep: .stop, onBattery: .pause))
    }

    func testStoredActionsDecodeAndTheMaximizedRuleDefaultsToKeepRunning() throws {
        let stored = #"{"otherApplicationFocused":"pauseAll","otherApplicationFullscreen":"pause"}"#
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(stored.utf8))
        XCTAssertEqual(settings.otherApplicationFocused, .pauseAll)
        XCTAssertEqual(settings.otherApplicationFullscreen, .pause)
        XCTAssertEqual(settings.otherApplicationMaximized, .keepRunning)
        let reencoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(reencoded, settings)
    }
}
