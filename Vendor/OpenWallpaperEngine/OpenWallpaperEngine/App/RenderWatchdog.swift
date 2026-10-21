//
//  RenderWatchdog.swift
//  Open Wallpaper Engine
//

import Foundation
import QuartzCore

/// Notices when a running wallpaper makes the app (and usually the Mac) unusable, so it can be
/// unloaded before the user has to force-quit.
///
/// Two cheap signals, both judged over sustained windows and only after a grace period that
/// covers first load and shader compilation:
/// - the main thread not answering a ping from a background queue for `mainThreadStall`;
/// - the median wallpaper frame time over the last `frameWindow` exceeding `slowFrameMedian`.
///
/// Frame times come from the scene renderer (CPU time per frame, including video drawn through
/// the scene pipeline), from web wallpapers (`requestAnimationFrame` intervals, posted once a
/// second) and from `AVPlayer` videos (`VideoPlaybackProbe`: how far playback advanced, and the
/// frames it dropped, once a second, without copying frames).
///
/// A third signal covers a web page whose JavaScript hangs outright and so posts no frames at
/// all: a source that promised a heartbeat (`recordHeartbeat(from:expectingMore: true)`: its page
/// is visible and its window on screen) and then stays silent for `heartbeatTimeout` trips like
/// lag. A hidden page, an occluded window or sleeping displays promise nothing. The page runs in
/// WebKit's own process, so the main-thread ping never sees it.
///
/// The clock is uptime-based (`CACurrentMediaTime`), so system sleep never reads as a stall.
///
/// Thread safety: `lock` owns every stored `var`. `recordFrame` is called from render callbacks,
/// the poll runs on a private queue, and `arm`/`disarm` come from the main actor.
final class RenderWatchdog: @unchecked Sendable {
    struct Thresholds {
        var gracePeriod: TimeInterval = 20
        var mainThreadStall: TimeInterval = 3
        var slowFrameMedian: TimeInterval = 0.25
        var frameWindow: TimeInterval = 10
        var minimumFrameSamples = 5
        var pollInterval: TimeInterval = 0.5
        /// A web page posts every second while visible; this much silence means it is hung.
        var heartbeatTimeout: TimeInterval = 10
    }

    enum Trip: Equatable {
        case mainThreadStalled(seconds: TimeInterval)
        case slowFrames(medianSeconds: TimeInterval)
        case heartbeatStopped(seconds: TimeInterval)
    }

    let thresholds: Thresholds
    private let clock: () -> TimeInterval
    private let lock = NSLock()
    private var armedAt: TimeInterval?
    private var hasTripped = false
    private var frames: [(time: TimeInterval, duration: TimeInterval)] = []
    private var pingSentAt: TimeInterval?
    /// Per heartbeat source: when it last promised another beat, or nil while it promises none.
    private var heartbeats: [ObjectIdentifier: TimeInterval?] = [:]
    private var timer: DispatchSourceTimer?

    init(thresholds: Thresholds = Thresholds(), clock: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.thresholds = thresholds
        self.clock = clock
    }

    deinit { timer?.cancel() }

    // MARK: - Arming

    /// Starts watching a newly shown wallpaper; the grace period starts now.
    func arm() {
        lock.withLock {
            armedAt = clock()
            hasTripped = false
            frames.removeAll(keepingCapacity: true)
            pingSentAt = nil
        }
    }

    /// Stops watching: nothing is showing.
    func disarm() {
        lock.withLock {
            armedAt = nil
            frames.removeAll()
            pingSentAt = nil
        }
    }

    // MARK: - Measurements

    /// One wallpaper frame took `duration` seconds to produce.
    func recordFrame(duration: TimeInterval) {
        lock.withLock {
            guard let armedAt, !hasTripped else { return }
            let now = clock()
            guard now >= armedAt + thresholds.gracePeriod else { return }
            frames.append((now, duration))
            pruneFrames(now: now)
        }
    }

    /// A ping to the main thread was sent; returns false when one is still unanswered.
    @discardableResult
    func mainThreadPingSent() -> Bool {
        lock.withLock {
            guard armedAt != nil, pingSentAt == nil else { return false }
            pingSentAt = clock()
            return true
        }
    }

    /// The main thread answered the outstanding ping.
    func mainThreadPongReceived() {
        lock.withLock { pingSentAt = nil }
    }

    /// `source` is alive now. `expectingMore` says whether it will keep beating: false while its
    /// page is hidden, its window is off screen or the displays sleep.
    func recordHeartbeat(from source: ObjectIdentifier, expectingMore: Bool) {
        lock.withLock { heartbeats[source] = .some(expectingMore ? clock() : nil) }
    }

    /// `source` is gone (its wallpaper was torn down).
    func endHeartbeat(from source: ObjectIdentifier) {
        lock.withLock { heartbeats[source] = nil }
    }

    // MARK: - Judgement

    /// Returns a trip once per arming when either signal is degraded past its threshold.
    func evaluate() -> Trip? {
        lock.withLock {
            guard let armedAt, !hasTripped else { return nil }
            let now = clock()
            let graceEnd = armedAt + thresholds.gracePeriod
            guard now >= graceEnd else { return nil }

            if let pingSentAt {
                // A ping sent during the grace period only counts from its end.
                let stall = now - max(pingSentAt, graceEnd)
                if stall > thresholds.mainThreadStall {
                    hasTripped = true
                    return .mainThreadStalled(seconds: stall)
                }
            }

            // A beat promised during the grace period only counts from its end.
            let silence = heartbeats.values.compactMap { $0.map { now - max($0, graceEnd) } }.max() ?? 0
            if silence > thresholds.heartbeatTimeout {
                hasTripped = true
                return .heartbeatStopped(seconds: silence)
            }

            pruneFrames(now: now)
            guard now - graceEnd >= thresholds.frameWindow,
                  frames.count >= thresholds.minimumFrameSamples else { return nil }
            let median = Self.median(frames.map(\.duration))
            if median > thresholds.slowFrameMedian {
                hasTripped = true
                return .slowFrames(medianSeconds: median)
            }
            return nil
        }
    }

    // MARK: - Polling

    /// Polls on a background queue and reports a trip on the main actor.
    func start(onTrip: @escaping @MainActor (Trip) -> Void) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "OpenWallpaperEngine.RenderWatchdog",
                                                                        qos: .utility))
        let interval = thresholds.pollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let trip = self.evaluate() {
                DispatchQueue.main.async { onTrip(trip) }
            }
            if self.mainThreadPingSent() {
                DispatchQueue.main.async { [weak self] in self?.mainThreadPongReceived() }
            }
        }
        timer.resume()
        self.timer = timer
    }

    // MARK: - Helpers

    private func pruneFrames(now: TimeInterval) {
        let cutoff = now - thresholds.frameWindow
        if let firstKept = frames.firstIndex(where: { $0.time >= cutoff }) {
            if firstKept > 0 { frames.removeFirst(firstKept) }
        } else {
            frames.removeAll(keepingCapacity: true)
        }
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
