import XCTest
@testable import OpenWallpaperEngine

/// A clone on the displays (WE renders a clone once and mirrors it): its members run their main
/// display's instance, a wallpaper set on one is set on all, a video decodes once, and a muted
/// display gives up the sound.
@MainActor
final class DisplayLayoutCloneTests: XCTestCase {
    private let displays = [DisplayIdentity(screenId: "1", identity: "UUID-A"),
                            DisplayIdentity(screenId: "2", identity: "UUID-B"),
                            DisplayIdentity(screenId: "3", identity: "UUID-C")]

    private func wallpaper(_ folder: String, type: String = "scene", file: String = "scene.json") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: file, preview: "preview.jpg", title: folder, type: type),
                    where: URL(filePath: "/tmp/owe-clone-tests/\(folder)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b"), "3": wallpaper("c")]
        return model
    }

    func testAWallpaperPerDisplayLeavesEveryDisplaysWallpaper() {
        let model = model()
        model.refreshDisplayLayout()
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "b", "c"])
        XCTAssertNotEqual(model.instanceKey(for: "1"), model.instanceKey(for: "2"))
    }

    func testCloneMembersShareTheMainDisplaysInstance() {
        let model = model()
        model.addCloneGroup(["1", "2"])
        XCTAssertEqual(model.wallpaper(for: "2").project.title, "a", "the member shows the main display's wallpaper")
        XCTAssertEqual(model.instanceKey(for: "2"), model.instanceKey(for: "1"))
        XCTAssertEqual(model.wallpaper(for: "3").project.title, "c", "display 3 isn't in the group")

        // Each display's view takes its instance from the registry by its key, as `SceneWallpaperView` does.
        final class Instance {}
        let registry = WallpaperInstanceRegistry<WallpaperInstanceKey, Instance>(teardown: { _ in }, deferTeardown: { $0() })
        var made = 0
        let holders = ["1", "2"].map { _ in NSObject() }
        let instances = zip(["1", "2"], holders).map { screen, holder in
            registry.acquire(model.instanceKey(for: screen), holder: holder) { made += 1; return Instance() }
        }
        XCTAssertEqual(made, 1, "the clone renders once")
        XCTAssertTrue(instances[0] === instances[1])
        XCTAssertEqual(registry.holderCount(for: model.instanceKey(for: "1")), 2)
    }

    func testAWallpaperSetOnAMemberIsSetOnTheClone() {
        let model = model()
        model.addCloneGroup(["1", "2"])
        model.setWallpaper(wallpaper("d"), for: "2")
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["d", "d", "c"])
    }

    // WE keeps each monitor's `selectedwallpapers` entry under a clone: a member's own pick stays.

    func testLeavingTheCloneLayoutRestoresEachDisplaysOwnWallpaper() {
        let model = model()
        model.setLayout(.clone)
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "a", "a"])
        XCTAssertEqual(model.wallpapers.mapValues(\.project.title), ["1": "a", "2": "b", "3": "c"],
                       "the clone doesn't overwrite the members' own picks")
        model.setLayout(.perDisplay)
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "b", "c"])
        XCTAssertNotEqual(model.instanceKey(for: "1"), model.instanceKey(for: "2"))
    }

    func testRemovingOneMemberOfAGroupRestoresOnlyThatOne() {
        let model = model()
        model.addCloneGroup(["1", "2", "3"])
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "a", "a"])
        model.removeFromGroup("3")
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "a", "c"])
        XCTAssertEqual(model.instanceKey(for: "2"), model.instanceKey(for: "1"), "display 2 still clones display 1")
    }

    func testChangingTheClonesWallpaperLeavesTheMembersOwnPicks() {
        let model = model()
        model.addCloneGroup(["1", "2"])
        model.setWallpaper(wallpaper("d"), for: ["2"])
        model.setWallpaper(wallpaper("e"), for: ["1", "2", "3"])
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["e", "e", "e"])
        XCTAssertEqual(model.wallpapers["2"]?.project.title, "b", "the member's own pick stays")
        model.removeFromGroup("2")
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["e", "b", "e"])
    }

    func testTheCloneLayoutShowsTheMainDisplaysWallpaperEverywhere() {
        let model = model()
        model.setMainCloneDisplay("3", true) // Not in a clone yet: nothing changes.
        model.setLayout(.clone)
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "a", "a"])
        model.setMainCloneDisplay("2", true)
        XCTAssertTrue(model.isMainCloneDisplay("2"))
        XCTAssertEqual(Set(["1", "2", "3"].map { model.instanceKey(for: $0) }).count, 1)
    }

    func testFlipStaysOffTheMainCloneDisplay() {
        let model = model()
        model.addCloneGroup(["1", "2"])
        XCTAssertFalse(model.toggleFlip("1"), "the main clone display can't be flipped")
        XCTAssertTrue(model.toggleFlip("2"))
        XCTAssertTrue(model.isFlipped("2"))
        XCTAssertFalse(model.isFlipped("1"))
        model.removeFromGroup("2")
        XCTAssertFalse(model.isFlipped("2"), "a display out of the clone shows its wallpaper as it is")
    }

    func testAVideoCloneDecodesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-clone-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: best-effort cleanup.
        let clip = try VideoClipFixture.make(frames: 10, in: directory)
        let video = WEWallpaper(using: WEProject(file: clip.lastPathComponent, preview: "p.jpg", title: "clip", type: "video"),
                                where: clip.deletingLastPathComponent())
        let model = model()
        model.wallpapers["1"] = video
        model.addCloneGroup(["1", "2"])

        // As `AudioReactiveVideoWallpaperView` takes each display's player.
        var made = 0
        let leases = ["1", "2"].map { screen in
            let wallpaper = model.wallpaper(for: screen)
            return WallpaperInstanceLease(model.videoInstances, key: WallpaperInstanceKey(wallpaper)) {
                made += 1
                return VideoWallpaperViewModel(wallpaper: wallpaper, wallpaperViewModel: model)
            }
        }
        defer { leases.forEach { $0.instance.stop(); $0.release() } }
        XCTAssertEqual(made, 1)
        XCTAssertTrue(leases[0].instance.player === leases[1].instance.player, "one player feeds both displays")
    }

    func testAMutedDisplayGivesUpTheSound() {
        let model = model()
        model.addCloneGroup(["1", "2"])
        model.rulePlayback = ["2": .pause]
        model.toggleMute("1")
        XCTAssertEqual(model.displayPlayback, ["1": .mute, "2": .pause], "mute joins the playback rules' states")
        XCTAssertTrue(model.isMuted("1"))

        let key = model.instanceKey(for: "1")
        let keys = model.instanceKeys
        let enabled: Set<String> = ["1", "2", "3"]
        XCTAssertTrue(DisplayPlaybackRouting.instance(key, instanceKeys: keys, enabledScreens: enabled,
                                                      states: model.displayPlayback).rendersFrames,
                      "a muted display still draws")
        XCTAssertFalse(DisplayPlaybackRouting.wallpaper(key, instanceKeys: keys, enabledScreens: enabled,
                                                        states: model.displayPlayback).playsSound,
                       "no display of the clone plays it unmuted")

        model.rulePlayback = [:]
        XCTAssertTrue(DisplayPlaybackRouting.wallpaper(key, instanceKeys: keys, enabledScreens: enabled,
                                                       states: model.displayPlayback).playsSound,
                      "display 2 plays it unmuted")
        XCTAssertEqual(DisplayPlaybackRouting.audibleCandidates(of: key, instanceKeys: keys, enabledScreens: enabled,
                                                                states: model.displayPlayback), ["2"],
                       "the sound comes from the unmuted display")
        model.toggleMute("1")
        XCTAssertEqual(model.displayPlayback, [:])
    }
}
