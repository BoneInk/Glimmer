import XCTest
@testable import OWESceneEditing

/// The clip model: WE's reading rules, writing WE's format back, keyframe editing, eases,
/// handles and the evaluation the curve editor draws.
final class TimelineClipTests: XCTestCase {
    private func clip(_ json: String) throws -> TimelineClip {
        let value = try JSONDecoder().decode(SceneJSONValue.self, from: Data(json.utf8))
        return try XCTUnwrap(TimelineClip(json: value))
    }

    // MARK: Reading and writing

    func testReadsWithWEsRules() throws {
        let clip = try clip("""
        {"c0": [{"frame": 0, "value": 1}, {"frame": 10.7, "value": 2, "step": true},
                {"frame": 10, "value": 9}, {"frame": 20, "value": "x"}, {"frame": 30, "value": 3,
                 "back": {"enabled": false, "x": -1, "y": 0}, "front": {"x": 0.5, "y": 2}}],
         "c1": [{"frame": 0, "value": 5}], "c3": [{"frame": 0, "value": 7}],
         "options": {"fps": 24, "length": 48, "mode": "mirror", "startpaused": true, "name": "glow",
                     "parent": {"key": "origin"}},
         "relative": false, "previewvalue": 3}
        """)
        XCTAssertEqual(clip.channels.count, 2, "a gap after c1 ends the channels")
        XCTAssertEqual(clip.channels[0].map(\.frame), [0, 10, 30], "frames are truncated; one not after the last is dropped, as is a non-numeric value")
        XCTAssertTrue(clip.channels[0][1].step)
        XCTAssertEqual(clip.channels[0][0].back, .none, "a missing handle is disabled")
        XCTAssertFalse(clip.channels[0][2].back.enabled)
        XCTAssertEqual(clip.channels[0][2].front, TimelineHandle(x: 0.5, y: 2), "enabled unless enabled is false")
        XCTAssertEqual(clip.fps, 24)
        XCTAssertEqual(clip.length, 48)
        XCTAssertEqual(clip.mode, .mirror)
        XCTAssertTrue(clip.startPaused)
        XCTAssertFalse(clip.wrapLoop)
        XCTAssertEqual(clip.name, "glow")
        XCTAssertTrue(clip.relative, "relative counts by its presence")
        XCTAssertEqual(clip.otherOptions["parent"], .object(["key": .string("origin")]))
        XCTAssertEqual(clip.otherFields["previewvalue"], .number(3))
    }

    func testAnAnimationWithoutNumericTimingIsNotAClip() {
        XCTAssertNil(TimelineClip(json: .object(["c0": .array([]), "options": .object(["fps": .number(30)])])))
        XCTAssertNil(TimelineClip(json: .object(["c0": .array([])])))
    }

    func testWritesWhatItReads() throws {
        var clip = TimelineClip(channelCount: 3, fps: 15, length: 45, mode: .single)
        clip.setKeyframe(channel: 0, frame: 0, value: 1)
        clip.setKeyframe(channel: 0, frame: 20, value: -2.25)
        clip.setKeyframe(channel: 2, frame: 5, value: 0.1)
        clip.applyEase(.hold, to: [0: [20]])
        clip.wrapLoop = true
        clip.name = "intro"
        clip.relative = true
        clip.otherOptions["events"] = .array([.object(["name": .string("e"), "frame": .number(3)])])
        XCTAssertEqual(TimelineClip(json: clip.json), clip)

        let encoded = try JSONEncoder().encode(clip)
        XCTAssertEqual(try JSONDecoder().decode(TimelineClip.self, from: encoded), clip, "the overlay stores WE's block")
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let options = try XCTUnwrap(block["options"] as? [String: Any])
        XCTAssertEqual(options["mode"] as? String, "single")
        XCTAssertEqual((options["fps"] as? NSNumber)?.intValue, 15)
        XCTAssertNotNil(block["c1"], "an empty channel keeps its place")
    }

    // MARK: Editing

