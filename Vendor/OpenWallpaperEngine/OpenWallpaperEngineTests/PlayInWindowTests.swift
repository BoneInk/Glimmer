import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// Play in Window: WE's window sizes, placement from the command line's pixels, and the windows
/// by name.
@MainActor
final class PlayInWindowTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testWEsSizesInPixels() {
        XCTAssertEqual(PlayInWindowRequest.Size.fullHD.pixels, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(PlayInWindowRequest.Size.phone.pixels, CGSize(width: 607, height: 1080))
        XCTAssertNil(PlayInWindowRequest.Size.maximized.pixels)
        XCTAssertEqual(PlayInWindowRequest.defaultName, "Wallpaper Pop-out")
    }

    func testFullHDIsPixelsOnARetinaScreenCentred() {
        let frame: CGRect = PlayInWindowRequest.contentFrame(size: .fullHD, origin: nil, visibleFrame: visible,
                                                             backingScale: 2, mainFrame: main, titleBarHeight: 28)
        XCTAssertEqual(frame.size, CGSize(width: 960, height: 540))
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 1)
    }

    func testASizeThatDoesNotFitShrinksAndKeepsItsShape() {
        let frame: CGRect = PlayInWindowRequest.contentFrame(size: .phone, origin: nil, visibleFrame: visible,
                                                             backingScale: 1, mainFrame: main, titleBarHeight: 28)
        XCTAssertLessThanOrEqual(frame.height, visible.height - 28)
        XCTAssertEqual(frame.width / frame.height, 607.0 / 1080.0, accuracy: 0.01)
    }

    func testMaximizedFillsTheVisibleScreen() {
        let frame: CGRect = PlayInWindowRequest.contentFrame(size: .maximized, origin: nil, visibleFrame: visible,
                                                             backingScale: 2, mainFrame: main, titleBarHeight: 28)
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 1512, height: 916))
    }

    func testAnOriginIsPixelsFromTheMainDisplaysTopLeft() {
        let frame: CGRect = PlayInWindowRequest.contentFrame(size: .pixels(width: 800, height: 600),
                                                             origin: CGPoint(x: 200, y: 100), visibleFrame: visible,
                                                             backingScale: 2, mainFrame: main, titleBarHeight: 28)
        XCTAssertEqual(frame, CGRect(x: 100, y: 982 - 50 - 28 - 300, width: 400, height: 300))
    }

    func testWindowsByName() {
        let controller = PlayInWindowController(desktop: WallpaperViewModel(persistsWallpapers: false))
        defer { controller.close() }
        let first = image("First"), second = image("Second")
        XCTAssertNil(controller.open(PlayInWindowRequest(wallpaper: first, activates: false)))
        XCTAssertEqual(controller.names, [PlayInWindowRequest.defaultName])
        // The same name shows the new wallpaper in the same window.
        let window = controller.windows[PlayInWindowRequest.defaultName]
        XCTAssertNil(controller.open(PlayInWindowRequest(wallpaper: second, activates: false)))
        XCTAssertTrue(controller.windows[PlayInWindowRequest.defaultName] === window)
        XCTAssertEqual(controller.wallpaper(in: PlayInWindowRequest.defaultName)?.project.title, "Second")
        // Another name is another window; closing one leaves the other.
        XCTAssertNil(controller.open(PlayInWindowRequest(wallpaper: first, name: "Left", borderless: true, activates: false)))
        XCTAssertEqual(controller.names, ["Left", PlayInWindowRequest.defaultName])
        XCTAssertEqual(controller.windows["Left"]?.styleMask.contains(.titled), false, "borderless")
        XCTAssertTrue(controller.close("Left"))
        XCTAssertFalse(controller.close("Left"))
        XCTAssertEqual(controller.names, [PlayInWindowRequest.defaultName])
        XCTAssertTrue(controller.close())
        XCTAssertTrue(controller.names.isEmpty)
    }

    func testAnApplicationWallpaperIsRefused() {
        let controller = PlayInWindowController(desktop: WallpaperViewModel(persistsWallpapers: false))
        let app = WEWallpaper(using: WEProject(file: "app.exe", preview: "p.jpg", title: "App", type: "application"),
                              where: URL(fileURLWithPath: "/tmp/owe-play-in-window/App"))
        XCTAssertFalse(PlayInWindowController.canPlay(app))
        XCTAssertEqual(controller.open(PlayInWindowRequest(wallpaper: app, activates: false)), .unsupported)
        XCTAssertTrue(controller.names.isEmpty)
    }

    func testAClickInAPlayInWindowWindowLandsOnTheWallpaper() throws {
        let controller = PlayInWindowController(desktop: WallpaperViewModel(persistsWallpapers: false))
        defer { controller.close() }
        controller.open(PlayInWindowRequest(wallpaper: image("Click"), size: .pixels(width: 400, height: 300),
                                            activates: false))
        let window = try XCTUnwrap(controller.windows[PlayInWindowRequest.defaultName])
        // Above every other app's window, so the point is the test window's.
        window.level = .floating
        window.orderFrontRegardless()
        let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == window.windowNumber else {
            throw XCTSkip("another window is above the test window")
        }
        XCTAssertTrue(DesktopClickMonitor.landsOnWallpaper(point))
    }

    /// A remote image with no address: it plays as a black picture, nothing to load.
    private func image(_ title: String) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: "", preview: "p.jpg", title: title, type: "remote-image"),
                    where: URL(fileURLWithPath: "/tmp/owe-play-in-window/\(title)"))
    }
}
