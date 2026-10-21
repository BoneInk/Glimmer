import XCTest
@testable import OpenWallpaperEngine

/// WE's audio spectrum as `wallpaper64.exe` computes it: the capture thread's block DFT and bands
/// (`AudioSpectrumBlockTransform`) and the render loop's gain, smoothing and resolutions
/// (`AudioSpectrumSmoothing`).
final class AudioSpectrumTests: XCTestCase {
    private let frame = 1.0 / 60

    private func sine(bin: Double, length: Int, sampleRate: Double = 48_000, amplitude: Float = 0.5,
                      count: Int) -> [Float] {
        let frequency = bin * sampleRate / Double(length)
        return (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    // MARK: - Capture half

    func testBluesteinMatchesADirectDFT() throws {
        let length = 37
        // All bins, and the first 12 on the smaller padding the spectrum uses.
        for bins in [length, 12] {
        let dft = try XCTUnwrap(BluesteinDFT(length: length, bins: bins))
        let real = (0..<length).map { Float(sin(Double($0) * 0.7) + 0.3) }
        let imaginary = (0..<length).map { Float(cos(Double($0) * 1.3)) * 0.5 }
        var power = [Float](repeating: 0, count: bins)
        dft.powerSpectrum(real: real, imaginary: imaginary, into: &power)
        for k in 0..<bins {
            var re = 0.0, im = 0.0
            for n in 0..<length {
                let angle = -2 * Double.pi * Double(n * k) / Double(length)
                re += Double(real[n]) * cos(angle) - Double(imaginary[n]) * sin(angle)
                im += Double(real[n]) * sin(angle) + Double(imaginary[n]) * cos(angle)
            }
            XCTAssertEqual(Double(power[k]), re * re + im * im, accuracy: 1e-3 * max(1, re * re + im * im), "bins \(bins), bin \(k)")
        }
        }
    }

    func testBlockLengthFollowsTheSampleRate() {
        XCTAssertEqual(AudioSpectrumBlockTransform.blockLength(sampleRate: 44_100), 1920)
        XCTAssertEqual(AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000), 2089)
        XCTAssertEqual(AudioSpectrumBlockTransform.blockLength(sampleRate: 22_050), 1920, "never shorter than at 44.1 kHz")
    }

    func testBandMapGivesTheLowestBandsOneBinEach() {
        let bands = AudioSpectrumBlockTransform.bandMap()
        XCTAssertEqual(bands.count, 640)
        XCTAssertEqual(Array(bands[1...16]), Array(0...15))
        for bin in 2..<639 {
            XCTAssertGreaterThanOrEqual(bands[bin], bands[bin - 1], "bin \(bin)")
            XCTAssertLessThanOrEqual(bands[bin], bands[bin - 1] + 1, "bin \(bin)")
        }
        XCTAssertEqual(bands[639], 63, "t stops at 638/639, so the modulo never wraps")
        let weights = AudioSpectrumBlockTransform.weights()
        XCTAssertEqual(weights[1], 0.002, accuracy: 1e-5)
        XCTAssertEqual(weights[639], 1, accuracy: 1e-5)
    }

    func testToneLandsInItsBandOnItsChannel() throws {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        let length = transform.blockLength
        let bin = 200
        let band = AudioSpectrumBlockTransform.bandMap()[bin]
        let left = sine(bin: Double(bin), length: length, count: length)
        let raw = transform.spectrum(left: left, right: [Float](repeating: 0, count: length))
        XCTAssertEqual(raw.count, 128)
        let leftBands = Array(raw[0..<64])
        XCTAssertEqual(leftBands.firstIndex(of: leftBands.max()!), band)
        // 127 · amplitude · L/2 · √w · 0.001 · N/(L/2), with w = 0.501 − 0.499·cos(π·199/639).
        let weight = 0.501 - 0.499 * cos(Double.pi * 199 / 639)
        XCTAssertEqual(Double(raw[band]), 127 * 0.5 * weight.squareRoot() * 0.64, accuracy: 0.01 * Double(raw[band]))
        XCTAssertLessThan(raw[64..<128].max()!, raw[band] * 1e-3, "the right channel is silent")
    }

    func testTheBufferThatCompletesABlockIsNotCarriedOver() throws {
        let transform = try XCTUnwrap(AudioSpectrumBlockTransform(sampleRate: 48_000))
        let chunk = [Float](repeating: 0.1, count: 1000)
        func append() -> [Float]? {
            chunk.withUnsafeBufferPointer { transform.append(left: $0, right: $0) }
        }
        XCTAssertNil(append())
        XCTAssertNil(append())
        XCTAssertNotNil(append(), "3000 samples complete a 2089-sample block")
        XCTAssertNil(append(), "the 911 left over were dropped, like the rest of WE's WASAPI packet")
        XCTAssertNil(append())
        XCTAssertNotNil(append())
    }

    // MARK: - Render half

    private func raw(left: [Int: Float] = [:], right: [Int: Float] = [:]) -> [Float] {
        var values = [Float](repeating: 0, count: 128)
        for (band, value) in left { values[band] = value }
        for (band, value) in right { values[64 + band] = value }
        return values
    }

    func testRiseIsLimitedPerFrameAndTheLevelSettlesToOne() {
        var smoothing = AudioSpectrumSmoothing()
        let input = raw(left: [3: 5])
        // Frame 1: the level resets to 1, so the value is 5; smoothed = 5 · 20/60; the output rises
        // by at most 40/60.
        let first = smoothing.advance(raw: input, deltaTime: frame)
        XCTAssertEqual(first.left64[3], Float(40.0 / 60), accuracy: 1e-5)
        var snapshot = first
        for _ in 0..<600 { snapshot = smoothing.advance(raw: input, deltaTime: frame) }
        XCTAssertEqual(snapshot.left64[3], 1, accuracy: 1e-3, "the group's level follows its peak")
        XCTAssertEqual(snapshot.right64.max()!, 0, accuracy: 1e-6)
    }

    func testValuesCanExceedOneWhileTheLevelCatchesUp() {
        var smoothing = AudioSpectrumSmoothing()
        for _ in 0..<600 { _ = smoothing.advance(raw: raw(left: [3: 1]), deltaTime: frame) }
        var snapshot = AudioSpectrumSnapshot.silent
        for _ in 0..<10 { snapshot = smoothing.advance(raw: raw(left: [3: 4]), deltaTime: frame) }
        XCTAssertGreaterThan(snapshot.left64[3], 1, "the level rises by at most one frame time a frame")
    }

    func testSilenceIsZeroAtOnce() {
        var smoothing = AudioSpectrumSmoothing()
        for _ in 0..<30 { _ = smoothing.advance(raw: raw(left: [3: 5], right: [40: 2]), deltaTime: frame) }
        let silent = smoothing.advance(raw: raw(), deltaTime: frame)
        XCTAssertEqual(silent, .silent)
    }

    func testAveragesAndCoarserResolutions() {
        var smoothing = AudioSpectrumSmoothing()
        var snapshot = AudioSpectrumSnapshot.silent
        for _ in 0..<600 {
            snapshot = smoothing.advance(raw: raw(left: [2: 1, 3: 0.5, 9: 1], right: [2: 1, 20: 1]), deltaTime: frame)
        }
        for band in 0..<64 {
            XCTAssertEqual(snapshot.average64[band], (snapshot.left64[band] + snapshot.right64[band]) / 2, accuracy: 1e-6)
        }
        for band in 0..<32 {
            XCTAssertEqual(snapshot.left32[band], max(snapshot.left64[2 * band], snapshot.left64[2 * band + 1]))
            XCTAssertEqual(snapshot.average32[band], max(snapshot.average64[2 * band], snapshot.average64[2 * band + 1]),
                           "a coarser average is the pair maximum, not the mean of left and right")
        }
        for band in 0..<16 {
            XCTAssertEqual(snapshot.right16[band], max(snapshot.right32[2 * band], snapshot.right32[2 * band + 1]))
            XCTAssertEqual(snapshot.average16[band], max(snapshot.average32[2 * band], snapshot.average32[2 * band + 1]))
        }
        XCTAssertEqual(snapshot.averages(bands: 16), snapshot.average16)
        XCTAssertNil(snapshot.averages(bands: 128))
    }

    // MARK: - Analyzer

    func testAnalyzerTurnsALeftToneIntoLeftBands() throws {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000)
        let length = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let tone = sine(bin: 120, length: length, count: length)
        let quiet = [Float](repeating: 0, count: length)
        tone.withUnsafeBufferPointer { left in quiet.withUnsafeBufferPointer { analyzer.ingest(left: left, right: $0) } }
        var snapshot = AudioSpectrumSnapshot.silent
        // The group's level climbs from 1 to the raw peak (≈ 12) by one frame time a frame.
        for _ in 0..<900 { snapshot = analyzer.advanceFrame(deltaTime: frame) }
        let band = AudioSpectrumBlockTransform.bandMap()[120]
        XCTAssertEqual(snapshot.left64.firstIndex(of: snapshot.left64.max()!), band)
        XCTAssertEqual(snapshot.left64[band], 1, accuracy: 0.01)
        XCTAssertLessThan(snapshot.right64.max()!, 0.01)
        XCTAssertEqual(analyzer.snapshot, snapshot)

        analyzer.reset()
        XCTAssertEqual(analyzer.advanceFrame(deltaTime: frame), .silent, "stopped capture is silent at once")
    }

