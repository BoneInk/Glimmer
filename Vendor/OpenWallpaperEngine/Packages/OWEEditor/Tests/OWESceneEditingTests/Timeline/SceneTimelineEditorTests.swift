import XCTest
@testable import OWESceneEditing

/// The timeline's edits on a session: keyframes added, moved, deleted, copied and pasted, eases
/// and handles, clip options, each one undo step stored in the overlay as WE's `animation`
/// blocks; animated fields keyed at the playhead; and the playhead driving the canvas.
@MainActor
final class SceneTimelineEditorTests: XCTestCase {
    private var editor: SceneTimelineEditor!
    private var session: SceneEditSession!
    private var canvasTimes: [Double?] = []

    override func setUp() async throws {
        let made = try TimelineFixtures.editor()
        editor = made.0
        session = made.1
        canvasTimes = []
        editor.onCanvasTime = { [unowned self] in canvasTimes.append($0) }
    }

    private func frames(_ target: TimelineTarget, channel: Int = 0) -> [Int] {
        editor.clip(target)?.channels[channel].map(\.frame) ?? []
    }

    // MARK: Tracks

    func testTracksListWhatTheSceneAndTheOverlayAnimate() throws {
        XCTAssertEqual(editor.tracks, [TimelineFixtures.alpha], "with nothing selected, every layer's")
        session.selection = 2
        XCTAssertEqual(editor.tracks, [])
        XCTAssertFalse(editor.addableProperties(of: 2).map(\.target.key).contains("scale"),
                       "a field a user property sets takes no timeline")
        let layer1 = editor.addableProperties(of: 1).map(\.target)
        XCTAssertTrue(layer1.contains(TimelineFixtures.origin))
        XCTAssertTrue(layer1.contains(TimelineFixtures.strength))
        XCTAssertTrue(layer1.contains(TimelineFixtures.tint))
        XCTAssertFalse(layer1.contains(TimelineFixtures.alpha), "already animated")
        XCTAssertFalse(layer1.contains { $0.key == "noise" }, "a texture isn't a number")
        XCTAssertEqual(editor.index.property(TimelineFixtures.tint)?.channelCount, 3)
        session.selection = nil
        XCTAssertEqual(editor.duration, 2, "the alpha clip's 60 frames at 30 fps")
    }

    // MARK: Keyframes

    func testAddingAKeyframeAtThePlayheadStartsATimeline() throws {
        session.selection = 1
        editor.isActive = true
        editor.setPlayhead(1)
        editor.addKeyframe(TimelineFixtures.origin, actionName: "Add Keyframe")

        let clip = try XCTUnwrap(editor.clip(TimelineFixtures.origin))
        XCTAssertEqual(clip.channels.count, 3)
        XCTAssertEqual(clip.fps, 30, "a new timeline takes the active clip's timing")
        XCTAssertEqual(clip.length, 60)
        XCTAssertEqual(clip.channels.map { $0.map(\.frame) }, [[30], [30], [30]])
        XCTAssertEqual(clip.channels.map { $0[0].value }, [960, 540, 0], "at the field's value")
        XCTAssertEqual(editor.selection.count, 3)
        XCTAssertEqual(editor.tracks, [TimelineFixtures.origin, TimelineFixtures.alpha])
        XCTAssertTrue(session.isEdited(1))

        let origin = try XCTUnwrap(TimelineFixtures.appliedObject(1, overlay: session.overlay)["origin"] as? [String: Any])
        XCTAssertEqual(origin["value"] as? String, "960 540 0", "the static value stays beside the timeline")
        let animation = try XCTUnwrap(origin["animation"] as? [String: Any])
        XCTAssertEqual(((animation["options"] as? [String: Any])?["fps"] as? NSNumber)?.intValue, 30)
        XCTAssertEqual((animation["c1"] as? [[String: Any]])?.first?["value"] as? Int, 540)

        session.undo()
        XCTAssertNil(editor.clip(TimelineFixtures.origin))
        XCTAssertNil(session.overlay.timelines)
        session.redo()
        XCTAssertEqual(frames(TimelineFixtures.origin, channel: 2), [30])
    }

