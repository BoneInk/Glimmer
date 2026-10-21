import XCTest
@testable import OpenWallpaperEngine

/// WE's texture animation clock and a script's override of it (docs/timeline-plan.md §2.7, §3.2).
final class SceneTextureAnimationClockTests: XCTestCase {
    private let tick: Float = 1.0 / 60

    private func frames(_ clock: SceneTextureAnimationClock, ticks: Int, delta: Float? = nil) -> [Int32] {
        var shown: [Int32] = []
        for index in 0..<ticks {
            shown.append(clock.advance(tick: UInt64(index + 1), delta: delta ?? tick))
        }
        return shown
    }

    // MARK: - The shared clock

    func testFramesShorterThanTheTickMoveOneFramePerEngineFrame() {
        let clock = SceneTextureAnimationClock(frameTimes: [0.005, 0.005, 0.005])
        XCTAssertEqual(frames(clock, ticks: 7), [1, 2, 0, 1, 2, 0, 1], "never more than one frame per step")
        XCTAssertEqual(clock.time, 0.005, "the leftover time is capped at the new frame's time")
    }

    func testTimeCarriesOverIntoTheNextFrame() {
        let clock = SceneTextureAnimationClock(frameTimes: [0.1, 0.1])
        XCTAssertEqual(frames(clock, ticks: 3, delta: 0.04), [0, 0, 1])
        XCTAssertEqual(clock.time, Float(0.04) + 0.04 + 0.04 - 0.1, accuracy: 1e-7)
    }

    func testAZeroSecondFrameShowsForOneEngineFrame() {
        let clock = SceneTextureAnimationClock(frameTimes: [0.1, 0, 0.1])
        XCTAssertEqual(frames(clock, ticks: 6, delta: 0.05), [0, 1, 2, 0, 0, 1])
        XCTAssertEqual(clock.frameCount, 3)
        XCTAssertEqual(clock.duration, 0.2, accuracy: 1e-7)
    }

    func testTheClockAdvancesOncePerEngineFrameWhateverItsUsers() {
        let clock = SceneTextureAnimationClock(frameTimes: [0.01, 0.01])
        XCTAssertEqual(clock.advance(tick: 7, delta: tick), 1)
        XCTAssertEqual(clock.advance(tick: 7, delta: tick), 1, "a second user in the same engine frame")
        XCTAssertEqual(clock.advance(tick: 8, delta: tick), 0)
    }

