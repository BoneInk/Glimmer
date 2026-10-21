import XCTest
@testable import OpenWallpaperEngine

/// WebKit by default; Chromium only for a wallpaper that needs it while the engine is installed;
/// a wallpaper's override wins.
@MainActor
final class WebEngineRoutingTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "WebEngineRoutingTests-\(UUID().uuidString)")
        folder = root.appending(path: "wallpaper")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "WebEngineRoutingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// A complete install of `version`: its framework binary and manifest, recorded as active.
    private func install(_ version: String) throws {
        let folder = root.appending(path: version)
        let framework = ChromiumEnginePackage.frameworksFolder(in: folder).appending(path: ChromiumEnginePackage.frameworkName)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data().write(to: framework.appending(path: ChromiumEnginePackage.frameworkBinary))
        let manifest = ChromiumEnginePackage.Manifest(version: version, platform: "macosarm64", sha256: "00")
        try JSONEncoder().encode(manifest).write(to: folder.appending(path: ChromiumEnginePackage.manifestName))
        try VersionedInstallState(active: version, previous: nil).write(in: root)
    }

    private func page(_ script: String) throws {
        try "<html><script>\(script)</script></html>".write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
    }

    private var wallpaper: WEWallpaper {
        WEWallpaper(using: WEProject(file: "index.html", preview: "", title: "W", type: "web"), where: folder)
    }

    private func router(installed: Bool) -> WebEngineRouter {
        WebEngineRouter(isInstalled: { installed }, defaults: defaults, store: ChromiumFeatureStore(defaults: defaults))
    }

    func testTheRule() {
        XCTAssertEqual(WebEngineRouting.engine(installed: true, needsChromium: false, override: .automatic), .webKit)
        XCTAssertEqual(WebEngineRouting.engine(installed: true, needsChromium: true, override: .automatic), .chromium)
        XCTAssertEqual(WebEngineRouting.engine(installed: false, needsChromium: true, override: .automatic), .webKit)
        XCTAssertEqual(WebEngineRouting.engine(installed: true, needsChromium: true, override: .webKit), .webKit)
        XCTAssertEqual(WebEngineRouting.engine(installed: true, needsChromium: false, override: .chromium), .chromium)
        XCTAssertEqual(WebEngineRouting.engine(installed: false, needsChromium: false, override: .chromium), .webKit)
    }

    func testNotNeededPlaysInWebKit() throws {
        try page("document.body.textContent = 'clock';")
        XCTAssertEqual(router(installed: true).engine(for: wallpaper), .webKit)
    }

    func testNeededAndInstalledPlaysInChromium() throws {
        try page("navigator.serial.requestPort();")
        XCTAssertEqual(router(installed: true).engine(for: wallpaper), .chromium)
        // Not installed: WebKit, and the alert and badge flow instead.
        XCTAssertEqual(router(installed: false).engine(for: wallpaper), .webKit)
    }

    func testRuntimeDetectionSwitchesTheNextLoad() async throws {
        // A use the static scan can't see; only WebKit's runtime probe catches it.
        try page("var Tool = window['Eye' + 'Dropper']; new Tool();")
        let router = router(installed: true)
        XCTAssertEqual(router.engine(for: wallpaper), .webKit)
        let advisor = ChromiumFeatureAdvisor(store: ChromiumFeatureStore(defaults: defaults), engine: { .webKit })
        advisor.recordRuntime(["eyedropper"], for: wallpaper)
        for _ in 0..<40 where router.engine(for: wallpaper) != .chromium {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(router.engine(for: wallpaper), .chromium)
        // Remembered for this content (a new router reads the same store).
        XCTAssertEqual(self.router(installed: true).engine(for: wallpaper), .chromium)
    }

    func testTheOverrideWins() throws {
        try page("navigator.serial.requestPort();")
        let router = router(installed: true)
        router.setOverride(.webKit, for: wallpaper)
        XCTAssertEqual(router.engine(for: wallpaper), .webKit)
        try page("document.title = 'x';")
        router.setOverride(.chromium, for: wallpaper)
        XCTAssertEqual(router.engine(for: wallpaper), .chromium)
        // Kept across launches, and back to automatic on request.
        XCTAssertEqual(self.router(installed: true).override(for: wallpaper), .chromium)
        router.setOverride(.automatic, for: wallpaper)
        XCTAssertEqual(router.engine(for: wallpaper), .webKit)
        // Forcing Chromium does nothing without the engine.
        router.setOverride(.chromium, for: wallpaper)
        XCTAssertEqual(self.router(installed: false).engine(for: wallpaper), .webKit)
    }

    func testTheInstallIsReadFromDisk() throws {
        XCTAssertNil(ChromiumEngineInstallation.activeInstall(in: root))
        try install("1.2.3")
        XCTAssertEqual(ChromiumEngineInstallation.activeInstall(in: root)?.lastPathComponent, "1.2.3")
        try FileManager.default.removeItem(at: root.appending(path: "1.2.3/\(ChromiumEnginePackage.manifestName)"))
        XCTAssertNil(ChromiumEngineInstallation.activeInstall(in: root))
    }

    func testTheRouterFollowsInstallAndRemove() throws {
        let root = self.root!
        let router = WebEngineRouter(isInstalled: { ChromiumEngineInstallation.activeInstall(in: root) != nil },
                                     defaults: defaults, store: ChromiumFeatureStore(defaults: defaults))
        XCTAssertFalse(router.installed)
        try install("2.0.0")
        NotificationCenter.default.post(name: .chromiumEngineChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(router.installed)
        try FileManager.default.removeItem(at: root.appending(path: "2.0.0"))
        router.refresh()
        XCTAssertFalse(router.installed)
    }
}