    func testAnalyzerTimesFramesWithTheClock() {
        var now = 100.0
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000, uptime: { now })
        let length = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let tone = sine(bin: 120, length: length, count: length)
        tone.withUnsafeBufferPointer { analyzer.ingest(left: $0, right: $0) }
        let band = AudioSpectrumBlockTransform.bandMap()[120]
        let first = analyzer.advanceFrame()
        XCTAssertEqual(first.left64[band], 0.004, accuracy: 1e-5, "the first frame steps by WE's minimum, 0.0001 · 40")
        now += 1.0 / 60
        let second = analyzer.advanceFrame()
        XCTAssertEqual(second.left64[band] - first.left64[band], Float(40.0 / 60), accuracy: 1e-4)
    }

    /// WE smooths by the scene's frame time, which the playback rate scales (0x1401114c3): at rate
    /// 2 a 1/120 s frame steps as far as a 1/60 s frame at rate 1.
    func testPlaybackRateScalesTheAnalyzersStep() {
        var now = 100.0
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000, uptime: { now })
        let length = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let tone = sine(bin: 120, length: length, count: length)
        tone.withUnsafeBufferPointer { analyzer.ingest(left: $0, right: $0) }
        let band = AudioSpectrumBlockTransform.bandMap()[120]
        let first = analyzer.advanceFrame(playbackRate: 2)
        now += 1.0 / 120
        let second = analyzer.advanceFrame(playbackRate: 2)
        XCTAssertEqual(second.left64[band] - first.left64[band], Float(40.0 / 60), accuracy: 1e-4)
    }
}
