import CoreGraphics
import XCTest
@testable import OWEEditor

/// The shared generator with a fake model: the result's size and convention, the model loaded
/// only to generate and released `idleGrace` after the last generation (a new one restarts the
/// wait), cancel, and the cache keyed by the layer texture.
@MainActor
final class DepthMapGeneratorTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() async throws {
        cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "owe-depthmap-cache-\(UUID().uuidString)",
                                                                         directoryHint: .isDirectory)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDirectory) // Scratch: a leftover is harmless.
    }

    private func makeGenerator(loader: FakeModelLoader, scheduler: ManualIdleScheduler, cached: Bool = false,
                               version: String = "fake-1") -> DepthMapGenerator {
        DepthMapGenerator(locateModel: { DepthMapTestSupport.model(version: version) },
                          loadModel: { try loader.load($0) },
                          cache: cached ? DepthMapCache(directory: cacheDirectory) : nil,
                          scheduler: scheduler, log: { _ in })
    }

    // MARK: Results

    func testTheDepthMapIsAtTheSourcesSizeWithNearWhite() async throws {
        let generator = makeGenerator(loader: FakeModelLoader(), scheduler: ManualIdleScheduler())
        let source = DepthMapTestSupport.edge(width: 200, height: 50)
        let result = try await generator.generate(from: source, smoothing: 0)
        XCTAssertEqual(result.depth.width, 200)
        XCTAssertEqual(result.depth.height, 50)
        // The fake's right half has the larger inverse depth: nearer, so white.
        XCTAssertLessThan(result.depth[10, 25], 0.05)
        XCTAssertGreaterThan(result.depth[190, 25], 0.95)
        XCTAssertFalse(result.fromCache)
        XCTAssertEqual(generator.phase, .finished)
        XCTAssertEqual(generator.progress, 1)
        XCTAssertFalse(generator.isBusy)
        XCTAssertFalse(result.png.isEmpty)
    }

    func testNotInstalledSaysSo() async {
        let generator = DepthMapGenerator(locateModel: { nil }, loadModel: { _ in XCTFail("no model to load"); throw CancellationError() },
                                          cache: nil, scheduler: ManualIdleScheduler(), log: { _ in })
        XCTAssertFalse(generator.isInstalled)
        do {
            _ = try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0)
            XCTFail("generated without a model")
        } catch {
            XCTAssertEqual(error as? DepthMapGenerator.Failure, .notInstalled)
        }
    }

    // MARK: The model's memory

    func testTheModelIsReleasedAfterTheIdleGrace() async throws {
        XCTAssertEqual(DepthMapGenerator.idleGrace, 300, "five minutes")
        let loader = FakeModelLoader()
        let scheduler = ManualIdleScheduler()
        let generator = makeGenerator(loader: loader, scheduler: scheduler)
        XCTAssertFalse(generator.isModelLoaded, "nothing is loaded to play wallpapers")

        _ = try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0)
        XCTAssertEqual(loader.loads, 1)
        XCTAssertTrue(generator.isModelLoaded)
        XCTAssertNotNil(loader.last)
        XCTAssertEqual(scheduler.scheduledDelays, [DepthMapGenerator.idleGrace])

        scheduler.advance(by: DepthMapGenerator.idleGrace - 1)
        XCTAssertTrue(generator.isModelLoaded, "kept for the next layer of a batch")
        scheduler.advance(by: 1)
        XCTAssertFalse(generator.isModelLoaded)
        XCTAssertNil(loader.last, "the model itself is gone, not only the generator's reference")
    }

    func testEveryGenerationRestartsTheWait() async throws {
        let loader = FakeModelLoader()
        let scheduler = ManualIdleScheduler()
        let generator = makeGenerator(loader: loader, scheduler: scheduler)

        _ = try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0)
        scheduler.advance(by: 200)
        _ = try await generator.generate(from: DepthMapTestSupport.edge(width: 128), smoothing: 0)
        XCTAssertEqual(loader.loads, 1, "a batch loads the model once")
        scheduler.advance(by: 200)
        XCTAssertTrue(generator.isModelLoaded, "the second generation restarted the five minutes")
        scheduler.advance(by: 100)
        XCTAssertFalse(generator.isModelLoaded)
        XCTAssertNil(loader.last)

        _ = try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0)
        XCTAssertEqual(loader.loads, 2, "loaded again when needed again")
    }

    func testCancelStopsTheGenerationAndStillReleasesTheModel() async throws {
        let estimator = FakeDepthEstimator { x, _ in Float(x) }
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "the model runs")
        estimator.gate = gate
        estimator.onEstimate = { started.fulfill() }
        let loader = FakeModelLoader(make: { estimator })
        let scheduler = ManualIdleScheduler()
        let generator = makeGenerator(loader: loader, scheduler: scheduler)

        let work = Task { try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0) }
        await fulfillment(of: [started], timeout: 10)
        XCTAssertTrue(generator.isBusy)
        generator.cancel()
        gate.signal()
        do {
            _ = try await work.value
            XCTFail("a cancelled generation gave a result")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(generator.phase, .cancelled)
        XCTAssertFalse(generator.isBusy)
        XCTAssertTrue(generator.isModelLoaded)
        scheduler.advance(by: DepthMapGenerator.idleGrace)
        XCTAssertFalse(generator.isModelLoaded, "released after a cancel too")
    }

    func testBusyRefusesASecondGeneration() async throws {
        let estimator = FakeDepthEstimator { _, _ in 1 }
        let gate = DispatchSemaphore(value: 0)
        let started = expectation(description: "the model runs")
        estimator.gate = gate
        estimator.onEstimate = { started.fulfill() }
        let generator = makeGenerator(loader: FakeModelLoader(make: { estimator }), scheduler: ManualIdleScheduler())
        let first = Task { try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0) }
        await fulfillment(of: [started], timeout: 10)
        do {
            _ = try await generator.generate(from: DepthMapTestSupport.edge(), smoothing: 0)
            XCTFail("two generations at once")
        } catch {
            XCTAssertEqual(error as? DepthMapGenerator.Failure, .busy)
        }
        gate.signal()
        _ = try await first.value
    }

    // MARK: The cache

    func testTheSameTextureIsntRunTwice() async throws {
        let loader = FakeModelLoader()
        let scheduler = ManualIdleScheduler()
        let generator = makeGenerator(loader: loader, scheduler: scheduler, cached: true)
        let source = DepthMapTestSupport.edge(width: 160, height: 40)

        let first = try await generator.generate(from: source, smoothing: 0)
        XCTAssertEqual(loader.last?.runs, 1)
        scheduler.advance(by: DepthMapGenerator.idleGrace)
        XCTAssertFalse(generator.isModelLoaded)

        let second = try await generator.generate(from: source, smoothing: 0)
        XCTAssertTrue(second.fromCache)
        XCTAssertEqual(loader.loads, 1, "a cached texture never loads the model")
        XCTAssertFalse(generator.isModelLoaded)
        XCTAssertEqual(second.depth.width, first.depth.width)
        for (a, b) in zip(first.depth.values, second.depth.values) { XCTAssertEqual(a, b, accuracy: 1 / 255) }

        // Smoothing is applied after the cache: no new run either.
        let smooth = try await generator.generate(from: source, smoothing: 0.8)
        XCTAssertTrue(smooth.fromCache)
        XCTAssertEqual(loader.loads, 1)
    }

    func testCacheKeysFollowThePixelsAndTheModel() throws {
        let a = DepthMapTestSupport.edge(width: 64, height: 16)
        let same = DepthMapTestSupport.edge(width: 64, height: 16)
        let changed = DepthMapTestSupport.image(width: 64, height: 16) { x, y in x == 3 && y == 3 ? 0.5 : (x < 32 ? 0 : 1) }
        let keyA = try XCTUnwrap(DepthMapCache.key(for: a, modelVersion: "v1"))
        XCTAssertEqual(keyA, DepthMapCache.key(for: same, modelVersion: "v1"), "the same texture, wherever it is used")
        XCTAssertNotEqual(keyA, DepthMapCache.key(for: changed, modelVersion: "v1"), "one pixel changes it")
        XCTAssertNotEqual(keyA, DepthMapCache.key(for: a, modelVersion: "v2"), "a new model never reuses an old result")
        XCTAssertNotEqual(keyA, DepthMapCache.key(for: DepthMapTestSupport.edge(width: 32, height: 32), modelVersion: "v1"))
    }

    func testTheCacheRoundTripsADepthMap() throws {
        let cache = DepthMapCache(directory: cacheDirectory)
        var depth = DepthMapBuffer(width: 20, height: 10)
        for x in 0..<20 { for y in 0..<10 { depth[x, y] = Float(x) / 19 } }
        XCTAssertNil(cache.depth(for: "missing"))
        try cache.store(depth, for: "k")
        let read = try XCTUnwrap(cache.depth(for: "k"))
        XCTAssertEqual(read.width, 20)
        XCTAssertEqual(read.height, 10)
        for (a, b) in zip(depth.values, read.values) { XCTAssertEqual(a, b, accuracy: 1 / 255) }
    }

    func testLargeSourcesAreCapped() {
        let big = DepthMapTestSupport.image(width: DepthMapGenerator.maximumSide * 2, height: 8) { _, _ in 0.5 }
        let fitted = DepthMapGenerator.fitted(big)
        XCTAssertEqual(fitted.width, DepthMapGenerator.maximumSide)
        XCTAssertEqual(fitted.height, 4)
        let small = DepthMapTestSupport.edge()
        XCTAssertTrue(DepthMapGenerator.fitted(small) === small)
    }
}
