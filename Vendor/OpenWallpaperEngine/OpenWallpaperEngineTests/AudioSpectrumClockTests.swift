import CoreMedia
import XCTest
@testable import OpenWallpaperEngine

/// Every consumer of WE's spectrum (a scene renderer, a web page) smooths the shared raw block on
/// its own clock (`AudioSpectrumClock`), and the capture stream's video side stays minimal.
final class AudioSpectrumClockTests: XCTestCase {
    private let frame: Double = 1.0 / 60

    private func analyzerHearingATone() -> AudioSpectrumAnalyzer {
        let analyzer = AudioSpectrumAnalyzer(sampleRate: 48_000)
        let length: Int = AudioSpectrumBlockTransform.blockLength(sampleRate: 48_000)
        let frequency: Double = 120 * 48_000 / Double(length)
        let tone: [Float] = (0..<length).map { index in
            0.5 * Float(sin(2 * Double.pi * frequency * Double(index) / 48_000))
        }
        tone.withUnsafeBufferPointer { analyzer.ingest(left: $0, right: $0) }
        return analyzer
    }

    /// A web page with nothing else running used to read a snapshot that only a scene advanced,
    /// so it heard 128 zeros forever.
    func testAClockNobodyElseAdvancesHearsTheTone() {
        let analyzer = analyzerHearingATone()
        let web: AudioSpectrumClock = analyzer.makeClock(publishes: false)
        var snapshot = AudioSpectrumSnapshot.silent
        for _ in 0..<30 { snapshot = web.advanceFrame(deltaTime: 1.0 / 30) }
        let band: Int = AudioSpectrumBlockTransform.bandMap()[120]
        let left: Float = snapshot.left64[band]
        let right: Float = snapshot.right64[band]
        XCTAssertGreaterThan(left, 0.1)
        XCTAssertGreaterThan(right, 0.1)
        XCTAssertEqual(web.snapshot, snapshot)
        XCTAssertEqual(analyzer.snapshot, .silent, "a web page's frames are not the scenes' frame")
    }

    /// Two scenes each stepping once a frame see what one scene alone sees; a shared smoothing
    /// state used to be stepped once per scene per frame.
    func testConsumersDoNotStepEachOther() {
        let analyzer = analyzerHearingATone()
        let alone: AudioSpectrumClock = analyzer.makeClock(publishes: false)
        let first: AudioSpectrumClock = analyzer.makeClock(publishes: true)
        let second: AudioSpectrumClock = analyzer.makeClock(publishes: true)
        for _ in 0..<5 {
            let expected: AudioSpectrumSnapshot = alone.advanceFrame(deltaTime: frame)
            let one: AudioSpectrumSnapshot = first.advanceFrame(deltaTime: frame)
            let two: AudioSpectrumSnapshot = second.advanceFrame(deltaTime: frame)
            XCTAssertEqual(one, expected)
            XCTAssertEqual(two, expected)
            XCTAssertEqual(analyzer.snapshot, expected, "SceneScript reads the scenes' frame")
        }
    }

    /// A clock that pauses (a paused scene) doesn't hold back one that keeps running (a web page).
    func testAPausedConsumerDoesNotFreezeAnother() {
        let analyzer = analyzerHearingATone()
        let scene: AudioSpectrumClock = analyzer.makeClock(publishes: true)
        let web: AudioSpectrumClock = analyzer.makeClock(publishes: false)
        let paused: AudioSpectrumSnapshot = scene.advanceFrame(deltaTime: frame)
        let before: AudioSpectrumSnapshot = web.advanceFrame(deltaTime: 1.0 / 30)
        let after: AudioSpectrumSnapshot = web.advanceFrame(deltaTime: 1.0 / 30)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(scene.snapshot, paused)
    }

    func testStoppedCaptureSilencesEveryConsumer() {
        let analyzer = analyzerHearingATone()
        let scene: AudioSpectrumClock = analyzer.makeClock(publishes: true)
        let web: AudioSpectrumClock = analyzer.makeClock(publishes: false)
        _ = scene.advanceFrame(deltaTime: frame)
        _ = web.advanceFrame(deltaTime: frame)
        analyzer.reset()
        XCTAssertEqual(scene.advanceFrame(deltaTime: frame), .silent)
        XCTAssertEqual(web.advanceFrame(deltaTime: frame), .silent)
    }

    /// ScreenCaptureKit has no audio-only mode; the video side must not capture the display at
    /// its refresh rate.
    func testCaptureStreamKeepsItsVideoSideMinimal() {
        let configuration = SystemAudioCapture.streamConfiguration()
        XCTAssertTrue(configuration.capturesAudio)
        XCTAssertEqual(configuration.sampleRate, 48_000)
        XCTAssertEqual(configuration.channelCount, 2)
        XCTAssertEqual(configuration.width, 2)
        XCTAssertEqual(configuration.height, 2)
        XCTAssertFalse(configuration.showsCursor)
        let interval: Double = CMTimeGetSeconds(configuration.minimumFrameInterval)
        XCTAssertEqual(interval, 1)
    }
}
