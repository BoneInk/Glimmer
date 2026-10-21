import XCTest
@testable import OpenWallpaperEngine

/// The left button as the wallpaper receives it (docs/scenescript-plan.md §4.8): only presses
/// that land on the wallpaper count, a release anywhere lets go, and a click shorter than a frame
/// is still seen for one frame.
final class DesktopClickMonitorTests: XCTestCase {
    /// The wallpaper is left of x = 100; a window covers the rest.
    private func monitor() -> DesktopClickMonitor {
        DesktopClickMonitor(hitTest: { $0.x < 100 })
    }

    func testOnlyPressesOnTheWallpaperCount() {
        let clicks = monitor()
        clicks.handle(.leftMouseDown, at: NSPoint(x: 200, y: 10))
        XCTAssertEqual(clicks.state, DesktopClickMonitor.State(isDown: false, presses: 0), "a press on another window")
        clicks.handle(.leftMouseUp, at: NSPoint(x: 200, y: 10))

        clicks.handle(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        XCTAssertEqual(clicks.state, DesktopClickMonitor.State(isDown: true, presses: 1))
        clicks.handle(.leftMouseUp, at: NSPoint(x: 300, y: 10))
        XCTAssertEqual(clicks.state, DesktopClickMonitor.State(isDown: false, presses: 1), "released over another window")
    }

    func testAClickBetweenTwoFramesIsSeenForOneFrame() {
        let clicks = monitor()
        var reader = DesktopClickReader()
        XCTAssertFalse(reader.isDown(clicks.state))
        clicks.handle(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        clicks.handle(.leftMouseUp, at: NSPoint(x: 10, y: 10))
        XCTAssertTrue(reader.isDown(clicks.state), "the press is seen")
        XCTAssertFalse(reader.isDown(clicks.state), "for one frame")

        clicks.handle(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        XCTAssertTrue(reader.isDown(clicks.state))
        XCTAssertTrue(reader.isDown(clicks.state), "held")
        clicks.handle(.leftMouseUp, at: NSPoint(x: 10, y: 10))
        XCTAssertFalse(reader.isDown(clicks.state))
    }

    /// Two renderers (displays) read one monitor, each with its own reader.
    func testReadersAreIndependent() {
        let clicks = monitor()
        var first = DesktopClickReader(), second = DesktopClickReader()
        _ = first.isDown(clicks.state)
        _ = second.isDown(clicks.state)
        clicks.handle(.leftMouseDown, at: NSPoint(x: 10, y: 10))
        clicks.handle(.leftMouseUp, at: NSPoint(x: 10, y: 10))
        XCTAssertTrue(first.isDown(clicks.state))
        XCTAssertTrue(second.isDown(clicks.state))
    }

    /// Nothing that takes mouse events is far off every screen, so a press there is the desktop's
    /// (`windowNumber(at:)` finds no window).
    func testAPressWhereNoWindowTakesMouseEventsLandsOnTheWallpaper() {
        XCTAssertTrue(DesktopClickMonitor.landsOnWallpaper(NSPoint(x: -100_000, y: -100_000)))
    }
}
