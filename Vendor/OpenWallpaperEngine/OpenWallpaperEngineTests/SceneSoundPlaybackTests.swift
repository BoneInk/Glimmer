import XCTest
@testable import OpenWallpaperEngine

/// A sound layer's playback as wallpaper64.exe runs it (`SceneSoundPlayback`; `play()` 0x1401f5980,
/// update 0x1401f4f50, `isPlaying()` 0x1401f6fb0, the gain handlers 0x1401f4c20 and 0x1401816d0),
/// against a recording output.
final class SceneSoundPlaybackTests: XCTestCase {
    private final class Recorder: SceneSoundOutput {
        var log: [String] = []
        var gains: [Int: Float] = [:]
        func start(file: Int, loop: Bool) { log.append("start \(file)\(loop ? " loop" : "")") }
        func pause(file: Int) { log.append("pause \(file)") }
        func resume(file: Int) { log.append("resume \(file)") }
        func stop(file: Int) { log.append("stop \(file)") }
        func setGain(_ gain: Float, file: Int) { gains[file] = gain }
    }

    /// Random numbers from a list, in turn.
    private func sequence(_ values: [Double]) -> () -> Double {
        var index = 0
        return {
            defer { index += 1 }
            return values[index % values.count]
        }
    }

    private func playback(_ mode: WESceneSound.PlaybackMode, durations: [Double], startSilent: Bool = false,
                          volume: Float = 1, sceneGain: Float = 1, random: [Double] = [0], minTime: Double = 1,
                          maxTime: Double = 5) -> (SceneSoundPlayback, Recorder) {
        let recorder = Recorder()
        let sound = WESceneSound(files: durations.indices.map { "sounds/\($0).mp3" }, playbackMode: mode,
                                 minTime: minTime, maxTime: maxTime, startSilent: startSilent)
        let playback = SceneSoundPlayback(sound: sound, durations: durations, volume: volume, sceneGain: sceneGain,
                                          output: recorder, random: sequence(random))
        return (playback, recorder)
    }

