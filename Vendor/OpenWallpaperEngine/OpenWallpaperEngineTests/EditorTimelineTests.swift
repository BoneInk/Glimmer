import Metal
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The editor's timeline against the player (editor-plan notes P4): what the editor writes is
/// what the player reads, curves shaped in the editor evaluate to the player's values bit for
/// bit, and the playhead sets the renderer's timeline time.
@MainActor
final class EditorTimelineTests: XCTestCase {
    private static let scene = Data("""
    {"general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
     "objects": [{"id": 1, "image": "a.json", "origin": "960 540 0", "alpha": 1,
                  "effects": [{"file": "effects/tint/effect.json",
                               "passes": [{"constantshadervalues": {"strength": 0.5}}]}]}]}
    """.utf8)

    private static let alpha = TimelineTarget.field("alpha", of: 1)
    private static let origin = TimelineTarget.field("origin", of: 1)
    private static let strength = TimelineTarget.constant("strength", effect: 0, of: 1)

    /// Curves as an author shapes them: eases, a hold, handles dragged with and without the
    /// locked angle and length, keyframes on uneven frames.
    private static func shapedClip() -> TimelineClip {
        var clip = TimelineClip(channelCount: 1, fps: 24, length: 96, mode: .loop)
        for (frame, value) in [(0, 0.0), (7, 0.8), (19, 0.35), (40, 1.0), (41, 0.2), (77, 0.6)] {
            clip.setKeyframe(channel: 0, frame: frame, value: value)
        }
        clip.applyEase(.linear, to: [0: [7]])
        clip.applyEase(.easeOut, to: [0: [19]])
        clip.applyEase(.hold, to: [0: [41]])
        clip.setHandle(channel: 0, frame: 0, side: .front, to: SIMD2(5.5, 0.9))
        clip.channels[0][3].lockLength = true
        clip.setHandle(channel: 0, frame: 40, side: .back, to: SIMD2(31, 1.4))
        clip.channels[0][5].lockAngle = false
        clip.setHandle(channel: 0, frame: 77, side: .back, to: SIMD2(60, -0.3))
        return clip
    }

    /// Three channels, relative to the authored origin, ping-ponging, wrapped at its length.
    private static func relativeClip() -> TimelineClip {
        var clip = TimelineClip(channelCount: 3, fps: 30, length: 45, mode: .mirror)
        clip.relative = true
        clip.wrapLoop = true
        clip.name = "sway"
        clip.otherOptions["events"] = .array([.object(["name": .string("top"), "frame": .number(12)])])
        for channel in 0..<3 {
            clip.setKeyframe(channel: channel, frame: 0, value: Double(channel) * 10)
            clip.setKeyframe(channel: channel, frame: 12 + channel, value: 50 - Double(channel) * 7.25)
            clip.setKeyframe(channel: channel, frame: 33, value: -20)
        }
        clip.setHandle(channel: 1, frame: 13, side: .front, to: SIMD2(20, 60))
        return clip
    }

    private func applied(_ clips: [TimelineTarget: TimelineClip?]) throws -> SceneJSON {
        var overlay = SceneEditOverlay()
        var edits = SceneTimelineEdits()
        for (target, clip) in clips { edits.set(clip, for: target) }
        overlay.timelines = edits
        return try JSONDecoder().decode(SceneJSON.self, from: overlay.applied(to: Self.scene))
    }

    private func firstObject(_ document: SceneJSON) -> [String: SceneJSON] {
        guard case .object(let root) = document, case .array(let objects)? = root["objects"],
              case .object(let object)? = objects.first else {
            XCTFail("the scene has no object")
            return [:]
        }
        return object
    }

    private func boundValue(_ key: String, in object: [String: SceneJSON]) -> [String: SceneJSON] {
        guard case .object(let holder)? = object[key] else {
            XCTFail("\(key) is not a bound value")
            return [:]
        }
        return holder
    }

    // MARK: Writer → decoder

