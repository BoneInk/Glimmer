import WebKit
import XCTest
@testable import OpenWallpaperEngine

final class WebWallpaperPropertyBridgeTests: XCTestCase {
    private let project: [String: Any] = [
        "general": ["properties": [
            "schemecolor": ["type": "color", "value": "0.5 0.25 1"],
            "showclock": ["type": "bool", "value": true],
            "speed": ["type": "slider", "value": 3, "min": 0, "max": 10],
            "mode": ["type": "combo", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"]]],
            "notice": ["text": "<b>hi</b>"],
            "header": ["type": "text", "text": "Header"]
        ]]
    ]

    func testDeclaredPropertiesSkipNoticeRows() {
        let properties = WebWallpaperPropertyBridge.declaredProperties(projectRoot: project)
        XCTAssertEqual(Set(properties.keys), ["schemecolor", "showclock", "speed", "mode"])
        XCTAssertEqual(properties["mode"]?.defaultValue, "a")
        XCTAssertEqual(properties["showclock"]?.defaultValue, "true")
    }

    func testPayloadTypes() throws {
        let properties = WebWallpaperPropertyBridge.declaredProperties(projectRoot: project)
        let values = WebWallpaperPropertyBridge.currentValues(properties: properties, stored: ["speed": "2.5", "junk": "x"])
        let payload = WebWallpaperPropertyBridge.payload(properties: properties, values: values)
        XCTAssertEqual((payload["schemecolor"] as? [String: Any])?["value"] as? String, "0.5 0.25 1")
        XCTAssertEqual((payload["showclock"] as? [String: Any])?["value"] as? Bool, true)
        XCTAssertEqual((payload["speed"] as? [String: Any])?["value"] as? Double, 2.5)
        XCTAssertEqual((payload["mode"] as? [String: Any])?["value"] as? String, "a")
        XCTAssertNil(payload["junk"])
    }

    func testApplyScriptContainsJSON() throws {
        let script = try XCTUnwrap(WebWallpaperPropertyBridge.applyUserPropertiesScript(
            ["showclock": ["type": "bool", "value": false]]))
        XCTAssertTrue(script.contains("__oweApplyUserProperties({\"showclock\":{\"type\":\"bool\",\"value\":false}})"))
        let full = try XCTUnwrap(WebWallpaperPropertyBridge.applyUserPropertiesScript(["a": ["value": 1]], full: true))
        XCTAssertTrue(full.contains("__oweSetUserProperties("))
        XCTAssertNil(WebWallpaperPropertyBridge.applyUserPropertiesScript([:]))
    }

    func testIntegerSliderIsWholeNumber() {
        let value = WebWallpaperPropertyBridge.jsonValue(type: "slider", value: "30") as? NSNumber
        XCTAssertEqual(value?.stringValue, "30")
    }

    func testAudioArrayIs128Clamped() {
        let samples = WebWallpaperPropertyBridge.audioArray(left: [2, 0.5], right: [-1])
        XCTAssertEqual(samples.count, 128)
        XCTAssertEqual(samples[0], 1)
        XCTAssertEqual(samples[1], 0.5)
        XCTAssertEqual(samples[64], 0)
        XCTAssertTrue(WebWallpaperPropertyBridge.audioDeliveryScript(samples).hasPrefix("window.__oweDeliverAudio"))
    }

    func testGeneralPropertiesCarryFPS() {
        XCTAssertTrue(WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: 15).contains("{fps:15}"))
    }

