import XCTest
@testable import OpenWallpaperEngine

/// WE's "Recording threshold" (`audioinputthreshold`): a capture packet whose highest first-channel
/// sample stays below the setting × 0.001 gives an all-zero spectrum and drops the block collected
/// so far (`wallpaper64.exe` 0x1400d1a15…0x1400d1ae5, 0x1400d1f25).
final class AudioRecordingThresholdTests: XCTestCase {
    /// A fixture tone: `amplitude` at DFT bin 200 of a 48 kHz block.
    private func tone(amplitude: Float, count: Int, length: Int) -> [Float] {
        let frequency = 200 * 48_000 / Double(length)
        return (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / 48_000)) }
    }

    private func spectrum(_ samples: [Float], threshold: Double, packet: Int = 512) throws -> [Float]? {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        transform.threshold = AudioSpectrumBlockTransform.threshold(setting: threshold)
        var result: [Float]?
        var start = 0
        while start < samples.count {
            let packetSamples = Array(samples[start..<min(start + packet, samples.count)])
            if let raw = packetSamples.withUnsafeBufferPointer({ transform.append(left: $0, right: $0) }) { result = raw }
            start += packet
        }
        return result
    }

    func testTheSettingIsASampleLevelInThousandths() {
        XCTAssertEqual(AudioSpectrumBlockTransform.threshold(setting: 0), 0)
        XCTAssertEqual(AudioSpectrumBlockTransform.threshold(setting: 10), 0.01, accuracy: 1e-7)
        XCTAssertEqual(AudioSpectrumBlockTransform.threshold(setting: 2.5), 0.0025, accuracy: 1e-7)
    }

    func testAQuietFixtureSpectrumIsSilencedAndALoudOneIsNot() throws {
        let length = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let quiet = tone(amplitude: 0.004, count: length + 100, length: length)
        let loud = tone(amplitude: 0.5, count: length + 100, length: length)

        // Off (WE's default 0): even the quiet tone reaches the bands.
        let open = try XCTUnwrap(try spectrum(quiet, threshold: 0))
        XCTAssertGreaterThan(open.max()!, 0)

        // 5 → 0.005: the 0.004 tone is below it in every packet, so every packet publishes zeros.
        let gated = try XCTUnwrap(try spectrum(quiet, threshold: 5))
        XCTAssertEqual(gated, [Float](repeating: 0, count: 128))

        // The loud tone passes the same gate unchanged.
        let passed = try XCTUnwrap(try spectrum(loud, threshold: 5))
        let ungated = try XCTUnwrap(try spectrum(loud, threshold: 0))
        XCTAssertEqual(passed, ungated)
    }

    func testAQuietPacketDropsTheBlockBeingCollected() throws {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        transform.threshold = AudioSpectrumBlockTransform.threshold(setting: 1)
        let loud = [Float](repeating: 0.5, count: 1000)
        let silent = [Float](repeating: 0, count: 10)
        func append(_ samples: [Float]) -> [Float]? { samples.withUnsafeBufferPointer { transform.append(left: $0, right: $0) } }
        XCTAssertNil(append(loud))
        XCTAssertNil(append(loud))
        XCTAssertEqual(append(silent), [Float](repeating: 0, count: 128))
        // The 2000 samples before the quiet packet were dropped: 2089 more are needed for a block.
        XCTAssertNil(append(loud))
        XCTAssertNil(append(loud))
        XCTAssertNotNil(append(loud))
    }

    func testOnlyTheFirstChannelsPositivePeakCounts() throws {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        transform.threshold = AudioSpectrumBlockTransform.threshold(setting: 1)
        // A loud right channel, or a loud negative swing, doesn't open the gate: WE reads the raw
        // first-channel sample, not its magnitude.
        let quietLeft = [Float](repeating: -0.5, count: 64)
        let loudRight = [Float](repeating: 0.9, count: 64)
        let raw = quietLeft.withUnsafeBufferPointer { left in
            loudRight.withUnsafeBufferPointer { right in transform.append(left: left, right: right) }
        }
        XCTAssertEqual(raw, [Float](repeating: 0, count: 128))
    }

    func testTheAnalyzerTakesTheSettingWithTheNextBuffer() {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000)
        XCTAssertEqual(analyzer.recordingThreshold, 0)
        analyzer.recordingThreshold = 4.2
        XCTAssertEqual(analyzer.recordingThreshold, 4.2)
        let settings = GlobalSettings()
        XCTAssertEqual(settings.audioRecordingThreshold, 0, "off by default, as in WE")
    }
}
