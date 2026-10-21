import XCTest
@testable import OpenWallpaperEngine

/// What the menu bar's menus and the Displays sheet show: recents whose folder is gone are left
/// out, a display without a wallpaper reads "No wallpaper", and the mouse goes to web wallpapers
/// only while one is shown.
@MainActor
final class StatusMenuStateTests: XCTestCase {
    private func wallpaper(_ name: String, type: String = "scene") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "p.jpg", title: name, type: type),
                    where: URL(fileURLWithPath: "/tmp/owe-recents/\(name)"))
    }

    func testRecentsWhoseFolderIsGoneAreLeftOut() {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.recentWallpapers = [wallpaper("kept"), wallpaper("deleted"), wallpaper("other")]
        let available = model.availableRecentWallpapers { $0.lastPathComponent != "deleted" }
        XCTAssertEqual(available.map(\.project.title), ["kept", "other"])
    }

    func testADisplayWithoutAWallpaperReadsNoWallpaper() {
        XCTAssertEqual(DisplaySettings.title(of: WallpaperViewModel.defaultWallpaper), String(localized: "No wallpaper"))
        XCTAssertEqual(DisplaySettings.title(of: wallpaper("Forest")), "Forest")
    }

    func testMouseForwardingOnlyWhileAWebWallpaperIsShown() {
        let web = WallpaperInstanceKey(wallpaper("page", type: "Web"))
        let scene = WallpaperInstanceKey(wallpaper("scene"))
        XCTAssertTrue(WebWallpaperMouseForwarder.isNeeded(instanceKeys: ["1": scene, "2": web],
                                                          enabledScreens: ["1", "2"], stopped: false))
        XCTAssertFalse(WebWallpaperMouseForwarder.isNeeded(instanceKeys: ["1": scene],
                                                           enabledScreens: ["1"], stopped: false))
        XCTAssertFalse(WebWallpaperMouseForwarder.isNeeded(instanceKeys: ["2": web],
                                                           enabledScreens: ["1"], stopped: false), "its display is off")
        XCTAssertFalse(WebWallpaperMouseForwarder.isNeeded(instanceKeys: ["2": web],
                                                           enabledScreens: ["2"], stopped: true), "stopped")
    }
}
