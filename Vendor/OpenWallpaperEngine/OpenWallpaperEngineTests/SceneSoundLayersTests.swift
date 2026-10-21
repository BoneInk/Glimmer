import XCTest
import AVFoundation
@testable import OpenWallpaperEngine

/// Sound layers through AVAudioEngine, rendered offline (`SceneSoundLayers`, `SceneSoundVoices`):
/// a layer plays its file, loops it past its end, fades with the wallpaper's gain like WE
/// (`v += (target − v) × min(dt × 6, 1)`), pauses at 0 and takes `volume²`. And the content
/// builder finds files loose and packaged, and leaves out what it can't decode.
final class SceneSoundLayersTests: XCTestCase {
    private var directory: URL!
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-sound-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// A 0.1 s full-scale 440 Hz tone.
    private func tone(_ name: String, seconds: Double = 0.1) throws -> URL {
        let url = directory.appending(path: name)
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(2 * Double.pi * 440 * Double(index) / 44_100))
        }
        let file = try AVAudioFile(forWriting: url, settings: mono.settings)
        try file.write(from: buffer)
        return url
    }

    private func content(_ url: URL, mode: WESceneSound.PlaybackMode = .loop, volume: Float = 1) -> SceneSoundContent {
        SceneSoundContent(id: 7, name: "tone", sound: WESceneSound(files: ["sounds/tone.wav"], playbackMode: mode),
                          files: [SceneSoundContent.File(path: "sounds/tone.wav", url: url, duration: 0.1)], volume: volume)
    }

    /// Sets `sounds` as a starting wallpaper's content and steps OWE's start fade-in to its end.
    private func start(_ layers: SceneSoundLayers, _ sounds: [SceneSoundContent]) {
        layers.setContent(sounds)
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
    }

    /// RMS of `seconds` rendered offline.
    private func render(_ layers: SceneSoundLayers, seconds: Double) throws -> Float {
        let engine = try XCTUnwrap(layers.soundMixer?.engine)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var remaining = Int(seconds * 44_100), sum: Float = 0, count = 0
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(remaining, 4096))
            guard engine.isRunning else { return 0 }
            let status = try engine.renderOffline(frames, to: buffer)
            XCTAssertEqual(status, .success)
            for index in 0..<Int(buffer.frameLength) {
                let sample = buffer.floatChannelData![0][index]
                sum += sample * sample
            }
            count += Int(buffer.frameLength)
            remaining -= Int(frames)
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : 0
    }

    func testALayerPlaysAndLoopsPastItsEnd() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        start(layers, [content(try tone("tone.wav"))])
        XCTAssertEqual(layers.isPlaying(7), true)
        XCTAssertGreaterThan(try render(layers, seconds: 0.05), 0.3, "a full-scale mono sine is 0.42 RMS per channel (0.71 × OpenAL's mono level)")
        // The second pass is queued from the start (offline rendering never reports a pass as
        // played, so the third one isn't queued here).
        XCTAssertGreaterThan(try render(layers, seconds: 0.1), 0.3, "past its end the next pass plays without a gap")
    }

    func testVolumeIsSquaredAndTheWallpaperGainFadesToAPause() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        start(layers, [content(try tone("tone.wav"), volume: 0.5)])
        let quiet = try render(layers, seconds: 0.05)
        // The mono tone reaches each stereo channel at OpenAL's mono level: RMS 0.71 × 0.596 at full gain.
        XCTAssertEqual(quiet, 0.7071 * SceneSoundSpatialization.monoLevel * 0.25, accuracy: 0.01,
                       "volume 0.5 is a gain of 0.25")

        layers.setTargetGain(0)
        layers.stepFade(1.0 / 60)
        XCTAssertEqual(layers.gain, 0.9, accuracy: 1e-6, "one 60 Hz step of WE's fade covers a tenth")
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertEqual(layers.gain, 0, "snapped at 0.01")
        XCTAssertLessThan(try render(layers, seconds: 0.05), 0.001, "paused")
        XCTAssertEqual(layers.playback(of: 7)?.hasSoundingVoice, false)

        layers.setTargetGain(1)
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertEqual(layers.isPlaying(7), true, "resumed where it was")
        XCTAssertGreaterThan(try render(layers, seconds: 0.05), 0.1)
    }

    /// A muted wallpaper (or a display that doesn't play its sound) never makes an audio engine,
    /// so it never touches the audio hardware; unmuting makes it and starts the sound.
    func testASilentWallpaperMakesNoEngine() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(0)
        layers.setContent([content(try tone("tone.wav"))])
        XCTAssertNil(layers.soundMixer)
        XCTAssertEqual(layers.isPlaying(7), false)
        layers.setTargetGain(1)
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        XCTAssertNotNil(layers.soundMixer)
        XCTAssertEqual(layers.isPlaying(7), true)
    }

    /// A rebuild of the same content (a user property changed a layer) keeps the sound going.
    func testTheSameContentKeepsPlaying() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTargetGain(1)
        let url = try tone("tone.wav")
        layers.setContent([content(url)])
        let playback = layers.playback(of: 7)
        layers.setContent([content(url, volume: 0.5)])
        XCTAssertTrue(layers.playback(of: 7) === playback)
        XCTAssertEqual(playback?.volume, 0.5)
        layers.setContent([])
        XCTAssertNil(layers.playback(of: 7))
    }

    /// A mono file of `seconds` at a constant `value`.
    private func constant(_ name: String, value: Float, seconds: Double) throws -> URL {
        let url = directory.appending(path: name)
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        let file = try AVAudioFile(forWriting: url, settings: mono.settings)
        try file.write(from: buffer)
        return url
    }

    /// The left channel's samples of `frames` rendered offline.
    private func samples(_ layers: SceneSoundLayers, frames: Int) throws -> [Float] {
        let engine = try XCTUnwrap(layers.soundMixer?.engine)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var out: [Float] = [], remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, 4096))
            XCTAssertEqual(try engine.renderOffline(count, to: buffer), .success)
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            remaining -= Int(count)
        }
        return out
    }

    /// OWE's start fade-in (not WE's, which starts at full volume: its fade is 1 from the
    /// constructor 0x14010dc00 and a loaded wallpaper takes it at once, 0x140114950): a starting
    /// wallpaper's sound eases in with the pause/resume ease, over 45 frames (0.75 s) at 60 Hz,
    /// ramped sample by sample, at its volume.
    func testAWallpaperFadesInWhenItStarts() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 0.5, audible: true)
        XCTAssertEqual(layers.gain, 0.5, "before any layer the fade takes its target")
        let dc = content(try constant("dc.wav", value: 0.5, seconds: 2))
        layers.setContent([dc])
        XCTAssertEqual(layers.gain, 0, "the first layer starts silent")
        XCTAssertEqual(layers.playback(of: 7)?.hasSoundingVoice, false)
        let level = 0.5 * SceneSoundSpatialization.monoLevel * 0.5
        var frames = 0, rendered: [Float] = []
        while layers.gain < 0.5 {
            layers.stepFade(1.0 / 60)
            frames += 1
            if frames == 1 { XCTAssertEqual(layers.gain, 0.05, accuracy: 1e-6, "a tenth of the volume after one frame") }
            rendered += try samples(layers, frames: 735)
        }
        XCTAssertEqual(frames, 45, "at full volume after 0.75 s")
        XCTAssertEqual(layers.isPlaying(7), true)
        let first = try XCTUnwrap(rendered.firstIndex { $0 > 0 })
        XCTAssertLessThanOrEqual(rendered[first], level * 0.1 + 1e-4, "it starts at a tenth of the volume at most")
        let rising = Array(rendered[first...])
        let jumps = zip(rising.dropFirst(), rising).map { abs($0 - $1) }
        XCTAssertLessThan(jumps.max() ?? 1, level * 0.1 / 20, "no steps: the rise spreads over many samples")
        XCTAssertEqual(try samples(layers, frames: 2048).last ?? 0, level, accuracy: 1e-4)

        // A rebuild (same content) and a script's new layer don't fade in again.
        layers.setContent([dc])
        layers.add(SceneSoundContent(id: 8, name: "tone", sound: dc.sound, files: dc.files, volume: 1))
        XCTAssertEqual(layers.gain, 0.5)
        // Released and loaded again (a reload, a switch back): it fades in again.
        layers.stopAll()
        layers.setContent([dc])
        XCTAssertEqual(layers.gain, 0)
    }

    /// A wallpaper that starts muted or paused has nothing to fade in, and a layer that starts
    /// silent stays silent once the fade-in ends.
    func testTheStartFadeInRespectsMuteAndStartSilent() throws {
        let muted = SceneSoundLayers(label: "test", offline: format)
        muted.setTarget(level: 0.8, audible: false)
        muted.setContent([content(try tone("tone.wav"))])
        XCTAssertEqual(muted.gain, 0)
        XCTAssertNil(muted.soundMixer, "no engine while muted")

        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 1, audible: true)
        var silent = content(try tone("silent.wav"))
        silent.sound.startSilent = true
        start(layers, [silent])
        XCTAssertEqual(layers.gain, 1)
        XCTAssertEqual(layers.isPlaying(7), false, "startsilent waits for a script")
    }

    /// The wallpaper's volume (WE's +0x178, 0x140114e20/0x140115361) applies at once; only being
    /// heard (WE's +0x174: mute, pause) fades.
    func testAVolumeChangeAppliesAtOnceAndOnlyMuteOrPauseFades() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 1, audible: true)
        start(layers, [content(try tone("tone.wav"))])
        layers.setTarget(level: 0.4, audible: true)
        XCTAssertEqual(layers.gain, 0.4, "no fade for a volume change")
        XCTAssertEqual(layers.playback(of: 7)?.sceneGain, 0.4)

        layers.setTarget(level: 0.4, audible: false)
        XCTAssertEqual(layers.gain, 0.4, "a mute fades out from where the sound was")
        layers.stepFade(1.0 / 60)
        XCTAssertEqual(layers.gain, 0.36, accuracy: 1e-6)

        // The app mutes by setting its volume to 0: the level is kept, and the sound fades.
        let muted = SceneSoundLayers(label: "test", offline: format)
        muted.setTarget(level: 0.8, audible: true)
        start(muted, [content(try tone("tone2.wav"))])
        muted.setTarget(level: 0, audible: true)
        XCTAssertEqual(muted.gain, 0.8)
        muted.stepFade(1.0 / 60)
        XCTAssertEqual(muted.gain, 0.72, accuracy: 1e-6)
    }

    /// WE's ease, stepped at 60 Hz: the gap shrinks by a tenth a frame and snaps once under 0.01,
    /// so a fade-out takes 45 frames (0.75 s) and a fade-in as long.
    func testFadeOutAndInFollowWEsEase() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 1, audible: true)
        start(layers, [content(try tone("tone.wav"))])

        layers.setTarget(level: 1, audible: false)
        var frames = 0, last = layers.gain
        while layers.gain > 0 {
            layers.stepFade(1.0 / 60)
            frames += 1
            if layers.gain > 0 { XCTAssertEqual(layers.gain / last, 0.9, accuracy: 1e-4, "frame \(frames)") }
            last = layers.gain
        }
        XCTAssertEqual(frames, 45, "silent after 0.75 s")
        XCTAssertEqual(layers.playback(of: 7)?.hasSoundingVoice, false, "paused once silent")

        layers.setTarget(level: 1, audible: true)
        layers.stepFade(1.0 / 60)
        XCTAssertEqual(layers.gain, 0.1, accuracy: 1e-6)
        XCTAssertEqual(layers.playback(of: 7)?.hasSoundingVoice, true, "resumed as the fade-in starts")
        frames = 1
        while layers.gain < 1 {
            layers.stepFade(1.0 / 60)
            frames += 1
        }
        XCTAssertEqual(frames, 45)
    }

    /// Each step of the fade sets the players' volume once a frame; the mixer ramps it sample by
    /// sample, so the envelope has no steps (a step would be a tenth of the level, a click).
    func testAFadeRampsSampleBySample() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 1, audible: true)
        start(layers, [content(try constant("dc.wav", value: 0.5, seconds: 1))])
        let level = 0.5 * SceneSoundSpatialization.monoLevel
        _ = try samples(layers, frames: 2048)

        layers.setTarget(level: 1, audible: false)
        var rendered: [Float] = []
        while layers.gain > 0.05 {
            layers.stepFade(1.0 / 60)
            let frame = try samples(layers, frames: 735)
            XCTAssertEqual(frame.last ?? 0, level * layers.gain, accuracy: 1e-3, "the frame ends at its gain")
            rendered += frame
        }
        let jumps = zip(rendered.dropFirst(), rendered).map { abs($0 - $1) }
        XCTAssertLessThan(jumps.max() ?? 1, level * 0.1 / 20, "no step: the first 10% drop spreads over many samples")
    }

    /// One looping file wraps with no gap and no discontinuity: a 0.1 s 440 Hz tone (44 whole
    /// cycles) rendered across its loop point changes no faster than the sine itself.
    func testTheLoopPointIsSeamless() throws {
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.setTarget(level: 1, audible: true)
        start(layers, [content(try tone("tone.wav"))])
        let rendered = try samples(layers, frames: 7_000)
        let first = try XCTUnwrap(rendered.firstIndex { $0 != 0 })
        let playing = Array(rendered[first...])
        XCTAssertGreaterThan(playing.count, 4_410 + 1_000, "renders past the loop point")
        let peak = playing.map(abs).max() ?? 0
        XCTAssertGreaterThan(peak, 0.5)
        let slope = 2 * Float.pi * 440 / 44_100 * peak
        let jumps = zip(playing.dropFirst(), playing).map { abs($0 - $1) }
        XCTAssertLessThanOrEqual(jumps.max() ?? 1, slope * 1.02, "no click at the loop point")
        var silentRun = 0, longest = 0
        for sample in playing {
            silentRun = abs(sample) < 1e-4 ? silentRun + 1 : 0
            longest = max(longest, silentRun)
        }
        XCTAssertLessThanOrEqual(longest, 1, "no gap: only the sine's own zero crossings")
    }

    func testTheBuilderFindsFilesAndLeavesOutWhatItCantDecode() throws {
        let loose = try tone("loose.wav", seconds: 0.5)
        let packaged = try Data(contentsOf: try tone("packaged.wav", seconds: 0.25))
        try Data("not audio".utf8).write(to: directory.appending(path: "broken.mp3"))
        let cache = directory.appending(path: "cache")
        let builder = SceneSoundContentBuilder(
            wallpaperDirectory: directory, packagedData: { $0 == "sounds/in-package.wav" ? packaged : nil },
            workshopURL: { _ in nil }, workshopData: { _ in nil }, cacheDirectory: cache)
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
            {"id": 3, "name": "Music", "sound": ["\#(loose.lastPathComponent)", "sounds/in-package.wav", "broken.mp3", "missing.mp3"],
             "volume": 0.5}
            """#.utf8))
        let sounds = builder.sounds(in: [object], context: StaticSceneValueContext())
        let sound = try XCTUnwrap(sounds.first)
        XCTAssertEqual(sound.id, 3)
        XCTAssertEqual(sound.volume, 0.5)
        XCTAssertEqual(sound.files.map(\.path), ["loose.wav", "sounds/in-package.wav"])
        XCTAssertEqual(sound.files[0].duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(sound.files[1].duration, 0.25, accuracy: 0.01)
        XCTAssertEqual(sound.files[1].url.deletingLastPathComponent().standardizedFileURL, cache.standardizedFileURL,
                       "a packaged file is read from its copy in the caches")
    }
}

/// No user properties: every binding takes its authored value.
private struct StaticSceneValueContext: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}
