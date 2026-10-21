import AppKit
import IOSurface
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Web wallpapers on the Chromium path, against a fake helper behind an anonymous XPC listener
/// (no CEF): the WE bridge's start script, user and general properties, the audio listener,
/// pause, mute and suspend, `owe-wallpaper` serving with WebKit's containment rules, frames,
/// script results and mouse input. Everything crosses real XPC.
@MainActor
final class ChromiumWebWallpaperBridgeTests: XCTestCase {
    private var listener: NSXPCListener!
    private var helper: FakeBrowserHelper!
    private var host: ChromiumBrowserHost!
    private var folder: URL!

    override func setUpWithError() throws {
        helper = FakeBrowserHelper()
        listener = NSXPCListener.anonymous()
        listener.delegate = helper
        listener.resume()
        let endpoint = listener.endpoint
        host = ChromiumBrowserHost(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) },
                                   device: MTLCreateSystemDefaultDevice(),
                                   engine: { (URL(fileURLWithPath: "/tmp/owe-engine"), URL(fileURLWithPath: "/tmp/owe-profile")) })
        folder = FileManager.default.temporaryDirectory.appending(path: "ChromiumBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project: [String: Any] = [
            "title": "Bridge", "type": "web", "file": "index.html",
            "general": ["properties": [
                "speed": ["type": "slider", "value": 3, "min": 1, "max": 10, "text": "Speed"],
                "glow": ["type": "bool", "value": true, "text": "Glow"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: project).write(to: folder.appending(path: "project.json"))
        try "<html><body>bridge</body></html>".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        listener.invalidate()
        try? FileManager.default.removeItem(at: folder)
    }

    private var wallpaper: WEWallpaper {
        WEWallpaper(using: WEProject(file: "index.html", preview: "", title: "Bridge", type: "web"), where: folder)
    }

    /// A view model wired to a Chromium page the way `ChromiumWebWallpaperView` wires them.
    private func makePage() -> (ChromiumBrowserPage, WebWallpaperViewModel, Int) {
        let viewModel = WebWallpaperViewModel(wallpaper: wallpaper, settings: GlobalSettingsViewModel())
        let page = ChromiumBrowserPage(host: host, startScripts: WebWallpaperViewModel.documentStartScripts, frameRate: 30)
        viewModel.page = page
        page.onMessage = { [weak viewModel] name, body in viewModel?.receivePageMessage(name: name, body: body) }
        page.onLoad = { [weak viewModel] _ in viewModel?.pageDidFinishLoading() }
        page.resize(width: 320, height: 200, scale: 2)
        page.load(.init(url: WebWallpaperSchemeHandler.url(forRelativePath: "index.html")!, directory: folder))
        waitUntil("the browser") { helper.created.count == 1 }
        return (page, viewModel, helper.created.first?.id ?? -1)
    }

    func testTheBrowserStartsWithWebKitsBridgeScripts() throws {
        let (page, _, id) = makePage()
        defer { page.close() }
        let created = try XCTUnwrap(helper.created.first)
        XCTAssertEqual(page.browserId, id)
        XCTAssertEqual(created.url, "owe-wallpaper://local/index.html")
        XCTAssertEqual(created.width, 320)
        XCTAssertEqual(created.height, 200)
        XCTAssertEqual(created.scale, 2)
        XCTAssertEqual(created.frameRate, 30)
        XCTAssertEqual(helper.initialized.first?.framework, "/tmp/owe-engine/OWE Chromium.app")
        // The same scripts as WebKit's, posting through the helper, and nothing named webkit.
        XCTAssertTrue(created.script.hasPrefix(ChromiumPageScripts.prelude))
        for script in WebWallpaperViewModel.documentStartScripts {
            XCTAssertTrue(created.script.contains(ChromiumPageScripts.adapt(script)))
        }
        XCTAssertFalse(created.script.contains("window.webkit"))
        XCTAssertTrue(created.script.contains("__oweMessageHandlers.\(WebWallpaperPropertyBridge.audioMessageName)"))
        XCTAssertTrue(created.script.contains("wallpaperRegisterAudioListener"))
        XCTAssertTrue(created.script.contains("___wpxPause"))
        XCTAssertTrue(created.script.contains("wallpaperRegisterMediaPropertiesListener"))
    }

    func testDevtoolsPortReachesTheHelperAndAChangeReopensThePageInANewOne() {
        let (page, _, _) = makePage()
        XCTAssertEqual(helper.debuggingPorts, [0])
        XCTAssertTrue(host.hasBrowsers)
        host.remoteDebuggingPort = WebDevtools.chromiumPort
        waitUntil("the page reopening with DevTools") { helper.created.count == 2 }
        XCTAssertEqual(helper.debuggingPorts.last, WebDevtools.chromiumPort)
        // The same port again keeps the running helper.
        host.remoteDebuggingPort = WebDevtools.chromiumPort
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(helper.created.count, 2)
        page.close()
    }

    func testUserAndGeneralPropertiesOnLoadThenChanges() throws {
        let (page, viewModel, id) = makePage()
        defer { page.close() }
        helper.finishLoading(id)
        let properties = WebWallpaperPropertyBridge.declaredProperties(wallpaperDirectory: folder)
        let stored = WallpaperSettingsIdentity.resolve(wallpaper).userSetValues(scope: viewModel.propertyScope)
        let full = try XCTUnwrap(WebWallpaperPropertyBridge.applyUserPropertiesScript(WebWallpaperPropertyBridge.payload(
            properties: properties, values: WebWallpaperPropertyBridge.currentValues(properties: properties, stored: stored)),
            full: true))
        let general = WebWallpaperPropertyBridge.applyGeneralPropertiesScript(fps: viewModel.frameRate)
        waitUntil("the properties") { helper.scripts(for: id).contains(full) && helper.scripts(for: id).contains(general) }

        // A change in the sidebar delivers that property alone.
        NotificationCenter.default.post(name: .wallpaperUserPropertyChanged, object: folder.path,
                                        userInfo: ["key": "speed", "value": "7"])
        let change = try XCTUnwrap(WebWallpaperPropertyBridge.applyUserPropertiesScript(
            WebWallpaperPropertyBridge.payload(properties: properties, values: ["speed": "7"])))
        waitUntil("the change") { helper.scripts(for: id).contains(change) }
        XCTAssertTrue(change.contains("\"speed\""))
        XCTAssertFalse(change.contains("\"glow\""))
    }

    func testTheAudioListenerGets128ValuesThirtyTimesASecond() throws {
        let (page, viewModel, id) = makePage()
        defer { page.close(); viewModel.stopAudio() }
        XCTAssertFalse(viewModel.isDeliveringAudio)
        helper.post(id, name: WebWallpaperPropertyBridge.audioMessageName, body: "1")
        waitUntil("audio deliveries") {
            helper.scripts(for: id).filter { $0.hasPrefix("window.__oweDeliverAudio&&") }.count >= 3
        }
        XCTAssertTrue(viewModel.isDeliveringAudio)
        let delivery = try XCTUnwrap(helper.scripts(for: id).first { $0.hasPrefix("window.__oweDeliverAudio&&") })
        let list = try XCTUnwrap(delivery.split(separator: "[").last?.split(separator: "]").first)
        XCTAssertEqual(list.split(separator: ",").count, 128)

        // Paused: no deliveries.
        viewModel.setPaused(true)
        XCTAssertFalse(viewModel.isDeliveringAudio)
    }

    func testPauseTellsThePageAndHidesTheBrowser() throws {
        let (page, viewModel, id) = makePage()
        defer { page.close() }
        viewModel.setPaused(true)
        let pause = WebWallpaperPropertyBridge.setPausedScript(true) + WebWallpaperPropertyBridge.wpxPauseScript(true)
        waitUntil("the pause") { helper.scripts(for: id).contains(pause) && helper.hidden[id] == true }

        viewModel.setPaused(false)
        let resume = WebWallpaperPropertyBridge.setPausedScript(false) + WebWallpaperPropertyBridge.wpxPauseScript(false)
        waitUntil("the resume") { helper.scripts(for: id).contains(resume) && helper.hidden[id] == false }

        // Covered: suspended (hidden) until uncovered.
        viewModel.windowOcclusionChanged(visible: false)
        waitUntil("the suspend") { helper.hidden[id] == true }
        viewModel.windowOcclusionChanged(visible: true)
        waitUntil("the wake") { helper.hidden[id] == false }
    }

    func testMuteAndFrameRateReachTheBrowser() {
        let (page, viewModel, id) = makePage()
        defer { page.close() }
        viewModel.setMuted(true)
        waitUntil("the mute") { helper.muted[id] == true }
        viewModel.setMuted(false)
        waitUntil("the unmute") { helper.muted[id] == false }
        page.setFrameRate(15)
        waitUntil("the frame rate") { helper.frameRates[id] == 15 }
    }

    func testResourcesFollowTheSchemeHandlersContainment() throws {
        let (page, _, id) = makePage()
        defer { page.close() }
        let outside = FileManager.default.temporaryDirectory.appending(path: "ChromiumBridgeSecret-\(UUID().uuidString).txt")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.txt"), withDestinationURL: outside)

        let page200 = helper.request(id, url: "owe-wallpaper://local/index.html", range: nil)
        XCTAssertEqual(page200.status, 200)
        XCTAssertEqual(page200.headers["Content-Type"], "text/html")
        XCTAssertEqual(String(decoding: try page200.bytes(), as: UTF8.self), "<html><body>bridge</body></html>")

        let partial = helper.request(id, url: "owe-wallpaper://local/index.html", range: "bytes=6-11")
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(String(decoding: try partial.bytes(), as: UTF8.self), "<body>")

        for refused in ["owe-wallpaper://local/../\(outside.lastPathComponent)", "owe-wallpaper://local/link.txt",
                        "owe-wallpaper://local/missing.js", "owe-wallpaper://elsewhere/index.html",
                        "file://\(outside.path)", "https://localhost/"] {
            XCTAssertEqual(helper.request(id, url: refused, range: nil).status, 404, refused)
        }
    }

    func testAnEmbedPageIsServedAtItsHttpsOrigin() throws {
        let page = ChromiumBrowserPage(host: host, startScripts: [], frameRate: 30)
        defer { page.close() }
        page.resize(width: 100, height: 100, scale: 1)
        page.load(.init(url: URL(string: ChromiumResourceServing.embedPageURL)!, directory: nil,
                        embedHTML: "<iframe src=\"https://www.youtube.com/embed/x\"></iframe>"))
        waitUntil("the browser") { helper.created.count == 1 }
        let id = try XCTUnwrap(helper.created.first?.id)
        XCTAssertEqual(helper.created.first?.url, ChromiumResourceServing.embedPageURL)
        let reply = helper.request(id, url: ChromiumResourceServing.embedPageURL, range: nil)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(String(decoding: try reply.bytes(), as: UTF8.self).contains("youtube.com/embed"))
        XCTAssertEqual(helper.request(id, url: "owe-wallpaper://local/index.html", range: nil).status, 404)
    }

    func testFramesScriptResultsAndMouseInput() throws {
        let (page, _, id) = makePage()
        defer { page.close() }
        var frames: [Int64] = []
        let frameLock = NSLock()
        page.onFrame = { frame in frameLock.withLock { frames.append(frame.frameNumber) } }
        helper.paint(id, frames: 2)
        waitUntil("frames") { frameLock.withLock { frames.count } == 2 }

        var result: Any?
        var answered = false
        page.evaluate("document.title") { value in result = value; answered = true }
        let evaluation = ChromiumPageScripts.evaluation("document.title", id: 1)
        waitUntil("the evaluation") { helper.scripts(for: id).contains(evaluation) }
        helper.post(id, name: ChromiumPageScripts.evaluationResultMessage, body: #"{"id":1,"value":"Bridge"}"#)
        waitUntil("the result") { answered }
        XCTAssertEqual(result as? String, "Bridge")

        let click = ChromiumMouseEvent(kind: .down, x: 12, y: 34, button: .left, clickCount: 1, modifiers: 1 << 4)
        page.sendMouse(click)
        waitUntil("the click") { helper.mouse[id]?.last == click }
    }

    // MARK: Screenshots

    /// A page that has shown one frame at its own size (320×200 points at 2: 640×400 pixels).
    private func makeShownPage() -> (ChromiumBrowserPage, Int, () -> [Int]) {
        let (page, _, id) = makePage()
        var widths: [Int] = []
        let frameLock = NSLock()
        page.onFrame = { frame in frameLock.withLock { widths.append(frame.texture.width) } }
        helper.paint(id, frames: 1, width: 640, height: 400)
        waitUntil("the first frame") { frameLock.withLock { widths.count } == 1 }
        return (page, id, { frameLock.withLock { widths } })
    }

    private func capture(_ page: ChromiumBrowserPage, pixelWidth: Int, timeout: TimeInterval = 5) -> CGImage? {
        var result: CGImage?
        var answered = false
        page.capture(pixelWidth: pixelWidth, timeout: timeout) { image in result = image; answered = true }
        waitUntil("the screenshot", timeout: timeout + 2) { answered }
        return result
    }

    func testAScreenshotDrawsThePageOnceAtTheChosenWidthThenGivesItsSizeBack() throws {
        let (page, id, shownWidths) = makeShownPage()
        defer { page.close() }
        helper.paintsOnResize = true
        let image = try XCTUnwrap(capture(page, pixelWidth: 1280))
        XCTAssertEqual(image.width, 1280)
        XCTAssertEqual(image.height, 800)
        // The device scale that makes 320 points 1280 pixels, then the page's own again.
        waitUntil("the restore") { helper.resizes(for: id).count == 2 }
        XCTAssertEqual(helper.resizes(for: id).map(\.scale), [4, 2])
        XCTAssertTrue(helper.resizes(for: id).allSatisfy { $0.width == 320 && $0.height == 200 })
        // The screenshot's frame never reaches the view, nor the page's last frame.
        waitUntil("the page's own frame") { shownWidths().count == 2 }
        XCTAssertEqual(shownWidths(), [640, 640])
        var last: CGImage?
        page.snapshot { last = $0 }
        XCTAssertEqual(last?.width, 640)
    }

    func testOneBrowserFeedsEveryDisplayMirroringIt() {
        let (page, id, _) = makeShownPage()
        defer { page.close() }
        let lock = NSLock()
        var seen: [Int: [Int64]] = [:]
        let mirrors = [NSObject(), NSObject()]
        for (index, mirror) in mirrors.enumerated() {
            page.addFrameObserver(mirror) { frame in lock.withLock { seen[index, default: []].append(frame.frameNumber) } }
        }
        XCTAssertEqual(lock.withLock { seen }, [0: [1], 1: [1]], "a mirror starts with the page's last frame")
        helper.paint(id, frames: 2, width: 640, height: 400)
        waitUntil("the mirrors' frames") { lock.withLock { seen.values.allSatisfy { $0.count == 3 } } }
        XCTAssertEqual(lock.withLock { seen }, [0: [1, 2, 3], 1: [1, 2, 3]])
        XCTAssertEqual(helper.created.count, 1, "one browser for every display")
        page.removeFrameObserver(mirrors[0])
        helper.paint(id, frames: 1, width: 640, height: 400)
        waitUntil("the remaining mirror's frame") { lock.withLock { seen[1]?.count } == 4 }
        XCTAssertEqual(lock.withLock { seen[0] }, [1, 2, 3])
    }

    func testWithoutAFrameOfThatSizeTheScreenshotIsTheLastFrame() throws {
        let (page, id, _) = makeShownPage()
        defer { page.close() }
        let image = try XCTUnwrap(capture(page, pixelWidth: 1280, timeout: 0.2))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(helper.resizes(for: id).last?.scale, 2)
    }

    func testAHiddenPageGivesItsLastFrameWithoutDrawing() throws {
        let (page, id, _) = makeShownPage()
        defer { page.close() }
        page.applySchedulingPolicy(muted: false, visible: false)
        let image = try XCTUnwrap(capture(page, pixelWidth: 1280))
        XCTAssertEqual(image.width, 640)
        XCTAssertTrue(helper.resizes(for: id).isEmpty)
    }

    func testAPageThatNeverDrawsTimesOut() async throws {
        let (page, _, _) = makePage()
        defer { page.close() }
        do {
            _ = try await WallpaperScreenshotService.capture(page, pixelWidth: 1280, timeout: 0.2)
            XCTFail("A page with no frame gave a screenshot")
        } catch WallpaperScreenshotService.Failure.timedOut {}
    }

    // MARK: Mouse mapping

    func testMousePointsAreFlippedIntoTheView() {
        let frame = NSRect(x: 100, y: 50, width: 400, height: 300)
        XCTAssertEqual(ChromiumMouseMapping.viewPoint(NSPoint(x: 100, y: 350), viewFrameInScreen: frame), CGPoint(x: 0, y: 0))
        XCTAssertEqual(ChromiumMouseMapping.viewPoint(NSPoint(x: 150, y: 250), viewFrameInScreen: frame), CGPoint(x: 50, y: 100))
        XCTAssertNil(ChromiumMouseMapping.viewPoint(NSPoint(x: 99, y: 100), viewFrameInScreen: frame))
    }

    func testOnlyClicksOnTheWallpaperReachThePage() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        var state = ChromiumMouseMapping.State()
        var covered = true
        func events(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> [ChromiumMouseEvent] {
            ChromiumMouseMapping.events(for: .init(type: type, screenPoint: NSPoint(x: x, y: y)), viewFrameInScreen: frame,
                                        state: &state, landsOnWallpaper: { _ in !covered })
        }
        // A press on another window isn't the wallpaper's, nor is its release.
        XCTAssertEqual(events(.leftMouseDown, 10, 290), [])
        XCTAssertEqual(events(.leftMouseUp, 10, 290), [])
        covered = false
        let down = events(.leftMouseDown, 10, 290)
        XCTAssertEqual(down.map(\.kind), [.move, .down])
        XCTAssertEqual(down.last?.x, 10)
        XCTAssertEqual(down.last?.y, 10)
        XCTAssertEqual((down.last?.modifiers ?? 0) & (1 << 4), 1 << 4)
        // A drag follows the press even over another window, clamped to the view.
        covered = true
        XCTAssertEqual(events(.leftMouseDragged, 500, 290).map(\.x), [400])
        XCTAssertEqual(events(.leftMouseUp, 500, 290).map(\.kind), [.up])
        // Moves: over the wallpaper, then one leave.
        covered = false
        XCTAssertEqual(events(.mouseMoved, 20, 20).map(\.kind), [.move])
        covered = true
        XCTAssertEqual(events(.mouseMoved, 20, 20).map(\.kind), [.leave])
        XCTAssertEqual(events(.mouseMoved, 21, 20), [])
    }

    func testWheelDeltasAreInPixels() {
        let frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        var state = ChromiumMouseMapping.State()
        let notched = ChromiumMouseMapping.events(
            for: .init(type: .scrollWheel, screenPoint: NSPoint(x: 5, y: 5), scrollDeltaY: -1, preciseScrolling: false),
            viewFrameInScreen: frame, state: &state, landsOnWallpaper: { _ in true })
        XCTAssertEqual(notched.first?.deltaY, -40)
        let precise = ChromiumMouseMapping.events(
            for: .init(type: .scrollWheel, screenPoint: NSPoint(x: 5, y: 5), scrollDeltaY: -3, preciseScrolling: true),
            viewFrameInScreen: frame, state: &state, landsOnWallpaper: { _ in true })
        XCTAssertEqual(precise.first?.deltaY, -3)
    }
}

/// Stands in for owe-chromium-helper's browsers: records every call and talks back as the helper
/// does (messages, load results, resource requests, frames).
private final class FakeBrowserHelper: NSObject, NSXPCListenerDelegate, ChromiumBrowserHelperProtocol, @unchecked Sendable {
    struct Created {
        let id: Int
        let url: String
        let width: Int
        let height: Int
        let scale: Double
        let frameRate: Int
        let script: String
    }

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var _initialized: [(framework: String, cache: String)] = []
    private var _debuggingPorts: [Int] = []
    private var _created: [Created] = []
    private var _scripts: [Int: [String]] = [:]
    private var _hidden: [Int: Bool] = [:]
    private var _muted: [Int: Bool] = [:]
    private var _frameRates: [Int: Int] = [:]
    private var _mouse: [Int: [ChromiumMouseEvent]] = [:]
    private var frameNumbers: [Int: Int64] = [:]
    private var _resizes: [Int: [(width: Int, height: Int, scale: Double)]] = [:]
    private var _paintsOnResize = false

    var initialized: [(framework: String, cache: String)] { lock.withLock { _initialized } }
    var created: [Created] { lock.withLock { _created } }
    var debuggingPorts: [Int] { lock.withLock { _debuggingPorts } }
    func scripts(for id: Int) -> [String] { lock.withLock { _scripts[id] ?? [] } }
    var hidden: [Int: Bool] { lock.withLock { _hidden } }
    var muted: [Int: Bool] { lock.withLock { _muted } }
    var frameRates: [Int: Int] { lock.withLock { _frameRates } }
    var mouse: [Int: [ChromiumMouseEvent]] { lock.withLock { _mouse } }
    func resizes(for id: Int) -> [(width: Int, height: Int, scale: Double)] { lock.withLock { _resizes[id] ?? [] } }
    /// Paint one frame of the new size on each resize, as Chromium does.
    var paintsOnResize: Bool {
        get { lock.withLock { _paintsOnResize } }
        set { lock.withLock { _paintsOnResize = newValue } }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = .chromiumBrowserHelper
        connection.exportedObject = self
        connection.remoteObjectInterface = .chromiumBrowserHost
        connection.resume()
        lock.withLock { self.connection = connection }
        return true
    }

    private var appHost: ChromiumBrowserHostProtocol? {
        lock.withLock { connection }?.remoteObjectProxy as? ChromiumBrowserHostProtocol
    }

    // MARK: Talking back

    func post(_ id: Int, name: String, body: String) {
        appHost?.browser(id, postedMessage: name, body: body)
    }

    func finishLoading(_ id: Int) {
        appHost?.browser(id, finishedLoadingWithStatus: 200)
    }

    /// Asks the app for a resource and waits for its answer.
    func request(_ id: Int, url: String, range: String?) -> ChromiumResourceResponse {
        let done = DispatchSemaphore(value: 0)
        var answer = ChromiumResourceResponse(status: -1, headers: [:])
        let proxy = lock.withLock { connection }?.remoteObjectProxyWithErrorHandler { _ in done.signal() }
            as? ChromiumBrowserHostProtocol
        proxy?.browser(id, requestsResource: url, range: range) { response in
            answer = response
            done.signal()
        }
        // The app answers on XPC's queue, so the main thread can wait.
        _ = done.wait(timeout: .now() + 5)
        return answer
    }

    func paint(_ id: Int, frames: Int, width: Int = 8, height: Int = 8) {
        for _ in 0..<frames {
            guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                                       .pixelFormat: ChromiumHelperIPC.pixelFormat]) else { continue }
            let number: Int64 = lock.withLock {
                frameNumbers[id, default: 0] += 1
                return frameNumbers[id]!
            }
            appHost?.didPaint(ChromiumFrameMessage(surface: surface, frameNumber: number, browserId: id))
        }
    }

    // MARK: ChromiumBrowserHelperProtocol

    func start(url: String, engineBundle: String, cacheDirectory: String, width: Int, height: Int,
               frameRate: Int, debugNoSandbox: Bool, reply: @escaping (String?) -> Void) {
        reply("not used")
    }

    func stop() {}

    func initialize(engineBundle: String, cacheDirectory: String, debugNoSandbox: Bool,
                    remoteDebuggingPort: Int, reply: @escaping (String?) -> Void) {
        lock.withLock {
            _initialized.append((engineBundle, cacheDirectory))
            _debuggingPorts.append(remoteDebuggingPort)
        }
        reply(nil)
    }

    func createBrowser(_ browserId: Int, url: String, width: Int, height: Int, scale: Double, frameRate: Int,
                       startScript: String, reply: @escaping (String?) -> Void) {
        lock.withLock {
            _created.append(Created(id: browserId, url: url, width: width, height: height, scale: scale,
                                    frameRate: frameRate, script: startScript))
        }
        reply(nil)
    }

    func closeBrowser(_ browserId: Int) {}
    func resizeBrowser(_ browserId: Int, width: Int, height: Int, scale: Double) {
        lock.withLock { _resizes[browserId, default: []].append((width, height, scale)) }
        if paintsOnResize {
            paint(browserId, frames: 1, width: Int((Double(width) * scale).rounded()),
                  height: Int((Double(height) * scale).rounded()))
        }
    }

    func setBrowserHidden(_ browserId: Int, hidden: Bool) {
        lock.withLock { _hidden[browserId] = hidden }
    }

    func setBrowserFrameRate(_ browserId: Int, frameRate: Int) {
        lock.withLock { _frameRates[browserId] = frameRate }
    }

    func setBrowserAudioMuted(_ browserId: Int, muted: Bool) {
        lock.withLock { _muted[browserId] = muted }
    }

    func executeJavaScript(_ browserId: Int, script: String) {
        lock.withLock { _scripts[browserId, default: []].append(script) }
    }

    func sendMouseEvent(_ browserId: Int, event: ChromiumMouseEvent) {
        lock.withLock { _mouse[browserId, default: []].append(event) }
    }
}

private extension ChromiumResourceResponse {
    /// The body: the bytes, or `length` bytes of the file from `offset`.
    func bytes() throws -> Data {
        if let file {
            try file.seek(toOffset: offset)
            return try file.read(upToCount: Int(length)) ?? Data()
        }
        return data ?? Data()
    }
}
