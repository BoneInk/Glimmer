import WebKit
import XCTest
@testable import OpenWallpaperEngine

/// The runtime probe in a real WebKit page: a fixture page that uses Chromium-only APIs reports
/// them through the probe's message, and the page's own feature checks still work.
@MainActor
final class ChromiumFeatureProbeTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var messages: [Any] = []
        var loaded = false

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(message.body)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    }

    /// Loads the fixture page and collects the probe's reports. A cold WebContent process can take
    /// seconds to load the page (CI's runners), so this waits for the load, then for `expected`
    /// features, and then `settle` more for any late or extra report.
    private func run(_ body: String, expecting expected: Int,
                     settle: TimeInterval = 0.5) async throws -> (features: [String], page: WKWebView) {
        let recorder = Recorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: ChromiumFeatureProbe.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(recorder, name: ChromiumFeatureProbe.messageName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        webView.navigationDelegate = recorder
        webView.loadHTMLString("<html><body><script>window.log=[];\(body)</script></body></html>",
                               baseURL: URL(string: "https://fixture.invalid/"))
        func features() -> [String] { Array(Set(recorder.messages.flatMap(ChromiumFeatureProbe.features(fromMessage:)))).sorted() }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !recorder.loaded || features().count < expected {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(recorder.loaded, "the fixture page didn't load")
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        return (features(), webView)
    }

    func testUncaughtErrorsOfMissingAPIsAreReported() async throws {
        let result = try await run("""
        setTimeout(function(){ navigator.serial.requestPort(); }, 0);
        setTimeout(function(){ new EyeDropper(); }, 0);
        """, expecting: 2)
        XCTAssertEqual(result.features, ["eyedropper", "web-serial"])
    }

    func testCaughtAndLoggedErrorsAndRejectionsAreReported() async throws {
        let result = try await run("""
        try { navigator.usb.getDevices(); } catch (e) { console.error(e); }
        Promise.resolve().then(function(){ return navigator.getBattery(); });
        """, expecting: 2)
        XCTAssertEqual(result.features, ["battery", "webusb"])
    }

    func testUnrelatedErrorsAndFeatureChecksReportNothing() async throws {
        let result = try await run("""
        window.hasSerial = 'serial' in navigator;
        window.hasDropper = typeof EyeDropper !== 'undefined';
        setTimeout(function(){ var o = null; o.missing(); }, 0);
        setTimeout(function(){ throw new Error('navigator.serial is great'); }, 0);
        """, expecting: 0, settle: 1)
        XCTAssertEqual(result.features, [])
        // The probe defines nothing the page could see.
        let hasSerial = try await result.page.evaluateJavaScript("window.hasSerial") as? Bool
        let hasDropper = try await result.page.evaluateJavaScript("window.hasDropper") as? Bool
        XCTAssertEqual(hasSerial, false)
        XCTAssertEqual(hasDropper, false)
    }
}
