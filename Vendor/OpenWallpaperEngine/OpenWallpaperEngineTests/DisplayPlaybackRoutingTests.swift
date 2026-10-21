import XCTest
@testable import OpenWallpaperEngine

/// How each display's playback reaches a wallpaper instance shown on several displays
/// (`DisplayPlayback.shared`, `DisplayPlaybackRouting`): it renders while any display plays, and
/// its sound, played once, stops only when every display agrees.
final class DisplayPlaybackRoutingTests: XCTestCase {
    private func key(_ folder: String, type: String = "scene", properties: WallpaperPropertyScope = .shared) -> WallpaperInstanceKey {
        let project = WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: type)
        return WallpaperInstanceKey(WEWallpaper(using: project, where: URL(filePath: "/tmp/owe/\(folder)")),
                                    properties: properties)
    }

    // MARK: Aggregation

    func testAnInstanceRendersWhileAnyDisplayPlays() {
        XCTAssertTrue(DisplayPlayback.shared([.pause, .run]).rendersFrames)
        XCTAssertTrue(DisplayPlayback.shared([.stop, .mute]).rendersFrames)
        XCTAssertFalse(DisplayPlayback.shared([.pause, .stop]).rendersFrames, "every display paused: no rendering")
    }

    func testSoundStopsOnlyWhenEveryDisplayAgrees() {
        XCTAssertTrue(DisplayPlayback.shared([.mute, .run]).playsSound)
        XCTAssertTrue(DisplayPlayback.shared([.pause, .run]).playsSound)
        XCTAssertFalse(DisplayPlayback.shared([.mute, .pause]).playsSound)
        XCTAssertFalse(DisplayPlayback.shared([.mute, .mute]).playsSound)
    }

    func testNoDisplayMeansRunning() {
        XCTAssertEqual(DisplayPlayback.shared([]), .run)
    }

    func testOnlyStopHidesTheWindow() {
        XCTAssertEqual(DisplayPlayback.allCases.filter(\.hidesWindow), [.stop])
    }

    // MARK: Routing

    func testASharedInstanceFollowsItsDisplaysOnly() {
        let shared = key("a"), other = key("b")
        let keys = ["1": shared, "2": shared, "3": other]
        let enabled: Set<String> = ["1", "2", "3"]
        XCTAssertEqual(DisplayPlaybackRouting.instance(shared, instanceKeys: keys, enabledScreens: enabled,
                                                       states: ["1": .pause, "2": .run, "3": .stop]), .run)
        XCTAssertEqual(DisplayPlaybackRouting.instance(shared, instanceKeys: keys, enabledScreens: enabled,
                                                       states: ["1": .pause, "2": .stop, "3": .run]), .pause,
                       "the third display plays another wallpaper")
    }

    func testDisabledDisplaysAndDisplaysWithoutAStateDontPause() {
        let shared = key("a")
        let keys = ["1": shared, "2": shared]
        XCTAssertEqual(DisplayPlaybackRouting.instance(shared, instanceKeys: keys, enabledScreens: ["1"],
                                                       states: ["1": .pause, "2": .run]), .pause, "display 2 is disabled")
        XCTAssertEqual(DisplayPlaybackRouting.instance(shared, instanceKeys: keys, enabledScreens: ["1", "2"],
                                                       states: ["1": .pause]), .run, "display 2 isn't evaluated yet")
    }

    func testTheWallpapersSoundFollowsEveryInstanceOfIt() {
        // Two displays with different properties run two instances of one wallpaper.
        let first = key("a"), second = key("a", properties: .display("2"))
        let keys = ["1": first, "2": second]
        let states: [String: DisplayPlayback] = ["1": .mute, "2": .run]
        XCTAssertEqual(DisplayPlaybackRouting.instance(first, instanceKeys: keys, enabledScreens: ["1", "2"], states: states), .mute)
        XCTAssertTrue(DisplayPlaybackRouting.wallpaper(first, instanceKeys: keys, enabledScreens: ["1", "2"],
                                                       states: states).playsSound,
                      "display 2 still plays the wallpaper unmuted")
    }

    func testTheSoundMovesToADisplayThatStillPlays() {
        let web = key("web", type: "web")
        let keys = ["1": web, "2": web, "3": key("other")]
        let enabled: Set<String> = ["1", "2", "3"]
        XCTAssertEqual(DisplayPlaybackRouting.audibleCandidates(of: web, instanceKeys: keys, enabledScreens: enabled,
                                                                states: ["1": .pause, "2": .run]), ["2"])
        let audible = WallpaperAudioRouting.audibleScreen(
            of: web, assignments: keys, enabledScreens: DisplayPlaybackRouting.audibleCandidates(
                of: web, instanceKeys: keys, enabledScreens: enabled, states: ["1": .pause, "2": .run]),
            mainScreen: "1")
        XCTAssertEqual(audible, "2", "the main display is paused, so the other plays the sound")
        XCTAssertEqual(DisplayPlaybackRouting.audibleCandidates(of: web, instanceKeys: keys, enabledScreens: enabled,
                                                                states: ["1": .mute, "2": .pause]), enabled,
                       "nobody plays it unmuted: the usual display keeps it, silenced")
    }
}
