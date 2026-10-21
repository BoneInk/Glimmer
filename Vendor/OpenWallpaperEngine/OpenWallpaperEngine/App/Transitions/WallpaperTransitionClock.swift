import QuartzCore

/// WE's transition clock: it starts when the change asked for the transition, its setup
/// included, holds the start for a lead-in (wallpaper64's transition window), then runs over the
/// duration: `max(0, elapsed - 0.1) / duration`.
struct WallpaperTransitionClock: Equatable, Sendable {
    /// When the change asked for it (`CACurrentMediaTime`).
    let startTime: CFTimeInterval
    let duration: TimeInterval

    static let leadIn: CFTimeInterval = 0.1

    init(startTime: CFTimeInterval, duration: TimeInterval) {
        self.startTime = startTime
        self.duration = max(duration, 0.001)
    }

    /// The progress at `time` (`CACurrentMediaTime`), 0...1.
    func progress(at time: CFTimeInterval) -> Float {
        Float(min(max((time - startTime - Self.leadIn) / duration, 0), 1))
    }

    /// When the progress reaches 1.
    var end: CFTimeInterval { startTime + Self.leadIn + duration }
}
