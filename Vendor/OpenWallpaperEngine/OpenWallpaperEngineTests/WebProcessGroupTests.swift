import WebKit
import XCTest
@testable import OpenWallpaperEngine

@MainActor
final class WebProcessGroupTests: XCTestCase {
    private let pageA = URL(fileURLWithPath: "/tmp/a/index.html")
    private let pageB = URL(fileURLWithPath: "/tmp/b/index.html")

    func testSecondPageOfSameWallpaperIsRelated() {
        let group = WebProcessGroup()
        let first = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        group.register(first, for: pageA)
        XCTAssertTrue(group.relatedWebView(for: pageA) === first)
        XCTAssertNil(group.relatedWebView(for: pageB))

        let configuration = WKWebViewConfiguration()
        // The private key may be missing; then the page falls back to its own process.
        if group.relate(configuration, to: pageA) {
            let second = WKWebView(frame: .zero, configuration: configuration)
            XCTAssertFalse(second.configuration.userContentController === first.configuration.userContentController)
        }
        XCTAssertFalse(group.relate(WKWebViewConfiguration(), to: pageB))
    }

    func testReregisterMovesPageAndClosedPagesDrop() {
        let group = WebProcessGroup()
        autoreleasepool {
            let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            group.register(view, for: pageA)
            group.register(view, for: pageB)
            XCTAssertNil(group.relatedWebView(for: pageA))
            XCTAssertNotNil(group.relatedWebView(for: pageB))
        }
        XCTAssertNil(group.relatedWebView(for: pageB))
    }

    func testRelatedPagesShareOneWebContentProcess() throws {
        let key = "_webProcessIdentifier"
        guard WKWebView.instancesRespond(to: NSSelectorFromString(key)) else {
            throw XCTSkip("process identifier not observable")
        }
        let group = WebProcessGroup()
        let first = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        group.register(first, for: pageA)
        let configuration = WKWebViewConfiguration()
        guard group.relate(configuration, to: pageA) else { throw XCTSkip("relation key missing") }
        let second = WKWebView(frame: .zero, configuration: configuration)
        for view in [first, second] { view.loadHTMLString("<p>x</p>", baseURL: pageA) }
        func pid(_ v: WKWebView) -> Int { (v.value(forKey: key) as? NSNumber)?.intValue ?? 0 }
        let deadline = Date().addingTimeInterval(10)
        while (pid(first) == 0 || pid(second) == 0) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotEqual(pid(first), 0)
        XCTAssertEqual(pid(first), pid(second))
    }
}
