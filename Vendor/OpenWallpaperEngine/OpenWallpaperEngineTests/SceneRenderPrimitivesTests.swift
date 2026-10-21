import XCTest
@testable import OpenWallpaperEngine

/// Area 8 review items: the scene clock, Retina target sizing, world-space scene regions and the
/// text cache.
final class SceneRenderPrimitivesTests: XCTestCase {
    // MARK: Scene clock

    func testClockStartsAtZeroAndCountsSceneSeconds() {
        var clock = SceneClock()
        clock.advance(to: 1_000_000, speed: 1)
        XCTAssertEqual(clock.time, 0, "the first frame only anchors the clock, whatever the uptime")
        clock.advance(to: 1_000_000.1, speed: 1)
        XCTAssertEqual(clock.time, 0.1, accuracy: 1e-9)
        XCTAssertEqual(clock.delta, 0.1, accuracy: 1e-9)
    }

    /// A rate change changes the next step, never the time already run: every frame advances by
    /// its own wall step × its rate, so the time is continuous across the change (roadmap notes 8.4).
    func testSpeedChangeDoesNotJump() {
        var clock = SceneClock()
        clock.advance(to: 100, speed: 1)
        clock.advance(to: 110, speed: 1) // clamped: a 10 s stall counts as one max-length frame
        XCTAssertEqual(clock.time, SceneClock.maximumFrameDelta, accuracy: 1e-9)
        var wall = 110.0
        var previous = clock.time
        for (frame, speed) in [1.0, 1, 3, 3, 0.5, 2, 1].enumerated() {
            wall += 1.0 / 60
            clock.advance(to: wall, speed: speed)
            XCTAssertEqual(clock.time - previous, speed / 60, accuracy: 1e-9, "frame \(frame) at \(speed)×")
            XCTAssertEqual(clock.delta, speed / 60, accuracy: 1e-9)
            previous = clock.time
        }
        // WE's rate is at least 0.1 (0x140114d98): the app's slider can't stop the scene.
        clock.advance(to: wall + 0.1, speed: 0)
        XCTAssertEqual(clock.delta, 0.01, accuracy: 1e-9)
    }

    /// WE clamps the frame to 0.0001…0.25 s before and after the rate (0x140111355, 0x1401114f7).
    func testFrameStepsAreClampedAsWEClampsThem() {
        var clock = SceneClock()
        clock.advance(to: 50, speed: 1)
        clock.advance(to: 50.2, speed: 2)
        XCTAssertEqual(clock.delta, SceneClock.maximumFrameDelta, accuracy: 1e-12, "0.2 s × 2 is capped at 0.25")
        clock.advance(to: 50.2, speed: 1)
        XCTAssertEqual(clock.delta, SceneClock.minimumFrameDelta, accuracy: 1e-12, "a repeated time still steps")
        clock.advance(to: 50.21, speed: 0.1)
        XCTAssertEqual(clock.delta, 0.001, accuracy: 1e-12)
    }

    /// A held clock (test harnesses settling at time 0) stands still, steps 0, and runs on from
    /// the wall time it was held at.
    func testHeldClockStandsStill() {
        var clock = SceneClock()
        clock.hold(at: 10)
        XCTAssertEqual(clock.time, 0)
        XCTAssertEqual(clock.delta, 0)
        clock.hold(at: 10)
        XCTAssertEqual(clock.time, 0, "no 0.1 ms floor while held")
        clock.advance(to: 10.5, speed: 1)
        XCTAssertEqual(clock.delta, SceneClock.maximumFrameDelta, accuracy: 1e-12, "from the held wall time")
        clock.hold(at: 20)
        XCTAssertEqual(clock.delta, 0)
        XCTAssertEqual(clock.time, SceneClock.maximumFrameDelta, accuracy: 1e-12)
        clock.advance(to: 20 + 1.0 / 30, speed: 1)
        XCTAssertEqual(clock.delta, 1.0 / 30, accuracy: 1e-9)
    }

