import XCTest
@testable import OpenWallpaperEngine

/// The static scan for Chromium-only APIs: uses count, mentions (strings, comments, regular
/// expressions) and existence checks don't, minified code is read as well as formatted code.
final class ChromiumFeatureScannerTests: XCTestCase {
    private func js(_ code: String) -> [String] { ChromiumFeatureScanner.features(inJavaScript: code) }
    private func html(_ page: String) -> [String] { ChromiumFeatureScanner.features(inHTML: page) }

    func testTheCatalogIsWellFormed() {
        let ids = ChromiumFeatureCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for entry in ChromiumFeatureCatalog.compiledPatterns {
            let feature = ChromiumFeatureCatalog.feature(id: entry.id)!
            XCTAssertEqual(entry.patterns.count, feature.staticPatterns.count, "\(entry.id) has a pattern that doesn't compile")
            XCTAssertFalse(feature.runtimeTokens.isEmpty)
            XCTAssertFalse(feature.source.isEmpty)
        }
    }

    func testUsesAreFound() {
        XCTAssertEqual(js("navigator.serial.requestPort().then(function(p){ p.open({baudRate: 9600}); });"), ["web-serial"])
        XCTAssertEqual(js("const ports = await navigator.serial.getPorts();"), ["web-serial"])
        XCTAssertEqual(js("window.chrome.runtime.sendMessage(id, {a: 1});"), ["chrome-apis"])
        XCTAssertEqual(js("CSS.paintWorklet.addModule('ripple.js');"), ["css-paint"])
        XCTAssertEqual(js("registerPaint('ripple', class { paint(ctx) {} });"), ["css-paint"])
        XCTAssertEqual(js("navigator.userAgentData.getHighEntropyValues(['platformVersion'])"), ["ua-client-hints"])
        XCTAssertEqual(js("const color = await new EyeDropper().open();"), ["eyedropper"])
        XCTAssertEqual(js("const [file] = await window.showOpenFilePicker();"), ["file-system-access"])
        XCTAssertEqual(js("navigator.getBattery().then(b => draw(b.level));"), ["battery"])
        XCTAssertEqual(js("const fonts = await queryLocalFonts();"), ["local-fonts"])
        XCTAssertEqual(js("const m = performance.memory.usedJSHeapSize;"), ["performance-memory"])
        XCTAssertEqual(js("const d = new IdleDetector(); await d.start();"), ["idle-detection"])
        XCTAssertEqual(js("const s = await window.getScreenDetails();"), ["window-management"])
        XCTAssertEqual(js("new PressureObserver(cb).observe('cpu');"), ["compute-pressure"])
        XCTAssertEqual(js("navigator.keyboard.getLayoutMap().then(show)"), ["keyboard-map"])
        XCTAssertEqual(js("await documentPictureInPicture.requestWindow({width: 200})"), ["document-pip"])
        XCTAssertEqual(js("document.featurePolicy.allowsFeature('camera')"), ["feature-policy"])
        XCTAssertEqual(js("window.webkitRequestFileSystem(TEMPORARY, 1024, ok, fail)"), ["chrome-file-system"])
        XCTAssertEqual(js("navigator.hid.requestDevice({filters: []})"), ["webhid"])
        XCTAssertEqual(js("navigator.bluetooth.requestDevice({acceptAllDevices: true})"), ["web-bluetooth"])
        XCTAssertEqual(js("navigator.usb.getDevices()"), ["webusb"])
    }

    func testMinifiedCodeIsRead() {
        let minified = #"!function(e){var t=navigator.usb.requestDevice({filters:[]}),n="x"/2;e.a=window.chrome.loadTimes()}(window);"#
        XCTAssertEqual(js(minified), ["chrome-apis", "webusb"])
        // A division right before a use doesn't hide the use as a "regular expression".
        XCTAssertEqual(js("a=b/c;navigator.hid.getDevices()"), ["webhid"])
        XCTAssertEqual(js("x=(w)/2,navigator.serial.getPorts()"), ["web-serial"])
    }

