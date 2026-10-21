import XCTest
@testable import OpenWallpaperEngine

/// The library bottom bar's Edit Wallpaper button: enabled only for a selected scene wallpaper.
final class EditWallpaperButtonStateTests: XCTestCase {
    private func wallpaper(_ type: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "scene.json", preview: "preview.jpg", title: "T", type: type),
                    where: FileManager.default.temporaryDirectory.appending(path: "EditWallpaperButtonState-\(type)"))
    }

    func testEnabledOnlyForASceneWallpaper() {
        XCTAssertEqual(EditWallpaperButtonState(selection: wallpaper("scene")), .enabled)
        XCTAssertEqual(EditWallpaperButtonState(selection: wallpaper("Scene")), .enabled)
        XCTAssertTrue(EditWallpaperButtonState(selection: wallpaper("scene")).isEnabled)
        for type in ["video", "web", "application", ""] {
            let state = EditWallpaperButtonState(selection: wallpaper(type))
            XCTAssertEqual(state, .notAScene, type)
            XCTAssertFalse(state.isEnabled, type)
        }
    }

    func testDisabledWithNothingSelected() {
        XCTAssertEqual(EditWallpaperButtonState(selection: nil), .nothingSelected)
        XCTAssertFalse(EditWallpaperButtonState(selection: nil).isEnabled)
        // The Details panel falls back to the placeholder when no wallpaper is selected or set.
        XCTAssertNil(EditWallpaperButtonState.selection(displayed: WallpaperViewModel.defaultWallpaper))
        XCTAssertEqual(EditWallpaperButtonState(displayed: WallpaperViewModel.defaultWallpaper), .nothingSelected)
        XCTAssertEqual(EditWallpaperButtonState(displayed: wallpaper("scene")), .enabled)
        XCTAssertEqual(EditWallpaperButtonState(displayed: wallpaper("video")), .notAScene)
    }

    /// It agrees with Window › Wallpaper Editor (⌥⌘E), which is enabled by the same rule.
    func testAgreesWithTheMenuItemRule() {
        for type in ["scene", "video", "web"] {
            let selection = wallpaper(type)
            XCTAssertEqual(EditWallpaperButtonState(selection: selection).isEnabled,
                           WallpaperEditorController.canEdit(selection), type)
        }
    }
}
