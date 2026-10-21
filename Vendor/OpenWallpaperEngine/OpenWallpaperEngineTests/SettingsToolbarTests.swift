import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// The settings window's toolbar: every tab is selectable, so the one shown is highlighted.
final class SettingsToolbarTests: XCTestCase {
    /// The tabs in the order chosen for the window, Plugins just before About.
    func testEveryTabIsSelectableInOrder() {
        XCTAssertEqual(SettingsTab.allCases, [
            .general, .performance, .optimizations, .assets, .updates, .privacy,
            .permissions, .diagnostics, .plugins, .about,
        ])
        let identifiers = SettingsTab.allCases.map(\.toolbarIdentifier)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab(toolbarIdentifier: tab.toolbarIdentifier), tab)
            XCTAssertEqual(SettingsTab(rawValue: tab.rawValue), tab)
        }
    }

    /// A search finds a setting on the tab it moved to.
    func testSearchFindsMovedSettings() {
        let storage = SettingsSearch.results(for: "wallpaper storage", locale: Locale(identifier: "en"))
        XCTAssertEqual(storage.first?.tab, .assets)
        XCTAssertEqual(storage.first?.anchor, SettingsAnchor.storage)
        XCTAssertEqual(SettingsSearch.results(for: "api key").first?.tab, .assets)
        XCTAssertEqual(SettingsSearch.results(for: "log level").first?.tab, .diagnostics)
        XCTAssertEqual(SettingsSearch.results(for: "rendering").first?.tab, .optimizations)
        XCTAssertTrue(SettingsSearch.results(for: "   ").isEmpty)
        XCTAssertTrue(SettingsSearch.results(for: "zzzz-no-such-setting").isEmpty)
    }

    /// A shortcut's name finds the Keyboard Shortcuts section, which opens for it.
    func testSearchFindsAShortcut() {
        let results = SettingsSearch.results(for: "import wallpaper from folder", locale: Locale(identifier: "en"))
        XCTAssertEqual(results.first?.tab, .general)
        XCTAssertEqual(results.first?.anchor, SettingsAnchor.shortcuts)
    }
}
