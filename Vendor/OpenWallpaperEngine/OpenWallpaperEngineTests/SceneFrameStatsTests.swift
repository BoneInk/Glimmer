import Metal
import XCTest
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's stats overlay counters: a renderer counts only while `frameStats` is
/// set (its frames' command buffer is the real one otherwise), and a counted frame reports its
/// draws, passes, pipelines, textures and the scene's particles and lights; effect.json's
/// `performance` reaches the effect plans.
final class SceneFrameStatsTests: XCTestCase {
    private func harness(_ scene: String) throws -> SceneFrameHarness {
        Fixtures.removeStoredSettings(for: Fixtures.url("Scenes/\(scene)"))
        return try SceneFrameHarness(directory: Fixtures.url("Scenes/\(scene)"), size: SIMD2(128, 64))
    }

    func testFramesAreCountedOnlyWhileStatsShow() throws {
        let harness = try harness("layers")
        defer { harness.close() }
        harness.draw(frames: 2)
        XCTAssertFalse((harness.renderer.lastCommandBuffer as AnyObject?) is SceneStatsCommandBuffer,
                       "no stand-in while nobody watches")

        let recorder = SceneFrameStatsRecorder()
        harness.renderer.frameStats = recorder
        harness.draw(frames: 3)
        XCTAssertTrue((harness.renderer.lastCommandBuffer as AnyObject?) is SceneStatsCommandBuffer)
        let stats = recorder.latest
        XCTAssertGreaterThan(stats.drawCalls, 0)
        XCTAssertGreaterThanOrEqual(stats.primitives, 2 * stats.drawCalls, "each draw is at least a quad")
        XCTAssertGreaterThan(stats.renderTargetChanges, 0)
        XCTAssertGreaterThan(stats.shaderPrograms, 0)
        XCTAssertGreaterThan(stats.textureBytes, 0)
        XCTAssertGreaterThanOrEqual(stats.framesPerSecond, 3)
        XCTAssertGreaterThan(stats.gpuMilliseconds, 0, "the last finished frame's GPU time")

        // Off again: frames are neither counted nor forced (an idle scene skips them as before).
        harness.renderer.frameStats = nil
        let counted = recorder.latest
        harness.draw(frames: 3)
        XCTAssertEqual(recorder.latest, counted)
    }

    func testParticlesAndLightsAreCounted() throws {
        for (scene, check) in [("particle-budget", { (stats: SceneFrameStats) in
            XCTAssertGreaterThan(stats.particleCount, 0)
            XCTAssertGreaterThan(stats.particleBytes, 0)
        }), ("lights", { (stats: SceneFrameStats) in
            XCTAssertGreaterThan(stats.lightCount, 0)
        })] {
            let harness = try harness(scene)
            let recorder = SceneFrameStatsRecorder()
            harness.renderer.frameStats = recorder
            harness.draw(frames: 10)
            check(recorder.latest)
            harness.close()
        }
    }

    func testCountingRules() {
        let recorder = SceneFrameStatsRecorder()
        recorder.draw(.triangleStrip, vertices: 4)
        recorder.draw(.triangle, vertices: 6, instances: 10)
        recorder.drawIndirect()
        recorder.copy()
        recorder.finishFrame({ $0.particleCount = 5 }, now: 100)
        recorder.finishFrame({ _ in }, now: 100.5)
        recorder.finishFrame({ _ in }, now: 101.4)
        // Only the last frame is published, its fps the frames in the second before it.
        XCTAssertEqual(recorder.latest.drawCalls, 0)
        XCTAssertEqual(recorder.latest.framesPerSecond, 2)
        let counted = SceneFrameStatsRecorder()
        counted.draw(.triangleStrip, vertices: 4)
        counted.draw(.triangle, vertices: 6, instances: 10)
        counted.drawIndirect()
        counted.copy()
        counted.finishFrame({ $0.particleCount = 5 })
        XCTAssertEqual(counted.latest.drawCalls, 3)
        XCTAssertEqual(counted.latest.primitives, 2 + 20)
        XCTAssertEqual(counted.latest.framebufferCopies, 1)
        XCTAssertEqual(counted.latest.particleCount, 5)
    }

    func testEffectPerformanceReachesTheDocument() throws {
        let expensive = try JSONDecoder().decode(EffectDocument.self, from: Data(#"{"performance": "veryexpensive", "passes": []}"#.utf8))
        XCTAssertEqual(expensive.performance, .veryExpensive)
        let plain = try JSONDecoder().decode(EffectDocument.self, from: Data(#"{"passes": []}"#.utf8))
        XCTAssertNil(plain.performance)
        XCTAssertEqual(SceneRenderStatsSampler.stats(SceneFrameStats(drawCalls: 7)).drawCalls, 7)
    }
}
