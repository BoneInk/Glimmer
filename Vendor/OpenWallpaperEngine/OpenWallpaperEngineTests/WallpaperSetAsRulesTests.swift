import XCTest
@testable import OpenWallpaperEngine

/// When the Installed, Discover and Workshop menus enable Set as Wallpaper and Set as Screen Saver.
final class WallpaperSetAsRulesTests: XCTestCase {
    private func wallpaper(_ type: String, file: String = "scene.json") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: file, preview: "preview.jpg", title: "T", type: type),
                    where: FileManager.default.temporaryDirectory.appending(path: "WallpaperSetAsRules-\(type)"))
    }

    private func item(_ tags: [String]) -> WorkshopItem {
        WorkshopItem(id: "123456", title: "Item", previewURL: nil, tags: tags, subscriptions: 0, fileSize: 0,
                     creatorAppId: nil, creatorId: nil, description: nil, votesUp: 0, votesDown: 0)
    }

    func testInstalledWallpapers() {
        for type in ["scene", "Scene", "video", "web", "Web"] {
            XCTAssertTrue(WallpaperSetAsRules.canSetWallpaper(wallpaper(type, file: type.lowercased() == "video" ? "a.mp4" : "index.html")), type)
        }
        XCTAssertFalse(WallpaperSetAsRules.canSetWallpaper(wallpaper("application", file: "a.exe")))
        XCTAssertFalse(WallpaperSetAsRules.canSetWallpaper(wallpaper("Application", file: "a.exe")))
        XCTAssertFalse(WallpaperSetAsRules.canSetWallpaper(WEWallpaper(using: .invalid, where: URL(filePath: "/tmp/none"))))
    }

    func testInstalledScreenSaverTakesScenesVideosAndWebPages() {
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(wallpaper("scene")))
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(wallpaper("video", file: "a.mp4")))
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(wallpaper("video", file: "a.mov")))
        // A web page and a WebM video are drawn through Chromium; without it the menu offers it.
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(wallpaper("web", file: "index.html")))
        let webm = wallpaper("video", file: "a.webm")
        XCTAssertEqual(WallpaperSetAsRules.canSetScreenSaver(webm), WebKitVideoPlayer.handles(webm.mediaURL))
        XCTAssertFalse(WallpaperSetAsRules.canSetScreenSaver(wallpaper("video", file: "a.avi")))
        XCTAssertFalse(WallpaperSetAsRules.canSetScreenSaver(wallpaper("application", file: "a.exe")))
    }

    func testWorkshopItemsByTheirTypeTag() {
        XCTAssertTrue(WallpaperSetAsRules.canSetWallpaper(item(["Scene", "Anime"])))
        XCTAssertTrue(WallpaperSetAsRules.canSetWallpaper(item(["Web"])))
        XCTAssertFalse(WallpaperSetAsRules.canSetWallpaper(item(["Application", "Everyone"])))

        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(item(["Scene"])))
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(item(["video"])))
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(item(["Web"])))
        XCTAssertFalse(WallpaperSetAsRules.canSetScreenSaver(item(["Application"])))
        // A preset carries no type tag: it is checked once downloaded.
        XCTAssertTrue(WallpaperSetAsRules.canSetWallpaper(item(["Preset"])))
        XCTAssertTrue(WallpaperSetAsRules.canSetScreenSaver(item(["Preset"])))
    }
}
