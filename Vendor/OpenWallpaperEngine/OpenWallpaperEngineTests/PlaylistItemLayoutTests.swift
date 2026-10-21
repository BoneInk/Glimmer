import SwiftUI
import XCTest
@testable import OpenWallpaperEngine

/// The Playlists tab's List/Grid choice: Grid unless the user chose List, kept in the app's
/// defaults (an AppKit window has no SwiftUI scene, so `@SceneStorage` never changed).
final class PlaylistItemLayoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "PlaylistItemLayoutTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func stored() -> AppStorage<PlaylistItemLayout> {
        AppStorage(wrappedValue: PlaylistItemLayout.defaultLayout, PlaylistItemLayout.defaultsKey, store: defaults)
    }

    func testGridWithoutAChoice() {
        XCTAssertEqual(PlaylistItemLayout.defaultLayout, .grid)
        XCTAssertEqual(stored().wrappedValue, .grid)
    }

    func testTheChoiceIsKept() {
        stored().wrappedValue = .list
        XCTAssertEqual(defaults.string(forKey: PlaylistItemLayout.defaultsKey), "list")
        XCTAssertEqual(stored().wrappedValue, .list)
        stored().wrappedValue = .grid
        XCTAssertEqual(stored().wrappedValue, .grid)
    }

    func testAnUnknownStoredValueFallsBackToGrid() {
        defaults.set("mosaic", forKey: PlaylistItemLayout.defaultsKey)
        XCTAssertEqual(stored().wrappedValue, .grid)
    }

    func testTheViewKeepsTheLayoutInTheAppsDefaults() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "OpenWallpaperEngine/UI/Playlists/PlaylistView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("@SceneStorage"), "the main window is an AppKit window: @SceneStorage never changes there")
        XCTAssertTrue(source.contains("@AppStorage(PlaylistItemLayout.defaultsKey, store: .app)"))
    }
}