    func testOneLoopingFileLoopsNatively() {
        let (sound, out) = playback(.loop, durations: [2])
        sound.load()
        XCTAssertEqual(out.log, ["start 0 loop"])
        for _ in 0..<600 { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertEqual(out.log, ["start 0 loop"], "no restarts: the file loops by itself")
        XCTAssertTrue(sound.isPlaying)
    }

    /// Several files in `loop`: each start picks one at random, plays it once, and the next random
    /// one starts when it ends (not in list order).
    func testSeveralLoopFilesPlayRandomClipsBackToBack() {
        let (sound, out) = playback(.loop, durations: [1, 2, 3], random: [0.9, 0.1, 0.5])
        sound.load()
        XCTAssertEqual(out.log, ["start 2"], "0.9 × 3 files picks the third")
        for _ in 0..<(3 * 60 + 1) { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertEqual(out.log, ["start 2", "start 0"], "its 3 s over, the next random clip starts")
        XCTAssertTrue(sound.isPlaying)
    }

    /// `random`: a clip at load, then a pause of `mintime + u·(maxtime − mintime)` after its end,
    /// during which `isPlaying()` is false and `play()` does nothing.
    func testRandomWaitsAfterEachClip() {
        let (sound, out) = playback(.random, durations: [1], random: [0, 0.5], minTime: 1, maxTime: 5)
        sound.load()
        XCTAssertEqual(out.log, ["start 0"])
        XCTAssertEqual(sound.restartTimer, 1 + 1 + 0.5 * 4, accuracy: 1e-9)
        for _ in 0..<90 { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertFalse(sound.isPlaying, "between clips the file is stopped")
        sound.play()
        XCTAssertEqual(out.log, ["start 0"], "play() while waiting does nothing")
        for _ in 0..<(3 * 60) { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertEqual(out.log, ["start 0", "start 0"], "4 s after the start the next clip plays")
    }

    func testSinglePlaysOnce() {
        let (sound, out) = playback(.single, durations: [0.5])
        sound.load()
        XCTAssertTrue(sound.isPlaying)
        for _ in 0..<120 { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertFalse(sound.isPlaying)
        XCTAssertEqual(out.log, ["start 0"])
    }

    func testStartSilentWaitsForPlay() {
        let (sound, out) = playback(.single, durations: [1], startSilent: true)
        sound.load()
        XCTAssertEqual(out.log, [])
        XCTAssertFalse(sound.isPlaying)
        sound.play()
        XCTAssertEqual(out.log, ["start 0"])
    }

    /// `pause()` then `play()` resumes where it was; `stop()` then `play()` starts afresh.
    func testPauseResumesAndStopRestarts() {
        let (sound, out) = playback(.loop, durations: [2])
        sound.load()
        sound.pause()
        XCTAssertFalse(sound.isPlaying, "a paused layer isn't playing")
        sound.play()
        XCTAssertEqual(out.log, ["start 0 loop", "pause 0", "resume 0"])
        sound.stop()
        XCTAssertFalse(sound.isPlaying)
        sound.play()
        XCTAssertEqual(out.log, ["start 0 loop", "pause 0", "resume 0", "stop 0", "start 0 loop"])
    }

    /// The gain is `volume² × sceneGain`; with none, `play()` starts nothing, and raising the
    /// volume later starts a sound that never could.
    func testGainIsVolumeSquaredAndASilentStartWaitsForVolume() {
        let (sound, out) = playback(.loop, durations: [2], volume: 0)
        sound.load()
        XCTAssertEqual(out.log, [])
        sound.setVolume(0.5)
        XCTAssertEqual(out.log, ["start 0 loop"])
        XCTAssertEqual(out.gains[0], 0.25)
        sound.setSceneGain(0.5)
        XCTAssertEqual(out.gains[0], 0.125)
    }

    /// The wallpaper's gain at 0 (muted, paused) pauses the files and freezes the timers; above 0
    /// they resume where they were.
    func testMutingPausesAndFreezesTimers() {
        let (sound, out) = playback(.loop, durations: [1, 1], random: [0])
        sound.load()
        sound.setSceneGain(0)
        XCTAssertEqual(out.log, ["start 0", "pause 0"])
        for _ in 0..<600 { sound.update(deltaTime: 1.0 / 60) }
        XCTAssertEqual(out.log, ["start 0", "pause 0"], "no clip ends while muted")
        sound.setSceneGain(1)
        XCTAssertEqual(out.log, ["start 0", "pause 0", "resume 0"])
    }

    /// Muted from load (another display plays the sound, or the app is muted): the sound starts
    /// once the gain comes up.
    func testASoundLoadedMutedStartsWhenUnmuted() {
        let (sound, out) = playback(.loop, durations: [1], sceneGain: 0)
        sound.load()
        XCTAssertEqual(out.log, [])
        sound.setSceneGain(1)
        XCTAssertEqual(out.log, ["start 0 loop"])
    }

    /// WE's defaults for an absent key (wallpaper64.exe 0x1401f7090) and both `sound` forms.
    func testSoundObjectDecodesWithWEsDefaults() throws {
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 5, "sound": ["a.mp3", "b.ogg"]}"#.utf8))
        let sound = try XCTUnwrap(object.sound)
        XCTAssertEqual(sound.files, ["a.mp3", "b.ogg"])
        XCTAssertEqual(sound.playbackMode, .loop)
        XCTAssertNil(sound.volume)
        XCTAssertEqual(sound.minTime, 1)
        XCTAssertEqual(sound.maxTime, 5)
        XCTAssertFalse(sound.startSilent)

        let created = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
            {"sound": "sounds/x.wav", "playbackmode": "random", "volume": {"user": "music", "value": 0.3},
             "mintime": 2, "maxtime": 3, "startsilent": true}
            """#.utf8))
        let other = try XCTUnwrap(created.sound)
        XCTAssertEqual(other.files, ["sounds/x.wav"], "createLayer('sounds/…') makes the one-path form")
        XCTAssertEqual(other.playbackMode, .random)
        XCTAssertEqual(other.volume?.userPropertyName, "music")
        XCTAssertTrue(other.startSilent)
        XCTAssertNil(try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"image": "a.json"}"#.utf8)).sound)
    }
}
