import AVFoundation
import XCTest
@testable import OpenWallpaperEngine

/// WE's pause ease (`wallpaper64.exe` 0x14011137f…0x1401113d7): a paused wallpaper's rate eases
/// to 0 by min(6·dt, 1) of the gap a frame, snapping under 0.01, and WE stops drawing only then
/// (0x140111452…0x140111498); the wallpaper volume eases the same way. The Animation Speed is
/// the instance's own, and the sound layers' timers run on the scene clock.
final class ScenePlaybackEaseTests: XCTestCase {
    private static let step = 1.0 / 60

    // MARK: - The clock

    func testTheEaseIsWEs() {
        XCTAssertEqual(SceneClock.ease(1, toward: 0, seconds: 1.0 / 60), 0.9, accuracy: 1e-6, "a tenth of the gap at 60 fps")
        XCTAssertEqual(SceneClock.ease(0.3, toward: 1, seconds: 0.25), 1, "min(6·dt, 1) closes the gap at 0.25 s")
        XCTAssertEqual(SceneClock.ease(0.009, toward: 0, seconds: 1.0 / 60), 0, "under 0.01 it snaps, before stepping")
        XCTAssertEqual(SceneClock.ease(0.011, toward: 0, seconds: 1.0 / 60), 0.0099, accuracy: 1e-6, "not yet under 0.01")
    }

    /// Paused at 60 fps the rate falls 0.9× a frame: after 44 frames it is 0.9⁴⁴ ≈ 0.0097, the 45th
    /// snaps it to 0, and the clock has stopped. Each frame's step is the wall step × the rate ×
    /// the factor. After the stop a frame 2 s later resumes at once (its step clamps to 0.25 s).
    func testAPauseEasesTheClockToAStopAndAResumeIsImmediate() {
        var clock = SceneClock()
        var now = 100.0
        clock.advance(to: now, speed: 2)
        for _ in 0..<10 {
            now += Self.step
            clock.advance(to: now, speed: 2)
        }
        XCTAssertEqual(clock.delta, 2 * Self.step, accuracy: 1e-9)
        clock.paused = true
        var factor: Float = 1
        for frame in 1...45 {
            now += Self.step
            clock.advance(to: now, speed: 2)
            factor = SceneClock.ease(factor, toward: 0, seconds: Self.step)
            XCTAssertEqual(clock.playback, factor, "frame \(frame)")
            XCTAssertEqual(clock.delta, max(Self.step * 2 * Double(factor), SceneClock.minimumFrameDelta), accuracy: 1e-9)
            XCTAssertEqual(clock.hasStopped, frame == 45, "frame \(frame)")
        }
        XCTAssertEqual(clock.playback, 0)
        clock.paused = false
        now += 2
        clock.advance(to: now, speed: 2)
        XCTAssertEqual(clock.playback, 1)
        XCTAssertEqual(clock.delta, SceneClock.maximumFrameDelta, "the 2 s gap clamps to 0.25 s, at full rate")
        XCTAssertFalse(clock.hasStopped)
    }

    // MARK: - The renderer

    /// A paused renderer keeps drawing its scene slower and slower, then reports the stop.
    func testThePausedRendererReportsTheStop() throws {
        let scene = try SceneFrameHarness(directory: Fixtures.url("Scenes/timeline"))
        defer { scene.close() }
        var stops = 0
        scene.renderer.onPlaybackStopped = { stops += 1 }
        scene.draw(frames: 11)
        let playing = scene.renderer.sceneTime
        XCTAssertEqual(playing, 10 * Self.step, accuracy: 1e-9)
        scene.renderer.pausesPlayback = true
        scene.draw(frames: 44)
        XCTAssertEqual(stops, 0)
        XCTAssertFalse(scene.renderer.hasStoppedPlayback)
        scene.draw(frames: 1)
        XCTAssertEqual(stops, 1)
        XCTAssertTrue(scene.renderer.hasStoppedPlayback)
        let eased = (1...44).reduce(into: (factor: Float(1), time: 0.0)) { state, _ in
            state.factor = SceneClock.ease(state.factor, toward: 0, seconds: Self.step)
            state.time += max(Self.step * Double(state.factor), SceneClock.minimumFrameDelta)
        }
        XCTAssertEqual(scene.renderer.sceneTime - playing, eased.time + SceneClock.minimumFrameDelta, accuracy: 1e-6,
                       "the clock slowed down to its floor instead of stopping at once")
        scene.renderer.pausesPlayback = false
        scene.draw(frames: 1)
        XCTAssertFalse(scene.renderer.hasStoppedPlayback)
    }

