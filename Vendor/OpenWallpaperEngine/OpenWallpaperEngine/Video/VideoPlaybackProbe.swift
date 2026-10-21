import Foundation

/// Turns once-a-second samples of an `AVPlayer` into frame times for the render watchdog, without
/// touching a frame: `AVPlayerLayer` decodes and draws out of process, so there is no per-frame
/// callback, and copying frames through `AVPlayerItemVideoOutput` would cost more than it measures.
///
/// Over each interval the frames shown are the media time played at the track's frame rate, less
/// the frames the item's access log says were dropped. Playback that barely advances while the
/// player is meant to play counts as one frame as long as the interval. Paused playback, a loop
/// or seek (media time going back) and a late sample (the Mac slept) judge nothing.
struct VideoPlaybackProbe {
    struct Sample {
        /// Uptime, seconds.
        var time: TimeInterval
        /// The item's current time, seconds.
        var mediaTime: Double
        /// The player's rate; 0 while paused.
        var rate: Float
        /// Total dropped frames from the item's access log, or nil when it keeps none.
        var droppedFrames: Int?
        /// The video track's current frame rate, or 0 when unknown.
        var frameRate: Double
    }

    /// Used when the track reports no rate: the lowest common one, so drops are never overstated.
    static let fallbackFrameRate = 24.0
    /// Playing less than this share of the expected media time is a stall.
    static let stallRatio = 0.1
    /// A sample this long after the last one was delayed (sleep, a stalled main thread that the
    /// ping already covers); it measures nothing about playback.
    static let maximumInterval: TimeInterval = 5

    private var last: Sample?

    /// Takes a sample; returns the frame time it implies, or nil when there is nothing to judge.
    mutating func frameDuration(after sample: Sample) -> TimeInterval? {
        defer { last = sample }
        guard let last, last.rate > 0, sample.rate > 0 else { return nil }
        let elapsed = sample.time - last.time
        let played = sample.mediaTime - last.mediaTime
        guard elapsed > 0, elapsed <= Self.maximumInterval, played >= 0, played.isFinite else { return nil }
        let expected = Double(sample.rate) * elapsed
        if played < expected * Self.stallRatio { return elapsed }
        let rate = sample.frameRate > 0 ? sample.frameRate : Self.fallbackFrameRate
        var dropped = 0
        if let now = sample.droppedFrames, let before = last.droppedFrames, now >= before { dropped = now - before }
        let shown = played * rate - Double(dropped)
        return shown >= 1 ? elapsed / shown : elapsed
    }

    /// Forgets the previous sample (a new item started).
    mutating func reset() { last = nil }
}
