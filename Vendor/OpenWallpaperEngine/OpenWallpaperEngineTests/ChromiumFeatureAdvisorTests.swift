import XCTest
@testable import OpenWallpaperEngine

/// The "needs Chromium" alert: when it is raised, "Use Anyway" remembered per wallpaper until its
/// content changes, and what the runtime probe adds.
@MainActor
final class ChromiumFeatureAdvisorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    /// What the fake scanner reports; changing `key` is changing the wallpaper's content.
    private var key = "content-1"
    private var features = ["web-serial"]
    private var engine = WebEngine.webKit
    private var scans = 0

    override func setUpWithError() throws {
        suiteName = "ChromiumFeatureAdvisorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory.appending(path: "ChromiumFeatureAdvisorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeAdvisor() -> ChromiumFeatureAdvisor {
        ChromiumFeatureAdvisor(
            store: ChromiumFeatureStore(defaults: defaults),
            engine: { [unowned self] in self.engine },
            scanner: { [unowned self] _ in
                self.scans += 1
                return ChromiumFeatureScanner.Result(contentKey: self.key, features: self.features)
            },
            contentKey: { [unowned self] _ in self.key })
    }

    private var wallpaper: WEWallpaper {
        WEWallpaper(using: WEProject(file: "index.html", preview: "", title: "Serial Clock", type: "web"), where: folder)
    }

    /// Waits for the advisor's background work to settle.
    private func settle(_ advisor: ChromiumFeatureAdvisor, until condition: () -> Bool = { false }) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func testThePolicy() {
        let finding = ChromiumFeatureFinding(contentKey: "a", staticFeatures: ["web-serial"])
        XCTAssertTrue(ChromiumFeatureAdvisor.shouldAdvise(engine: .webKit, finding: finding, useAnywayKey: nil))
        XCTAssertFalse(ChromiumFeatureAdvisor.shouldAdvise(engine: .chromium, finding: finding, useAnywayKey: nil))
        XCTAssertFalse(ChromiumFeatureAdvisor.shouldAdvise(engine: .webKit, finding: finding, useAnywayKey: "a"))
        XCTAssertTrue(ChromiumFeatureAdvisor.shouldAdvise(engine: .webKit, finding: finding, useAnywayKey: "old"))
        XCTAssertFalse(ChromiumFeatureAdvisor.shouldAdvise(
            engine: .webKit, finding: ChromiumFeatureFinding(contentKey: "a", staticFeatures: []), useAnywayKey: nil))
        XCTAssertFalse(ChromiumFeatureAdvisor.shouldAdvise(engine: .webKit, finding: nil, useAnywayKey: nil))
    }

    func testApplyingAWallpaperThatNeedsChromiumRaisesTheAlert() async throws {
        let advisor = makeAdvisor()
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor) { advisor.pendingAdvice != nil }
        let advice = try XCTUnwrap(advisor.pendingAdvice)
        XCTAssertEqual(advice.features.map(\.id), ["web-serial"])
        XCTAssertEqual(advice.featureList, "navigator.serial")
        XCTAssertEqual(advice.title, "Serial Clock")
        XCTAssertEqual(advisor.features(of: wallpaper)?.map(\.id), ["web-serial"])
    }

    func testUseAnywayIsRememberedUntilTheContentChanges() async throws {
        var advisor = makeAdvisor()
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor) { advisor.pendingAdvice != nil }
        advisor.useAnyway(try XCTUnwrap(advisor.pendingAdvice))
        XCTAssertNil(advisor.pendingAdvice)

        // Applied again, also after a relaunch (a new advisor over the same store): no alert.
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)
        advisor = makeAdvisor()
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)
        // The finding was cached for this content: no second read of the files.
        XCTAssertEqual(scans, 1)

        // New content: asked again.
        key = "content-2"
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor) { advisor.pendingAdvice != nil }
        XCTAssertEqual(advisor.pendingAdvice?.contentKey, "content-2")
        XCTAssertEqual(scans, 2)
    }

    func testNoAlertWhenChromiumPlaysItOrNothingIsNeeded() async throws {
        engine = .chromium
        let advisor = makeAdvisor()
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)
        // The badge still shows what was found.
        XCTAssertEqual(advisor.features(of: wallpaper)?.map(\.id), ["web-serial"])

        engine = .webKit
        features = []
        key = "plain"
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)
        XCTAssertEqual(advisor.features(of: wallpaper)?.count, 0)
    }

    func testRuntimeFindingsAddToTheStaticOnes() async throws {
        features = []
        let advisor = makeAdvisor()
        advisor.wallpaperApplied(wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)

        advisor.recordRuntime(["eyedropper"], for: wallpaper)
        try await settle(advisor) { advisor.pendingAdvice != nil }
        XCTAssertEqual(advisor.pendingAdvice?.features.map(\.id), ["eyedropper"])
        advisor.useAnyway(try XCTUnwrap(advisor.pendingAdvice))

        // Kept with the content, and a repeat of a known failure doesn't ask again.
        XCTAssertEqual(ChromiumFeatureStore(defaults: defaults)
            .finding(for: folder.standardizedFileURL.path)?.runtimeFeatures, ["eyedropper"])
        advisor.recordRuntime(["eyedropper"], for: wallpaper)
        try await settle(advisor)
        XCTAssertNil(advisor.pendingAdvice)
    }

    func testOnlyWebWallpapersAreScanned() async throws {
        let advisor = makeAdvisor()
        let scene = WEWallpaper(using: WEProject(file: "scene.json", preview: "", title: "S", type: "scene"), where: folder)
        let finding = await advisor.scan(scene)
        XCTAssertNil(finding)
        XCTAssertEqual(scans, 0)
    }
}