    /// The clock starts at 0 whatever the uptime (WE's scene time, not the machine's), so 30 days
    /// of uptime cost no precision: 1/60 s steps land exactly as they would at boot.
    func testLongUptimeKeepsFramePrecision() {
        let thirtyDays = 30.0 * 86_400
        var clock = SceneClock()
        clock.advance(to: thirtyDays, speed: 1)
        for frame in 1...600 {
            clock.advance(to: thirtyDays + Double(frame) / 60, speed: 1)
        }
        XCTAssertEqual(clock.time, 10, accuracy: 1e-6)
        XCTAssertEqual(Float(clock.time), 10, accuracy: 1e-5, "g_Time is exact to the float's precision at 10 s")
        // The same frames seen through `Float(CACurrentMediaTime())` lose most of their steps.
        let step = Float(thirtyDays + 1.0 / 60) - Float(thirtyDays)
        XCTAssertNotEqual(step, Float(1.0 / 60), accuracy: 1e-3)
    }

    /// WE's scene time goes back to 0 once its float passes five days (0x14017fcde…0x14017fcf6), so
    /// `g_Time` never loses more than 1/32 s of precision however long a wallpaper runs.
    func testSceneTimeWrapsAfterFiveDays() {
        var clock = SceneClock()
        var wall = 1_000.0
        clock.advance(to: wall, speed: 1)
        var wrapped = false
        var longest = 0.0
        // Six days of 0.25 s frames.
        for _ in 0..<(6 * 86_400 * 4) {
            wall += 0.25
            let before = clock.time
            clock.advance(to: wall, speed: 1)
            if clock.time < before { wrapped = true }
            longest = max(longest, clock.time)
        }
        XCTAssertTrue(wrapped)
        XCTAssertLessThanOrEqual(Float(longest), SceneClock.wrapTime)
        XCTAssertGreaterThan(longest, 431_999)
        let ulp = Float(longest).ulp
        XCTAssertLessThanOrEqual(ulp, 1.0 / 32)
    }

    /// Risk #17: speeds and wall times a frame can see. Time never runs backwards or turns NaN,
    /// and a long gap (sleep) advances it by one clamped frame.
    func testClockSurvivesDegenerateSpeedsAndWallTimes() {
        var clock = SceneClock()
        clock.advance(to: 10, speed: 1)
        for (step, speed) in [0, -1, Double.nan, Double.infinity, -Double.infinity].enumerated() {
            let before = clock.time
            clock.advance(to: 10 + 0.1 * Double(step + 1), speed: speed)
            XCTAssertTrue(clock.time.isFinite && clock.delta.isFinite, "speed \(speed)")
            XCTAssertGreaterThanOrEqual(clock.delta, 0, "speed \(speed)")
            XCTAssertGreaterThanOrEqual(clock.time, before, "speed \(speed)")
        }
        let beforeRewind = clock.time
        clock.advance(to: 5, speed: 1) // the wall clock went backwards: WE's shortest step
        XCTAssertEqual(clock.delta, SceneClock.minimumFrameDelta, accuracy: 1e-12)
        XCTAssertEqual(clock.time, beforeRewind + SceneClock.minimumFrameDelta, accuracy: 1e-9)
        clock.advance(to: 5 + 3600, speed: 1) // an hour asleep
        XCTAssertEqual(clock.delta, SceneClock.maximumFrameDelta, accuracy: 1e-12)
        clock.advance(to: .nan, speed: 1)
        XCTAssertTrue(clock.time.isFinite, "a NaN wall time does not poison the clock")
        clock.advance(to: 5 + 3600.1, speed: 1)
        XCTAssertTrue(clock.time.isFinite)
    }

    // MARK: Retina target

