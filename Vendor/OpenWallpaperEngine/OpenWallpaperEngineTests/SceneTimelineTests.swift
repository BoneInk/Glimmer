import XCTest
@testable import OpenWallpaperEngine

/// WE's timeline format, load-time transforms, sampler and clock (docs/timeline-plan.md §1.1, §2.2–§2.5, §3.1).
final class SceneTimelineTests: XCTestCase {
    private typealias Keyframe = SceneTimelineDocument.Keyframe

    private func json(_ text: String) throws -> SceneJSON {
        try JSONDecoder().decode(SceneJSON.self, from: Data(text.utf8))
    }

    private func animation(_ text: String, staticValue: SceneJSON? = nil) throws -> SceneTimelineAnimation {
        try SceneTimelineAnimation(json: json(text), staticValue: staticValue)
    }

    private func key(_ frame: Int32, _ value: Float, flags: Keyframe.Flags = [],
                     back: SIMD2<Float> = .zero, front: SIMD2<Float> = .zero) -> Keyframe {
        Keyframe(frame: frame, value: value, flags: flags, back: back, front: front)
    }

    private let defaultHandles = #""back":{"enabled":true,"x":-1,"y":0},"front":{"enabled":true,"x":1,"y":0}"#

    // MARK: - Format

    func testKeyframesThatDontMoveForwardAreDroppedNotSorted() throws {
        let document = try SceneTimelineDocument(json: json(#"""
        {"c0":[{"frame":0,"value":1},{"frame":10,"value":2},{"frame":5,"value":3},{"frame":10,"value":4},
               {"frame":-3,"value":5},{"frame":12.9,"value":6},{"frame":"14","value":7},{"frame":15,"value":"8"},
               {"frame":16,"value":true},{"frame":20,"value":9}],
         "options":{"fps":10,"length":20}}
        """#))
        XCTAssertEqual(document.channels[0].map(\.frame), [0, 10, 12, 20])
        XCTAssertEqual(document.channels[0].map(\.value), [1, 2, 6, 9])
    }

    func testANegativeFirstFrameIsDropped() throws {
        let document = try SceneTimelineDocument(json: json(#"{"c0":[{"frame":-1,"value":1},{"frame":0,"value":2}],"options":{"fps":1,"length":1}}"#))
        XCTAssertEqual(document.channels[0].map(\.frame), [0])
    }

    func testHandlesAndStep() throws {
        let document = try SceneTimelineDocument(json: json(#"""
        {"c0":[{"frame":0,"value":0,"back":{"enabled":true,"x":-1,"y":2},"front":{"x":0.5,"y":"a"}},
               {"frame":1,"value":0,"back":{"enabled":false,"x":-1,"y":2},"front":{"enabled":1,"x":3,"y":4}},
               {"frame":2,"value":0,"step":true,"back":{"enabled":true,"x":-1,"y":2}},
               {"frame":3,"value":0,"step":1,"back":7}],
         "options":{"fps":1,"length":3}}
        """#))
        XCTAssertEqual(document.channels[0], [
            key(0, 0, flags: [.back, .front], back: [-1, 2], front: [0.5, 0]),
            key(1, 0, flags: .front, front: [3, 4]),
            key(2, 0, flags: .step),
            key(3, 0),
        ])
    }

    func testChannelsStopAtTheFirstMissingOne() throws {
        let document = try SceneTimelineDocument(json: json(#"""
        {"c0":[{"frame":0,"value":1}],"c2":[{"frame":0,"value":3}],"options":{"fps":1,"length":1}}
        """#))
        XCTAssertEqual(document.channels.count, 1)
        let noC0 = try SceneTimelineDocument(json: json(#"{"c0":{},"c1":[],"options":{"fps":1,"length":1}}"#))
        XCTAssertEqual(noC0.channels.count, 0)
        let empty = try SceneTimelineDocument(json: json(#"{"c0":[],"c1":[],"c2":[],"c3":[],"c4":[],"options":{"fps":1,"length":1}}"#))
        XCTAssertEqual(empty.channels.count, 4)
    }

    func testOptions() throws {
        let document = try SceneTimelineDocument(json: json(#"""
        {"c0":[],"relative":null,"options":{"fps":30,"length":120.7,"mode":"mirror","random":true,"startpaused":true,
         "wraploop":null,"name":"glow","parent":{"key":"origin"},"events":[{"name":"a","frame":12},{"name":3,"frame":1},{"name":"b"}]}}
        """#))
        XCTAssertEqual(document.options, .init(fps: 30, length: 120, mode: .mirror, random: true, startPaused: true,
                                               wrapLoop: false, events: [.init(name: "a", frame: 12)]))
        XCTAssertEqual(document.name, "glow")
        XCTAssertEqual(document.parentKey, "origin")
        XCTAssertTrue(document.isRelative)

        let loose = try SceneTimelineDocument(json: json(#"{"options":{"fps":30,"length":1,"mode":"Single","startpaused":1}}"#))
        XCTAssertEqual(loose.options?.mode, .loop)
        XCTAssertEqual(loose.options?.startPaused, false)
        XCTAssertFalse(loose.isRelative)
    }

    func testInvalidOptionsGiveNoTimeline() throws {
        XCTAssertThrowsError(try animation(#"{"c0":[],"options":{"length":10}}"#)) {
            XCTAssertEqual($0 as? SceneTimelineAnimation.LoadError, .missingOptions)
        }
        XCTAssertThrowsError(try animation(#"{"c0":[],"options":{"fps":0,"length":10}}"#))
        XCTAssertThrowsError(try animation(#"{"c0":[],"options":{"fps":30,"length":0}}"#))
        XCTAssertThrowsError(try animation(#"{"c0":[]}"#))
    }

    // MARK: - relative

    func testRelativeNeedsThreeTokens() {
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets("1 2.5 -3"), [1, 2.5, -3])
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets("1  2 "), [1, 2, 0])
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets("x 2y 3"), [0, 2, 3])
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets("1 2 3 4"), [1, 2, 3])
        // A leading space ends the first token at once, so the first number is read twice.
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets(" 1 2 3"), [1, 1, 2])
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets("0x1.8 -inf 2e1x"), [1.5, -.infinity, 20])
        XCTAssertEqual(SceneTimelineAnimation.relativeOffsets(".5 +1. 0x"), [0.5, 1, 0])
        XCTAssertNil(SceneTimelineAnimation.relativeOffsets("5"))
        XCTAssertNil(SceneTimelineAnimation.relativeOffsets("1 2"))
        XCTAssertNil(SceneTimelineAnimation.relativeOffsets("1\t2\t3"))
    }

    func testRelativeIsBakedFromAStringValueOnly() throws {
        let text = #"{"c0":[{"frame":0,"value":1}],"c1":[{"frame":0,"value":1}],"c2":[{"frame":0,"value":1}],"c3":[{"frame":0,"value":1}],"relative":false,"options":{"fps":1,"length":1}}"#
        var baked = try animation(text, staticValue: .string("10 20 30"))
        XCTAssertEqual(baked.value(), [11, 21, 31, 1])
        var scalar = try animation(text, staticValue: .number(10))
        XCTAssertEqual(scalar.value(), [1, 1, 1, 1])
        var short = try animation(text, staticValue: .string("10 20"))
        XCTAssertEqual(short.value(), [1, 1, 1, 1])
        var absolute = try animation(text.replacingOccurrences(of: #""relative":false,"#, with: ""),
                                     staticValue: .string("10 20 30"))
        XCTAssertEqual(absolute.value(), [1, 1, 1, 1])
    }

    // MARK: - wraploop

    func testWrapLoopOverwritesTheKeyframeAtLength() {
        var keys = [key(0, 1, flags: [.back, .front], back: [-1, 0], front: [0.5, 0.25]), key(10, 5), key(20, 3, flags: .step)]
        SceneTimelineAnimation.wrapLoop(&keys, length: 20)
        XCTAssertEqual(keys.last, key(20, 1, flags: [.step, .back], back: [-0.5, -0.25]))
    }

    func testWrapLoopDropsKeysPastLengthAndAppends() {
        var keys = [key(0, 1, back: [-1, 0]), key(10, 5, flags: [.back, .front], back: [-2, 3]), key(30, 3), key(40, 2)]
        SceneTimelineAnimation.wrapLoop(&keys, length: 20)
        XCTAssertEqual(keys, [key(0, 1, back: [-1, 0]), key(10, 5, flags: [.back, .front], back: [-2, 3]), key(20, 1)])

        // Without a front handle on the first keyframe the last loses its back bit but keeps its handle.
        var kept = [key(0, 1), key(20, 3, flags: .back, back: [-1, 4])]
        SceneTimelineAnimation.wrapLoop(&kept, length: 20)
        XCTAssertEqual(kept.last, key(20, 1, back: [-1, 4]))

        var single = [key(0, 1), key(30, 3)]
        SceneTimelineAnimation.wrapLoop(&single, length: 20)
        XCTAssertEqual(single, [key(0, 1)])
    }

    // MARK: - Sampler

    func testDefaultHandlesEaseInAndOut() {
        let keys = [key(0, 0, flags: [.back, .front], back: [-1, 0], front: [1, 0]),
                    key(10, 1, flags: [.back, .front], back: [-1, 0], front: [1, 0])]
        let expected: [Float] = [0, 0.0148831178, 0.0639549717, 0.160378799, 0.310405105, 0.499249995,
                                 0.690925479, 0.840700209, 0.935260713, 0.985496819, 1]
        XCTAssertEqual((0...10).map { SceneTimelineChannel.evaluate(keys, at: $0) }, expected)
    }

    func testZeroHandlesAreLinearWithinTheBisectionTolerance() {
        let keys = [key(0, 0), key(10, 1)]
        let expected: [Float] = [0, 0.0993556529, 0.199608997, 0.299528897, 0.400337487, 0.499249995,
                                 0.599626541, 0.699082911, 0.799162388, 0.899700224, 1]
        XCTAssertEqual((0...10).map { SceneTimelineChannel.evaluate(keys, at: $0) }, expected)
    }

    func testStepBelongsToTheLaterKeyframe() {
        let keys = [key(0, 2), key(4, 6, flags: .step), key(8, -1)]
        XCTAssertEqual((0...4).map { SceneTimelineChannel.evaluate(keys, at: $0) }, [2, 2, 2, 2, 6])
        XCTAssertNotEqual(SceneTimelineChannel.evaluate(keys, at: 6), 6)
    }

    func testOutsideTheKeyframes() {
        XCTAssertEqual(SceneTimelineChannel.evaluate([], at: 3), 0)
        let keys = [key(5, 2), key(9, 4)]
        XCTAssertEqual(SceneTimelineChannel.evaluate(keys, at: 0), 2)
        XCTAssertEqual(SceneTimelineChannel.evaluate(keys, at: 20), 4)
    }

    /// Two keys at one frame: the first in the list is kept and the second dropped (WE 2.8.42,
    /// docs/models-plan.md §5.22: a camera path's eye x with 400 then −400 at frame 30 plays through
    /// 400 there, easing in and out of it, and never reaches −400).
    func testTheFirstOfTwoKeysAtOneFrameWins() {
        let keys = [key(0, 0, front: [1, 0]), key(30, 400, back: [-1, 0], front: [1, 0]),
                    key(30, -400, back: [-1, 0], front: [1, 0]), key(60, 0, back: [-1, 0])]
        var channel = SceneTimelineChannel(keyframes: keys)
        XCTAssertEqual(channel.keyframes.map(\.value), [0, 400, 0])
        XCTAssertEqual(channel.sample(30), 400)
        let samples = (0...60).map { channel.sample(Int32($0)) }
        XCTAssertGreaterThanOrEqual(samples.min() ?? -1, 0, "−400 is never reached")
        XCTAssertGreaterThan(channel.sample(45), 100, "eases back from 400")
    }

    func testTheCacheMatchesDirectEvaluation() {
        let keys = [key(0, 0, front: [1, 0.3]), key(7, 2, back: [-0.2, 1]), key(15, -1)]
        var channel = SceneTimelineChannel(keyframes: keys)
        XCTAssertEqual(channel.sample(12), SceneTimelineChannel.evaluate(keys, at: 12))
        XCTAssertEqual((0...15).map { channel.sample($0) }, (0...15).map { SceneTimelineChannel.evaluate(keys, at: $0) })
    }

    func testValueBlendsLinearlyBetweenWholeFrames() throws {
        var timeline = try animation(#"{"c0":[{"frame":0,"value":0},{"frame":2,"value":4,"step":true}],"options":{"fps":10,"length":2}}"#)
        timeline.clock.setFrame(1.25)
        let position = timeline.clock.samplePosition
        XCTAssertEqual(position.frame0, 1)
        XCTAssertEqual(position.frame1, 2)
        XCTAssertEqual(timeline.value(), [4 * position.fraction])
        XCTAssertEqual(position.fraction, 0.25, accuracy: 1e-5)
    }

    func testSamplePositionClampsAndOverflowsLikeCvttss2si() {
        var clock = SceneTimelineClock(frameDuration: 0.1, duration: 1, length: 10, flags: [])
        clock.time = -0.35
        XCTAssertEqual(clock.samplePosition.frame0, 0)
        XCTAssertEqual(clock.samplePosition.frame1, 1)
        XCTAssertLessThan(clock.samplePosition.fraction, 0)
        clock.time = 5
        XCTAssertEqual(clock.samplePosition.frame0, 9)
        XCTAssertEqual(clock.samplePosition.frame1, 10)
        clock.time = 1e9
        XCTAssertEqual(clock.samplePosition.frame0, 0)
        XCTAssertEqual(SceneTimelineClock.convertTruncating(.nan), Int32.min)
        XCTAssertEqual(SceneTimelineClock.convertTruncating(-2.9), -2)
    }

    // MARK: - Clock

    private func clock(_ mode: SceneTimelineDocument.Options.Mode, startPaused: Bool = false,
                       events: [SceneTimelineDocument.Event] = []) -> SceneTimelineClock {
        SceneTimelineClock(options: .init(fps: 10, length: 10, mode: mode, random: false, startPaused: startPaused,
                                          wrapLoop: false, events: events))!
    }

    func testSingleFinishesAndPlayRestarts() {
        var single = clock(.single, startPaused: true)
        XCTAssertFalse(single.isPlaying)
        single.advance(by: 0.5)
        XCTAssertEqual(single.time, 0)
        single.play()
        single.advance(by: 0.75)
        single.advance(by: 0.75)
        XCTAssertEqual(single.time, 1)
        XCTAssertTrue(single.flags.contains(.finished))
        XCTAssertFalse(single.isPlaying)
        single.play()
        XCTAssertEqual(single.time, 0)
        XCTAssertTrue(single.isPlaying)
    }

    func testSetFramePastTheEndOfASingleHoldsWithoutFinishing() {
        var single = clock(.single)
        single.setFrame(20)
        XCTAssertEqual(single.frame, 20)
        single.advance(by: 0.1)
        XCTAssertEqual(single.frame, 20)
        XCTAssertTrue(single.isPlaying)
        XCTAssertEqual(single.samplePosition.frame0, 9)
    }

    func testNegativeRateOnASingleRunsBelowZero() {
        var single = clock(.single)
        single.advance(by: -0.25)
        XCTAssertEqual(single.time, -0.25)
        XCTAssertLessThan(single.samplePosition.fraction, 0)
    }

    func testMirrorBouncesAndStopResetsDirection() {
        var mirror = clock(.mirror)
        mirror.advance(by: 1.25)
        XCTAssertTrue(mirror.flags.contains(.reversed))
        XCTAssertEqual(mirror.time, 0.75)
        mirror.advance(by: 0.5)
        XCTAssertEqual(mirror.time, 0.25)
        mirror.advance(by: 0.5)
        XCTAssertFalse(mirror.flags.contains(.reversed))
        XCTAssertEqual(mirror.time, 0.25)
        mirror.advance(by: 0.9)
        XCTAssertTrue(mirror.flags.contains(.reversed))
        mirror.stop()
        XCTAssertEqual(mirror.flags, [.mirror, .paused])
        XCTAssertEqual(mirror.time, 0)
    }

    func testLoopWrapsBothWays() {
        var loop = clock(.loop)
        loop.advance(by: 1.25)
        XCTAssertEqual(loop.time, 0.25)
        loop.advance(by: -0.5)
        XCTAssertEqual(loop.time, 0.75)
        loop.pause()
        loop.advance(by: 0.1)
        XCTAssertEqual(loop.time, 0.75)
    }

    func testEventsFireOncePerCrossing() {
        let events = [SceneTimelineDocument.Event(name: "a", frame: 2), .init(name: "b", frame: 8)]
        var loop = clock(.loop, events: events)
        XCTAssertEqual(loop.advance(by: 0.2).map(\.name), [], "the event at 0.2 needs new > 0.2")
        XCTAssertEqual(loop.advance(by: 0.05).map(\.name), ["a"])
        XCTAssertEqual(loop.advance(by: 0.3).map(\.name), [])
        // Forward past the end: [time, new) then, after the wrap, [0, time).
        XCTAssertEqual(loop.advance(by: 0.8).map(\.name), ["b", "a"])
        // Backward past 0: (new, time] then, after the wrap, (time, duration].
        XCTAssertEqual(loop.advance(by: -0.6).map(\.name), ["a", "b"])
        XCTAssertEqual(loop.events.map(\.time), [0.2, 0.8].map { Float($0) })
    }

    // MARK: - Linked timelines

    func testAChildSamplesItsOwnKeysOnTheParentsClock() throws {
        var parent = try animation(#"{"c0":[{"frame":0,"value":0},{"frame":60,"value":60}],"options":{"fps":60,"length":60,"mode":"single"}}"#)
        var child = try animation(#"""
        {"c0":[{"frame":0,"value":1},{"frame":80,"value":0,"step":true}],
         "options":{"fps":1,"length":1000,"mode":"loop","parent":{"key":"origin"}}}
        """#)
        XCTAssertEqual(child.parentKey, "origin")
        parent.clock.advance(by: 0.5)
        XCTAssertEqual(parent.clock.frame, 30, accuracy: 1e-4)
        XCTAssertEqual(child.value(on: parent.clock)[0], 1, accuracy: 1e-6)
        // The parent's length clamps the frame: 100 samples frames 59 and 60, not 100.
        parent.clock.setFrame(100)
        XCTAssertEqual(child.value(on: parent.clock)[0], 1, accuracy: 1e-6)
        child.clock.setFrame(100)
        XCTAssertEqual(child.value()[0], 0)
    }
}