    func testTheWrittenBlockReadsBackAsAuthored() throws {
        let shaped = Self.shapedClip(), relative = Self.relativeClip()
        let object = firstObject(try applied([Self.alpha: shaped, Self.origin: relative]))
        for (key, clip) in [("alpha", shaped), ("origin", relative)] {
            let holder = boundValue(key, in: object)
            let document = try SceneTimelineDocument(json: try XCTUnwrap(holder["animation"]))
            let options = try XCTUnwrap(document.options)
            XCTAssertEqual(options.fps, Float(clip.fps))
            XCTAssertEqual(options.length, Int32(clip.length))
            let mode: SceneTimelineDocument.Options.Mode = clip.mode == .mirror ? .mirror : clip.mode == .single ? .single : .loop
            XCTAssertEqual(options.mode, mode)
            XCTAssertEqual(options.wrapLoop, clip.wrapLoop)
            XCTAssertEqual(options.startPaused, clip.startPaused)
            XCTAssertEqual(document.name, clip.name)
            XCTAssertEqual(document.isRelative, clip.relative)
            XCTAssertEqual(document.channels.count, clip.channels.count)
            for (channel, keyframes) in clip.channels.enumerated() {
                XCTAssertEqual(document.channels[channel].count, keyframes.count, "\(key) c\(channel): every keyframe kept")
                for (read, written) in zip(document.channels[channel], keyframes) {
                    XCTAssertEqual(read.frame, Int32(written.frame))
                    XCTAssertEqual(read.value, Float(written.value))
                    XCTAssertEqual(read.flags.contains(.step), written.step)
                    XCTAssertEqual(read.back, written.effectiveBack, "\(key) c\(channel) frame \(written.frame)")
                    XCTAssertEqual(read.front, written.effectiveFront)
                }
            }
        }
        let origin = boundValue("origin", in: object)
        XCTAssertEqual(origin["value"], .string("960 540 0"), "the authored value stays: relative offsets from it")
        let events = try XCTUnwrap(SceneTimelineDocument(json: try XCTUnwrap(origin["animation"])).options?.events)
        XCTAssertEqual(events, [SceneTimelineDocument.Event(name: "top", frame: 12)])
    }

    func testTheAnimationSetFindsTheEditorsTimelines() throws {
        var constant = TimelineClip(channelCount: 1, fps: 10, length: 10)
        constant.setKeyframe(channel: 0, frame: 0, value: 0)
        constant.setKeyframe(channel: 0, frame: 10, value: 1)
        let document = try applied([Self.alpha: Self.shapedClip(), Self.strength: constant])
        let set = SceneAnimationSet(document: document, wallpaperID: "editor")
        XCTAssertTrue(set.contains(SceneAnimationSite(owner: .object(1), key: "alpha")))
        XCTAssertTrue(set.contains(SceneAnimationSite(owner: .material(object: 1, effect: 0, pass: 0), key: "strength")))

        // A removed timeline leaves its field static.
        let removed = firstObject(try applied([Self.alpha: nil]))
        XCTAssertEqual(removed["alpha"], .number(1))
    }

    // MARK: Curves

    /// Every frame `S(n)` and blended times of curves shaped in the editor are the player's,
    /// bit for bit, after the player's own load transforms (relative, wraploop).
    func testEditedCurvesEvaluateAsThePlayerDrawsThem() throws {
        let clips = [Self.alpha: Self.shapedClip(), Self.origin: Self.relativeClip()]
        let object = firstObject(try applied(clips.mapValues { Optional($0) }))
        for (target, clip) in clips {
            let holder = boundValue(target.key, in: object)
            var timeline = try SceneTimelineAnimation(json: try XCTUnwrap(holder["animation"]), staticValue: holder["value"])
            let staticValue: SceneJSONValue? = target == Self.origin ? .string("960 540 0") : .number(1)
            XCTAssertEqual(timeline.channels.count, clip.channels.count)
            for channel in clip.channels.indices {
                let editorKeys = clip.playerKeyframes(channel: channel, staticValue: staticValue)
                for frame in Int32(-2)...Int32(clip.length + 2) {
                    let player = SceneTimelineChannel.evaluate(timeline.channels[channel].keyframes, at: frame)
                    let editor = TimelineCurve.sample(editorKeys, at: frame)
                    XCTAssertEqual(editor.bitPattern, player.bitPattern, "\(target.key) c\(channel) S(\(frame)): \(editor) vs \(player)")
                }
            }
            var clock = timeline.clock
            for step in 0...240 {
                clock.time = Float(step) * (clock.duration / 240)
                let player = timeline.value(on: clock)
                for channel in clip.channels.indices {
                    let editor = clip.value(channel: channel, atTime: Double(clock.time), staticValue: staticValue)
                    XCTAssertEqual(editor.bitPattern, player[channel].bitPattern, "\(target.key) c\(channel) at \(clock.time)")
                }
            }
        }
    }

    // MARK: Scrubbing

