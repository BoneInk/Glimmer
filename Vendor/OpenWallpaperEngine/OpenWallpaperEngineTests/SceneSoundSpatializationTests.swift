import XCTest
import AVFoundation
import simd
@testable import OpenWallpaperEngine

/// `spatialization` sound layers (`SceneSoundSpatialization`): wallpaper64.exe's placement in the
/// camera's frame (0x1401f5029…0x1401f53ff) through OpenAL Soft 1.21.1's inverse-distance-clamped
/// attenuation and stereo pair-wise panning, against values worked out by hand from those
/// formulas and against WE 2.8.0.42's capture on speakers (we-test-wp-images 9bd33fb,
/// tools/peer/requests/sound-spatialization/response: levels per channel relative to a plain mono
/// tone); the decoding and WE's defaults; a moving object through AVAudioEngine; no change for a
/// sound without spatialization or a stereo file; and a mono file's level against a stereo one's.
final class SceneSoundSpatializationTests: XCTestCase {
    /// A 1920×1080 orthographic scene's camera: eye (960, 540, 2000) looking down −z, y up.
    private let orthographic = SceneSoundSpatialization.Listener(
        eye: SIMD3(960, 540, 2000), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1),
        orthographicSize: SIMD2(1920, 1080))
    /// A perspective camera at the origin with the same axes.
    private let perspective = SceneSoundSpatialization.Listener(
        eye: .zero, right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1), orthographicSize: nil)

    private func assertGains(_ gains: SIMD2<Float>, _ left: Float, _ right: Float, _ message: String,
                             accuracy: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(gains.x, left, accuracy: accuracy, "left: \(message)", file: file, line: line)
        XCTAssertEqual(gains.y, right, accuracy: accuracy, "right: \(message)", file: file, line: line)
    }

    /// The gains relative to a plain mono source, as the capture reports them.
    private func gains(_ world: SIMD3<Float>, _ listener: SceneSoundSpatialization.Listener?,
                       minDistance: Float = 1, attenuation: Float = 1) -> SIMD2<Float> {
        SceneSoundSpatialization.gains(position: SceneSoundSpatialization.position(world: world, listener: listener),
                                       minDistance: minDistance, attenuation: attenuation)
            / SceneSoundSpatialization.monoLevel
    }

    /// WE's capture, project 1: a mono tone at x = 0, 192, …, 1920 (y 540, z 0), left and right.
    private let capturedPan: [SIMD2<Float>] = [
        SIMD2(1.0760, 0.3172), SIMD2(1.0053, 0.3761), SIMD2(0.9288, 0.4426), SIMD2(0.8476, 0.5162),
        SIMD2(0.7636, 0.5956), SIMD2(0.6788, 0.6788), SIMD2(0.5956, 0.7636), SIMD2(0.5162, 0.8476),
        SIMD2(0.4426, 0.9288), SIMD2(0.3761, 1.0053), SIMD2(0.3172, 1.0760),
    ]

    /// Project 2: centred, z = 750, 600, …, −750, `mindistance` 0.5, `attenuation` 2 (L = R).
    private let capturedDepth: [Float] = [1.0000, 0.6788, 0.6788, 0.4848, 0.3085, 0.2262, 0.1785, 0.1475, 0.1256,
                                          0.1094, 0.0969]

    func testMatchesWEsCapturedDepth() {
        for (step, level) in capturedDepth.enumerated() {
            let world = SIMD3<Float>(960, 540, 750 - Float(step) * 150)
            assertGains(gains(world, orthographic, minDistance: 0.5, attenuation: 2), level, level, "step \(step)",
                        accuracy: 2e-4)
        }
    }

    /// The captured pan has the model's sign, centre and shape, within 0.02.
    func testFollowsWEsCapturedPan() {
        for (step, level) in capturedPan.enumerated() {
            assertGains(gains(SIMD3(Float(step) * 192, 540, 0), orthographic), level.x, level.y, "step \(step)",
                        accuracy: 0.02)
        }
    }

    /// Toward the edges WE pans up to 0.018 harder than OpenAL Soft 1.21.1's formulas give for these
    /// positions; the dll's panning path is that code (see `SceneSoundSpatialization`).
    func testMatchesWEsCapturedPanClosely() {
        XCTExpectFailure("sound-spatialization capture: WE's edge pan is stronger than OpenAL Soft's pair-wise law for the modelled positions")
        for (step, level) in capturedPan.enumerated() {
            assertGains(gains(SIMD3(Float(step) * 192, 540, 0), orthographic), level.x, level.y, "step \(step)",
                        accuracy: 0.002)
        }
    }

    // MARK: - Decoding

    func testDecodesSpatializationAndWEsDefaults() throws {
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
            {"id": 4, "sound": ["sounds/a.mp3"], "spatialization": true, "attenuation": 2.5, "mindistance": 0.5}
            """#.utf8))
        let sound = try XCTUnwrap(object.sound)
        XCTAssertTrue(sound.spatialization)
        XCTAssertEqual(sound.attenuation?.literalDouble, 2.5)
        XCTAssertEqual(sound.minDistance?.literalDouble, 0.5)

        let plain = try XCTUnwrap(try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
            {"id": 5, "sound": ["sounds/a.mp3"]}
            """#.utf8)).sound)
        XCTAssertFalse(plain.spatialization, "off by default (0x140190645 leaves bit 2 clear)")
        XCTAssertNil(plain.attenuation)
        XCTAssertNil(plain.minDistance)
        let context = NoUserProperties()
        XCTAssertEqual(SceneSoundContentBuilder.value(plain.attenuation, in: context), 1, "0x14019062a")
        XCTAssertEqual(SceneSoundContentBuilder.value(plain.minDistance, in: context), 1, "0x140190634")
        XCTAssertEqual(SceneSoundContentBuilder.value(sound.attenuation, in: context), 2.5)
    }

    // MARK: - Placement and gains

    /// In a 2D scene only the direction pans: an object on the scene plane is 1 unit away, and
    /// WE's frame puts the scene (in front of the camera) behind OpenAL's listener.
    func testAnOrthographicSceneOnlyPans() {
        let centre = SceneSoundSpatialization.position(world: SIMD3(960, 540, 0), listener: orthographic)
        XCTAssertEqual(centre.x, 0, accuracy: 1e-6)
        XCTAssertEqual(centre.z, 1, accuracy: 1e-6, "(0, 0, 2000) scaled to (750 − 0) / 750")
        // Behind: az = π; each channel 0.5 − 0.0956623 of the centre's 0.5956623.
        assertGains(gains(SIMD3(960, 540, 0), orthographic), 0.678804, 0.678804, "the scene's centre")
        // Right edge: (960, 0, 2000) normalised; az = π − atan(960 / 2000), left
        // 0.5 − 0.5 · 0.432717 − 0.0956623 · 0.901518 = 0.197394.
        assertGains(gains(SIMD3(1920, 540, 0), orthographic), 0.331384, 1.057855, "the right edge")
        assertGains(gains(SIMD3(0, 540, 0), orthographic), 1.057855, 0.331384, "the left edge")
    }

    /// z moves a 2D sound: at z = 375 the distance is (750 − 375) / 750 = 0.5, which attenuates
    /// only below that `mindistance`: 0.25 / (0.25 + 1 · (0.5 − 0.25)) = 0.5.
    func testAnOrthographicSoundsZSetsItsDistance() {
        assertGains(gains(SIMD3(960, 540, 375), orthographic), 0.678804, 0.678804, "within mindistance 1")
        assertGains(gains(SIMD3(960, 540, 375), orthographic, minDistance: 0.25), 0.339402, 0.339402,
                    "half the gain at twice mindistance")
    }

    /// OpenAL's inverse distance, clamped: `mindistance / (mindistance + attenuation · (d − mindistance))`.
    func testDistanceAttenuationAndPanningInPerspective() {
        // 3 units right: hard right (az = π/2), gain 1 / (1 + 2).
        assertGains(gains(SIMD3(3, 0, 0), perspective), 0, 0.559601, "right, defaults")
        // mindistance 2, attenuation 0.5: 2 / (2 + 0.5) = 0.8.
        assertGains(gains(SIMD3(3, 0, 0), perspective, minDistance: 2, attenuation: 0.5), 0, 1.343043, "right, 2 / 0.5")
        // Straight up 5 units: cos ev = 0 leaves 0.5 a channel, gain 1 / 5.
        assertGains(gains(SIMD3(0, 5, 0), perspective), 0.167880, 0.167880, "above")
        // A negative value is refused by alSourcef, which keeps SFML's 1.
        assertGains(gains(SIMD3(3, 0, 0), perspective, minDistance: -1, attenuation: -2), 0, 0.559601, "refused")
        // mindistance 0 turns attenuation off.
        assertGains(gains(SIMD3(3, 0, 0), perspective, minDistance: 0), 0, 1.678804, "no attenuation")
        // At the listener: centred, the plain level.
        assertGains(gains(.zero, perspective), 1, 1, "at the eye")
    }

    /// Before a frame has a camera, WE puts the sound at (0, 0, 100000): all but silent.
    func testNoCameraYetIsFarAway() {
        let far = gains(SIMD3(960, 540, 0), nil)
        XCTAssertEqual(far.x, 6.788e-6, accuracy: 1e-8)
        XCTAssertEqual(far.y, far.x, accuracy: 1e-10)
    }

    /// The listener axes come from the frame camera's view matrix.
    func testTheListenerReadsTheFrameCamera() {
        var camera = SceneFrameCamera()
        camera.eye = SIMD3(1, 2, 3)
        camera.forward = SIMD3(0, 0, -1)
        let listener = SceneSoundSpatialization.Listener(camera: camera, orthographicSize: nil)
        XCTAssertEqual(listener.right, SIMD3(1, 0, 0))
        XCTAssertEqual(listener.up, SIMD3(0, 1, 0))
        XCTAssertEqual(listener.eye, SIMD3(1, 2, 3))
    }

    // MARK: - Through AVAudioEngine

    private var directory: URL!
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-spatial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// A one-second full-scale 440 Hz tone with `channels` channels.
    private func tone(_ name: String, channels: AVAudioChannelCount, rate: Double = 48_000) throws -> URL {
        let url = directory.appending(path: name)
        let fileFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let frames = AVAudioFrameCount(rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = Float(sin(2 * Double.pi * 440 * Double(index) / rate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        try file.write(from: buffer)
        return url
    }

    private func layers(spatialization: Bool, channels: AVAudioChannelCount, rate: Double = 48_000,
                        at world: @escaping () -> SIMD3<Float>) throws -> SceneSoundLayers {
        let url = try tone("tone\(channels)-\(Int(rate)).wav", channels: channels, rate: rate)
        let layers = SceneSoundLayers(label: "test", offline: format)
        layers.listener = orthographic
        layers.locate = { _ in world() }
        layers.setTargetGain(1)
        let sound = WESceneSound(files: ["sounds/tone.wav"], spatialization: spatialization)
        layers.setContent([SceneSoundContent(
            id: 9, name: "tone", sound: sound,
            files: [SceneSoundContent.File(path: "sounds/tone.wav", url: url, duration: 1, channels: Int(channels))],
            volume: 1)])
        // Past OWE's start fade-in, at full volume.
        for _ in 0..<60 { layers.stepFade(1.0 / 60) }
        return layers
    }

    /// Left and right RMS of 0.05 s rendered offline, after 0.05 s that let the mixer's ramps to
    /// new gains settle.
    private func render(_ layers: SceneSoundLayers) throws -> SIMD2<Float> {
        let engine = try XCTUnwrap(layers.soundMixer?.engine)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 2400))
        XCTAssertEqual(try engine.renderOffline(2400, to: buffer), .success)
        XCTAssertEqual(try engine.renderOffline(2400, to: buffer), .success)
        var sums = SIMD2<Float>.zero
        for index in 0..<Int(buffer.frameLength) {
            let left = buffer.floatChannelData![0][index], right = buffer.floatChannelData![1][index]
            sums += SIMD2(left * left, right * right)
        }
        return (sums / Float(buffer.frameLength)).squareRoot()
    }

    /// A mono sound moving from the left edge to the right one crosses from the left speaker to
    /// the right, by the ratios worked out above, against the same file unspatialized.
    func testAMovingObjectPansAcross() throws {
        let plain = try render(try layers(spatialization: false, channels: 1, at: { .zero }))
        var world = SIMD3<Float>(0, 540, 0)
        let moving = try layers(spatialization: true, channels: 1, at: { world })
        let left = try render(moving)
        XCTAssertEqual(left.x / plain.x, 1.057855, accuracy: 0.01)
        XCTAssertEqual(left.y / plain.y, 0.331384, accuracy: 0.01)
        world = SIMD3(960, 540, 0)
        moving.update(deltaTime: 1.0 / 60)
        let centre = try render(moving)
        XCTAssertEqual(centre.x / plain.x, 0.678804, accuracy: 0.01)
        XCTAssertEqual(centre.y / plain.y, 0.678804, accuracy: 0.01)
        world = SIMD3(1920, 540, 0)
        moving.update(deltaTime: 1.0 / 60)
        let right = try render(moving)
        XCTAssertEqual(right.x / plain.x, 0.331384, accuracy: 0.01)
        XCTAssertEqual(right.y / plain.y, 1.057855, accuracy: 0.01)
    }

    /// Without spatialization a sound plays as before wherever its object is; with it, a stereo
    /// file does too, since OpenAL Soft places only mono sources.
    func testNoChangeWithoutSpatializationOrForStereo() throws {
        let plainMono = try render(try layers(spatialization: false, channels: 1, at: { .zero }))
        let movedMono = try render(try layers(spatialization: false, channels: 1, at: { SIMD3(1920, 540, 900) }))
        XCTAssertEqual(movedMono.x, plainMono.x, accuracy: 1e-5)
        XCTAssertEqual(movedMono.y, plainMono.y, accuracy: 1e-5)
        XCTAssertEqual(plainMono.x, plainMono.y, accuracy: 1e-5)

        let plainStereo = try render(try layers(spatialization: false, channels: 2, at: { .zero }))
        let spatialStereo = try layers(spatialization: true, channels: 2, at: { SIMD3(1920, 540, 900) })
        let stereo = try render(spatialStereo)
        XCTAssertEqual(stereo.x, plainStereo.x, accuracy: 1e-5)
        XCTAssertEqual(stereo.y, plainStereo.y, accuracy: 1e-5)
    }

    /// WE plays a stereo tone at 1.6789× the same tone in mono in each channel (project 3 against
    /// project 4): OpenAL's centred mono source, 0.595662 a channel. Ours does at any file rate
    /// (AVAudioMixerNode alone upmixes mono at 0.707 or 1 depending on its rate).
    func testAMonoFilePlaysAtOpenALsMonoLevel() throws {
        for rate in [44_100.0, 48_000.0] {
            let mono = try render(try layers(spatialization: false, channels: 1, rate: rate, at: { .zero }))
            let stereo = try render(try layers(spatialization: false, channels: 2, rate: rate, at: { .zero }))
            XCTAssertEqual(stereo.x / mono.x, 1.6789, accuracy: 0.002, "left at \(rate) Hz")
            XCTAssertEqual(stereo.y / mono.y, 1.6789, accuracy: 0.002, "right at \(rate) Hz")
        }
    }
}

/// No user properties: every binding takes its authored value.
private struct NoUserProperties: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}
