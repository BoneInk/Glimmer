import XCTest
@testable import OpenWallpaperEngine

/// What the Details pane says about a wallpaper in the screen saver: scenes are drawn live, web
/// wallpapers and WebM videos through Chromium, video wallpapers drawn live at once, and nothing is
/// said while the plugin is off.
final class ScreenSaverStatusTests: XCTestCase {
    private typealias Plugin = ScreenSaverPlugin

    private func wallpaper(type: String, file: String = "scene.json",
                           directory: URL = URL(fileURLWithPath: "/tmp/owe-status-test")) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: file, preview: "p.jpg", title: "t", type: type), where: directory)
    }

    func testScenesWebPagesVideosAndWebMVideosAreEligible() {
        XCTAssertTrue(Plugin.isEligible(wallpaper(type: "scene")))
        XCTAssertTrue(Plugin.isEligible(wallpaper(type: "Scene")))
        XCTAssertTrue(Plugin.isEligible(wallpaper(type: "web", file: "index.html")))
        XCTAssertTrue(Plugin.isEligible(wallpaper(type: "video", file: "clip.webm")))
        XCTAssertTrue(Plugin.isEligible(wallpaper(type: "video", file: "clip.mp4")))
        XCTAssertFalse(Plugin.isEligible(wallpaper(type: "application", file: "app.exe")))
        XCTAssertFalse(Plugin.isEligible(WEWallpaper(using: .invalid, where: URL(fileURLWithPath: "/tmp/x"))))
    }

    func testScenesAreAvailableAtOnce() {
        XCTAssertEqual(Plugin.status(for: wallpaper(type: "scene"), enabled: true, chromiumInstalled: false),
                       .available, "drawn live: nothing to make first")
    }

    func testPagesNeedChromium() {
        for page in [wallpaper(type: "web", file: "index.html"), wallpaper(type: "video", file: "clip.webm")] {
            XCTAssertEqual(Plugin.status(for: page, enabled: true, chromiumInstalled: false), .needsChromium)
            XCTAssertEqual(Plugin.status(for: page, enabled: true, chromiumInstalled: true), .available)
        }
    }

    func testVideosAreAvailableAtOnce() {
        let video = wallpaper(type: "video", file: "clip.mp4")
        XCTAssertEqual(Plugin.status(for: video, enabled: true, chromiumInstalled: false), .available,
                       "drawn live: no file to put in place first")
    }

    func testNotEligibleTypesSayNotAvailable() {
        for type in ["application", "preset"] {
            XCTAssertEqual(Plugin.status(for: wallpaper(type: type), enabled: true, chromiumInstalled: true),
                           .notEligible, type)
        }
        XCTAssertEqual(Plugin.status(for: wallpaper(type: "video", file: "clip.mkv"), enabled: true,
                                     chromiumInstalled: true), .notEligible)
    }

    func testNoStatusWhenDisabled() {
        XCTAssertNil(Plugin.status(for: wallpaper(type: "scene"), enabled: false, chromiumInstalled: true))
        XCTAssertNil(Plugin.status(for: wallpaper(type: "video"), enabled: false, chromiumInstalled: true))
    }

    @MainActor
    func testANewPluginHasNoStatus() {
        let plugin = ScreenSaverPlugin(store: ScreenSaverVideoStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "owe-status-\(UUID().uuidString)")),
                                       installer: ScreenSaverInstaller(bundledSaver: nil,
                                                                       saversDirectory: URL(fileURLWithPath: "/tmp/owe-status-savers"),
                                                                       mayInstall: false))
        XCTAssertNil(plugin.status(for: wallpaper(type: "scene")), "off")
        XCTAssertNil(plugin.status(for: wallpaper(type: "video", file: "clip.mp4")), "off")
    }
}
