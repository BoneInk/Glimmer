import Foundation

/// One consumer's WE audio spectrum: its own `AudioSpectrumSmoothing`, stepped by its own frames
/// from the shared raw block (`AudioSpectrumFeed`). WE smooths once per frame of the thing that
/// shows the values, so every scene renderer and every web page owns one: stepping a shared state
/// from several consumers would advance it several times a frame, and a consumer that nobody else
/// advances (a web page on its own) would never move.
///
/// Threading: `lock` owns `smoothing`, `current` and `lastAdvance`; any thread may advance, though
/// each consumer normally does from one.
final class AudioSpectrumClock {
    private let feed: AudioSpectrumFeed
    /// Whether frames go to `AudioSpectrumFeed.publishedFrame` (scenes; SceneScript reads it).
    private let publishes: Bool
    private let uptime: () -> TimeInterval

    private let lock = NSLock()
    private var smoothing = AudioSpectrumSmoothing()
    private var current = AudioSpectrumSnapshot.silent
    private var lastAdvance: TimeInterval?

    init(feed: AudioSpectrumFeed, publishes: Bool,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.feed = feed
        self.publishes = publishes
        self.uptime = uptime
    }

    /// Advances by one frame, timed by the monotonic clock. Call exactly once per frame.
    /// WE steps the smoothing by the scene's frame time, which its playback rate scales
    /// (`SceneClock`, 0x1401114c3): the monotonic step, clamped as WE clamps its frame, times
    /// `playbackRate`.
    func advanceFrame(playbackRate: Double = 1) -> AudioSpectrumSnapshot {
        let raw = feed.latestRaw
        lock.lock()
        let now = uptime()
        // The first frame has no predecessor; WE's clamp turns 0 into its minimum step.
        let frame: Double = lastAdvance.map { now - $0 } ?? 0
        let clamped: Double = min(max(frame, SceneClock.minimumFrameDelta), SceneClock.maximumFrameDelta)
        lastAdvance = now
        let result = step(raw: raw, deltaTime: clamped * playbackRate)
        lock.unlock()
        if publishes { feed.publish(result) }
        return result
    }

    /// Advances by one frame of `deltaTime` seconds.
    func advanceFrame(deltaTime: Double) -> AudioSpectrumSnapshot {
        let raw = feed.latestRaw
        lock.lock()
        lastAdvance = uptime()
        let result = step(raw: raw, deltaTime: deltaTime)
        lock.unlock()
        if publishes { feed.publish(result) }
        return result
    }

    /// This consumer's latest frame, without advancing.
    var snapshot: AudioSpectrumSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Under `lock`.
    private func step(raw: [Float], deltaTime: Double) -> AudioSpectrumSnapshot {
        current = smoothing.advance(raw: raw, deltaTime: deltaTime)
        return current
    }
}
