import AppKit

/// Tells a scheduled playlist (Time of day, Day of week) to look at the clock again when the Mac
/// wakes, the clock is set, the time zone changes or the day changes: a timer doesn't run while
/// the Mac sleeps, and a wall-clock time moves when the clock or the zone does. Nothing polls.
@MainActor
final class PlaylistClockObserver {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(onChange: @escaping @MainActor () -> Void) {
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        let observed: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
            (center, .NSSystemClockDidChange),
            (center, .NSSystemTimeZoneDidChange),
            (center, .NSCalendarDayChanged),
        ]
        tokens = observed.map { center, name in
            (center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            })
        }
    }

    deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
