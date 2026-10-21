import OWEEditor
import OWESceneEditing
import XCTest
@testable import OpenWallpaperEngine

/// The editor previews' background pre-warm, with fake helpers, power and clock: its order
/// (effects, then particles, a browser's tiles first), resuming, rendering again only what an
/// assets update changed, the power gate, helper reuse, and an editor handing its tiles over.
@MainActor
final class EditorPreviewPrewarmTests: XCTestCase {
    private var scratch: URL!
    private var assets: URL!

    private let tint = EditorPreviewSubject.effect(file: "effects/tint/effect.json", wallpaper: nil)
    private let blur = EditorPreviewSubject.effect(file: "effects/blur/effect.json", wallpaper: nil)
    private let example = EditorPreviewSubject.particleSystem(path: "particles/example.json", is3D: false)
    private let turbulence = EditorPreviewSubject.particleSystem(path: "particles/exampleturbolence.json", is3D: false)
    private var catalog: [EditorPreviewSubject] { [tint, blur, example, turbulence] }

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "EditorPreviewPrewarmTests-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        assets = scratch.appending(path: "we/assets", directoryHint: .isDirectory)
        for name in ["tint", "blur"] { try write("{}", to: "effects/\(name)/effect.json") }
        try write("// common", to: "shaders/common.h")
        try write("{}", to: "particles/example.json")
        try write("{}", to: "particles/exampleturbolence.json")
        try write("{}", to: "materials/particle/halo.json")
        try setBuild("100")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch) // Optional: a scratch folder.
    }

    // MARK: Order, resume, reuse

    func testEveryEffectRendersBeforeTheParticlesInCatalogOrderOnOneReusedHelper() async {
        let harness = Harness(test: self, lanes: 1)
        await harness.run()
        XCTAssertEqual(harness.rendered, catalog)
        XCTAssertEqual(harness.lanesMade, 1, "one helper renders every preview of its lane")
        XCTAssertEqual(harness.prewarm.lastSummary?.rendered, catalog)
        XCTAssertTrue(harness.logs.contains { $0.hasPrefix("pre-warm started (test): 4 to render") }, "\(harness.logs)")
        XCTAssertTrue(harness.logs.contains { $0.hasPrefix("pre-warm finished: 4 rendered, 0 failed") }, "\(harness.logs)")
    }

    func testTwoLanesShareTheQueue() async {
        let harness = Harness(test: self, lanes: 2)
        await harness.run()
        XCTAssertEqual(Set(harness.rendered), Set(catalog))
        XCTAssertEqual(harness.rendered.count, catalog.count, "no preview renders twice")
        XCTAssertEqual(harness.lanesMade, 2)
    }

    func testARunResumesWhereTheLastStoppedAndAFullCacheStartsNothing() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data().write(to: cache.outputBase(for: blur).appendingPathExtension("heic"))

        let first = Harness(test: self, lanes: 1)
        await first.run()
        XCTAssertEqual(first.rendered, [tint, example, turbulence], "what an editor already rendered is skipped")
        XCTAssertEqual(cache.inputs().count, 4, "its inputs are recorded too")

        let second = Harness(test: self, lanes: 1)
        await second.run()
        XCTAssertEqual(second.rendered, [])
        XCTAssertEqual(second.lanesMade, 0, "no helper starts when every preview is cached")
        XCTAssertTrue(second.logs.contains { $0.contains("all 4 previews are cached") }, "\(second.logs)")
    }

    func testProgressCountsTheWholeCatalogAndClearsWhenTheRunEnds() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data().write(to: cache.outputBase(for: blur).appendingPathExtension("heic"))

        let harness = Harness(test: self, lanes: 1)
        var seen: [EditorPreviewPrewarm.Progress?] = []
        harness.onRender = { [unowned harness] _, _ in seen.append(harness.prewarm.progress) }
        await harness.run()
        XCTAssertEqual(seen, [1, 2, 3].map { EditorPreviewPrewarm.Progress(done: $0, total: 4) },
                       "the cached one counts as done from the start")
        XCTAssertNil(harness.prewarm.progress, "no line once the run ends")

        let second = Harness(test: self, lanes: 1)
        await second.run()
        XCTAssertEqual(second.rendered, [])
        XCTAssertNil(second.prewarm.progress, "a run with nothing to render shows nothing")
    }

    // MARK: Incremental

    func testAnAssetsUpdateRendersOnlyTheChangedPreviews() async throws {
        let first = Harness(test: self, lanes: 1)
        await first.run()
        XCTAssertEqual(first.rendered.count, 4)

        try setBuild("101")
        try write(#"{"changed": true}"#, to: "effects/blur/effect.json")
        let second = Harness(test: self, lanes: 1)
        await second.run()
        XCTAssertEqual(second.rendered, [blur], "the others' inputs didn't change: carried over")
        XCTAssertEqual(second.prewarm.lastSummary?.carriedOver, 3)
        let old = EditorPreviewCache(cachesDirectory: scratch, build: "steam-100")
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path(percentEncoded: false)), "the old build's folder is removed")

        try write("// changed include", to: "shaders/common.h")
        try setBuild("102")
        let third = Harness(test: self, lanes: 1)
        await third.run()
        XCTAssertEqual(third.rendered, [tint, blur, example, turbulence], "a shared include changes every preview")
    }

    func testAFailedPreviewWaitsForNewInputsUnlessABrowserAsks() async throws {
        let first = Harness(test: self, lanes: 1, failing: [example])
        await first.run()
        XCTAssertEqual(first.prewarm.lastSummary?.failed, [example])

        let second = Harness(test: self, lanes: 1)
        await second.run()
        XCTAssertEqual(second.rendered, [], "not tried again with the same inputs")
        XCTAssertTrue(second.logs.contains { $0.contains("1 failed before") }, "\(second.logs)")

        let cache = EditorPreviewCache(cachesDirectory: scratch, build: EditorPreviewCache.assetsBuild(of: assets))
        try EditorPreviewWants(cache: cache).post([example])
        try FileManager.default.removeItem(at: cache.outputBase(for: tint).appendingPathExtension("heic"))
        let third = Harness(test: self, lanes: 1)
        await third.run()
        XCTAssertEqual(third.rendered, [example, tint], "a browser's request is tried again, first")
    }

    // MARK: Visible first

    func testABrowsersTilesJumpTheQueue() async throws {
        let harness = Harness(test: self, lanes: 1)
        let workshop = EditorPreviewSubject.effect(file: "effects/workshop/1/glow/effect.json", wallpaper: "/w/1")
        let first = tint, next = turbulence
        harness.onRender = { subject, cache in
            guard subject == first else { return }
            try? EditorPreviewWants(cache: cache).post([next, workshop]) // Optional: checked by the order.
        }
        await harness.run()
        XCTAssertEqual(harness.rendered, [tint, turbulence, workshop, blur, example],
                       "a browser opened after the first preview: its tiles next, a Workshop effect included")
        XCTAssertEqual(harness.urgent, [turbulence, workshop], "only a browser's tiles leave the background")
    }

    func testAnEditorHandsItsTilesToARunningPrewarmAndRendersTheRestWhenItStops() async throws {
        let cache = EditorPreviewCache(cachesDirectory: scratch, build: "steam-100")
        let lock = EditorPreviewPrewarmLock(cache: cache)
        XCTAssertTrue(lock.lock())
        let items = [tint, blur].map { EditorPreviewRenderItem(subject: $0, outputBase: cache.outputBase(for: $0)) }
        let reported = Reported()
        let delegated = Task { await EditorPreviewHelper.delegate(items, cache: cache, finished: { reported.add($0) },
                                                                  poll: .milliseconds(10)) }
        let wants = EditorPreviewWants(cache: cache)
        var taken: [EditorPreviewSubject] = []
        for _ in 0..<200 where taken.isEmpty {
            taken = wants.take()
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(taken, [tint, blur], "the tiles are posted in order")
        try FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try Data().write(to: cache.outputBase(for: tint).appendingPathExtension("heic"))
        for _ in 0..<200 where reported.subjects.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(reported.subjects, [tint], "a preview the pre-warm wrote is shown")
        lock.unlock()
        let left = await delegated.value
        XCTAssertEqual(left.map(\.subject), [blur], "the pre-warm stopped first: the editor renders the rest")
    }

    // MARK: Power

    func testItPausesOnLowBatteryOrHeatAndResumes() async throws {
        let low = PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.2))
        let hot = PowerPolicy(PowerState(thermal: .critical))
        let ac = PowerPolicy(PowerState())
        let harness = Harness(test: self, lanes: 1)
        // Allowed for the first preview, then held back for two checks.
        harness.policies = [ac, low, hot, ac]
        var lockHeldWhilePaused: Bool?
        var progressWhilePaused: EditorPreviewPrewarm.Progress?
        harness.onSleep = { [unowned harness] cache in
            lockHeldWhilePaused = EditorPreviewPrewarmLock.isHeld(for: cache)
            progressWhilePaused = harness.prewarm.progress
        }
        await harness.run()
        XCTAssertEqual(progressWhilePaused, EditorPreviewPrewarm.Progress(done: 1, total: 4, isPaused: true),
                       "Settings › Assets shows the run as paused")
        XCTAssertNil(harness.prewarm.progress)
        XCTAssertEqual(harness.rendered, catalog)
        XCTAssertEqual(harness.sleeps, [EditorPreviewPrewarm.pauseRecheck, EditorPreviewPrewarm.pauseRecheck])
        XCTAssertEqual(lockHeldWhilePaused, false, "an editor renders on its own while the pre-warm is paused")
        XCTAssertEqual(harness.lanesMade, 2, "the helper exits while paused")
        let events = harness.logs.map { $0.components(separatedBy: ":").first ?? $0 }
        XCTAssertEqual(events, ["pre-warm started (test)", "pre-warm paused", "pre-warm resumed", "pre-warm finished"])
        XCTAssertTrue(harness.logs[1].contains("on battery at 20 %"), harness.logs[1])
    }

    func testThePowerRuleIsTheDailyReRecordings() {
        XCTAssertTrue(PowerPolicy(PowerState()).allowsEditorPreviewPrewarm)
        XCTAssertTrue(PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.3)).allowsEditorPreviewPrewarm)
        XCTAssertFalse(PowerPolicy(PowerState(onBattery: true, batteryLevel: 0.29)).allowsEditorPreviewPrewarm)
        XCTAssertFalse(PowerPolicy(PowerState(thermal: .critical)).allowsEditorPreviewPrewarm)
        XCTAssertTrue(PowerPolicy(PowerState(thermal: .serious)).allowsEditorPreviewPrewarm)
    }

    func testWithoutAssetsNothingStarts() async {
        let harness = Harness(test: self, lanes: 1)
        harness.hasAssets = false
        await harness.run()
        XCTAssertEqual(harness.lanesMade, 0)
        XCTAssertTrue(harness.logs.first?.contains("assets aren't installed") ?? false, "\(harness.logs)")
    }

    // MARK: Fixtures

    private func write(_ text: String, to path: String) throws {
        let url = assets.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func setBuild(_ build: String) throws {
        try Data(build.utf8).write(to: assets.deletingLastPathComponent().appending(path: ".build"))
    }

    /// A pre-warm over the fixture tree with fake lanes (each "renders" by writing the file),
    /// policies and an immediate clock.
    @MainActor
    private final class Harness {
        let test: EditorPreviewPrewarmTests
        var rendered: [EditorPreviewSubject] = []
        var urgent: [EditorPreviewSubject] = []
        var logs: [String] = []
        var sleeps: [TimeInterval] = []
        var lanesMade = 0
        var policies: [PowerPolicy] = []
        var hasAssets = true
        var failing: Set<EditorPreviewSubject>
        var onRender: ((EditorPreviewSubject, EditorPreviewCache) -> Void)?
        var onSleep: ((EditorPreviewCache) -> Void)?
        private(set) var prewarm: EditorPreviewPrewarm!
        private var clock = Date(timeIntervalSince1970: 1_000_000)

        init(test: EditorPreviewPrewarmTests, lanes: Int, failing: Set<EditorPreviewSubject> = []) {
            self.test = test
            self.failing = failing
            let catalog = test.catalog
            prewarm = EditorPreviewPrewarm(environment: .init(
                assets: { [unowned self] in self.hasAssets ? test.assets : nil },
                cachesDirectory: test.scratch,
                catalog: { _ in catalog },
                power: { [unowned self] in self.policies.count > 1 ? self.policies.removeFirst() : (self.policies.first ?? PowerPolicy(PowerState())) },
                makeLane: { [unowned self] in
                    self.lanesMade += 1
                    return FakeLane(harness: self)
                },
                sleep: { [unowned self] seconds in
                    self.sleeps.append(seconds)
                    self.clock.addTimeInterval(seconds)
                    self.onSleep?(self.currentCache)
                    await Task.yield()
                },
                now: { [unowned self] in self.clock },
                log: { [unowned self] in self.logs.append($0) },
                laneCount: lanes))
        }

        var currentCache: EditorPreviewCache {
            EditorPreviewCache(cachesDirectory: test.scratch, build: EditorPreviewCache.assetsBuild(of: test.assets))
        }

        func run() async {
            prewarm.start(reason: "test")
            await prewarm.wait()
        }

        func render(_ item: EditorPreviewRenderItem) async {
            clock.addTimeInterval(1)
            await Task.yield()
            rendered.append(item.subject)
            if !failing.contains(item.subject) {
                // Optional: a test file.
                try? Data().write(to: item.outputBase.appendingPathExtension(item.subject.isParticle ? "mov" : "heic"))
            }
            onRender?(item.subject, currentCache)
        }
    }

    @MainActor
    private final class FakeLane: EditorPreviewLane {
        weak var harness: Harness?
        private var closed = false

        init(harness: Harness) { self.harness = harness }

        func render(_ item: EditorPreviewRenderItem, isUrgent: Bool) async -> Bool {
            guard !closed, let harness else { return false }
            if isUrgent { harness.urgent.append(item.subject) }
            try? FileManager.default.createDirectory(at: item.outputBase.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true) // Optional: a test folder.
            await harness.render(item)
            return true
        }

        func close() { closed = true }
    }

    private final class Reported: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [EditorPreviewSubject] = []
        var subjects: [EditorPreviewSubject] { lock.withLock { list } }
        func add(_ subject: EditorPreviewSubject) { lock.withLock { list.append(subject) } }
    }
}