    func testStringLiteralsAndCommentsAreNotCounted() {
        XCTAssertEqual(js(#"var help = "Call navigator.serial.requestPort() to connect";"#), [])
        XCTAssertEqual(js("var s = 'new EyeDropper()';"), [])
        XCTAssertEqual(js("var t = `showOpenFilePicker() is ${name}`;"), [])
        XCTAssertEqual(js("// navigator.usb.requestDevice()\nvar a = 1;"), [])
        XCTAssertEqual(js("/* window.chrome.runtime.sendMessage() */ go();"), [])
        XCTAssertEqual(js(#"var re = /navigator\.serial\.requestPort/;"#), [])
        XCTAssertEqual(js(#"if (/getBattery\(/.test(src)) {}"#), [])
        XCTAssertEqual(js(#"var s = "it's \" navigator.hid.getDevices() \"";"#), [])
    }

    func testExistenceChecksAreNotCounted() {
        XCTAssertEqual(js("if (navigator.serial) { useSerial(); }"), [])
        XCTAssertEqual(js("if ('serial' in navigator) {}"), [])
        XCTAssertEqual(js("var ok = typeof EyeDropper !== 'undefined';"), [])
        XCTAssertEqual(js("var isChrome = !!window.chrome;"), [])
        XCTAssertEqual(js("var isChrome = /Chrome/.test(navigator.userAgent);"), [])
        XCTAssertEqual(js("if (window.showOpenFilePicker) {}"), [])
        XCTAssertEqual(js("var mem = navigator.deviceMemory || 4;"), [])
    }

    func testHTMLInlineScriptsAndHandlers() {
        XCTAssertEqual(html("<html><body><script>navigator.serial.requestPort()</script></body></html>"), ["web-serial"])
        XCTAssertEqual(html(#"<button onclick="showDirectoryPicker()">Pick</button>"#), ["file-system-access"])
        XCTAssertEqual(html(#"<SCRIPT type="module">new EyeDropper()</SCRIPT>"#), ["eyedropper"])
        // Not run: commented-out markup, templates and data blocks; and text outside scripts.
        XCTAssertEqual(html("<!-- <script>navigator.usb.getDevices()</script> -->"), [])
        XCTAssertEqual(html(#"<script type="text/template">navigator.hid.getDevices()</script>"#), [])
        XCTAssertEqual(html("<p>Use navigator.serial.requestPort() in Chrome</p>"), [])
        XCTAssertEqual(html(#"<script src="app.js"></script>"#), [])
    }

    func testAFolderIsScannedAndKeyedByItsContent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ChromiumFeatureScannerTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "js"), withIntermediateDirectories: true)
        try #"<html><script src="js/app.js"></script><script>var x = "navigator.usb.getDevices()";</script></html>"#
            .write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "window.addEventListener('load', function(){ navigator.getBattery().then(draw); });"
            .write(to: folder.appending(path: "js/app.js"), atomically: true, encoding: .utf8)
        try "navigator.serial.requestPort()".write(to: folder.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let first = ChromiumFeatureScanner.scan(directory: folder)
        XCTAssertEqual(first.features, ["battery"])
        XCTAssertEqual(ChromiumFeatureScanner.contentKey(of: folder), first.contentKey)
        XCTAssertEqual(ChromiumFeatureScanner.scan(directory: folder), first)

        // Editing a script changes the key (and the findings).
        try "new EyeDropper().open(); // edited".write(to: folder.appending(path: "js/app.js"), atomically: true, encoding: .utf8)
        let second = ChromiumFeatureScanner.scan(directory: folder)
        XCTAssertNotEqual(second.contentKey, first.contentKey)
        XCTAssertEqual(second.features, ["eyedropper"])
    }

    func testRuntimeMessagesNameFeatures() {
        func ids(_ type: String, _ message: String) -> [String] {
            ChromiumFeatureCatalog.features(inError: type, message: message).map(\.id)
        }
        XCTAssertEqual(ids("TypeError", "undefined is not an object (evaluating 'navigator.serial.requestPort')"), ["web-serial"])
        XCTAssertEqual(ids("ReferenceError", "Can't find variable: EyeDropper"), ["eyedropper"])
        XCTAssertEqual(ids("TypeError", "navigator.getBattery is not a function. (In 'navigator.getBattery()', 'navigator.getBattery' is undefined)"), ["battery"])
        XCTAssertEqual(ids("ReferenceError", "Can't find variable: chrome"), ["chrome-apis"])
        // Other errors, and other kinds of error, don't count.
        XCTAssertEqual(ids("TypeError", "null is not an object (evaluating 'a.b')"), [])
        XCTAssertEqual(ids("SyntaxError", "Unexpected token 'navigator.serial'"), [])
    }
}
