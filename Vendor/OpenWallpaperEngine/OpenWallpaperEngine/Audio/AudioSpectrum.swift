import Foundation

/// One frame of WE's audio spectrum: `g_AudioSpectrum{16,32,64}{Left,Right}` for shaders and the
/// `left`/`right`/`average` arrays of SceneScript's `registerAudioBuffers`. WE fills one buffer
/// that both read (`AudioSpectrumSmoothing`). Values are normally 0…1 but can exceed 1.
struct AudioSpectrumSnapshot: Equatable {
    var left16: [Float]
    var right16: [Float]
    var left32: [Float]
    var right32: [Float]
    var left64: [Float]
    var right64: [Float]
    var average16 = [Float](repeating: 0, count: 16)
    var average32 = [Float](repeating: 0, count: 32)
    var average64 = [Float](repeating: 0, count: 64)

    static let silent = AudioSpectrumSnapshot(
        left16: [Float](repeating: 0, count: 16), right16: [Float](repeating: 0, count: 16),
        left32: [Float](repeating: 0, count: 32), right32: [Float](repeating: 0, count: 32),
        left64: [Float](repeating: 0, count: 64), right64: [Float](repeating: 0, count: 64))

    /// The array for a band count and channel, or nil for a count WE doesn't define.
    func values(bands: Int, right: Bool) -> [Float]? {
        switch bands {
        case 16: return right ? right16 : left16
        case 32: return right ? right32 : left32
        case 64: return right ? right64 : left64
        default: return nil
        }
    }

    /// The `average` array for a band count, or nil for a count WE doesn't define.
    func averages(bands: Int) -> [Float]? {
        switch bands {
        case 16: return average16
        case 32: return average32
        case 64: return average64
        default: return nil
        }
    }
}

/// WE's audio spectrum from stereo PCM: `AudioSpectrumBlockTransform` on the audio thread turns
/// blocks of samples into raw band values (`AudioSpectrumFeed`), and each consumer's
/// `AudioSpectrumClock` turns the latest block into its frames' arrays with
/// `AudioSpectrumSmoothing`. Both follow `wallpaper64.exe` (see their docs).
///
/// Threading: `ingest` runs on the audio thread and owns `transform`; the feed and the clocks own
/// their own locks.
final class AudioSpectrumAnalyzer {
    static let rawCount = 2 * AudioSpectrumBlockTransform.bandCount

    private let feed = AudioSpectrumFeed()
    private let uptime: () -> TimeInterval
    /// The analyzer's own publishing clock, for `advanceFrame`.
    private let frames: AudioSpectrumClock

    // Audio-thread only.
    private let transform: AudioSpectrumBlockTransform?

    /// `sampleRate` is the capture stream's.
    init(sampleRate: Double = 48_000,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        transform = AudioSpectrumBlockTransform(sampleRate: sampleRate)
        self.uptime = uptime
        frames = AudioSpectrumClock(feed: feed, publishes: true, uptime: uptime)
        if transform == nil {
            OWELog.error(.audio, "Audio spectrum DFT setup failed for \(sampleRate) Hz; the spectrum stays silent")
        }
    }

    /// WE's "Recording threshold" setting (0…10; `AudioSpectrumBlockTransform.threshold`), set from
    /// any thread; the audio thread takes it with the next buffer. `thresholdLock` owns it.
    var recordingThreshold: Double {
        get { thresholdLock.withLock { pendingThreshold } }
        set { thresholdLock.withLock { pendingThreshold = newValue } }
    }
    private let thresholdLock = NSLock()
    private var pendingThreshold: Double = 0

    /// WE's "Recording volume" setting (`audioinputvolume`, 0…200, default 50;
    /// `AudioSpectrumBlockTransform.inputVolume(setting:)`), set from any thread; the audio thread
    /// takes it with the next buffer. `thresholdLock` owns it too.
    var recordingVolume: Double {
        get { thresholdLock.withLock { pendingVolume } }
        set { thresholdLock.withLock { pendingVolume = newValue } }
    }
    private var pendingVolume = AudioSpectrumBlockTransform.defaultVolumeSetting

    /// Adds one buffer of non-interleaved float samples. Pass the same buffer twice for mono.
    func ingest(left: UnsafeBufferPointer<Float>, right: UnsafeBufferPointer<Float>) {
        let (threshold, volume) = thresholdLock.withLock { (pendingThreshold, pendingVolume) }
        transform?.threshold = AudioSpectrumBlockTransform.threshold(setting: threshold)
        transform?.inputVolume = AudioSpectrumBlockTransform.inputVolume(setting: volume)
        guard let raw = transform?.append(left: left, right: right) else { return }
        feed.setLatestRaw(raw)
    }

    /// Capture stopped: WE's processor hands out zeros while it isn't running, which silences
    /// every consumer's next frame.
    func reset() {
        feed.setLatestRaw([Float](repeating: 0, count: Self.rawCount))
    }

    /// A new consumer with its own smoothing, fed by this analyzer. `publishes`: its frames are what
    /// `snapshot` returns (scenes, whose SceneScripts read it).
    func makeClock(publishes: Bool) -> AudioSpectrumClock {
        AudioSpectrumClock(feed: feed, publishes: publishes, uptime: uptime)
    }

    /// Advances the analyzer's own clock by one frame (`AudioSpectrumClock.advanceFrame(playbackRate:)`).
    func advanceFrame(playbackRate: Double = 1) -> AudioSpectrumSnapshot {
        frames.advanceFrame(playbackRate: playbackRate)
    }

    /// Advances the analyzer's own clock by one frame of `deltaTime` seconds.
    func advanceFrame(deltaTime: Double) -> AudioSpectrumSnapshot {
        frames.advanceFrame(deltaTime: deltaTime)
    }

    /// The latest frame any publishing clock advanced to, without advancing.
    var snapshot: AudioSpectrumSnapshot { feed.publishedFrame }
}
