import AppKit
import Metal
import WebKit
import XCTest
@testable import OpenWallpaperEngine

/// WE's "CEF devtools" for both engines: off by default, WebKit pages inspectable while on,
/// Chromium's port only while on, and "No web wallpaper active." without a page.
@MainActor
final class WebDevtoolsTests: XCTestCase {
    private func makeHost() -> ChromiumBrowserHost {
        ChromiumBrowserHost(makeConnection: { NSXPCConnection(serviceName: "app.openwallpaperengine.none") },
                            device: MTLCreateSystemDefaultDevice(), engine: { nil })
    }

    func testOffByDefaultAndWebKitPagesFollowTheSwitch() {
        let host = makeHost()
        let devtools = WebDevtools(chromium: host)
        XCTAssertFalse(devtools.isEnabled)
        let webView = WKWebView(frame: .zero)
        devtools.register(webView)
        XCTAssertFalse(webView.isInspectable)
        XCTAssertEqual(host.remoteDebuggingPort, 0)

        devtools.isEnabled = true
        XCTAssertTrue(webView.isInspectable)
        XCTAssertEqual(host.remoteDebuggingPort, WebDevtools.chromiumPort)
        let late = WKWebView(frame: .zero)
        devtools.register(late)
        XCTAssertTrue(late.isInspectable)

        devtools.isEnabled = false
        XCTAssertFalse(webView.isInspectable)
        XCTAssertFalse(late.isInspectable)
        XCTAssertEqual(host.remoteDebuggingPort, 0)
    }

    func testTheTargetIsNoneWithoutAPageAndWebKitForAPageInAWindow() {
        let devtools = WebDevtools(chromium: makeHost())
        devtools.isEnabled = true
        XCTAssertEqual(devtools.target, .none)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        devtools.register(webView)
        // A page outside any window isn't playing.
        XCTAssertEqual(devtools.target, .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        XCTAssertEqual(devtools.target, .webKit)
        window.contentView = nil
    }

    func testTheChromiumListIsOnLoopbackOnly() {
        XCTAssertEqual(WebDevtools.chromiumListURL.host, "127.0.0.1")
        XCTAssertEqual(WebDevtools.chromiumListURL.port, WebDevtools.chromiumPort)
        XCTAssertTrue((1024...65535).contains(WebDevtools.chromiumPort))
    }

    func testEveryTargetHasAMessage() {
        for target: WebDevtools.Target in [.chromium(WebDevtools.chromiumListURL), .webKit, .none] {
            XCTAssertFalse(WebDevtoolsSection.message(for: target).isEmpty)
        }
        XCTAssertTrue(WebDevtoolsSection.message(for: .chromium(WebDevtools.chromiumListURL))
            .contains(WebDevtools.chromiumListURL.absoluteString))
    }
}
