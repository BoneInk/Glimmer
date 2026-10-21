import QuartzCore

/// What `WallpaperTransitionMetrics` measured for one transition.
struct WallpaperTransitionFrameSummary: Equatable, CustomStringConvertible {
    /// The intervals between a series of frame times.
    struct Intervals: Equatable {
        var frames: Int
        /// From the first frame to the last.
        var span: CFTimeInterval
        var p50: CFTimeInterval
        var p95: CFTimeInterval
        var maxInterval: CFTimeInterval
        /// Refreshes without a new frame: an interval of n refreshes drops n - 1.
        var dropped: Int

        init(_ times: [CFTimeInterval], refreshInterval: CFTimeInterval) {
            let times = times.sorted()
            let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
            frames = times.count
            span = (times.last ?? 0) - (times.first ?? 0)
            p50 = WallpaperTransitionFrameSummary.percentile(intervals, 0.5)
            p95 = WallpaperTransitionFrameSummary.percentile(intervals, 0.95)
            maxInterval = intervals.last ?? 0
            dropped = intervals.reduce(0) { $0 + max(Int(($1 / refreshInterval).rounded()) - 1, 0) }
        }
    }

    /// When frames were handed to the GPU to present.
    var submitted: Intervals
    /// When frames reached the screen; fewer when the window was covered or the compositor skipped one.
    var presented: Intervals
    var refreshInterval: CFTimeInterval
    /// Main-thread stalls of a refresh or more: how many, the longest and their sum.
    var stallCount: Int
    var stallMax: CFTimeInterval
    var stallTotal: CFTimeInterval

    init(submitted: [CFTimeInterval], presented: [CFTimeInterval], stalls: [CFTimeInterval],
         refreshInterval: CFTimeInterval) {
        self.submitted = Intervals(submitted, refreshInterval: refreshInterval)
        self.presented = Intervals(presented, refreshInterval: refreshInterval)
        self.refreshInterval = refreshInterval
        stallCount = stalls.count
        stallMax = stalls.max() ?? 0
        stallTotal = stalls.reduce(0, +)
    }

    /// The nearest-rank percentile of sorted `values`; 0 when there are none.
    static func percentile(_ values: [CFTimeInterval], _ fraction: Double) -> CFTimeInterval {
        guard !values.isEmpty else { return 0 }
        let rank = Int((fraction * Double(values.count)).rounded(.up))
        return values[min(max(rank, 1), values.count) - 1]
    }

    var description: String {
        func ms(_ value: CFTimeInterval) -> String { String(format: "%.1f", value * 1000) }
        func line(_ name: String, _ series: Intervals) -> String {
            "\(name) \(series.frames) frames over \(ms(series.span)) ms, interval p50 \(ms(series.p50)) "
                + "p95 \(ms(series.p95)) max \(ms(series.maxInterval)) ms, \(series.dropped) dropped"
        }
        return "\(line("submitted", submitted)); \(line("on screen", presented)) (refresh \(ms(refreshInterval)) ms); "
            + "main thread: \(stallCount) stalls, max \(ms(stallMax)) ms, total \(ms(stallTotal)) ms"
    }
}
