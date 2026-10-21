import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// The menu bar's shortcuts: no two items share one, none takes a system shortcut, the menus use
/// exactly the list Settings shows, and the status menu agrees with the menu bar.
@MainActor
final class MenuShortcutTests: XCTestCase {
    private func combination(_ item: NSMenuItem) -> String {
        "\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)-\(item.keyEquivalent.lowercased())"
    }

    private func items(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items(of:)) ?? []) }
    }

    func testTheShortcutListHasNoDuplicatesOrSystemShortcuts() {
        let combinations = AppShortcut.all.map(\.combination)
        XCTAssertEqual(Set(combinations).count, combinations.count, "two shortcuts share keys")
        XCTAssertEqual(Set(AppShortcut.all.map(\.name)).count, AppShortcut.Name.allCases.count)
        let reserved = Set(AppShortcut.reservedBySystem.map { "\($0.modifiers.rawValue)-\($0.key)" })
        for shortcut in AppShortcut.all {
            XCTAssertFalse(reserved.contains(shortcut.combination), "\(shortcut.name) takes a system shortcut")
            XCTAssertTrue(shortcut.modifiers.contains(.command), "\(shortcut.name) has no ⌘")
        }
    }

    func testTheMenuBarUsesEveryShortcutOnce() {
        let menu = AppDelegate.makeMainMenu()
        let keyed = items(of: menu).filter { !$0.keyEquivalent.isEmpty }
        let combinations = keyed.map(combination)
        XCTAssertEqual(Set(combinations).count, combinations.count, "menu items share a shortcut: \(combinations)")
        XCTAssertEqual(Set(combinations), Set(AppShortcut.all.map(\.combination)))
        let titles = Set(menu.items.compactMap { $0.submenu?.title })
        for expected in ["File", "Edit", "View", "Window", "Help"] {
            XCTAssertTrue(titles.contains(String(localized: String.LocalizationValue(expected))), "no \(expected) menu")
        }
    }

    func testTheStatusMenuAgreesWithTheMenuBar() {
        let bar = items(of: AppDelegate.makeMainMenu()).filter { !$0.keyEquivalent.isEmpty }
        var actions: [String: Selector] = [:]
        for item in bar { actions[combination(item)] = item.action }
        let status = AppDelegate.statusMenuItems(recentWallpapers: NSMenuItem(), assetsMissing: true)
        for item in status where !item.keyEquivalent.isEmpty {
            let action = actions[combination(item)]
            XCTAssertNotNil(action, "\(item.title) has a shortcut the menu bar doesn't")
            XCTAssertEqual(action, item.action, "\(item.title) does something else than the menu bar item")
        }
    }
}
