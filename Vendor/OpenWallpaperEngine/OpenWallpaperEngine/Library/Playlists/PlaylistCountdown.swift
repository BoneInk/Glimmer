import Foundation

/// A timer playlist's time to the next wallpaper. Without "Allow wallpaper to change while paused"
/// (WE's `updateonpause`) it stands still while the wallpaper is paused and runs on from where it
/// stopped when it plays again.
struct PlaylistCountdown: Equatable {
    /// The time left when it last stopped, or when it started.
    private(set) var remaining: TimeInterval
    /// When it last started running; nil while it stands still.
    private(set) var runningSince: Date?

    init(duration: TimeInterval) {
        remaining = max(duration, 0)
    }

    var isRunning: Bool { runningSince != nil }

    mutating func run(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    mutating func pause(at now: Date) {
        guard let since = runningSince else { return }
        remaining = max(remaining - now.timeIntervalSince(since), 0)
        runningSince = nil
    }

    /// When the wallpaper changes while it keeps running; nil while it stands still.
    var fireDate: Date? { runningSince.map { $0.addingTimeInterval(remaining) } }
}
