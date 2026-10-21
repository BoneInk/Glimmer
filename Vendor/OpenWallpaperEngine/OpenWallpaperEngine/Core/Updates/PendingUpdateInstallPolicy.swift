import Foundation

/// When a silently downloaded update is installed. Sparkle installs it when the app quits, but
/// Open Wallpaper Engine runs in the background and rarely quits, so an update that is ready is
/// also installed (the app relaunches, restoring its wallpapers, in a couple of seconds):
/// - once the user has been away from the Mac for `idleThreshold`, so nobody sees the wallpaper
///   blink, or
/// - at the latest `maximumWait` after it became ready, whatever the user is doing.
struct PendingUpdateInstallPolicy: Equatable {
    var idleThreshold: TimeInterval = 10 * 60
    var maximumWait: TimeInterval = 24 * 60 * 60
    /// How often the ready update is reconsidered.
    var pollInterval: TimeInterval = 5 * 60

    func shouldInstall(readySince: Date, now: Date, userIdleSeconds: TimeInterval) -> Bool {
        userIdleSeconds >= idleThreshold || now.timeIntervalSince(readySince) >= maximumWait
    }
}
