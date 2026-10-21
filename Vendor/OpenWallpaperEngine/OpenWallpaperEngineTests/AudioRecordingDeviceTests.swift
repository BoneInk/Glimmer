import XCTest
@testable import OpenWallpaperEngine

/// WE's Settings › Audio "Audio recording device" (`audioinputdevice`, default "default") and
/// "Recording volume" (`audioinputvolume`, slider 0…200, default 50, × 0.02 on the spectrum).
final class AudioRecordingDeviceTests: XCTestCase {
    // MARK: Recording volume

    func testTheVolumeSettingScalesTheSpectrumByAFiftieth() {
        XCTAssertEqual(AudioSpectrumBlockTransform.inputVolume(setting: 50), 1)
        XCTAssertEqual(AudioSpectrumBlockTransform.inputVolume(setting: 200), 4)
        XCTAssertEqual(AudioSpectrumBlockTransform.inputVolume(setting: 0), 0)
        XCTAssertEqual(AudioSpectrumBlockTransform.inputVolume(setting: -5), 0)
        XCTAssertEqual(AudioSpectrumBlockTransform.defaultVolumeSetting, 50)
    }

    func testABoostedFixtureToneDoublesEveryBand() throws {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        let length = transform.blockLength
        let frequency = 200 * 48_000 / Double(length)
        let tone: [Float] = (0..<length).map { 0.25 * Float(sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
        let normal = transform.spectrum(left: tone, right: tone)
        transform.inputVolume = AudioSpectrumBlockTransform.inputVolume(setting: 100)
        let boosted = transform.spectrum(left: tone, right: tone)
        XCTAssertGreaterThan(normal.max() ?? 0, 0)
        for (plain, louder) in zip(normal, boosted) {
            XCTAssertEqual(louder, plain * 2, accuracy: max(plain * 1e-5, 1e-9))
        }
    }

    func testTheAnalyzerKeepsTheVolumeForTheNextBuffer() {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000)
        XCTAssertEqual(analyzer.recordingVolume, 50, "WE's default")
        analyzer.recordingVolume = 120
        XCTAssertEqual(analyzer.recordingVolume, 120)
    }

    // MARK: Settings

    func testTheDefaultsAreWEs() {
        let settings = GlobalSettings()
        XCTAssertNil(settings.audioRecordingDevice, "WE's \"default\": the system output")
        XCTAssertEqual(settings.audioRecordingVolume, 50)
    }

    func testTheChoicesAreStoredAndAVolumeOutOfRangeIsClamped() throws {
        var settings = GlobalSettings()
        settings.audioRecordingDevice = AudioInputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        settings.audioRecordingVolume = 140
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.audioRecordingDevice, settings.audioRecordingDevice)
        XCTAssertEqual(decoded.audioRecordingVolume, 140)

        let stored = Data(#"{"audioRecordingVolume": 900}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(GlobalSettings.self, from: stored).audioRecordingVolume, 200)
        let old = Data("{}".utf8)
        XCTAssertNil(try JSONDecoder().decode(GlobalSettings.self, from: old).audioRecordingDevice)
    }

    // MARK: Backends

    func testAChosenDeviceComesFirstOnlyWithTheMicrophonePermission() {
        let granted = SystemAudioBackend.candidates(tapSupported: true, tapPermission: .authorized,
                                                    screenRecordingGranted: false,
                                                    inputDevice: "mic", microphoneGranted: true)
        XCTAssertEqual(granted, [.inputDevice(uid: "mic"), .processTap], "the system output stays as the fallback")
        let denied = SystemAudioBackend.candidates(tapSupported: true, tapPermission: .authorized,
                                                   screenRecordingGranted: false,
                                                   inputDevice: "mic", microphoneGranted: false)
        XCTAssertEqual(denied, [.processTap])
        let onlyMicrophone = SystemAudioBackend.candidates(tapSupported: true, tapPermission: .denied,
                                                           screenRecordingGranted: false,
                                                           inputDevice: "mic", microphoneGranted: true)
        XCTAssertEqual(onlyMicrophone, [.inputDevice(uid: "mic")])
        let systemOutput = SystemAudioBackend.candidates(tapSupported: true, tapPermission: .authorized,
                                                         screenRecordingGranted: true, microphoneGranted: true)
        XCTAssertEqual(systemOutput, [.processTap, .screenCapture])
    }

    // MARK: Devices

    func testListedDevicesCanBeFoundAgainByTheirUID() {
        for device in AudioInputDevices.list() {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertNotNil(AudioInputDevices.deviceID(uid: device.uid), device.name)
            XCTAssertGreaterThan(AudioInputDevices.inputChannelCount(of: AudioInputDevices.deviceID(uid: device.uid)!), 0)
        }
    }

    func testADisconnectedDeviceFailsToStart() {
        let capture = InputDeviceAudioCapture(uid: "no-such-device-\(UUID().uuidString)",
                                              consume: { _, _ in }, onInterruption: { _ in })
        XCTAssertThrowsError(try capture.start())
        capture.stop()
    }
}
