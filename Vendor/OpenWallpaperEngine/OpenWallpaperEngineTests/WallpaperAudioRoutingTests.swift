import XCTest
@testable import OpenWallpaperEngine

/// Where wallpapers' sound comes from (`WallpaperAudioRouting`): once per wallpaper, from the
/// main display when it shows it; web pages on the other displays are muted.
final class WallpaperAudioRoutingTests: XCTestCase {
    private func key(_ folder: String, type: String = "web") -> WallpaperInstanceKey {
        let project = WEProject(file: "index.html", preview: "preview.jpg", title: folder, type: type)
        return WallpaperInstanceKey(WEWallpaper(using: project, where: URL(filePath: "/tmp/owe/\(folder)")))
    }

    func testTheSameWebWallpaperOnTwoDisplaysPlaysFromOne() {
        let web = key("web")
        let assignments = ["1": web, "2": web]
        let audible = assignments.keys.filter {
            WallpaperAudioRouting.audibleScreen(of: web, assignments: assignments, enabledScreens: ["1", "2"],
                                                mainScreen: "2") == $0
        }
        XCTAssertEqual(audible, ["2"], "the main display's page plays; the other is muted")
    }

    func testWithoutTheMainDisplayTheLowestIdPlays() {
        let web = key("web")
        let assignments = ["5": web, "3": web, "1": key("other")]
        XCTAssertEqual(WallpaperAudioRouting.audibleScreen(of: web, assignments: assignments,
                                                           enabledScreens: ["1", "3", "5"], mainScreen: "1"), "3")
    }

    func testDifferentWallpapersEachPlayTheirOwn() {
        let a = key("a"), b = key("b", type: "scene")
        let assignments = ["1": a, "2": b]
        XCTAssertEqual(WallpaperAudioRouting.audibleScreen(of: a, assignments: assignments, enabledScreens: ["1", "2"],
                                                           mainScreen: "1"), "1")
        XCTAssertEqual(WallpaperAudioRouting.audibleScreen(of: b, assignments: assignments, enabledScreens: ["1", "2"],
                                                           mainScreen: "1"), "2")
    }

    func testDisabledDisplaysDontPlay() {
        let web = key("web")
        let assignments = ["1": web, "2": web]
        XCTAssertEqual(WallpaperAudioRouting.audibleScreen(of: web, assignments: assignments, enabledScreens: ["2"],
                                                           mainScreen: "1"), "2")
        XCTAssertNil(WallpaperAudioRouting.audibleScreen(of: web, assignments: assignments, enabledScreens: [],
                                                         mainScreen: "1"))
    }

    /// The script fallback mutes media elements and only unmutes the ones it muted.
    func testTheMuteScriptRestoresOnlyWhatItMuted() {
        let mute = WebPageAudio.mediaScript(muted: true)
        XCTAssertTrue(mute.contains("window.__oweMuted=true"))
        XCTAssertTrue(mute.contains("m.__oweMuted=true"))
        XCTAssertTrue(WebPageAudio.mediaScript(muted: false).contains("window.__oweMuted=false"))
    }

    /// Settings → Audio Output off silences every wallpaper; the preview window always plays.
    @MainActor
    func testAudioOutputOffSilencesEveryWallpaper() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        XCTAssertTrue(model.playsInstanceAudio)
        XCTAssertTrue(model.shouldPlayAudio(on: model.selectedScreenId))
        model.audioOutputEnabled = false
        XCTAssertFalse(model.playsInstanceAudio)
        XCTAssertFalse(model.shouldPlayAudio(on: model.selectedScreenId))
    }
}
