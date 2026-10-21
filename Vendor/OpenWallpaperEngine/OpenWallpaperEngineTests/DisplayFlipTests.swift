import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// A flipped clone display mirrors its window's content about the window's centre, as WE's
/// "Flip clone display" does, with a layer transform and nothing rendered again.
@MainActor
final class DisplayFlipTests: XCTestCase {
    func testAFlippedWindowMirrorsItsContentInPlace() throws {
        let wallpaper = NSView()
        wallpaper.wantsLayer = true
        let content = WallpaperWindowContentView(content: wallpaper)
        content.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        // AppKit assembles the views' layer tree in a window, on the next display cycle; the
        // window stays off screen.
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        content.display()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let layer = try XCTUnwrap(content.layer)
        let inner = try XCTUnwrap(wallpaper.layer)

        content.isMirrored = true
        let left = layer.convert(CGPoint(x: 10, y: 50), from: inner)
        XCTAssertEqual(left.x, 390, accuracy: 0.5, "the content's left edge shows at the window's right")
        XCTAssertEqual(left.y, 50, accuracy: 0.5)
        XCTAssertTrue(wallpaper.isMirroredOnScreen)

        window.setContentSize(NSSize(width: 600, height: 200))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(layer.convert(CGPoint(x: 10, y: 50), from: inner).x, 590, accuracy: 0.5, "follows a resize")

        content.isMirrored = false
        XCTAssertEqual(layer.convert(CGPoint(x: 10, y: 50), from: inner).x, 10, accuracy: 0.5)
        XCTAssertFalse(wallpaper.isMirroredOnScreen)
    }
}
