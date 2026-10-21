import XCTest
@testable import OpenWallpaperEngine

/// Music sync maps an audio level to the same zoom, tilt, saturation and pace on every video path.
@MainActor
final class VideoMusicSyncEffectTests: XCTestCase {
    func testLevelMapsToTransformValues() {
        let effect = VideoMusicSyncEffect(zoomAmount: 0.08, tiltAmount: 3, saturationAmount: 0.6, paceAmount: 0.25)
        XCTAssertEqual(effect.zoom(at: 0), 1)
        XCTAssertEqual(effect.zoom(at: 0.5), 1.04, accuracy: 1e-9)
        XCTAssertEqual(effect.tilt(at: 0.5), 1.5, accuracy: 1e-9)
        XCTAssertEqual(effect.saturation(at: 0.5), 1.3, accuracy: 1e-9)
        XCTAssertEqual(effect.rate(base: 1, level: 0.4), 1.1, accuracy: 1e-6)
    }

    func testValuesStayInRange() {
        let effect = VideoMusicSyncEffect(zoomAmount: -2, saturationAmount: -2, paceAmount: -1)
        XCTAssertEqual(effect.zoom(at: 1), 0.1, "the picture never collapses")
        XCTAssertEqual(effect.saturation(at: 1), 0)
        XCTAssertEqual(effect.rate(base: 0.5, level: 1), 0, "negative pace slows to a stop, never backwards")
        XCTAssertEqual(VideoMusicSyncEffect(paceAmount: 0.25).rate(base: 0, level: 1), 0, "a paused video stays paused")
    }

    func testSwitchedOffEffectsLeaveThePictureAlone() {
        let effect = VideoMusicSyncEffect()
        XCTAssertFalse(effect.isActive)
        XCTAssertEqual(effect.zoom(at: 1), 1)
        XCTAssertEqual(effect.tilt(at: 1), 0)
        XCTAssertEqual(effect.saturation(at: 1), 1)
        XCTAssertEqual(effect.rate(base: 1, level: 1), 1)
    }

    func testAmountsComeFromTheSwitchedOnSettings() {
        let wallpaper = WEWallpaper(using: WEProject(file: "a.webm", preview: "p.jpg", title: "sync", type: "video"),
                                    where: URL(fileURLWithPath: "/tmp/owe-music-sync-\(UUID().uuidString)"))
        defer {
            for name in ["zoom", "tilt", "saturation", "pace"] {
                UserDefaults.app.removeObject(forKey: VideoMusicSyncSettings.key(wallpaper, "\(name)Enabled"))
                UserDefaults.app.removeObject(forKey: VideoMusicSyncSettings.key(wallpaper, "\(name)Amount"))
            }
        }
        XCTAssertEqual(VideoMusicSyncEffect(wallpaper), VideoMusicSyncEffect())
        UserDefaults.app.set(true, forKey: VideoMusicSyncSettings.key(wallpaper, "zoomEnabled"))
        UserDefaults.app.set(true, forKey: VideoMusicSyncSettings.key(wallpaper, "paceEnabled"))
        UserDefaults.app.set(-0.5, forKey: VideoMusicSyncSettings.key(wallpaper, "paceAmount"))
        UserDefaults.app.set(9, forKey: VideoMusicSyncSettings.key(wallpaper, "tiltAmount"))
        XCTAssertEqual(VideoMusicSyncEffect(wallpaper), VideoMusicSyncEffect(zoomAmount: 0.08, paceAmount: -0.5),
                       "defaults for an unset amount; an amount whose switch is off is 0")
    }

    func testFrameCarriesPaceOnlyWhenPaceIsOn() {
        let noPace = WebKitVideoPlayer.MusicSyncFrame(effect: VideoMusicSyncEffect(zoomAmount: 0.1), level: 1,
                                                      smoothedLevel: 1, baseRate: 1)
        XCTAssertEqual(noPace, WebKitVideoPlayer.MusicSyncFrame(zoom: 1.1, tilt: 0, saturation: 1, rate: nil))
        let paced = WebKitVideoPlayer.MusicSyncFrame(effect: VideoMusicSyncEffect(paceAmount: 0.5), level: 1,
                                                     smoothedLevel: 0.5, baseRate: 1)
        XCTAssertEqual(paced.rate ?? 0, 1.25, accuracy: 1e-6, "pace follows the smoothed level")
    }

    func testScriptCarriesTheFrame() {
        let script = WebKitVideoPlayer.musicSyncScript(.init(zoom: 1.04, tilt: -1.5, saturation: 1.3, rate: 1.1))
        XCTAssertTrue(script.contains("{zoom:1.0400,tilt:-1.5000,saturation:1.3000,rate:1.1000}"), script)
        XCTAssertTrue(WebKitVideoPlayer.musicSyncScript(.init(zoom: 1, tilt: 0, saturation: 1, rate: nil)).contains("rate:null"))
        XCTAssertTrue(WebKitVideoPlayer.musicSyncScript(nil).contains("window.__oweSync=null;"))
        XCTAssertTrue(WebKitVideoPlayer.musicSyncScript(.init(zoom: .nan, tilt: .infinity, saturation: 1, rate: nil))
            .contains("{zoom:0.0000,tilt:0.0000,"), "a non-finite value never reaches the page")
    }

    func testPaceRateMovesInStepsAFewTimesASecond() {
        var limiter = WebKitVideoPlayer.PaceRateLimiter()
        XCTAssertEqual(limiter.rate(for: 1.02, base: 1, at: 0), 1.02, "the first rate goes through")
        XCTAssertEqual(limiter.rate(for: 1.04, base: 1, at: 1), 1.02, "a change under a step is held")
        XCTAssertEqual(limiter.rate(for: 1.2, base: 1, at: 1.1), 1.2)
        XCTAssertEqual(limiter.rate(for: 1.0, base: 1, at: 1.2), 1.2, "held until the interval passes")
        XCTAssertEqual(limiter.rate(for: 1.0, base: 1, at: 1.4), 1.0)
        XCTAssertEqual(limiter.rate(for: 0, base: 1, at: 1.41), 0, "a stop goes through at once")
        XCTAssertEqual(limiter.rate(for: 1.51, base: 1.5, at: 1.42), 1.51, "a new base rate goes through at once")
    }
}
