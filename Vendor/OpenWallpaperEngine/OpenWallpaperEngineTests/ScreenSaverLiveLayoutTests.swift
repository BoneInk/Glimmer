import XCTest
@testable import OpenWallpaperEngine

/// Which ring each display shows in the live screen saver's manifest.
final class ScreenSaverLiveLayoutTests: XCTestCase {
    private func size(_ width: Int, _ height: Int) -> ScreenSaverLayoutPlan.Size {
        .init(pixels: SIMD2(width, height), points: SIMD2(width / 2, height / 2))
    }

    func testALoopOnEveryDisplayIsForAnyDisplay() {
        let loop = ScreenSaverLayoutPlan.Loop(content: .init(id: "/w"), sizes: [size(3840, 2160)], displays: ["A", "B"])
        let entries = ScreenSaverPlugin.liveDisplayEntries([loop], pixels: [SIMD2(3840, 2160)], displays: ["A", "B"])
        XCTAssertEqual(entries, [.init(display: nil, ring: 0)])
    }

    func testLoopsPerDisplayNameTheirDisplays() {
        let first = ScreenSaverLayoutPlan.Loop(content: .init(id: "/a"), sizes: [size(3840, 2160)], displays: ["A"])
        let second = ScreenSaverLayoutPlan.Loop(content: .init(id: "/b"), sizes: [size(2560, 1440)], displays: ["B", "C"])
        let entries = ScreenSaverPlugin.liveDisplayEntries([first, second], pixels: [SIMD2(3840, 2160), SIMD2(2560, 1440)],
                                                           displays: ["A", "B", "C", "D"])
        XCTAssertEqual(entries, [.init(display: "A", ring: 0), .init(display: "B", ring: 1), .init(display: "C", ring: 1)],
                       "D shows a web page or a video: not listed, it plays its video")
    }

    func testAStretchNamesEachDisplaysRect() {
        let canvas = CGRect(x: 0, y: 0, width: 3840, height: 1080)
        let loop = ScreenSaverLayoutPlan.Loop(content: .init(id: "/w"), sizes: [size(7680, 2160)], displays: ["L", "R"],
                                              canvas: canvas,
                                              crops: ["L": CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                                      "R": CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])
        let entries = ScreenSaverPlugin.liveDisplayEntries([loop], pixels: [SIMD2(7680, 2160)], displays: ["L", "R"])
        XCTAssertEqual(entries.map(\.display), ["L", "R"])
        XCTAssertEqual(entries.map(\.ring), [0, 0])
        XCTAssertEqual(entries.compactMap(\.crop?.x), [0, 0.5])
        XCTAssertEqual(entries.compactMap(\.crop?.width), [0.5, 0.5])
    }

    func testScenesAndVideosDrawLiveAndPagesThroughChromiumOnly() {
        let folder = URL(filePath: "/tmp/owe-live-kind", directoryHint: .isDirectory)
        func wallpaper(_ type: String, _ file: String) -> WEWallpaper {
            WEWallpaper(using: WEProject(file: file, preview: "p.jpg", title: "t", type: type), where: folder)
        }
        let scene = wallpaper("scene", "scene.json"), web = wallpaper("web", "index.html")
        let webm = wallpaper("video", "clip.webm"), mp4 = wallpaper("video", "clip.mp4")
        XCTAssertEqual(ScreenSaverPlugin.liveKind(of: scene, chromiumInstalled: false), .scene)
        XCTAssertNil(ScreenSaverPlugin.liveKind(of: web, chromiumInstalled: false), "without Chromium: the still")
        XCTAssertEqual(ScreenSaverPlugin.liveKind(of: web, chromiumInstalled: true), .page(.web))
        XCTAssertEqual(ScreenSaverPlugin.liveKind(of: webm, chromiumInstalled: true),
                       WebKitVideoPlayer.handles(webm.mediaURL) ? .page(.webm) : nil)
        XCTAssertEqual(ScreenSaverPlugin.liveKind(of: mp4, chromiumInstalled: false), .video, "drawn live by the app, no file copied")
    }

    func testAPagesRingIsThePagesOwnPixels() {
        XCTAssertEqual(ScreenSaverLiveWeb.pixels(points: SIMD2(1512, 982), pixelsPerPoint: 2), SIMD2(3024, 1964))
        XCTAssertEqual(ScreenSaverLiveWeb.pixels(points: SIMD2(1512, 982), pixelsPerPoint: 1), SIMD2(1512, 982))
    }
}
