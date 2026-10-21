import XCTest
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's window lays out and settles. A split view nested in the editor's
/// split view once reported changing minimum sizes until AppKit stopped the layout with an
/// exception ("more Update Constraints passes than there are views"), which crashed the app as
/// soon as the editor opened.
@MainActor
final class WallpaperEditorWindowLayoutTests: XCTestCase {
    func testTheEditorWindowLaysOutAndSettles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
         "objects": []}
        """.utf8).write(to: folder.appending(path: "scene.json"))
        try Data(#"{"file": "scene.json", "title": "Layout", "type": "scene"}"#.utf8)
            .write(to: folder.appending(path: "project.json"))
        let wallpaper = WEWallpaper(using: WEProject(file: "scene.json", title: "Layout", type: "scene"), where: folder)

        let editor = try WallpaperEditorController(wallpaper: wallpaper)
        defer { editor.window.close() }
        for size in [NSSize(width: 1360, height: 840), NSSize(width: 960, height: 600), NSSize(width: 1800, height: 1100)] {
            editor.window.setContentSize(size)
            editor.window.orderFront(nil)
            for _ in 0..<5 {
                editor.window.contentView?.layoutSubtreeIfNeeded()
                editor.window.displayIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        XCTAssertGreaterThan(editor.window.frame.width, 0)
    }
}
