import Foundation

/// The shared half of WE's audio spectrum: the latest raw block (left 64, right 64) that capture
/// produced, which every consumer's `AudioSpectrumClock` smooths on its own clock, and the last
/// frame a scene published for readers that don't advance (SceneScript's `registerAudioBuffers`).
///
/// Threading: `lock` owns `raw` and `published`; any thread may call any member.
final class AudioSpectrumFeed {
    private let lock = NSLock()
    private var raw = [Float](repeating: 0, count: AudioSpectrumAnalyzer.rawCount)
    private var published = AudioSpectrumSnapshot.silent

    /// The latest raw block; zeros while capture isn't running.
    var latestRaw: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return raw
    }

    func setLatestRaw(_ values: [Float]) {
        lock.lock()
        raw = values
        lock.unlock()
    }

    /// The last frame a publishing clock advanced to.
    var publishedFrame: AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    func publish(_ frame: AudioSpectrumSnapshot) {
        lock.lock()
        published = frame
        lock.unlock()
    }
}
