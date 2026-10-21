import AVFoundation
import CoreAudio
import XCTest
@testable import OpenWallpaperEngine

/// With the default "Audio recording device" (the system output), nothing the app does with
/// sound may ask for the microphone. A client of a device that also records (a headset) makes
/// coreaudiod check the Microphone permission, so wallpaper sound plays on the default output
/// device without its inputs (`OutputOnlyAudioDevice`), the scene engine never makes its own
/// hardware output, and only a chosen recording device is ever recorded.
final class AudioMicrophoneUseTests: XCTestCase {
    func testTheDefaultSettingNeverRecordsAnInputDevice() {
        for permission in [SystemAudioRecordingPermission.Status.authorized, .unknown, .notDetermined, .denied] {
            for screenRecording in [true, false] {
                let candidates = SystemAudioBackend.candidates(tapSupported: true, tapPermission: permission,
                                                               screenRecordingGranted: screenRecording,
                                                               inputDevice: nil, microphoneGranted: true)
                XCTAssertFalse(candidates.contains { if case .inputDevice = $0 { return true } else { return false } },
                               "\(permission), screen recording \(screenRecording): \(candidates)")
            }
        }
    }

    func testWallpaperSoundPlaysOnAStackedDeviceWithOnlyTheOutput() throws {
        let description = OutputOnlyAudioDevice.aggregateDescription(outputUID: "headset", uid: "owe-output")
        XCTAssertEqual(description[kAudioAggregateDeviceIsStackedKey] as? Bool, true, "a stack exposes only its sub-devices' outputs")
        XCTAssertEqual(description[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(description[kAudioAggregateDeviceMainSubDeviceKey] as? String, "headset")
        let subDevices = try XCTUnwrap(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        XCTAssertEqual(subDevices.map { $0[kAudioSubDeviceUIDKey] as? String }, ["headset"])
        XCTAssertNil(description[kAudioAggregateDeviceTapListKey], "no tap: nothing is recorded")
    }

    /// The real device, on a Mac with an output device: it has no input stream for coreaudiod to
    /// check the microphone for, whatever the default output device records.
    func testTheOutputOnlyDeviceHasNoInputs() throws {
        let device = OutputOnlyAudioDevice()
        guard let id = device.deviceID else { throw XCTSkip("no output device on this Mac") }
        XCTAssertEqual(OutputOnlyAudioDevice.inputStreamCount(of: id), 0)
        XCTAssertNotNil(device.sampleRate)
        let player = WallpaperAVPlayer.make(output: device)
        XCTAssertEqual(player.audioOutputDeviceUniqueID, device.uid, "video wallpapers play on it too")
    }

    /// The test host is the app: its video players play on the output-only device too, or every
    /// freshly signed test build asked for the microphone on a Mac whose output is a headset.
    /// Scene sound layers stay silent or offline in tests.
    @MainActor
    func testTheTestHostsPlayersUseTheOutputOnlyDevice() throws {
        let services = WallpaperServices.shared
        XCTAssertNil(services.sceneSoundOutput, "sound layers never play live in a test host")
        guard let output = services.soundOutput, let id = output.deviceID else { throw XCTSkip("no output device on this Mac") }
        XCTAssertEqual(OutputOnlyAudioDevice.inputStreamCount(of: id), 0)
        XCTAssertEqual(WallpaperAVPlayer.make().audioOutputDeviceUniqueID, output.uid)
        XCTAssertEqual(VideoLoop().player.audioOutputDeviceUniqueID, output.uid, "muted previews are routed too")
    }

    /// Every player the app makes is routed (`WallpaperAVPlayer`): a file that makes an `AVPlayer`
    /// or an `AVQueuePlayer` routes it.
    func testEveryPlayerTheAppMakesIsRouted() throws {
        let sources = AppIdentityLintTests.repository.appending(path: "OpenWallpaperEngine")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("AVPlayer(") || text.contains("AVQueuePlayer(") else { continue }
            checked += 1
            XCTAssertTrue(text.contains("WallpaperAVPlayer.route(") || url.lastPathComponent == "WallpaperAVPlayer.swift",
                          "\(url.lastPathComponent) makes a player without routing it to the output-only device")
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// The scene engine renders manually, so it never opens the default output device itself.
    func testSceneSoundNeverMakesItsOwnHardwareOutput() {
        let live = SceneSoundMixer(label: "test", device: nil)
        XCTAssertTrue(live.engine.isInManualRenderingMode)
        XCTAssertEqual(live.engine.manualRenderingMode, .realtime)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        let offline = SceneSoundMixer(label: "test", offline: format, device: nil)
        XCTAssertEqual(offline.engine.manualRenderingMode, .offline)
    }

    /// The output copies left and right into the device's first two channels, silence elsewhere.
    func testTheOutputCopiesStereoIntoTheDevicesChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        source.frameLength = 4
        for frame in 0..<4 {
            source.floatChannelData![0][frame] = 1
            source.floatChannelData![1][frame] = 0.5
        }
        // One interleaved buffer of four channels, two frames written at frame 1.
        var samples = [Float](repeating: 9, count: 3 * 4)
        samples.withUnsafeMutableBytes { bytes in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(mNumberChannels: 4, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            ManualRenderingOutput.Renderer.copy(source, frames: 2, into: list, at: 1)
        }
        XCTAssertEqual(Array(samples[0..<4]), [9, 9, 9, 9], "frames before the offset are untouched")
        XCTAssertEqual(Array(samples[4..<12]), [1, 0.5, 0, 0, 1, 0.5, 0, 0])
        // Nothing rendered (the engine paused): silence.
        var silent = [Float](repeating: 9, count: 2)
        silent.withUnsafeMutableBytes { bytes in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            ManualRenderingOutput.Renderer.copy(nil, frames: 2, into: list, at: 0)
        }
        XCTAssertEqual(silent, [0, 0])
    }

    /// At another device rate, the IO callback resamples without allocating (realtime safe), and
    /// gives the frames `AVAudioConverter` gives, failed engine renders included.
    func testResamplingOutputAllocatesNothingAndMatchesAVAudioConverter() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // Callback sizes, one past the engine's largest render, and three engine renders that fail.
        let sizes: [Int] = [512, 471, 5000, 128] + Array(repeating: 512, count: 28)
        let failing: Set<Int> = [3, 4, 20]
        let known: Int = AllocationCounter.count { _ = NSMutableArray(capacity: 8).count }
        XCTAssertGreaterThan(known, 0, "the allocation counter sees allocations")
        for rate in [44_100.0, 96_000.0] {
            let renderer = try XCTUnwrap(ManualRenderingOutput.Renderer(render: Self.tone(failing: failing), format: format,
                                                                         deviceRate: rate))
            let reference = try XCTUnwrap(ReferenceResampler(render: Self.tone(failing: failing), format: format, deviceRate: rate))
            for (index, frames) in sizes.enumerated() {
                let output = try Self.callbackBuffers(frames: frames)
                let expected = try Self.callbackBuffers(frames: frames)
                defer { Self.release(output); Self.release(expected) }
                // The first callback may set up the converter's state.
                let allocations: Int = AllocationCounter.count { renderer.fill(output.unsafeMutablePointer) }
                if index > 0 { XCTAssertEqual(allocations, 0, "callback \(index) of \(frames) frames at \(rate) Hz allocated") }
                reference.fill(expected.unsafeMutablePointer)
                for channel in 0..<2 {
                    let got = UnsafeBufferPointer(start: output[channel].mData!.assumingMemoryBound(to: Float.self), count: frames)
                    let want = UnsafeBufferPointer(start: expected[channel].mData!.assumingMemoryBound(to: Float.self), count: frames)
                    XCTAssertEqual(Array(got), Array(want), "callback \(index), channel \(channel) at \(rate) Hz")
                }
            }
        }
    }

    /// A test engine: two sines (left, right), failing on the `failing` calls (1-based).
    private static func tone(failing: Set<Int>) -> AVAudioEngineManualRenderingBlock {
        var phase = 0
        var call = 0
        return { frames, list, _ in
            call += 1
            guard !failing.contains(call) else { return .insufficientDataFromInputNode }
            for (channel, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                let step: Float = channel == 0 ? 0.031 : 0.017
                for frame in 0..<Int(frames) { samples[frame] = sinf(Float(phase + frame) * step) / 2 }
            }
            phase += Int(frames)
            return .success
        }
    }

    /// Two non-interleaved device channels of `frames` frames.
    private static func callbackBuffers(frames: Int) throws -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        for channel in 0..<2 {
            let bytes = frames * MemoryLayout<Float>.size
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: try XCTUnwrap(calloc(1, bytes)))
        }
        return list
    }

    private static func release(_ list: UnsafeMutableAudioBufferListPointer) {
        for buffer in list { Darwin.free(buffer.mData) }
        Darwin.free(list.unsafeMutablePointer)
    }
}

/// The output's resampling as `AVAudioConverter` does it, chunked like the IO callback: what the
/// realtime path must match.
private final class ReferenceResampler {
    private let render: AVAudioEngineManualRenderingBlock
    private let engineBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter
    private let deviceFormat: AVAudioFormat