    private static let fade = #"""
    {"objects": [{"id": 1,
      "alpha": {"value": 0.25, "animation": {
        "c0": [{"frame": 0, "value": 0, "back": {"enabled": false}, "front": {"enabled": false}},
               {"frame": 60, "value": 1, "back": {"enabled": false}, "front": {"enabled": false}}],
        "options": {"fps": 60, "length": 60, "mode": "single", "startpaused": true}}},
      "origin": {"value": "0 0 0", "animation": {
        "c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 30}], "c1": [{"frame": 0, "value": 5}],
        "c2": [{"frame": 0, "value": 0}],
        "options": {"fps": 30, "length": 30, "mode": "mirror"}}}}]}
    """#

    private func timelines() throws -> SceneRendererAnimations {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(Self.fade.utf8))
        let timelines = SceneRendererAnimations()
        timelines.setTimelines(SceneTimelineSource(wallpaperID: "scrub", document: document, signature: ""), restart: true)
        return timelines
    }

    func testScrubbingSetsTheRendererTimelineTime() throws {
        let timelines = try timelines()
        let set = try XCTUnwrap(timelines.set)
        let alphaSite = SceneAnimationSite(owner: .object(1), key: "alpha")
        let originSite = SceneAnimationSite(owner: .object(1), key: "origin")
        let alphaClip = try XCTUnwrap(TimelineClip(json: .object([
            "c0": .array([.object(["frame": .number(0), "value": .number(0)]),
                          .object(["frame": .number(60), "value": .number(1)])]),
            "options": .object(["fps": .number(60), "length": .number(60), "mode": .string("single"),
                                "startpaused": .bool(true)])])))

        timelines.scrubTime = 0.5
        _ = timelines.advance(by: 1 / 60)
        XCTAssertEqual(set.state(of: alphaSite)?.time, TimelineCurve.clockTime(atPlayhead: 0.5, frameDuration: 1 / 60, duration: 1, mode: .single),
                       "a paused timeline stands at the playhead too")
        let drawn = try XCTUnwrap(timelines.object("1")?.alpha)
        XCTAssertEqual(drawn, alphaClip.values(atPlayhead: 0.5)[0], "the canvas draws what the editor shows")
        XCTAssertEqual(drawn, 0.5, accuracy: 1e-3, "half way, to the bisection's tolerance")

        _ = timelines.advance(by: 1 / 60)
        XCTAssertEqual(try XCTUnwrap(timelines.object("1")?.alpha), drawn, "frames don't move a scrubbed timeline")

        // Past a clip's end: a single holds it, a mirror runs back.
        timelines.scrubTime = 1.5
        _ = timelines.advance(by: 1 / 60)
        XCTAssertEqual(try XCTUnwrap(set.state(of: alphaSite)?.time), 1, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(set.state(of: originSite)?.time), 0.5, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(timelines.object("1")?.origin?.y), 5, "every channel of a vector")

        // Letting go: the scene runs on from the playhead.
        timelines.scrubTime = 0.25
        _ = timelines.advance(by: 0)
        timelines.scrubTime = nil
        set.perform(.play, on: alphaSite)
        _ = timelines.advance(by: 0.125)
        XCTAssertEqual(try XCTUnwrap(set.state(of: alphaSite)?.time), 0.375, accuracy: 1e-6)
    }

    func testTheCanvasHoldsTheSceneClockWhileTheTimelineIsOpen() throws {
        guard let renderer = SceneMetalRenderer(pixelFormat: .bgra8Unorm) else { throw XCTSkip("no Metal device") }
        EditorTimelineCanvas.apply(0.75, to: renderer)
        XCTAssertTrue(renderer.holdsClock)
        XCTAssertEqual(renderer.timelines.scrubTime, 0.75)
        EditorTimelineCanvas.apply(nil, to: renderer)
        XCTAssertFalse(renderer.holdsClock)
        XCTAssertNil(renderer.timelines.scrubTime)
    }

    /// The editor's playhead reaches the canvas: the timeline hands its time to the link, nil once closed.
    func testTheTimelinesPlayheadReachesTheCanvasLink() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Self.scene))
        let editor = SceneTimelineEditor(session: session, index: try TimelineSceneIndex(sceneData: Self.scene))
        var shown: [Double?] = []
        editor.onCanvasTime = { shown.append($0) }
        editor.isActive = true
        editor.setPlayhead(0.5)
        editor.isActive = false
        XCTAssertEqual(shown, [0, 0.5, nil])
    }
}