    /// Roadmap 8.18: each instance runs at the Animation Speed of its own property store, so two
    /// displays with their own properties run one wallpaper at their own speeds.
    func testEachInstanceRunsAtItsOwnSpeed() throws {
        let directory = Fixtures.url("Scenes/timeline")
        let fast = try SceneFrameHarness(directory: directory, scope: .display("speed-test-A"), screenID: "A")
        defer { fast.close() }
        let slow = try SceneFrameHarness(directory: directory, scope: .display("speed-test-B"), screenID: "B")
        defer { slow.close() }
        WallpaperServices.shared.setUserProperties([ScenePlaybackSpeed.propertyKey: "2"], wallpaper: fast.model.propertyStoreKey,
                                                   replacing: false)
        WallpaperServices.shared.setUserProperties([ScenePlaybackSpeed.propertyKey: "0.5"], wallpaper: slow.model.propertyStoreKey,
                                                   replacing: false)
        XCTAssertNotEqual(fast.model.propertyStoreKey, slow.model.propertyStoreKey)
        for _ in 0..<31 {
            fast.draw(frames: 1)
            slow.draw(frames: 1)
        }
        XCTAssertEqual(fast.renderer.sceneTime, 30 * 2 * Self.step, accuracy: 1e-9)
        XCTAssertEqual(slow.renderer.sceneTime, 30 * 0.5 * Self.step, accuracy: 1e-9)
        XCTAssertEqual(ScenePlaybackSpeed.speed(ofStore: "no such store"), 1)
    }

    // MARK: - Sound

    private func toneContent() -> SceneSoundContent {
        SceneSoundContent(id: 7, name: "tone", sound: WESceneSound(files: ["sounds/tone.wav"], playbackMode: .loop),
                          files: [SceneSoundContent.File(path: "sounds/tone.wav",
                                                         url: Fixtures.url("Scenes/scripted-objects/sounds/tone.wav"),
                                                         duration: 0.1)], volume: 1)
    }

    /// OWE's start fade-in (not WE's) is stepped by the drawn frames with the same ease: silent
    /// as the first layer arrives, a tenth after one 60 Hz frame, full after 45.
    func testTheStartFadeInStepsByTheFrames() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        layers.setContent([toneContent()])
        XCTAssertEqual(layers.gain, 0)
        layers.advanceFade(frameSeconds: Self.step)
        XCTAssertEqual(layers.gain, 0.1, accuracy: 1e-6)
        for _ in 0..<44 { layers.advanceFade(frameSeconds: Self.step) }
        XCTAssertEqual(layers.gain, 1, "snapped once within 0.01")
        layers.stopAll()
    }

    /// The wallpaper gain fades by the drawn frames' steps with WE's ease (a pause once the
    /// sound plays at full volume).
    func testTheWallpaperGainFadesByTheFrames() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        layers.setContent([toneContent()])
        for _ in 0..<45 { layers.advanceFade(frameSeconds: Self.step) }
        XCTAssertEqual(layers.gain, 1)
        layers.setTargetGain(0)
        layers.advanceFade(frameSeconds: Self.step)
        XCTAssertEqual(layers.gain, 0.9, accuracy: 1e-6)
        for _ in 0..<44 { layers.advanceFade(frameSeconds: Self.step) }
        XCTAssertEqual(layers.gain, 0, "snapped once under 0.01, as the clock's ease")
        layers.stopAll()
    }

    /// A sound layer's timers take the scene clock's step: at rate 2, `random`'s wait after its
    /// clip counts down twice as fast as the wall clock (the objects' update step, 0x1401891a0).
    func testSoundTimersRunOnTheSceneClock() throws {
        _ = try Fixtures.assets()
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-sound-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "sounds"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) } // Optional: cleanup only.
        try FileManager.default.copyItem(at: Fixtures.url("Scenes/scripted-objects/sounds/tone.wav"),
                                         to: directory.appending(path: "sounds/tone.wav"))
        try Data(#"{"file": "scene.json", "general": {"properties": {}}, "title": "sound clock", "type": "scene"}"#.utf8)
            .write(to: directory.appending(path: "project.json"))
        try Data(#"""
            {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"}, "version": 1,
             "general": {"orthogonalprojection": {"width": 128, "height": 64}, "clearcolor": "0 0 0"},
             "objects": [{"id": 1, "name": "Back", "image": "models/util/solidlayer.json", "origin": "64 32 0",
                          "size": "128 64", "color": "0 0 0"},
                         {"id": 2, "name": "Tone", "sound": ["sounds/tone.wav"], "playbackmode": "random",
                          "mintime": 10, "maxtime": 10, "volume": 0.001}]}
            """#.utf8).write(to: directory.appending(path: "scene.json"))
        let scene = try SceneFrameHarness(directory: directory)
        defer { scene.close() }
        scene.renderer.playbackRate = { 2 }
        // The layer plays once the wallpaper gain, faded by the frames, is above 0 (a quiet volume).
        scene.renderer.sounds.setTargetGain(1)
        scene.draw(frames: 3)
        let playback = try XCTUnwrap(scene.renderer.sounds.playback(of: 2))
        let start = playback.restartTimer
        XCTAssertGreaterThan(start, 10)
        scene.draw(frames: 30)
        XCTAssertEqual(playback.restartTimer, start - 30 * 2 * Self.step, accuracy: 1e-6)
        scene.renderer.sounds.setTargetGain(0)
    }
}
