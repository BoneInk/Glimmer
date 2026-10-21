import XCTest
@testable import OWEInspectorKit

/// The stats overlay's rows follow WE's editor (`editorSceneStatsOverlay`): which numbers show
/// only when non-zero, which warn past WE's limits, Auto showing only the warnings; and its feed
/// counts only while watched (its catalog is checked by OWEEditorTests' `CatalogCoverageTests`).
@MainActor
final class RenderStatsTests: XCTestCase {
    func testRowsHideZerosAndWarnPastWEsLimits() {
        var stats = RenderStats()
        XCTAssertEqual(stats.rows.map(\.id), [.fps, .gpu, .textureMemory, .scriptTime, .drawCalls, .primitives, .programs,
                                              .framebufferCopies, .particleCount, .particleMemory, .particleTime,
                                              .renderTargetChanges],
                       "lights, expensive effects, video textures and clipping masks only when there are any")
        XCTAssertFalse(stats.rows.contains(where: \.isWarning))

        stats.textureBytes = 401 * 1_048_576
        stats.lightCount = 7
        stats.scriptMilliseconds = 10.5
        stats.expensiveEffects = 11
        stats.veryExpensiveEffects = 1
        stats.shaderPrograms = 101
        stats.particleMilliseconds = 2
        stats.renderTargetChanges = 100
        stats.videoTextureCount = 4
        stats.clippingMaskPasses = 5
        let warnings = Set(stats.rows.filter(\.isWarning).map(\.id))
        XCTAssertEqual(warnings, [.textureMemory, .lights, .scriptTime, .expensive, .programs, .videoTextures])
        XCTAssertEqual(stats.rows.first { $0.id == .expensive }?.title, "Too many expensive effects used")
        XCTAssertEqual(stats.rows.first { $0.id == .veryExpensive }?.title, "Very expensive effects used",
                       "one very expensive effect is fine")
        stats.veryExpensiveEffects = 2
        XCTAssertEqual(stats.rows.first { $0.id == .veryExpensive }?.title, "Too many very expensive effects used")
        XCTAssertTrue(stats.rows.contains { $0.id == .clippingMasks && !$0.isWarning })
    }

    func testValuesAreFormattedAsWEShowsThem() {
        var stats = RenderStats()
        stats.framesPerSecond = 60
        stats.gpuMilliseconds = 1.234
        stats.textureBytes = 3 * 1_048_576
        stats.particleBytes = 1_572_864
        stats.particleMilliseconds = 0.5
        let values = Dictionary(uniqueKeysWithValues: stats.rows.map { ($0.id, $0.value) })
        XCTAssertEqual(values[.particleMemory], 1.5.formatted(.number.precision(.fractionLength(2))))
        XCTAssertEqual(values[.particleTime], 0.5.formatted(.number.precision(.fractionLength(3))))
        XCTAssertEqual(values[.textureMemory], "3")
        XCTAssertEqual(stats.summary, "60 FPS · GPU \(1.2.formatted(.number.precision(.fractionLength(1)))) ms · 3 MB")
    }

    func testTheFeedCountsOnlyWhileWatched() {
        var started = 0, stopped = 0
        let feed = RenderStatsFeed(start: { _ in started += 1 }, stop: { stopped += 1 })
        feed.publish(RenderStats())
        XCTAssertNil(feed.stats, "nothing is published while nobody watches")
        feed.watch()
        feed.watch()
        XCTAssertEqual(started, 1)
        feed.publish(RenderStats())
        XCTAssertNotNil(feed.stats)
        feed.unwatch()
        XCTAssertEqual(stopped, 0)
        feed.unwatch()
        XCTAssertEqual(stopped, 1)
        XCTAssertNil(feed.stats)
        feed.unwatch()
        XCTAssertEqual(stopped, 1, "an extra unwatch does nothing")
    }
}
