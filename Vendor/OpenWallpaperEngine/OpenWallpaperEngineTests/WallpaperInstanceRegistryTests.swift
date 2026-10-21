import XCTest
@testable import OpenWallpaperEngine

/// The registry that runs one instance per wallpaper however many displays show it
/// (docs/architecture.md "Wallpaper instances").
@MainActor
final class WallpaperInstanceRegistryTests: XCTestCase {
    /// A wallpaper instance with an audio engine, counted: each instance makes one.
    private final class FakeInstance {
        static var audioEngines = 0
        let key: String
        private(set) var stopped = false

        init(key: String) {
            self.key = key
            Self.audioEngines += 1
        }

        func stop() { stopped = true }
    }

    private final class Display {}

    private var deferred: [() -> Void] = []

    private func registry() -> WallpaperInstanceRegistry<String, FakeInstance> {
        FakeInstance.audioEngines = 0
        return WallpaperInstanceRegistry(teardown: { $0.stop() }, deferTeardown: { [weak self] work in
            self?.deferred.append { MainActor.assumeIsolated(work) }
        })
    }

    private func runDeferred() {
        let work = deferred
        deferred.removeAll()
        work.forEach { $0() }
    }

    func testTheSameWallpaperOnTwoDisplaysIsOneInstanceWithOneAudioEngine() {
        let registry = registry()
        let left = Display(), right = Display()
        let a = registry.acquire("scene", holder: left) { FakeInstance(key: "scene") }
        let b = registry.acquire("scene", holder: right) { FakeInstance(key: "scene") }
        XCTAssertIdentical(a, b)
        XCTAssertEqual(registry.holderCount(for: "scene"), 2)
        XCTAssertEqual(FakeInstance.audioEngines, 1, "one audio engine for both displays")
    }

    func testAnotherWallpaperOnOneDisplaySplitsIntoItsOwnInstance() {
        let registry = registry()
        let left = Display(), right = Display()
        let shared = registry.acquire("scene", holder: left) { FakeInstance(key: "scene") }
        _ = registry.acquire("scene", holder: right) { FakeInstance(key: "scene") }
        // The right display switches wallpaper: it holds the other one and lets go of the first.
        let other = registry.acquire("other", holder: right) { FakeInstance(key: "other") }
        registry.release("scene", holder: right)
        runDeferred()
        XCTAssertNotIdentical(shared, other)
        XCTAssertFalse(shared.stopped, "the left display still shows it")
        XCTAssertEqual(registry.holderCount(for: "scene"), 1)
        XCTAssertEqual(registry.holderCount(for: "other"), 1)
        XCTAssertEqual(FakeInstance.audioEngines, 2)
    }

    func testAnInstanceStopsOnceItsLastDisplayIsRemoved() {
        let registry = registry()
        let left = Display(), right = Display()
        let instance = registry.acquire("scene", holder: left) { FakeInstance(key: "scene") }
        _ = registry.acquire("scene", holder: right) { FakeInstance(key: "scene") }
        registry.release("scene", holder: right)
        runDeferred()
        XCTAssertFalse(instance.stopped)
        registry.release("scene", holder: left)
        XCTAssertFalse(instance.stopped, "not before the next main-queue turn")
        runDeferred()
        XCTAssertTrue(instance.stopped)
        XCTAssertNil(registry.instance(for: "scene"))
    }

    /// Screens changing rebuild every wallpaper window: the new display takes hold before the
    /// teardown runs, and the wallpaper keeps running instead of loading again.
    func testARebuiltDisplayKeepsTheRunningInstance() {
        let registry = registry()
        let old = Display(), rebuilt = Display()
        let instance = registry.acquire("scene", holder: old) { FakeInstance(key: "scene") }
        registry.release("scene", holder: old)
        let again = registry.acquire("scene", holder: rebuilt) { FakeInstance(key: "scene") }
        runDeferred()
        XCTAssertIdentical(instance, again)
        XCTAssertFalse(instance.stopped)
        XCTAssertEqual(FakeInstance.audioEngines, 1)
    }

    func testReleasingTwiceOrAnUnknownHolderChangesNothing() {
        let registry = registry()
        let left = Display(), right = Display()
        _ = registry.acquire("scene", holder: left) { FakeInstance(key: "scene") }
        _ = registry.acquire("scene", holder: right) { FakeInstance(key: "scene") }
        registry.release("scene", holder: right)
        registry.release("scene", holder: right)
        registry.release("scene", holder: Display())
        XCTAssertEqual(registry.holderCount(for: "scene"), 1)
    }

    func testDroppingALeaseReleasesItsDisplay() {
        let registry = registry()
        var first: WallpaperInstanceLease<String, FakeInstance>? = WallpaperInstanceLease(registry, key: "scene") {
            FakeInstance(key: "scene")
        }
        let second = WallpaperInstanceLease(registry, key: "scene") { FakeInstance(key: "scene") }
        XCTAssertIdentical(first?.instance, second.instance)
        XCTAssertEqual(registry.holderCount(for: "scene"), 2)
        first = nil
        XCTAssertEqual(registry.holderCount(for: "scene"), 1)
        second.release()
        runDeferred()
        XCTAssertTrue(second.instance.stopped)
    }

    /// The key is the wallpaper (folder, file, type); user properties are stored per wallpaper, so
    /// they never tell two displays of it apart, and a property change reaches the one instance.
    func testTheKeyIsTheWallpaper() {
        let project = WEProject(file: "scene.json", preview: "preview.jpg", title: "A", type: "scene")
        let folder = URL(filePath: "/tmp/owe/wallpapers/123")
        let key = WallpaperInstanceKey(WEWallpaper(using: project, where: folder))
        XCTAssertEqual(key, WallpaperInstanceKey(WEWallpaper(using: project, where: URL(filePath: "/tmp/owe/wallpapers/./123"))))
        XCTAssertNotEqual(key, WallpaperInstanceKey(WEWallpaper(using: project, where: URL(filePath: "/tmp/owe/wallpapers/456"))))
        let video = WEProject(file: "scene.json", preview: "preview.jpg", title: "A", type: "video")
        XCTAssertNotEqual(key, WallpaperInstanceKey(WEWallpaper(using: video, where: folder)))
    }
}