    func testANegativeStepWalksBackwardsAndWraps() {
        var frame: Int32 = 0
        var time: Float = 0
        let times: [Float] = [0.1, 0.2, 0.3]
        SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: -0.05, frameTimes: times)
        XCTAssertEqual(frame, 2, "back past frame 0 onto the last")
        XCTAssertEqual(time, 0.25, accuracy: 1e-7, "the new frame's time is added")
        SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: -0.1, frameTimes: times)
        XCTAssertEqual(frame, 2)
        XCTAssertEqual(time, 0.15, accuracy: 1e-7)
        SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: -1, frameTimes: times)
        XCTAssertEqual(frame, 1, "one frame per step backwards too")
        XCTAssertEqual(time, 0, "floored at 0")
    }

    func testZeroAndNaNStepsDoNothing() {
        var frame: Int32 = 1
        var time: Float = 0.05
        for delta in [Float(0), .nan] {
            SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: delta, frameTimes: [0.1, 0.1])
            XCTAssertEqual(frame, 1)
            XCTAssertEqual(time, 0.05)
        }
    }

    func testAFrameOutsideTheListReadsFrameZeroAndStepsOntoIt() {
        for start: Int32 in [9, -3] {
            var frame = start
            var time: Float = 0
            SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: 0.05, frameTimes: [0.1, 0.2])
            XCTAssertEqual(frame, start, "0.05 < frame 0's 0.1")
            SceneTextureAnimationClock.step(frame: &frame, time: &time, delta: 0.05, frameTimes: [0.1, 0.2])
            XCTAssertEqual(frame, 0, "WE compares the next frame unsigned")
        }
    }

    func testAnEmptyClockStaysPut() {
        let clock = SceneTextureAnimationClock(frameTimes: [])
        XCTAssertEqual(clock.advance(tick: 1, delta: tick), 0)
        XCTAssertEqual(clock.duration, 0)
    }

    // MARK: - A script's override

    func testTheOverrideStartsOffAndPlaying() {
        let control = SceneTextureAnimationControl()
        XCTAssertEqual(control.rate, 1)
        XCTAssertTrue(control.playing)
        XCTAssertFalse(control.overridden)
        XCTAssertTrue(control.isPlaying)
    }

    func testARateOtherThanOneTakesControlFromTheSharedFrame() {
        let shared = SceneTextureAnimationClock(frameTimes: [0.1, 0.1, 0.1])
        shared.advance(tick: 1, delta: 0.15)
        var control = SceneTextureAnimationControl()
        control.setRate(1, shared: shared)
        XCTAssertFalse(control.overridden, "rate 1 keeps the shared clock")
        control.setRate(3, shared: shared)
        XCTAssertTrue(control.overridden)
        XCTAssertEqual(control.frame, 1)
        XCTAssertEqual(control.time, shared.time)
        shared.advance(tick: 2, delta: 0.1)
        control.setRate(0, shared: shared)
        XCTAssertEqual(control.frame, 1, "already in control: no second copy")

        var nan = SceneTextureAnimationControl()
        nan.setRate(.nan, shared: shared)
        XCTAssertTrue(nan.overridden, "NaN is not 1")
    }

    func testTheOverrideAdvancesByRateAndOnlyWhilePlaying() {
        let times: [Float] = [0.1, 0.1, 0.1, 0.1]
        let shared = SceneTextureAnimationClock(frameTimes: times)
        var control = SceneTextureAnimationControl()
        control.advance(delta: 0.5, frameTimes: times)
        XCTAssertEqual(control.frame, 0, "not in control: the override doesn't move")
        control.setRate(2, shared: shared)
        control.advance(delta: 0.06, frameTimes: times)
        XCTAssertEqual(control.frame, 1, "0.06 × 2 ≥ 0.1")
        control.setRate(-1, shared: shared)
        control.advance(delta: 0.01, frameTimes: times)
        XCTAssertEqual(control.frame, 1)
        control.advance(delta: 0.03, frameTimes: times)
        XCTAssertEqual(control.frame, 0, "a negative rate walks backwards")
        XCTAssertEqual(control.time, 0.08, accuracy: 1e-6)
        control.pause(shared: shared)
        control.advance(delta: 1, frameTimes: times)
        XCTAssertEqual(control.frame, 0)
        XCTAssertFalse(control.isPlaying)
        control.play()
        control.setRate(1, shared: shared)
        XCTAssertTrue(control.isPlaying)
        XCTAssertTrue(control.overridden, "rate 1 doesn't give control back; join does")
        control.advance(delta: 0.2, frameTimes: times)
        XCTAssertEqual(control.frame, 1, "still one frame per step")
        XCTAssertEqual(control.time, 0.1, "capped at the new frame's time")
    }

    func testPauseStopSetFrameAndJoin() {
        let shared = SceneTextureAnimationClock(frameTimes: [0.1, 0.1, 0.1])
        shared.advance(tick: 1, delta: 0.1)
        shared.advance(tick: 2, delta: 0.1)

        var paused = SceneTextureAnimationControl()
        paused.pause(shared: shared)
        XCTAssertEqual([paused.frame, paused.currentFrame(shared: shared)], [2, 2], "pause copies the shared frame")
        XCTAssertFalse(paused.isPlaying)
        paused.join()
        XCTAssertTrue(paused.isPlaying, "back on the shared clock, which always plays")
        XCTAssertFalse(paused.playing, "join keeps the override's playing flag")

        var stopped = SceneTextureAnimationControl()
        stopped.stop()
        XCTAssertEqual(stopped.currentFrame(shared: shared), 0)
        XCTAssertFalse(stopped.isPlaying)
        stopped.setFrame(1)
        XCTAssertFalse(stopped.isPlaying, "setFrame in control keeps the play state")

        var set = SceneTextureAnimationControl()
        set.setFrame(7)
        XCTAssertEqual(set.currentFrame(shared: shared), 7, "not range-checked")
        XCTAssertEqual(set.time, 0)
        XCTAssertTrue(set.isPlaying, "taking control with setFrame plays")
        set.join()
        XCTAssertEqual(set.currentFrame(shared: shared), 2, "joined: the shared frame")
    }

    /// 2963872291's pattern: `rate = 9; stop()` at init, then `rate = 5` until `getFrame() == 30`,
    /// then `rate = 0` holds frame 30.
    func testTheStopThenRunToAFramePattern() {
        let times = [Float](repeating: 0.03, count: 147)
        let shared = SceneTextureAnimationClock(frameTimes: times)
        var control = SceneTextureAnimationControl()
        control.setRate(9, shared: shared)
        control.stop()
        control.play()
        var tick: UInt64 = 0
        for _ in 0..<200 {
            tick += 1
            control.setRate(control.currentFrame(shared: shared) == 30 ? 0 : 5, shared: shared)
            shared.advance(tick: tick, delta: 1.0 / 60)
            control.advance(delta: 1.0 / 60, frameTimes: shared.frameTimes)
        }
        XCTAssertEqual(control.currentFrame(shared: shared), 30)
        XCTAssertNotEqual(shared.frame, 30, "the shared clock went on for the texture's other users")
    }
}
