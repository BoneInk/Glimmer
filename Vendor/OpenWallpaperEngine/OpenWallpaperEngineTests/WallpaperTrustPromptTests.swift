import XCTest
@testable import OpenWallpaperEngine

/// A web wallpaper runs only once the user trusted it, whatever case project.json writes its type
/// in, and only while its folder holds what was trusted.
@MainActor
final class WallpaperTrustPromptTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var asked: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "TrustPrompt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "js"), withIntermediateDirectories: true)
        try Data("<script src=js/a.js></script>".utf8).write(to: folder.appending(path: "index.html"))
        try Data("1".utf8).write(to: folder.appending(path: "js/a.js"))
        try Data(#"{"title":"Page","type":"Web","file":"index.html"}"#.utf8).write(to: folder.appending(path: "project.json"))
        suiteName = "TrustPrompt-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        asked = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder) // Test scratch.
        defaults.removePersistentDomain(forName: suiteName)
    }

    private var web: WEWallpaper {
        WEWallpaper(using: WEProject(file: "index.html", title: "Page", type: "Web"), where: folder)
    }

    private var store: WallpaperTrustStore { WallpaperTrustStore(defaults: defaults) }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.trustStore = store
        model.askToTrust = { [weak self] in self?.asked.append($0.project.title) }
        return model
    }

    /// Applies and waits for the folder check a trusted wallpaper goes through.
    private func apply(_ wallpaper: WEWallpaper, on model: WallpaperViewModel) async {
        model.apply(wallpaper)
        await model.trustCheck?.value
    }

    func testCapitalisedWebTypeStillAsksFirst() async {
        let model = model()
        let screen = model.selectedScreenId

        await apply(web, on: model)
        XCTAssertNil(model.wallpapers[screen], "an untrusted web wallpaper waits for the user")
        XCTAssertEqual(asked, ["Page"])
        XCTAssertEqual(model.trustRequest?.contentChanged, false)

        model.endTrustRequest()
        await apply(WEWallpaper(using: WEProject(file: "a.mp4", title: "Clip", type: "Video"), where: folder), on: model)
        XCTAssertEqual(model.wallpapers[screen]?.project.title, "Clip")
    }

    func testCancelledOrRefusedApplyLeavesNoState() async {
        let model = model()
        await apply(web, on: model)
        XCTAssertNotNil(model.trustRequest)
        model.endTrustRequest()
        XCTAssertNil(model.trustRequest, "a cancelled prompt drops the wallpaper it asked about")
        XCTAssertNil(model.trustRequestFingerprint)
        XCTAssertNil(model.proceedWithTrustRequest(remember: true), "nothing is left to proceed with")
        XCTAssertNil(model.wallpapers[model.selectedScreenId])

        model.confirmApply = { _ in false }
        await apply(web, on: model)
        XCTAssertNil(model.trustRequest, "safe restart's refusal neither asks nor waits")
        XCTAssertEqual(asked, ["Page"])
        XCTAssertNil(model.wallpapers[model.selectedScreenId])
    }

    func testProceedRememberingTrustsAndDoesntAskAgain() async {
        let model = model()
        await apply(web, on: model)
        await model.proceedWithTrustRequest(remember: true)?.value
        XCTAssertNil(model.trustRequest)
        XCTAssertEqual(model.wallpapers[model.selectedScreenId]?.project.title, "Page")

        model.wallpapers = [:]
        await apply(web, on: model)
        XCTAssertEqual(asked, ["Page"], "trusted and unchanged: no second prompt")
        XCTAssertEqual(model.wallpapers[model.selectedScreenId]?.project.title, "Page")
    }

    func testProceedAppliesAsAnApplyWithoutPromptDoes() async {
        let model = model()
        let transitions = RecordingTransitions()
        model.transitions = transitions
        let asked = model.layoutResolution.targets(of: model.selectedScreenIds)
        XCTAssertFalse(asked.isEmpty)
        await apply(web, on: model)
        XCTAssertTrue(transitions.performed.isEmpty, "nothing changes while the prompt waits")

        // The selection moving while the prompt counts down (the menu bar) doesn't move the wallpaper.
        model.selectedScreenIds = ["elsewhere"]
        model.proceedWithTrustRequest(remember: false)
        XCTAssertEqual(transitions.performed.count, 1, "Settings' transition, as for any wallpaper chosen by hand")
        XCTAssertEqual(transitions.performed.first?.kind, .door)
        XCTAssertEqual(transitions.performed.first?.screens, asked)
        for screen in asked {
            XCTAssertEqual(model.wallpapers[screen]?.project.title, "Page")
        }
        XCTAssertNil(model.wallpapers["elsewhere"])
    }

    func testUnchangedFolderDoesntAskEvenAfterTheAppEditsProjectJSON() async throws {
        store.trust(web, fingerprint: WallpaperTrustStore.fingerprint(of: web))
        // Renaming or tagging in the library rewrites project.json; Finder drops a .DS_Store.
        XCTAssertTrue(WallpaperProjectFileEdit.setLogging(["title": "Renamed", "tags": ["Anime"]], inProjectAt: folder))
        try Data([0]).write(to: folder.appending(path: ".DS_Store"))
        let model = model()
        await apply(web, on: model)
        XCTAssertEqual(asked, [])
        XCTAssertNil(model.trustRequest)
        XCTAssertEqual(model.wallpapers[model.selectedScreenId]?.project.title, "Page")
        XCTAssertTrue(WallpaperViewModel.mayRunWithoutAsking(web, store: store))
    }

    func testContentChangeAsksAgain() async throws {
        store.trust(web, fingerprint: WallpaperTrustStore.fingerprint(of: web))
        // A Workshop update, or another item downloaded into the same folder.
        try Data("console.log('updated')".utf8).write(to: folder.appending(path: "js/a.js"))
        let model = model()
        XCTAssertFalse(WallpaperViewModel.needsTrust(web, store: store), "still listed: the cheap filter can't tell")
        XCTAssertFalse(WallpaperViewModel.mayRunWithoutAsking(web, store: store), "the control channel and rules refuse it")

        await apply(web, on: model)
        XCTAssertEqual(asked, ["Page"])
        XCTAssertEqual(model.trustRequest?.contentChanged, true)
        XCTAssertNil(model.wallpapers[model.selectedScreenId])

        await model.proceedWithTrustRequest(remember: true)?.value
        model.wallpapers = [:]
        await apply(web, on: model)
        XCTAssertEqual(asked, ["Page"], "trusted again as it is now")
        XCTAssertEqual(model.wallpapers[model.selectedScreenId]?.project.title, "Page")
    }

    func testAddedFileAsksAgain() throws {
        store.trust(web, fingerprint: WallpaperTrustStore.fingerprint(of: web))
        try Data("x".utf8).write(to: folder.appending(path: "js/b.js"))
        XCTAssertEqual(store.verdict(for: web), .changed)
    }

    func testLegacyPathOnlyEntryMigratesWithoutAsking() async throws {
        // As trust was stored before fingerprints: the folder's path only.
        defaults.set([web.wallpaperDirectory.path(percentEncoded: false)], forKey: WallpaperTrustStore.pathsKey)
        let model = model()
        await apply(web, on: model)
        XCTAssertEqual(asked, [], "updating the app asks no one again")
        XCTAssertEqual(model.wallpapers[model.selectedScreenId]?.project.title, "Page")
        let fingerprints = defaults.dictionary(forKey: WallpaperTrustStore.fingerprintsKey) as? [String: String]
        XCTAssertEqual(fingerprints?[web.wallpaperDirectory.path(percentEncoded: false)], WallpaperTrustStore.fingerprint(of: web),
                       "bound to the content found on first use")

        try Data("changed".utf8).write(to: folder.appending(path: "index.html"))
        model.wallpapers = [:]
        await apply(web, on: model)
        XCTAssertEqual(asked, ["Page"], "from then on, a change asks")
    }

    func testResetForgetsPathsAndFingerprints() {
        store.trust(web, fingerprint: "f")
        store.reset()
        XCTAssertFalse(store.isListed(web))
        XCTAssertNil(defaults.dictionary(forKey: WallpaperTrustStore.fingerprintsKey))
        XCTAssertEqual(store.verdict(for: web, fingerprint: "f"), .untrusted)
    }

    func testTrustingAWallpaperAgainDoesNotGrowTheList() {
        XCTAssertEqual(WallpaperTrustStore.trustList(["/a", "/b"], adding: "/a"), ["/a", "/b"])
        XCTAssertEqual(WallpaperTrustStore.trustList(["/a", "/a"], adding: "/c"), ["/a", "/c"])
    }
}

/// Records each transition and applies its change at once.
@MainActor
private final class RecordingTransitions: WallpaperTransitionPerforming {
    var manualSettings = WallpaperTransitionSettings(choice: .kind(.door), milliseconds: 500)
    var performed: [(kind: WallpaperTransitionKind, screens: Set<String>)] = []

    func perform(_ kind: WallpaperTransitionKind, duration: TimeInterval, on screens: Set<String>,
                 apply: @escaping @MainActor () -> Void) {
        performed.append((kind, screens))
        apply()
    }

    func flushPending() {}
}
