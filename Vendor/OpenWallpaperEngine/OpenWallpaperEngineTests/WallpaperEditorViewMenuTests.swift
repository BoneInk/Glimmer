import AppKit
import XCTest
import OWEEditor
@testable import OpenWallpaperEngine

/// The Wallpaper Editor process's View menu: Wallpaper Engine's editor View menu, each item
/// sending its command to the key editor window.
@MainActor
final class WallpaperEditorViewMenuTests: XCTestCase {
    func testTheViewMenuListsWEsCommands() throws {
        let menu = WallpaperEditorMenu.make(helpTarget: NSApp, help: #selector(NSApplication.showHelp(_:)))
        let view = try XCTUnwrap(menu.items.first { $0.submenu?.title == EditorViewCommand.menuTitle }?.submenu)
        XCTAssertEqual(menu.items.firstIndex { $0.submenu === view }, 3, "after Edit, before Window")
        let commands = view.items.compactMap { ($0.representedObject as? WallpaperEditorMenu.ViewCommandBox)?.command }
        XCTAssertEqual(commands, [.resetCamera, .showGrid, .showSelectionBox, .desktopPreview, .phonePreview, .lowFrameRate])
        XCTAssertTrue(view.items.filter { $0.representedObject != nil }.allSatisfy { $0.action == WallpaperEditorMenu.viewCommand })
        let ratios = try XCTUnwrap(view.items[1].submenu).items.compactMap { ($0.representedObject as? WallpaperEditorMenu.ViewCommandBox)?.command }
        XCTAssertEqual(ratios, EditorViewOptions.PreviewRatio.allCases.map { .previewRatio($0) })
    }
}
