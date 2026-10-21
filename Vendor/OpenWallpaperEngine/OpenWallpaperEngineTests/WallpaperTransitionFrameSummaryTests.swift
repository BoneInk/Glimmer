import XCTest
@testable import OpenWallpaperEngine

/// The debug summary of a transition's frames: intervals, refreshes without a new frame and
/// main-thread stalls.
final class WallpaperTransitionFrameSummaryTests: XCTestCase {
    func testIntervalsAndDroppedRefreshes() {
        let refresh = 1.0 / 100
        // Four refreshes on time, then one that took three refreshes.
        let presented = [0, 0.01, 0.02, 0.03, 0.04, 0.07]
        let submitted = (0...7).map { Double($0) * 0.01 }
        let summary = WallpaperTransitionFrameSummary(submitted: submitted, presented: presented.reversed(),
                                                      stalls: [0.05, 0.02], refreshInterval: refresh)
        XCTAssertEqual(summary.presented.frames, 6)
        XCTAssertEqual(summary.presented.span, 0.07, accuracy: 1e-9)
        XCTAssertEqual(summary.presented.p50, 0.01, accuracy: 1e-9)
        XCTAssertEqual(summary.presented.maxInterval, 0.03, accuracy: 1e-9)
        XCTAssertEqual(summary.presented.p95, 0.03, accuracy: 1e-9)
        XCTAssertEqual(summary.presented.dropped, 2, "an interval of three refreshes drops two")
        XCTAssertEqual(summary.submitted.frames, 8)
        XCTAssertEqual(summary.submitted.dropped, 0, "every refresh had a frame submitted")
        XCTAssertEqual(summary.stallCount, 2)
        XCTAssertEqual(summary.stallMax, 0.05, accuracy: 1e-9)
        XCTAssertEqual(summary.stallTotal, 0.07, accuracy: 1e-9)
    }

    func testNothingMeasured() {
        let summary = WallpaperTransitionFrameSummary(submitted: [], presented: [], stalls: [], refreshInterval: 1.0 / 60)
        XCTAssertEqual(summary.presented.frames, 0)
        XCTAssertEqual(summary.presented.p95, 0)
        XCTAssertEqual(summary.submitted.dropped, 0)
        XCTAssertEqual(summary.stallCount, 0)
    }

    func testNearestRankPercentile() {
        let values = (1...20).map(Double.init)
        XCTAssertEqual(WallpaperTransitionFrameSummary.percentile(values, 0.5), 10)
        XCTAssertEqual(WallpaperTransitionFrameSummary.percentile(values, 0.95), 19)
        XCTAssertEqual(WallpaperTransitionFrameSummary.percentile(values, 1), 20)
    }
}
