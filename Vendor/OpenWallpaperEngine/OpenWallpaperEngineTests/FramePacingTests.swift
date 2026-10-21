import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Adaptive frame rate and idle skipping (efficiency-plan-2d notes WP2-C): the demand and rate
/// decision tables, the ramps, the slider and N10, and an idle scene waking on a cursor move.
final class FramePacingTests: XCTestCase {
    // MARK: - Demand

    func testDemandDecisionTable() {
        struct Row { let inputs: FrameDemandInputs; let expected: FrameDemand; let line: UInt }
        let rows: [Row] = [
            Row(inputs: .init(), expected: .idle, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.cursor], pointerMoved: true), expected: .interactive, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.parallax], pointerMoved: true, parallaxMoved: true), expected: .interactive, line: #line),
            // Parallax easing after the cursor stopped, or moved by camera shake.
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.parallax], parallaxMoved: true), expected: .smooth, line: #line),
            Row(inputs: .init(pointerMoved: true, particlesLive: true, particlesFollowCursor: true), expected: .interactive, line: #line),
            // The pointer moved but nothing visible follows it.
            Row(inputs: .init(pointerMoved: true), expected: .idle, line: #line),
            Row(inputs: .init(pointerMoved: true, particlesLive: true), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.time]), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.video]), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.audio]), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.timeline]), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.frameBeneath]), expected: .smooth, line: #line),
            Row(inputs: .init(sceneStagesAnimate: true), expected: .smooth, line: #line),
            Row(inputs: .init(particlesLive: true), expected: .smooth, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.userProperties]), expected: .slow, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.inspector]), expected: .slow, line: #line),
            Row(inputs: .init(anyDirty: true, dirtyDependencies: [.script]), expected: .slow, line: #line),
            // A scene-wide change with no named input (a pipeline landing).
            Row(inputs: .init(anyDirty: true), expected: .slow, line: #line),
        ]
        for row in rows {
            var pacing = FramePacing()
            XCTAssertEqual(pacing.classify(row.inputs), row.expected, line: row.line)
        }
    }

    /// A lone script change is slow content (a clock's text); two frames running is motion.
    func testScriptsAreMotionOnlyWhenTheyChangeFramesRunning() {
        var pacing = FramePacing()
        let script = FrameDemandInputs(anyDirty: true, dirtyDependencies: [.script])
        XCTAssertEqual(pacing.classify(script), .slow)
        XCTAssertEqual(pacing.classify(script), .smooth)
        XCTAssertEqual(pacing.classify(FrameDemandInputs()), .idle)
        XCTAssertEqual(pacing.classify(script), .slow)
    }

    // MARK: - Rates

    func testRateDecisionTable() {
        struct Row { let stop: Int; let user: Int; let cap: Int?; let rates: [FrameDemand: Int]; let line: UInt }
        let rows: [Row] = [
            Row(stop: 1, user: 120, cap: nil, rates: [.interactive: 120, .smooth: 120, .slow: 30, .idle: 30], line: #line),
            Row(stop: 2, user: 120, cap: nil, rates: [.interactive: 120, .smooth: 60, .slow: 30, .idle: 30], line: #line),
            Row(stop: 3, user: 120, cap: nil, rates: [.interactive: 120, .smooth: 60, .slow: 15, .idle: 15], line: #line),
            Row(stop: 4, user: 120, cap: nil, rates: [.interactive: 120, .smooth: 30, .slow: 15, .idle: 15], line: #line),
            Row(stop: 5, user: 120, cap: nil, rates: [.interactive: 120, .smooth: 30, .slow: 10, .idle: 10], line: #line),
            // WE's FPS setting caps everything.
            Row(stop: 4, user: 30, cap: nil, rates: [.interactive: 30, .smooth: 30, .slow: 15, .idle: 15], line: #line),
            Row(stop: 1, user: 10, cap: nil, rates: [.interactive: 10, .smooth: 10, .slow: 10, .idle: 10], line: #line),
            // N10 at `.critical`.
            Row(stop: 1, user: 120, cap: 30, rates: [.interactive: 30, .smooth: 30, .slow: 30, .idle: 30], line: #line),
        ]
        for row in rows {
            var pacing = FramePacing()
            pacing.limits = .init(userLimit: row.user, policy: QualityEfficiency(stop: row.stop), powerCap: row.cap)
            for (demand, rate) in row.rates {
                XCTAssertEqual(pacing.rate(for: demand), rate, "stop \(row.stop) \(demand)", line: row.line)
            }
        }
    }

    func testEventOnlySceneProbesSlowlyWhileIdle() {
        var pacing = FramePacing()
        pacing.limits = .init(userLimit: 60, policy: QualityEfficiency(stop: 1))
        pacing.changesOnItsOwn = false
        XCTAssertEqual(pacing.rate(for: .idle), FramePacing.eventOnlyProbeRate)
        XCTAssertEqual(pacing.rate(for: .slow), 30)
    }

    func testCadenceIsADivisorOfTheRefreshRate() {
        let rows: [(target: Int, refresh: Int, rate: Int)] = [
            (120, 120, 120), (200, 120, 120), (60, 120, 60), (30, 120, 30), (25, 120, 24), (15, 120, 15),
            (10, 120, 10), (5, 120, 5), (25, 60, 20), (45, 60, 30), (30, 60, 30), (48, 144, 48), (60, 144, 48),
            (30, 0, 30),
        ]
        for row in rows {
            XCTAssertEqual(FramePacing.cadence(row.target, refreshRate: row.refresh), row.rate, "\(row)")
            if row.refresh > 0 { XCTAssertEqual(row.refresh % row.rate, 0, "\(row) is not a divisor") }
        }
    }

    // MARK: - Ramps

    func testRateRisesAtOnceAndFallsAfterOneSecondOfLowerDemand() {
        var pacing = FramePacing()
        pacing.limits = .init(userLimit: 120, policy: QualityEfficiency(stop: 4))
        var now = 0.0
        pacing.record(.interactive, at: now)
        XCTAssertEqual(pacing.targetRate, 120)
        // Lower demand for just under a second keeps the rate.
        while now < 0.99 {
            now += 1.0 / 120
            XCTAssertFalse(pacing.record(.idle, at: now))
            XCTAssertEqual(pacing.level, .interactive, "at \(now)")
        }
        now = 1.01
        pacing.record(.idle, at: now)
        XCTAssertEqual(pacing.level, .idle)
        XCTAssertEqual(pacing.targetRate, 15)
        // Up at once.
        XCTAssertTrue(pacing.record(.smooth, at: now + 0.01))
        XCTAssertEqual(pacing.targetRate, 30)
    }

    /// The rate falls to the most that was asked for in the quiet second, not straight to idle.
    func testRampDownKeepsThePeakOfTheLastSecond() {
        var pacing = FramePacing()
        pacing.limits = .init(userLimit: 120, policy: QualityEfficiency(stop: 4))
        pacing.record(.interactive, at: 0)
        pacing.record(.idle, at: 0.1)
        pacing.record(.smooth, at: 0.5)
        pacing.record(.idle, at: 1.1)
        XCTAssertEqual(pacing.level, .smooth)
        pacing.record(.idle, at: 1.6)
        XCTAssertEqual(pacing.level, .smooth)
        pacing.record(.idle, at: 2.2)
        XCTAssertEqual(pacing.level, .idle)
    }

    func testWakeRaisesTheRateAtOnce() {
        var pacing = FramePacing()
        pacing.limits = .init(userLimit: 120, policy: QualityEfficiency(stop: 4))
        pacing.record(.idle, at: 0)
        pacing.record(.idle, at: 2)
        pacing.record(.idle, at: 4)
        XCTAssertEqual(pacing.level, .idle)
        pacing.wake(.interactive, at: 4.001)
        XCTAssertEqual(FramePacing.cadence(pacing.targetRate, refreshRate: 120), 120,
                       "the next tick comes one refresh later")
    }

    // MARK: - Slider and N10

    func testPresetsSetTheSlider() {
        XCTAssertEqual(QualityEfficiency(preset: .ultra).stop, 1)
        XCTAssertEqual(QualityEfficiency(preset: .high).stop, 2)
        XCTAssertEqual(QualityEfficiency(preset: .medium).stop, 4)
        XCTAssertEqual(QualityEfficiency(preset: .low).stop, 5)
        XCTAssertEqual(GlobalSettings().qualityEfficiency, 4)
        XCTAssertEqual(QualityEfficiency(stop: 9).stop, 5)
        XCTAssertEqual(QualityEfficiency(stop: -1).stop, 1)
    }

    /// Each preset sets a frame rate with its stop: Low 15, Medium 30, High 60, Ultra the display's
    /// refresh; and no preset's stop caps smooth motion below its own rate.
    @MainActor
    func testPresetsSetTheFrameRate() {
        let viewModel = GlobalSettingsViewModel()
        let refresh = 180
        for (preset, fps, rate) in [(GSQuality.low, 15.0, 15), (.medium, 30, 30), (.high, 60, 60), (.ultra, GlobalSettings.unlimitedFPS, refresh)] {
            viewModel.settings.fpsSetByUser = true
            viewModel.setQuality(preset)
            XCTAssertEqual(viewModel.settings.fps, fps, "\(preset)")
            XCTAssertFalse(viewModel.settings.fpsSetByUser, "\(preset)")
            XCTAssertEqual(viewModel.settings.qualityEfficiency, QualityEfficiency(preset: preset).stop, "\(preset)")
            var pacing = FramePacing()
            pacing.limits = FramePacing.Limits(viewModel.settings, power: PowerPolicy(PowerState()))
            XCTAssertEqual(FramePacing.cadence(pacing.rate(for: .smooth), refreshRate: refresh), rate, "\(preset)")
            XCTAssertEqual(FramePacing.cadence(pacing.rate(for: .interactive), refreshRate: refresh), rate, "\(preset)")
        }
    }

    /// An FPS the user set themselves wins over the stop's smooth-motion cap, unless power moves the stop.
    func testTheUsersOwnFrameRateWinsOverTheStop() {
        var settings = GlobalSettings()
        settings.qualityEfficiency = 4
        settings.fps = 90
        var pacing = FramePacing()
        pacing.limits = FramePacing.Limits(settings, power: PowerPolicy(PowerState()))
        XCTAssertEqual(pacing.rate(for: .smooth), 30, "a preset's or the default rate: the stop caps it")
        settings.fpsSetByUser = true
        pacing.limits = FramePacing.Limits(settings, power: PowerPolicy(PowerState()))
        XCTAssertEqual(pacing.rate(for: .smooth), 90)
        pacing.limits = FramePacing.Limits(settings, power: PowerPolicy(PowerState(lowPowerMode: true)))
        XCTAssertEqual(pacing.rate(for: .smooth), 30)
        let decoded = try? JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded?.fpsSetByUser, true)
    }

    func testThermalStateAndLowPowerModeMoveTheEffectiveStop() {
        var settings = GlobalSettings()
        settings.fps = 120
        settings.qualityEfficiency = 2
        let nominal = FramePacing.Limits(settings, power: PowerPolicy(PowerState()))
        XCTAssertEqual(nominal.policy.stop, 2)
        XCTAssertNil(nominal.powerCap)
        let lowPower = FramePacing.Limits(settings, power: PowerPolicy(PowerState(lowPowerMode: true)))
        XCTAssertEqual(lowPower.policy.stop, 3)
        let serious = FramePacing.Limits(settings, power: PowerPolicy(PowerState(thermal: .serious)))
        XCTAssertEqual(serious.policy.stop, 3)
        let critical = FramePacing.Limits(settings, power: PowerPolicy(PowerState(thermal: .critical)))
        XCTAssertEqual(critical.policy.stop, 4)
        XCTAssertEqual(critical.powerCap, 30)
        var pacing = FramePacing()
        pacing.limits = critical
        XCTAssertEqual(pacing.rate(for: .interactive), 30)
    }

    func testSettingsKeepTheStopAndClampAStoredOne() throws {
        var settings = GlobalSettings()
        settings.qualityEfficiency = 2
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.qualityEfficiency, 2)
        let stored = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"qualityEfficiency": 12}"#.utf8))
        XCTAssertEqual(stored.qualityEfficiency, 5)
        XCTAssertTrue(SettingsTab.performance.fields.contains { $0.isChanged(settings) })
        var textures = GlobalSettings()
        textures.optimiseTextures = false
        XCTAssertTrue(SettingsTab.optimizations.fields.contains { $0.isChanged(textures) })
        XCTAssertTrue(GlobalSettings().optimiseTextures)
    }

    // MARK: - Idle and wake

    /// A still scene whose layer follows the camera parallax goes idle once the parallax settles
    /// (no frame encoded), and the first frame after a cursor move is drawn, at the display's full
    /// rate from then on. Under the hang watchdog.
    @MainActor
    func testIdleSceneWakesOnACursorMoveWithinOneRefresh() throws {
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm))
        var layer = SceneMetalLayer(
            id: "1", name: "card", source: .image(try Self.image()), position: SIMD2(32, 32),
            size: SIMD2(32, 32), scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1),
            text: nil, parallaxDepth: SIMD3<Float>(1, 1, 0), perspective: false, rotation: 0)
        layer.order = 0
        var content = SceneMetalContent(
            size: SIMD2(64, 64), layers: [layer], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        content.camera.parallax = true
        renderer.framePacing.limits = .init(userLimit: 120, policy: QualityEfficiency(stop: 4))
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(10)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent)
        let watchdog = HangWatchdog()
        watchdog.start()

        func tick(cursor: SIMD2<Float>) {
            now += 1.0 / 120
            renderer.renderShared([SceneViewport(drawableSize: SIMD2(64, 64), pointSize: SIMD2(64, 64),
                                                 cursor: cursor, frameRateLimit: 120)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            watchdog.noteRenderFrame()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        // The parallax eases to the still cursor, then nothing changes.
        var idleTicks = 0
        for _ in 0..<(120 * 20) where idleTicks < 240 {
            let before = renderer.encodedFrames
            tick(cursor: SIMD2(40, 40))
            idleTicks = renderer.encodedFrames == before ? idleTicks + 1 : 0
        }
        XCTAssertEqual(idleTicks, 240, "the scene never went idle")
        XCTAssertLessThan(renderer.framePacing.targetRate, 120, "idle for 2 s: the rate fell")

        let before = renderer.encodedFrames
        tick(cursor: SIMD2(10, 20))
        XCTAssertEqual(renderer.encodedFrames, before + 1, "the first tick after the move draws")
        XCTAssertEqual(renderer.framePacing.level, .interactive)
        XCTAssertEqual(FramePacing.cadence(renderer.framePacing.targetRate, refreshRate: 120), 120,
                       "the next tick is one refresh away")
        renderer.releaseContent()
        let hangs = watchdog.stop().filter { $0.kind == .mainThreadHang }
        XCTAssertEqual(hangs, [])
    }

    private static func image() throws -> NSImage {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
