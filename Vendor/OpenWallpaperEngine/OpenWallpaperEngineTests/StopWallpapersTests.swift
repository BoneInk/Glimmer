import AppKit
import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// WE's Stop wallpapers (`WallpaperViewModel.isStopped`, `AppDelegate+StopWallpapers`): pause,
/// stop and resume; application rules under a user's stop; each display's wallpaper back exactly;
/// the wallpapers' instances released when their windows close.
@MainActor
final class StopWallpapersTests: XCTestCase {
    private let displays = [DisplayIdentity(screenId: "1", identity: "UUID-A"),
                            DisplayIdentity(screenId: "2", identity: "UUID-B"),
                            DisplayIdentity(screenId: "3", identity: "UUID-C")]

    private func wallpaper(_ folder: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: folder, type: "scene"),
                    where: URL(filePath: "/tmp/owe-stop-tests/\(folder)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b"), "3": wallpaper("c")]
        model.refreshDisplayLayout()
        return model
    }

    func testPlayingPausedStoppedResumed() {
        let model = model()
        var told: [Bool] = []
        model.onStoppedChange = { told.append($0) }
        XCTAssertFalse(model.isStopped)

        model.playRate = 0 // Pause
        model.stopWallpapers()
        XCTAssertTrue(model.isStopped)
        XCTAssertEqual(model.playRate, 0, "stopping leaves the pause as it is")
        model.stopWallpapers()
        XCTAssertEqual(told, [true], "a second Stop changes nothing")

        model.resumeWallpapers()
        XCTAssertFalse(model.isStopped)
        XCTAssertEqual(model.playRate, 1, "Resume plays, as WE's Play does")
        XCTAssertEqual(told, [true, false])

        // Stop while playing, then resume: playing again; a resume with nothing to resume is nothing.
        model.stopWallpapers()
        model.resumeWallpapers()
        model.resumeWallpapers()
        XCTAssertEqual(model.playRate, 1)
        XCTAssertEqual(told, [true, false, true, false])
    }

    func testResumeRestoresEachDisplaysWallpaperExactly() {
        let model = model()
        let keys = model.instanceKeys
        model.stopWallpapers()
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "b", "c"],
                       "a stopped display keeps its wallpaper")
        model.resumeWallpapers()
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "b", "c"])
        XCTAssertEqual(model.instanceKeys, keys, "each display runs what it ran, with the same properties")
    }

    func testApplicationRulesDontEndAUserStopAndApplyOnResume() {
        let model = model()
        model.stopWallpapers()
        // A rule's Stop, Pause and load, while the user's stop holds.
        model.rulePlayback = ["1": .stop, "2": .pause]
        model.wallpapers["3"] = wallpaper("rule")
        XCTAssertTrue(model.isStopped, "a rule's stop or load doesn't end the user's stop")
        model.rulePlayback = [:]
        XCTAssertTrue(model.isStopped, "nor does a rule ending")

        model.rulePlayback = ["1": .stop]
        model.resumeWallpapers()
        XCTAssertFalse(model.isStopped)
        XCTAssertEqual(model.displayPlayback["1"], .stop, "the rule in force still stops its display")
        XCTAssertEqual(model.wallpaper(for: "3").project.title, "rule", "the rule's wallpaper shows")
    }

    /// A display's view holds its wallpaper's running instance; stopping drops the view, and
    /// closing the window as Stop does drops the rest: the registries are left empty.
    func testStoppingReleasesEveryInstance() {
        // A video (the file needn't exist): an AVKit player, or a Metal scene with WE's assets.
        let video = WEWallpaper(using: WEProject(file: "clip.mp4", preview: "p.jpg", title: "clip", type: "video"),
                                where: URL(filePath: "/tmp/owe-stop-tests/clip"))
        let model = model()
        model.wallpapers["1"] = video
        func running() -> Int { model.sceneInstances.instances.count + model.videoInstances.instances.count }

        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 64, height: 64), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DisplayWallpaperView(viewModel: model, screenId: "1"))
        window.orderFront(nil)
        waitUntil("the display's view to run its wallpaper") { running() == 1 }

        model.stopWallpapers()
        waitUntil("nothing to run once stopped") { running() == 0 }
        AppDelegate.closeWallpaperWindows(["1": window])
        XCTAssertNil(window.contentView)
        XCTAssertFalse(window.isVisible)

        model.resumeWallpapers()
        XCTAssertEqual(running(), 0, "a closed window loads nothing; the app delegate makes new ones on resume")
    }
}
