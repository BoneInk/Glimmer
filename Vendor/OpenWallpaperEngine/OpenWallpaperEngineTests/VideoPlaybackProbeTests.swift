import XCTest
@testable import OpenWallpaperEngine

/// AVPlayer videos report frame times to the render watchdog from playback progress alone.
final class VideoPlaybackProbeTests: XCTestCase {
    private typealias Sample = VideoPlaybackProbe.Sample

    private func sample(_ time: TimeInterval, _ media: Double, rate: Float = 1, dropped: Int? = nil,
                        fps: Double = 30) -> Sample {
        Sample(time: time, mediaTime: media, rate: rate, droppedFrames: dropped, frameRate: fps)
    }

    func testSmoothPlaybackReportsTheTrackFrameTime() throws {
        var probe = VideoPlaybackProbe()
        XCTAssertNil(probe.frameDuration(after: sample(0, 0, dropped: 0)), "the first sample only sets a baseline")
        let duration = try XCTUnwrap(probe.frameDuration(after: sample(1, 1, dropped: 0)))
        XCTAssertEqual(duration, 1.0 / 30, accuracy: 1e-9)
    }

    func testDroppedFramesLengthenTheFrameTime() throws {
        var probe = VideoPlaybackProbe()
        _ = probe.frameDuration(after: sample(0, 0, dropped: 10))
        let duration = try XCTUnwrap(probe.frameDuration(after: sample(1, 1, dropped: 37)))
        XCTAssertEqual(duration, 1.0 / 3, accuracy: 1e-9, "27 of 30 frames dropped: 3 shown in a second")
        XCTAssertGreaterThan(duration, RenderWatchdog.Thresholds().slowFrameMedian)
    }

    func testStalledPlaybackIsOneLongFrame() {
        var probe = VideoPlaybackProbe()
        _ = probe.frameDuration(after: sample(0, 5))
        XCTAssertEqual(probe.frameDuration(after: sample(1, 5.05)), 1, "playing but barely advancing")
    }

    func testPausedLoopedOrLateSamplesJudgeNothing() {
        var probe = VideoPlaybackProbe()
        _ = probe.frameDuration(after: sample(0, 5, rate: 0))
        XCTAssertNil(probe.frameDuration(after: sample(1, 5, rate: 0)), "paused")
        XCTAssertNil(probe.frameDuration(after: sample(2, 5)), "just resumed from a pause")
        XCTAssertNil(probe.frameDuration(after: sample(3, 0.2)), "looped back to the start")
        XCTAssertNil(probe.frameDuration(after: sample(60, 0.3)), "the Mac slept between samples")
        probe.reset()
        XCTAssertNil(probe.frameDuration(after: sample(61, 1.3)), "a new item starts a new baseline")
    }

    func testUnknownFrameRateAndLogFallBack() throws {
        var probe = VideoPlaybackProbe()
        _ = probe.frameDuration(after: sample(0, 0, fps: 0))
        let duration = try XCTUnwrap(probe.frameDuration(after: sample(1, 1, dropped: 50, fps: 0)))
        XCTAssertEqual(duration, 1.0 / VideoPlaybackProbe.fallbackFrameRate, accuracy: 1e-9,
                       "a count without a baseline is not a drop")
    }

    /// Sustained stalls trip the watchdog like slow scene frames do.
    func testSustainedStallTripsTheWatchdog() {
        var now: TimeInterval = 1000
        let watchdog = RenderWatchdog(clock: { now })
        watchdog.arm()
        now += watchdog.thresholds.gracePeriod
        var probe = VideoPlaybackProbe()
        var trip: RenderWatchdog.Trip?
        for second in 0..<30 where trip == nil {
            now += 1
            if let duration = probe.frameDuration(after: sample(now, Double(second) * 0.01)) {
                watchdog.recordFrame(duration: duration)
            }
            trip = watchdog.evaluate()
        }
        XCTAssertEqual(trip, .slowFrames(medianSeconds: 1))
    }
}