    /// The value WE hands the page for each property type.
    func testValueFormatPerPropertyType() throws {
        let project: [String: Any] = ["general": ["properties": [
            "b": ["type": "bool", "value": false],
            "s": ["type": "slider", "value": 100, "min": 10, "max": 200],
            "f": ["type": "slider", "value": 0.5, "min": 0, "max": 1, "precision": 2],
            "c": ["type": "combo", "value": 2, "options": [["label": "A", "value": 1], ["label": "B", "value": 2]]],
            "cs": ["type": "combo", "value": "b", "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"]]],
            "cf": ["type": "combo", "value": 0.5, "options": [["label": "Half", "value": 0.5], ["label": "One", "value": 1.5]]],
            "cb": ["type": "combo", "value": true, "options": [["label": "On", "value": true], ["label": "Off", "value": false]]],
            "cn": ["type": "combo", "value": "1", "options": [["label": "One", "value": "1"], ["label": "Two", "value": "2"]]],
            "col": ["type": "color", "value": "1 1 1"],
            "t": ["type": "textinput", "value": "hello"],
            "file": ["type": "file", "value": ""],
            "dir": ["type": "directory", "value": ""]
        ]]]
        let properties = WebWallpaperPropertyBridge.declaredProperties(projectRoot: project)
        let values = WebWallpaperPropertyBridge.currentValues(
            properties: properties, stored: ["b": "true", "s": "150", "col": "0 0.5 1", "dir": "/tmp/x", "cb": "false"])
        let payload = WebWallpaperPropertyBridge.payload(properties: properties, values: values)
        func value(_ key: String) -> Any? { (payload[key] as? [String: Any])?["value"] }
        XCTAssertEqual(value("b") as? Bool, true)
        XCTAssertFalse(value("b") is String)
        XCTAssertEqual((value("s") as? NSNumber)?.stringValue, "150")
        XCTAssertEqual(value("f") as? Double, 0.5)
        // A combo's value keeps the JSON type its option was authored with, as WE passes it.
        XCTAssertEqual((value("c") as? NSNumber)?.intValue, 2)
        XCTAssertFalse(value("c") is String, "an int option arrives as a number")
        XCTAssertEqual(value("cs") as? String, "b")
        XCTAssertEqual((value("cf") as? NSNumber)?.doubleValue, 0.5)
        XCTAssertEqual(value("cb") as? Bool, false, "the user's choice keeps the option's type")
        XCTAssertEqual(value("cn") as? String, "1", "a string option stays a string even when it looks numeric")
        XCTAssertEqual(value("col") as? String, "0 0.5 1")
        XCTAssertEqual(value("t") as? String, "hello")
        XCTAssertEqual(value("file") as? String, "")
        XCTAssertEqual(value("dir") as? String, "tmp/x", "without the slash, for the page's 'file:///' + path")
        XCTAssertEqual(WebWallpaperPropertyBridge.jsonValue(type: "bool", value: "false") as? Bool, false)
    }

    func testPauseScriptDefinesWEHooksAndQueues() {
        let script = WebWallpaperPropertyBridge.pauseScript
        for token in ["___wpxPause", "___wpxUnpause", "wpxPausePseudoAnimationAll", "pending.raf",
                      "suspend()", "WeakRef", "CAP = 1000"] {
            XCTAssertTrue(script.contains(token), token)
        }
        XCTAssertEqual(WebWallpaperPropertyBridge.wpxPauseScript(true), "window.___wpxPause&&window.___wpxPause();")
        XCTAssertTrue(WebWallpaperPropertyBridge.wpxPauseScript(false).contains("___wpxUnpause()"))
        // The heartbeat keeps the originals so a paused page's queue doesn't stop it.
        XCTAssertTrue(WebWallpaperPropertyBridge.bootstrapScript.contains("window.___wpxRAF"))
    }
}

final class WebPageScaleTests: XCTestCase {
    /// Only an opted-in Retina display is overridden to 1; otherwise WebKit keeps the window's scale.
    func testScaleFactorOverridesOnlyOptedInRetina() {
        XCTAssertEqual(WebPageScale.scaleFactor(standardResolution: true, halfResolution: false, backingScale: 2), 1)
        XCTAssertEqual(WebPageScale.scaleFactor(standardResolution: true, halfResolution: false, backingScale: 1), 0)
        XCTAssertEqual(WebPageScale.scaleFactor(standardResolution: false, halfResolution: false, backingScale: 2), 0)
    }