    init?(render: @escaping AVAudioEngineManualRenderingBlock, format: AVAudioFormat, deviceRate: Double) {
        guard let engineBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: ManualRenderingOutput.maximumFrameCount),
              let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2),
              let converter = AVAudioConverter(from: format, to: deviceFormat) else { return nil }
        self.render = render
        self.engineBuffer = engineBuffer
        self.converter = converter
        self.deviceFormat = deviceFormat
    }

    func fill(_ output: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        var done = 0
        while done < frames {
            let chunk = min(frames - done, Int(ManualRenderingOutput.maximumFrameCount))
            ManualRenderingOutput.Renderer.copy(produce(AVAudioFrameCount(chunk)), frames: chunk, into: buffers, at: done)
            done += chunk
        }
    }

    private func produce(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: deviceFormat, frameCapacity: frames) else { return nil }
        var failed = false
        let status = converter.convert(to: buffer, error: nil) { [self] packets, inputStatus in
            let count = min(packets, ManualRenderingOutput.maximumFrameCount)
            engineBuffer.frameLength = count
            var error: OSStatus = noErr
            guard render(count, engineBuffer.mutableAudioBufferList, &error) == .success else {
                failed = true
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return engineBuffer
        }
        return failed || status == .error ? nil : buffer
    }
}

/// Counts heap allocations on the calling thread (`malloc_logger`, the hook malloc stack logging uses).
private enum AllocationCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    private static var counted = 0
    private static var thread: pthread_t?
    /// `MALLOC_LOG_TYPE_ALLOCATE`.
    private static let allocate: UInt32 = 2
    private static let logger: Logger = { type, _, _, _, _, _ in
        guard type & AllocationCounter.allocate != 0, let thread = AllocationCounter.thread,
              pthread_equal(pthread_self(), thread) != 0 else { return }
        AllocationCounter.counted += 1
    }

    static func count(_ body: () -> Void) -> Int {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1 }
        let hook = symbol.assumingMemoryBound(to: Logger?.self)
        counted = 0
        thread = pthread_self()
        hook.pointee = logger
        body()
        hook.pointee = nil
        thread = nil
        return counted
    }
}
