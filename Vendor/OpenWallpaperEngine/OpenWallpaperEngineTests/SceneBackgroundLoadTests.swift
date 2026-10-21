import MetalKit
import XCTest
@testable import OpenWallpaperEngine

/// Setting a scene wallpaper loads it on the preparation pool (`SceneContentLoader.startLoad`):
/// the main thread never waits on the key, the cache read, the parse or the content build, a newer
/// load cancels an older one, and the display shows the preview until the live scene draws.
final class SceneBackgroundLoadTests: XCTestCase {
    private var restorePool: PreparationPool?

    override func tearDown() {
        if let restorePool { SceneContentLoader.loadPool = restorePool }
        restorePool = nil
        SceneContentLoader.dropSharedParses()
        super.tearDown()
    }

    private func wallpaper(_ directory: URL) throws -> WEWallpaper {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        return WEWallpaper(using: project, where: directory)
    }

    /// A heavy library wallpaper when `OWE_LIBRARY` has one, else a fixture with several layers.
    private func heavyWallpaper() throws -> URL {
        let library = ProcessInfo.processInfo.environment["OWE_LIBRARY"].map { URL(fileURLWithPath: $0) }
        if let library, let entries = try? FileManager.default.contentsOfDirectory(atPath: library.path) {
            for id in ["2370927443", "3803167460"] + entries.sorted() {
                let directory = library.appending(path: id, directoryHint: .isDirectory)
                if let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                   let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a scene
                   project.type.lowercased() == "scene" {
                    return directory
                }
            }
        }
        return Fixtures.url("Scenes/layers")
    }

    /// Setting a wallpaper, up to its built content: the main thread answers throughout, and no
    /// heavy work reports a thread guard hit on it.
    func testBackgroundLoadNeverBlocksTheMainThread() throws {
        let directory = try heavyWallpaper()
        defer { Fixtures.removeStoredSettings(for: directory) }
        let wallpaper = try wallpaper(directory)
        SceneContentLoader.dropSharedParses()
        let watchdog = HangWatchdog(pingInterval: 0.005, mainThreshold: 0.1)
        watchdog.start()

        let model = SceneContentLoader(wallpaper: wallpaper, loadsInBackground: true)
        spin(until: { model.metalRevision > 0 && !model.isLoading }, timeout: 60)
        var built: SceneMetalContent??
        model.contentAsync { built = .some($0) }
        spin(until: { built != nil }, timeout: 60)

        let hangs = watchdog.stop()
        XCTAssertEqual(hangs, [], "\(directory.lastPathComponent)")
        let revision: Int = model.metalRevision
        XCTAssertEqual(revision, 1)
        let content = try XCTUnwrap(built ?? nil, "no content")
        XCTAssertFalse(content.layers.isEmpty)
        // A thread guard hit fails the test through `ThreadGuardTestObserver`.
    }

    /// A load superseded before it ran never commits: only the newest wallpaper loads.
    func testSupersededLoadIsCancelled() throws {
        _ = try Fixtures.assets()  // both scenes draw WE's util models, which come from the assets
        let first = Fixtures.url("Scenes/layers")
        let second = Fixtures.url("Scenes/solid")
        defer {
            Fixtures.removeStoredSettings(for: first)
            Fixtures.removeStoredSettings(for: second)
        }
        let pool = PreparationPool(maxWorkers: 1)
        restorePool = SceneContentLoader.loadPool
        SceneContentLoader.loadPool = pool
        // Holds the only worker, so both loads queue behind it.
        let gate = DispatchSemaphore(value: 0)
        pool.submit(priority: .settingWallpaper) { _ in gate.wait() }

        let model = SceneContentLoader(wallpaper: try wallpaper(first), loadsInBackground: true)
        model.currentWallpaper = try wallpaper(second)
        XCTAssertTrue(model.isLoading)
        gate.signal()
        spin(until: { !model.isLoading && model.metalRevision > 0 }, timeout: 60)
        spin(for: 0.2)

        let revision: Int = model.metalRevision
        XCTAssertEqual(revision, 1, "the superseded load committed too")
        let content = try XCTUnwrap(model.metalContent())
        let solid = try XCTUnwrap(SceneContentLoader(wallpaper: try wallpaper(second)).metalContent())
        XCTAssertEqual(content.layers.map(\.id), solid.layers.map(\.id))
    }

    /// A load that a newer one supersedes while it runs is dropped at its commit.
    func testRunningLoadSupersededByReloadCommitsOnce() throws {
        let directory = Fixtures.url("Scenes/layers")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let model = SceneContentLoader(wallpaper: try wallpaper(directory), loadsInBackground: true)
        model.reloadCurrentScene()
        model.reloadCurrentScene()
        spin(until: { !model.isLoading && model.metalRevision > 0 }, timeout: 60)
        spin(for: 0.2)
        let revision: Int = model.metalRevision
        XCTAssertGreaterThanOrEqual(revision, 1)
        XCTAssertLessThanOrEqual(revision, 3)
        XCTAssertNotNil(model.metalContent())
    }