    func testTheKeyframeButtonTogglesTheKeyframeAtThePlayhead() throws {
        editor.setPlayhead(1)
        guard case .keyed(partial: false) = editor.keyState(TimelineFixtures.alpha) else { return XCTFail("frame 30 is keyed") }
        editor.toggleKeyframe(TimelineFixtures.alpha, addName: "Add", removeName: "Remove")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0])
        guard case .animated = editor.keyState(TimelineFixtures.alpha) else { return XCTFail("no keyframe at 30 now") }
        XCTAssertTrue(editor.isActive, "the button opens the timeline")
        XCTAssertEqual(session.undoManager.undoActionName, "Remove")

        editor.toggleKeyframe(TimelineFixtures.alpha, addName: "Add", removeName: "Remove")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 30])
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 30)?.value ?? -1, 0,
                       accuracy: 1e-6, "the value it shows there now, the held first value")
        session.undo()
        session.undo()
        XCTAssertNil(session.overlay.timelines, "back to scene.json's timeline: nothing stored")
        guard case .none = editor.keyState(TimelineFixtures.origin) else { return XCTFail("origin isn't animated") }
    }

    func testMovingAndDeletingKeyframesUndoesStepByStep() throws {
        let key30 = TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 30)
        editor.select([key30])
        editor.previewMove(byFrames: 10)
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 40], "the drag draws its preview")
        XCTAssertNil(session.overlay.timelines, "and commits nothing yet")
        XCTAssertTrue(editor.isSelected(TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 40)))
        editor.commitPreview(actionName: "Move Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 40])
        XCTAssertEqual(editor.selection, [TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 40)])
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 40)?.extra["magic"], .bool(true),
                       "what the editor doesn't change goes with the keyframe")

        editor.deleteSelection(actionName: "Delete Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0])
        XCTAssertTrue(editor.selection.isEmpty)

        session.undo()
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 40])
        session.undo()
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 30])
        XCTAssertNil(session.overlay.timelines)

        editor.select([key30])
        editor.previewMove(byFrames: -100)
        XCTAssertEqual(editor.previewFrameDelta, -30, "frame 0 stops the selection")
        editor.cancelPreview()
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 30])
    }

    /// Escape during a drag: the preview goes, the rest of the drag does nothing, and its end
    /// commits nothing; the next drag works again.
    func testCancellingADragIgnoresTheRestOfIt() throws {
        let key30 = TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 30)
        editor.select([key30])
        editor.previewMove(byFrames: 10)
        XCTAssertTrue(editor.isPreviewing)
        editor.cancelPreview()
        XCTAssertFalse(editor.isPreviewing)
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 30])
        editor.previewMove(byFrames: 20)
        XCTAssertFalse(editor.isPreviewing, "the cancelled drag keeps going under the pointer, drawing nothing")
        editor.commitPreview(actionName: "Move Keyframes")
        XCTAssertNil(session.overlay.timelines, "its end commits nothing")
        XCTAssertEqual(editor.selection, [key30], "the selection stays")

        editor.previewMove(byFrames: 5)
        editor.commitPreview(actionName: "Move Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 35], "the next drag moves")

        editor.cancelPreview()
        editor.select([TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 35)])
        editor.previewMove(byFrames: 1)
        XCTAssertTrue(editor.isPreviewing, "Escape without a drag doesn't block the next one")
    }

    func testSelectAllCopyAndPasteAtThePlayhead() throws {
        editor.selectAll()
        XCTAssertEqual(editor.selection.count, 2)
        editor.copySelection()
        editor.setPlayhead(1)
        editor.paste(actionName: "Paste Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 30, 60], "offsets kept from the playhead")
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 30)?.value, 0)
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 60)?.value, 1)
        XCTAssertEqual(editor.selection.map(\.frame).sorted(), [30, 60])

        // Keyframes of one track paste onto the focused track instead.
        editor.focused = TimelineFixtures.strength
        editor.setPlayhead(0)
        editor.paste(actionName: "Paste Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.strength), [0, 30])
        let strength = try XCTUnwrap(TimelineFixtures.appliedObject(1, overlay: session.overlay)["effects"] as? [[String: Any]])
        let constants = try XCTUnwrap((strength[0]["passes"] as? [[String: Any]])?[0]["constantshadervalues"] as? [String: Any])
        let bound = try XCTUnwrap(constants["strength"] as? [String: Any])
        XCTAssertEqual(bound["value"] as? Double, 0.5)
        XCTAssertNotNil(bound["animation"])
        XCTAssertEqual(constants["noise"] as? String, "textures/noise", "other constants stay")

        editor.selection = [TimelineKeyframeRef(target: TimelineFixtures.strength, channel: 0, frame: 30)]
        editor.cutSelection(actionName: "Cut Keyframes")
        XCTAssertEqual(frames(TimelineFixtures.strength), [0])
        XCTAssertTrue(editor.canPaste)
    }

    func testEasesAndHandleDragsChangeTheStoredHandles() throws {
        let key0 = TimelineKeyframeRef(target: TimelineFixtures.alpha, channel: 0, frame: 0)
        editor.select([key0])
        editor.applyEase(.linear, actionName: "Change Ease")
        XCTAssertEqual(editor.selectionEase, .linear)
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 0)?.front, TimelineHandle.none)

        editor.applyEase(.easeInOut, actionName: "Change Ease")
        // The front handle's unit is half the 30-frame segment: frame 15 is x = 1.
        editor.previewHandle(key0, side: .front, to: SIMD2(7.5, 0.25))
        XCTAssertNil(session.overlay.timelines, "scene.json's handles until the drag ends")
        editor.commitPreview(actionName: "Change Curve")
        let keyframe = try XCTUnwrap(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 0))
        XCTAssertEqual(keyframe.front, TimelineHandle(x: 0.5, y: 0.25))
        XCTAssertEqual(session.undoManager.undoActionName, "Change Curve")
    }

    func testClipOptionsAreStoredAsWEOptions() throws {
        editor.change(TimelineFixtures.alpha, actionName: "Change Clip Options") {
            $0.fps = 60
            $0.mode = .mirror
            $0.wrapLoop = true
            $0.name = "fade"
        }
        let alpha = try XCTUnwrap(TimelineFixtures.appliedObject(1, overlay: session.overlay)["alpha"] as? [String: Any])
        let options = try XCTUnwrap((alpha["animation"] as? [String: Any])?["options"] as? [String: Any])
        XCTAssertEqual(options["fps"] as? Int, 60)
        XCTAssertEqual(options["mode"] as? String, "mirror")
        XCTAssertEqual(options["wraploop"] as? Bool, true)
        XCTAssertEqual(options["name"] as? String, "fade")
        XCTAssertNotNil(options["events"], "options the editor doesn't change stay")
        XCTAssertEqual(alpha["value"] as? Int, 1)
    }

    func testRemovingATimelineLeavesTheStaticValue() throws {
        editor.removeTrack(TimelineFixtures.alpha, actionName: "Remove Animation")
        XCTAssertNil(editor.clip(TimelineFixtures.alpha))
        XCTAssertEqual(editor.tracks, [])
        XCTAssertEqual(try TimelineFixtures.appliedObject(1, overlay: session.overlay)["alpha"] as? Int, 1)

        let decoded = try SceneEditOverlay.decoded(from: session.overlay.encoded())
        XCTAssertEqual(decoded, session.overlay, "the overlay file keeps timeline edits")
        XCTAssertNil(try SceneEditOverlay.decoded(from: Data(#"{"version": 1, "objects": {}}"#.utf8)).timelines,
                     "an overlay from before timelines still reads")
    }

    // MARK: Animated fields

    func testEditingAnAnimatedFieldKeysItAtThePlayhead() throws {
        session.selection = 1
        editor.isActive = true
        editor.setPlayhead(0.5)
        let shown = try XCTUnwrap(session.value("alpha", of: 1)?.doubleValue)
        XCTAssertEqual(shown, 0.5, accuracy: 0.01, "the inspector shows the timeline at the playhead")

        session.setValue(.number(0.25), for: "alpha", of: 1, actionName: "Change Opacity")
        XCTAssertEqual(frames(TimelineFixtures.alpha), [0, 15, 30])
        XCTAssertEqual(editor.clip(TimelineFixtures.alpha)?.keyframe(channel: 0, frame: 15)?.value, 0.25)
        XCTAssertNil(session.overlay.field("alpha", of: 1), "the static value isn't touched")
        XCTAssertEqual(session.number("alpha", of: 1, default: 1), 0.25, accuracy: 1e-6)

        // Dragging the gizmo keys only the channels it moved.
        editor.addKeyframe(TimelineFixtures.origin, actionName: "Add Keyframe")
        editor.setPlayhead(1)
        var transform = session.transform(of: 1)
        transform.origin.x += 100
        session.setTransform(transform, of: 1, actionName: "Move")
        XCTAssertEqual(frames(TimelineFixtures.origin, channel: 0), [15, 30])
        XCTAssertEqual(frames(TimelineFixtures.origin, channel: 1), [15], "y didn't move")
        XCTAssertEqual(editor.clip(TimelineFixtures.origin)?.keyframe(channel: 0, frame: 30)?.value, 1060)

        editor.isActive = false
        session.setValue(.number(0.75), for: "alpha", of: 1, actionName: "Change Opacity")
        XCTAssertEqual(session.overlay.field("alpha", of: 1), .number(0.75), "with the timeline closed, the static value")
    }

    // MARK: Playhead and canvas

    func testThePlayheadDrivesTheCanvasWhileTheTimelineIsOpen() {
        editor.setPlayhead(0.5)
        XCTAssertEqual(canvasTimes, [nil], "closed: the canvas plays on its own")
        editor.isActive = true
        editor.setPlayhead(1.25)
        editor.setPlayhead(9)
        XCTAssertEqual(canvasTimes, [nil, 0.5, 1.25, 2], "scrubbing shows each time; the end of the longest clip stops it")
        editor.isActive = false
        XCTAssertEqual(canvasTimes.last, .some(nil), "closing resumes the scene")
    }

    func testPlaybackAdvancesTheCanvasAndLoops() {
        var clock: TimeInterval = 100
        editor.now = { clock }
        editor.loops = true
        editor.play()
        XCTAssertTrue(editor.isActive && editor.isPlaying)
        clock += 0.75
        editor.tick()
        XCTAssertEqual(editor.playhead, 0.75, accuracy: 1e-9)
        XCTAssertEqual(canvasTimes.last ?? nil, 0.75)
        clock += 1.5
        editor.tick()
        XCTAssertEqual(editor.playhead, 0.25, accuracy: 1e-9, "past the 2 s end it starts over")

        editor.loops = false
        clock += 5
        editor.tick()
        XCTAssertEqual(editor.playhead, 2)
        XCTAssertFalse(editor.isPlaying, "without looping it stops at the end")
        editor.pause()
    }
}