    /// Risk #11: target size for the displays and scene shapes people use. The target never
    /// exceeds what Metal can allocate (16384 px per side), keeps the scene's aspect, and follows
    /// the drawable's density up to about a 5K frame.
    func testTargetSizeTable() {
        struct Case { let scene: SIMD2<Float>; let drawable: SIMD2<Float> }
        let cases = [
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(5120, 2880)),   // 5K
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(6016, 3384)),   // 6K XDR
            Case(scene: SIMD2(5120, 1440), drawable: SIMD2(5120, 1440)),   // 32:9
            Case(scene: SIMD2(1080, 1920), drawable: SIMD2(2880, 1800)),   // portrait scene, landscape display
            Case(scene: SIMD2(1920, 1080), drawable: .zero),                // no drawable yet
            Case(scene: SIMD2(1, 1), drawable: SIMD2(3840, 2160)),
            Case(scene: SIMD2(20000, 20000), drawable: SIMD2(3840, 2160)),
            Case(scene: SIMD2(1920, 1080), drawable: SIMD2(.nan, .infinity)),
        ]
        for item in cases {
            let scale = SceneRenderResolution.pixelsPerUnit(sceneSize: item.scene, drawableSize: item.drawable,
                                                            floorsAtAuthoredSize: true)
            let size = SceneRenderResolution.targetSize(sceneSize: item.scene, pixelsPerUnit: scale)
            let label = "scene \(item.scene), drawable \(item.drawable)"
            XCTAssertTrue(scale.isFinite && scale > 0, label)
            XCTAssertGreaterThanOrEqual(size.x, 1, label)
            XCTAssertGreaterThanOrEqual(size.y, 1, label)
            XCTAssertLessThanOrEqual(max(size.x, size.y), Int(SceneRenderResolution.maximumTextureDimension), label)
            XCTAssertEqual(Float(size.x) / Float(size.y), item.scene.x / item.scene.y,
                           accuracy: 0.01 * item.scene.x / item.scene.y, label)
        }
        // WE draws at the display's resolution: 5K and 6K get exactly their density, or eighths
        // rounded up for a target that follows a live-resizing window.
        let fiveK = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(5120, 2880))
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: SIMD2(1920, 1080), pixelsPerUnit: fiveK), SIMD2(5120, 2880))
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(5120, 2880),
                                                           quantised: true), 2.75, accuracy: 1e-6)
        let sixK = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(6016, 3384),
                                                       quantised: true)
        XCTAssertEqual(sixK, 3.25, accuracy: 1e-6)
        // A floored scene bigger than Metal's largest texture is fitted into it rather than failing to allocate.
        let huge = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(20000, 20000), drawableSize: SIMD2(3840, 2160),
                                                       floorsAtAuthoredSize: true)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: SIMD2(20000, 20000), pixelsPerUnit: huge),
                       SIMD2(16384, 16384))
    }

    func testTargetFollowsDrawableDensity() {
        let scene = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(3840, 2160)), 2)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: scene, pixelsPerUnit: 2), SIMD2(3840, 2160))
        // Floored, never below the authored size (thumbnails, small windows, the exports).
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: scene, drawableSize: SIMD2(640, 360),
                                                           floorsAtAuthoredSize: true), 1)
    }

    /// Only the hardware limits the target: no memory budget caps the density.
    func testTargetIsLimitedOnlyByTheLargestTexture() {
        let scale = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(15360, 8640))
        XCTAssertEqual(scale, 8)
        XCTAssertEqual(SceneRenderResolution.targetSize(sceneSize: SIMD2(1920, 1080), pixelsPerUnit: scale), SIMD2(15360, 8640))
        let beyond = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(30720, 17280),
                                                         quantised: true)
        XCTAssertEqual(beyond, 8.5, "the largest eighth whose target fits 16384 px")
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(7680, 4320), drawableSize: SIMD2(7680, 4320)), 1)
    }

    // MARK: Scene regions

    func testRotatedQuadBoundingBox() {
        let world = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 300), scale: SIMD2(2, 2), angle: .pi / 2))
        let box = SceneQuadGeometry(world: world, size: SIMD2(100, 50), alignment: nil).boundingBox
        // Turned a quarter: 200×100 becomes 100 wide, 200 tall.
        XCTAssertEqual(box.min.x, 450, accuracy: 0.01)
        XCTAssertEqual(box.max.x, 550, accuracy: 0.01)
        XCTAssertEqual(box.min.y, 200, accuracy: 0.01)
        XCTAssertEqual(box.max.y, 400, accuracy: 0.01)
    }

    // MARK: Text cache

    func testLRUEvictsLeastRecentlyUsed() {
        var cache = SceneLRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "b"), "b was the least recently used")
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    /// A seconds clock never reuses its old strings: the byte cap keeps the cache near its budget
    /// instead of 128 full rasters.
    func testLRUEvictsOldEntriesPastItsByteBudget() {
        var cache = SceneLRUCache<String, Int>(capacity: 128, costLimit: 100)
        for second in 0..<60 {
            cache.beginGeneration()
            cache.insert(second, for: "12:00:\(second)", cost: 30)
        }
        let count: Int = cache.count
        let total: Int = cache.totalCost
        XCTAssertEqual(count, 3)
        XCTAssertEqual(total, 90)
        XCTAssertEqual(cache.value(for: "12:00:59"), 59)
        XCTAssertEqual(cache.value(for: "12:00:57"), 57)
        XCTAssertNil(cache.value(for: "12:00:56"))
    }

    /// What the current frame draws stays even over the budget, so a frame never rasterises its own
    /// strings twice; the cap applies again to what the next frame doesn't use.
    func testLRUKeepsTheCurrentGenerationPastItsByteBudget() {
        var cache = SceneLRUCache<String, Int>(capacity: 128, costLimit: 100)
        cache.beginGeneration()
        cache.insert(1, for: "a", cost: 80)
        cache.insert(2, for: "b", cost: 80)
        let pinnedCount: Int = cache.count
        XCTAssertEqual(pinnedCount, 2)
        cache.beginGeneration()
        XCTAssertEqual(cache.value(for: "b"), 2)
        cache.insert(3, for: "c", cost: 10)
        XCTAssertNil(cache.value(for: "a"), "a was not drawn this frame")
        let total: Int = cache.totalCost
        XCTAssertEqual(total, 90)
    }

    /// Re-inserting a key replaces its cost; trimming and clearing keep the total right.
    func testLRUCostAccounting() {
        var cache = SceneLRUCache<String, Int>(capacity: 10, costLimit: 1_000)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "a", cost: 10)
        cache.insert(3, for: "b", cost: 20)
        let replaced: Int = cache.totalCost
        XCTAssertEqual(replaced, 30)
        cache.trim(to: 1)
        let trimmed: Int = cache.totalCost
        XCTAssertEqual(trimmed, 20)
        cache.removeAll()
        let cleared: Int = cache.totalCost
        XCTAssertEqual(cleared, 0)
    }

    func testTextRasterScaleIsRetainedWhileScaleAnimatesDown() {
        var retained: Float?
        var scales = Set<Float>()
        for step in 0..<200 {
            let animated = 1 + 0.5 * sin(Float(step) * 0.1) // a pulsing scale
            let scale = SceneTextRasterScale.retained(SceneTextRasterScale.quantized(animated * 2), previous: retained)
            retained = scale
            scales.insert(scale)
        }
        XCTAssertLessThanOrEqual(scales.count, 4, "only the growth steps re-rasterise")
    }

    func testAnimatedTextScaleReusesABoundedSetOfRastersAndSettlesExact() {
        var tracker = SceneTextRasterScale.Tracker()
        var scales = Set<Float>()
        for step in 0..<600 {
            scales.insert(tracker.scale(for: 2 * (1 + 0.5 * sin(Float(step) * 0.1))))
        }
        XCTAssertLessThanOrEqual(scales.count, 4, "an animating layer reuses a handful of quantised rasters")
        let rest: Float = 2.37
        var settled: Float = 0
        for _ in 0...SceneTextRasterScale.settleFrames { settled = tracker.scale(for: rest) }
        XCTAssertEqual(settled, rest, "text at rest gets an exact raster")
        XCTAssertNotEqual(tracker.scale(for: 2.0), rest, "a new animation goes back to quantised steps")
    }

    func testTextCacheEvictsLeastRecentlyUsedUnderItsByteBudget() {
        var cache = SceneLRUCache<String, Int>(capacity: 128, costLimit: 300)
        cache.beginGeneration()
        cache.insert(1, for: "a", cost: 100)
        cache.insert(2, for: "b", cost: 100)
        cache.insert(3, for: "c", cost: 100)
        cache.beginGeneration()
        _ = cache.value(for: "a")
        cache.insert(4, for: "d", cost: 100)
        XCTAssertNil(cache.value(for: "b"), "the least recently used raster goes, not the whole cache")
        XCTAssertNotNil(cache.value(for: "a"))
        XCTAssertNotNil(cache.value(for: "c"))
        XCTAssertNotNil(cache.value(for: "d"))
        XCTAssertEqual(cache.totalCost, 300)
    }
}