    /// The preview shows at once (decoded off the main thread), then crossfades out.
    @MainActor
    func testPlaceholderShowsThenCrossfades() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-placeholder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup
        let image = SceneContentLoader.solidImage(red: 1, green: 0, blue: 0)
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appending(path: "preview.png"))

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let placeholder = ScenePreviewPlaceholder(in: view, wallpaperDirectory: directory)
        XCTAssertTrue(placeholder.layer.superlayer === view.layer)
        spin(until: { placeholder.layer.contents != nil }, timeout: 5)
        XCTAssertNotNil(placeholder.layer.contents, "the preview never showed")
        let shownOpacity: Float = placeholder.layer.opacity
        XCTAssertEqual(shownOpacity, 1)

        placeholder.fadeOut()
        XCTAssertTrue(placeholder.isFading)
        let fadedOpacity: Float = placeholder.layer.opacity
        XCTAssertEqual(fadedOpacity, 0)
        let fadeTimeout: TimeInterval = ScenePreviewPlaceholder.fadeDuration + 2
        spin(until: { placeholder.layer.superlayer == nil }, timeout: fadeTimeout)
        XCTAssertNil(placeholder.layer.superlayer, "the preview stayed after the crossfade")
    }

    /// The preview is downsampled to the display, never decoded at full size.
    func testPreviewImageIsDownsampled() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: directory.appending(path: "preview.jpg"))
        let image = try XCTUnwrap(ScenePreviewPlaceholder.previewImage(in: directory, maxPixels: 200))
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
        XCTAssertNil(ScenePreviewPlaceholder.previewImage(in: directory.appending(path: "missing"), maxPixels: 200))
    }
}

/// Main-thread blocking while setting each wallpaper of `OWE_LOAD_BENCH` (comma-separated ids, or
/// `all`) from `OWE_LIBRARY`, cold (the shared parse dropped first), up to built content. While it
/// waits, the main thread reads what the instance's `update()` reads on every SwiftUI update (the
/// texture reduction size, the settings, the revision), as the app does. Printed: the synchronous
/// load (on the main thread, as the app ran it before) and the longest main-thread gap while its
/// content builds; then the background load's longest gap.
final class SceneLoadBlockingBenchmarkTests: XCTestCase {
    func testMainThreadBlockingWhileSettingWallpapers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_LOAD_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_LOAD_BENCH to measure main-thread blocking while loading")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let ids = request == "all"
            ? try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
            : request.split(separator: ",").map(String.init)
        var lines = ["Main-thread blocking while setting a wallpaper (ms): synchronous load, worst gap while its content "
                     + "builds | background load, worst gap until its content is built"]
        for id in ids {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a wallpaper
                  project.type.lowercased() == "scene" else { continue }
            let wallpaper = WEWallpaper(using: project, where: directory)

            SceneContentLoader.dropSharedParses()
            let syncStart = CACurrentMediaTime()
            let syncModel = SceneContentLoader(wallpaper: wallpaper)
            let syncMs: Double = (CACurrentMediaTime() - syncStart) * 1000
            let syncGaps = GapMeter()
            syncGaps.start()
            Self.build(syncModel)
            let syncWorst: Double = max(syncGaps.stop() * 1000, syncMs)

            SceneContentLoader.dropSharedParses()
            let gaps = GapMeter()
            gaps.start()
            let start = CACurrentMediaTime()
            let model = SceneContentLoader(wallpaper: wallpaper, loadsInBackground: true)
            let initMs: Double = (CACurrentMediaTime() - start) * 1000
            Self.pump(model, until: { !model.isLoading && model.metalRevision > 0 })
            Self.build(model)
            let totalMs: Double = (CACurrentMediaTime() - start) * 1000
            let worstMs: Double = max(gaps.stop() * 1000, initMs)
            lines.append(String(format: "%@ “%@”: sync load %.1f, worst gap %.1f | background worst gap %.1f (init %.2f), content after %.0f",
                                id, String(project.title.prefix(24)), syncMs, syncWorst, worstMs, initMs, totalMs))
        }
        print(lines.joined(separator: "\n"))
    }

    private static func build(_ model: SceneContentLoader) {
        var built = false
        model.contentAsync { _ in built = true }
        pump(model, until: { built })
    }

    /// Spins the main run loop, reading what `SceneWallpaperInstance.update()` reads every 16 ms.
    private static func pump(_ model: SceneContentLoader, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(120)
        while !done(), Date() < deadline {
            _ = model.textureReductionSceneSize
            model.setRenderSettings(SceneRenderSettings())
            _ = model.metalRevision
            RunLoop.main.run(until: Date().addingTimeInterval(0.016))
        }
    }

    /// The longest the main run loop went without answering a 1 ms ping.
    private final class GapMeter: @unchecked Sendable {
        private let lock = NSLock()
        private var running = false
        private var worst: CFTimeInterval = 0

        func start() {
            lock.withLock { running = true; worst = 0 }
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let sent = CACurrentMediaTime()
                    let answered = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { answered.signal() }
                    while answered.wait(timeout: .now() + 0.5) == .timedOut, lock.withLock({ running }) {}
                    let gap = CACurrentMediaTime() - sent
                    lock.withLock { worst = max(worst, gap) }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }

        func stop() -> CFTimeInterval {
            lock.withLock { running = false; return worst }
        }
    }
}