    /// High Performance texture resolution is WE's `-halfresolution`: half the display's scale,
    /// combined with standard resolution by taking whichever gives fewer pixels.
    @MainActor
    func testHalfResolutionHalvesTheDisplaysScale() {
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: false, halfResolution: true, backingScale: 1), 0.5)
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: false, halfResolution: true, backingScale: 2), 1)
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: true, halfResolution: true, backingScale: 1), 0.5)
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: true, halfResolution: true, backingScale: 2), 1)
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: true, halfResolution: false, backingScale: 2), 1)
        XCTAssertEqual(WebPageScale.pixelsPerPoint(standardResolution: false, halfResolution: false, backingScale: 2), 2)
        XCTAssertEqual(WebPageScale.scaleFactor(standardResolution: false, halfResolution: true, backingScale: 1), 0.5)
        XCTAssertEqual(ChromiumPageView.pageScale(standardResolution: false, halfResolution: true, backingScale: 1), 0.5)
        XCTAssertEqual(ChromiumPageView.pageScale(standardResolution: false, halfResolution: false, backingScale: 2), 2)
    }

    /// Only High Performance halves web pages; Automatic doesn't, as WE passes the flag for `half` only.
    func testOnlyHighPerformanceAsksForHalfResolution() {
        var settings = GlobalSettings()
        for (value, half) in [(GSTextureResolutionQuality.highPerformance, true), (.highQuality, false), (.automatic, false)] {
            settings.textureResolution = value
            XCTAssertEqual(WebPageScale.halfResolution(settings), half, value.rawValue)
        }
    }
}

/// Runs the bootstrap in a real page that records every listener call.
@MainActor
final class WebWallpaperPropertyDeliveryTests: XCTestCase {
    private func page(_ body: String) async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebWallpaperPropertyBridge.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body><script>window.calls=[];\(body)</script></body></html>", baseURL: nil)
        try await delegate.wait()
        return webView
    }

    private func recorded(_ webView: WKWebView) async throws -> [[String: Any]] {
        let json = try await webView.evaluateJavaScript("JSON.stringify(window.calls)") as? String ?? "[]"
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] ?? []
    }

    private func run(_ webView: WKWebView, _ script: String?) async throws {
        _ = try await webView.evaluateJavaScript((script ?? "") + ";0")
    }

    private let listener = "{applyUserProperties:function(p){window.calls.push(p);}}"

    func testLateListenerGetsFullSetThenOnlyChanges() async throws {
        let webView = try await page("")
        let full: [String: Any] = ["speed": ["type": "slider", "value": 3], "on": ["type": "bool", "value": true]]
        // Loaded with no listener yet: nothing to call, and a change made meanwhile is kept.
        try await run(webView, WebWallpaperPropertyBridge.applyUserPropertiesScript(full, full: true))
        try await run(webView, WebWallpaperPropertyBridge.applyUserPropertiesScript(["speed": ["type": "slider", "value": 7]]))
        var calls = try await recorded(webView)
        XCTAssertTrue(calls.isEmpty)
        // The page assigns its listener late: it gets the whole, current set once.
        try await run(webView, "setTimeout(function(){ window.wallpaperPropertyListener = \(listener); }, 50)")
        try await Task.sleep(nanoseconds: 300_000_000)
        calls = try await recorded(webView)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Set(calls[0].keys), ["speed", "on"])
        XCTAssertEqual((calls[0]["speed"] as? [String: Any])?["value"] as? Int, 7)
        // A live change delivers only the changed property.
        try await run(webView, WebWallpaperPropertyBridge.applyUserPropertiesScript(["on": ["type": "bool", "value": false]]))
        calls = try await recorded(webView)
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(Set(calls[1].keys), ["on"])
        XCTAssertEqual((calls[1]["on"] as? [String: Any])?["value"] as? Bool, false)
    }

    func testEarlyListenerGetsFullSetOnLoad() async throws {
        let webView = try await page("var wallpaperPropertyListener = \(listener);")
        let full: [String: Any] = ["a": ["type": "textinput", "value": "x"], "b": ["type": "color", "value": "1 0 0"]]
        try await run(webView, WebWallpaperPropertyBridge.applyUserPropertiesScript(full, full: true))
        let calls = try await recorded(webView)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Set(calls[0].keys), ["a", "b"])
        XCTAssertEqual((calls[0]["b"] as? [String: Any])?["value"] as? String, "1 0 0")
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    func wait() async throws {
        if done { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        done = true; continuation?.resume(); continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done = true; continuation?.resume(throwing: error); continuation = nil
    }
}
