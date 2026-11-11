import Foundation

/// A single-frame-in-flight cadence. Work consumes the current period instead
/// of adding another period; missed deadlines are skipped without catch-up frames.
struct SceneFrameSchedule {
    private(set) var deadline: ContinuousClock.Instant
    private let interval: Duration

    init(framesPerSecond: Int, now: ContinuousClock.Instant, immediately: Bool = false) {
        precondition((1...240).contains(framesPerSecond))
        interval = .seconds(1 / Double(framesPerSecond))
        deadline = immediately ? now : now.advanced(by: interval)
    }

    /// Call after the complete frame, including GPU consumption and ACK.
    mutating func advance(after now: ContinuousClock.Instant) {
        deadline = deadline.advanced(by: interval)
        if deadline <= now {
            let missedPeriods = Int64((deadline.duration(to: now) / interval).rounded(.down)) + 1
            deadline = deadline.advanced(by: interval * missedPeriods)
        }
    }
}