    func testAddMoveDeleteKeepFramesInOrder() {
        var clip = TimelineClip(channelCount: 1)
        clip.setKeyframe(channel: 0, frame: 30, value: 3)
        clip.setKeyframe(channel: 0, frame: 10, value: 1)
        clip.setKeyframe(channel: 0, frame: 20, value: 2)
        XCTAssertEqual(clip.channels[0].map(\.frame), [10, 20, 30])
        XCTAssertEqual(clip.channels[0][1].back, .back, "a new keyframe has WE's default handles")

        clip.applyEase(.linear, to: [0: [20]])
        clip.setKeyframe(channel: 0, frame: 20, value: 5)
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 20)?.value, 5)
        XCTAssertEqual(clip.ease(channel: 0, frame: 20), .linear, "setting a value keeps the handles")

        XCTAssertEqual(clip.moveKeyframes([0: [20]], by: 15), 15)
        XCTAssertEqual(clip.channels[0].map(\.frame), [10, 30, 35])
        XCTAssertEqual(clip.moveKeyframes([0: [35]], by: -5), -5)
        XCTAssertEqual(clip.channels[0].map(\.frame), [10, 30], "a moved keyframe replaces the one where it lands")
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 30)?.value, 5)

        XCTAssertEqual(clip.moveKeyframes([0: [10, 30]], by: -100), -10, "frame 0 stops the earliest")
        XCTAssertEqual(clip.channels[0].map(\.frame), [0, 20])

        clip.removeKeyframe(channel: 0, frame: 0)
        XCTAssertEqual(clip.channels[0].map(\.frame), [20])
        clip.setKeyframe(channel: 0, frame: -4, value: 1)
        XCTAssertEqual(clip.channels[0].map(\.frame), [0, 20], "no keyframe before frame 0")
    }

    func testEasePresetsAreWEsHandles() {
        var clip = TimelineClip(channelCount: 1)
        clip.setKeyframe(channel: 0, frame: 0, value: 0)
        for ease in TimelineEase.allCases {
            clip.applyEase(ease, to: [0: [0]])
            XCTAssertEqual(clip.ease(channel: 0, frame: 0), ease)
        }
        clip.applyEase(.easeIn, to: [0: [0]])
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 0)?.back, .back)
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 0)?.front, TimelineHandle.none)
    }

    func testHandleDragsInWEsUnits() throws {
        var clip = TimelineClip(channelCount: 1)
        clip.setKeyframe(channel: 0, frame: 0, value: 0)
        clip.setKeyframe(channel: 0, frame: 20, value: 10)
        // The front handle's x unit is half the segment (10 frames).
        XCTAssertEqual(clip.handlePoint(channel: 0, frame: 0, side: .front), SIMD2(10, 0))
        var keyframe = try XCTUnwrap(clip.keyframe(channel: 0, frame: 0))
        keyframe.lockAngle = false
        clip.insert(keyframe, channel: 0)
        clip.setHandle(channel: 0, frame: 0, side: .front, to: SIMD2(5, 4))
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 0)?.front, TimelineHandle(x: 0.5, y: 4))
        clip.setHandle(channel: 0, frame: 0, side: .front, to: SIMD2(-8, 1))
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 0)?.front.x, 0, "a front handle stays after its keyframe")
        clip.setHandle(channel: 0, frame: 0, side: .front, to: SIMD2(80, 1))
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 0)?.front.x, 2, "and within its segment")

        // Locked angle: the back handle turns opposite (in frames and value), keeping its length.
        clip.setHandle(channel: 0, frame: 20, side: .back, to: SIMD2(10, 10))
        let back = try XCTUnwrap(clip.keyframe(channel: 0, frame: 20)?.back)
        XCTAssertEqual(back, TimelineHandle(x: -1, y: 0))
        XCTAssertEqual(clip.keyframe(channel: 0, frame: 20)?.front, TimelineHandle(x: 1, y: 0),
                       "a flat back handle leaves the front flat")
        clip.setHandle(channel: 0, frame: 20, side: .back, to: SIMD2(10, 0))
        let front = try XCTUnwrap(clip.keyframe(channel: 0, frame: 20)?.front)
        // Back is (−10 frames, −10): the front points (+, +) with the front's length of 10 (unit 10).
        XCTAssertEqual(front.x, 0.5.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(front.y, 50.squareRoot(), accuracy: 1e-9)
    }

    // MARK: Evaluation

    func testDefaultHandlesEaseAndDisabledOnesAreLinear() {
        var clip = TimelineClip(channelCount: 1, fps: 30, length: 30)
        clip.setKeyframe(channel: 0, frame: 0, value: 0)
        clip.setKeyframe(channel: 0, frame: 30, value: 1)
        let eased = TimelineCurve.sample(clip.channels[0], at: 15)
        XCTAssertEqual(eased, 0.5, accuracy: 0.01, "the ease is symmetric about the midpoint")
        XCTAssertLessThan(TimelineCurve.sample(clip.channels[0], at: 5), 5 / 30, "and slow at the start")
        clip.applyEase(.linear, to: [0: [0, 30]])
        for frame in [5, 10, 20, 25] {
            // Straight, to the bisection's 0.01-frame tolerance.
            XCTAssertEqual(TimelineCurve.sample(clip.channels[0], at: Int32(frame)), Float(frame) / 30, accuracy: 0.01 / 30)
        }
        clip.applyEase(.hold, to: [0: [30]])
        XCTAssertEqual(TimelineCurve.sample(clip.channels[0], at: 29), 0, "a step holds the earlier value")
        XCTAssertEqual(TimelineCurve.sample(clip.channels[0], at: 30), 1)
        XCTAssertEqual(TimelineCurve.sample([], at: 3), 0)
    }

    func testWrapLoopAndRelativeAsThePlayerLoadsThem() {
        var clip = TimelineClip(channelCount: 3, fps: 10, length: 20)
        clip.setKeyframe(channel: 0, frame: 0, value: 1)
        clip.setKeyframe(channel: 0, frame: 10, value: 5)
        clip.wrapLoop = true
        let wrapped = clip.playerKeyframes(channel: 0)
        XCTAssertEqual(wrapped.map(\.frame), [0, 10, 20])
        XCTAssertEqual(wrapped.last?.value, 1, "the loop ends on the first value")
        XCTAssertEqual(wrapped.last?.back, TimelineHandle(x: -1, y: 0), "mirroring the first front handle")

        clip.relative = true
        XCTAssertEqual(clip.playerKeyframes(channel: 0, staticValue: .string("100 200 0")).map(\.value), [101, 105, 101])
        XCTAssertEqual(clip.playerKeyframes(channel: 0, staticValue: .string("100 200")).map(\.value), [1, 5, 1],
                       "WE adds nothing without three numbers")
        XCTAssertEqual(clip.playerKeyframes(channel: 0, staticValue: .number(5)).map(\.value), [1, 5, 1],
                       "a numeric value is never an offset")
    }

    func testThePlayheadReachesEachModeAsTheRendererScrubs() {
        func time(_ seconds: Float, _ mode: TimelineClip.Mode) -> Float {
            TimelineCurve.clockTime(atPlayhead: seconds, frameDuration: 1 / 10, duration: 2, mode: mode)
        }
        XCTAssertEqual(time(1.55, .loop), 1.55)
        XCTAssertEqual(time(2.55, .loop), 0.55, accuracy: 1e-6)
        XCTAssertEqual(time(2.55, .mirror), 1.45, accuracy: 1e-6)
        XCTAssertEqual(time(4.55, .mirror), 0.55, accuracy: 1e-6)
        XCTAssertEqual(time(9, .single), 2)
        XCTAssertEqual(time(-1, .loop), 0)
        // On a whole frame, WE's setFrame time: frame 15 at 30 fps samples frame 15 alone.
        let frameDuration: Float = 1 / 30
        let onFrame = TimelineCurve.clockTime(atPlayhead: 0.5, frameDuration: frameDuration, duration: 2, mode: .loop)
        XCTAssertEqual(onFrame, frameDuration * 15)
        var clip = TimelineClip(channelCount: 1, fps: 30, length: 60)
        clip.setKeyframe(channel: 0, frame: 0, value: 0)
        clip.setKeyframe(channel: 0, frame: 15, value: 0.25)
        clip.setKeyframe(channel: 0, frame: 30, value: 1)
        XCTAssertEqual(clip.values(atPlayhead: 0.5)[0], 0.25, accuracy: 1e-5)
    }
}
