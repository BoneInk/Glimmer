import XCTest
@testable import OpenWallpaperEngine

/// Auto-advance passes over wallpapers flagged by safe restart.
final class PlaylistSkipTests: XCTestCase {
    private func playlist(_ count: Int) -> WallpaperPlaylist {
        WallpaperPlaylist(name: "p", items: (0..<count).map { index in
            WallpaperPlaylistItem(wallpaper: WEWallpaper(
                using: WEProject(file: "scene.json", preview: "p.jpg", title: "\(index)", type: "scene"),
                where: URL(fileURLWithPath: "/tmp/owe-playlist/\(index)")))
        })
    }

    func testSequentialAdvanceSkipsFlaggedItems() {
        let list = playlist(4)
        XCTAssertEqual(list.nextIndex(after: 0, shuffle: false, repeats: true, isSkipped: { $0 == 1 }), 2)
        XCTAssertEqual(list.nextIndex(after: 2, shuffle: false, repeats: true, isSkipped: { $0 == 3 || $0 == 0 }), 1)
        XCTAssertNil(list.nextIndex(after: 2, shuffle: false, repeats: false, isSkipped: { $0 == 3 }))
        XCTAssertEqual(list.nextIndex(after: 0, shuffle: false, repeats: true, isSkipped: { _ in false }), 1)
    }

    func testEverythingFlaggedLeavesNothingToShow() {
        let list = playlist(3)
        XCTAssertNil(list.nextIndex(after: 0, shuffle: false, repeats: true, isSkipped: { _ in true }))
        XCTAssertNil(list.nextIndex(after: 0, shuffle: true, repeats: true, isSkipped: { _ in true }))
    }

    func testShufflePicksOnlyUnflaggedItems() {
        let list = playlist(4)
        let picked = list.nextIndex(after: 0, shuffle: true, repeats: true, isSkipped: { $0 != 2 },
                                    random: { $0.lowerBound })
        XCTAssertEqual(picked, 2)
    }
}
