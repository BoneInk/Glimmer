import Foundation

/// When the broker (`owe-saver-broker`) launches the app for a saver that shows while the app
/// isn't running: only during a real screen saver session, a saver asked (the extension for the
/// app's endpoint, the `.saver` by its Darwin `saverAlive`), the app isn't running, and it wasn't
/// launched within `retryInterval` (a launch that is still starting, or one that failed, isn't
/// repeated every second). Times are seconds on one monotonic clock.
///
/// A real session is loginwindow's `didstart` without `runFromPref` until `willstop`, `didstop` or
/// an unlock. System Settings hosts savers too: for the picker's thumbnail and the full-size view it
/// shows when one is selected (no `didstart` at all, and the view's preview flag says false), and
/// for Preview (`didstart` with `runFromPref` 1). None of those launches the app; their views show
/// the still. The broker runs from login on (`RunAtLoad`, `KeepAlive`) so it hears every `didstart`.
struct LiveSaverLaunchPolicy: Equatable {
    /// A launch isn't repeated within this long.
    static let retryInterval: TimeInterval = 20

    private(set) var lastLaunch: TimeInterval?
    /// Between a real session's `didstart` and its end.
    private(set) var sessionRuns = false

    /// loginwindow posted `didstart`; `fromPreferences` is its `runFromPref` (System Settings' Preview).
    mutating func screenSaverStarted(fromPreferences: Bool) {
        sessionRuns = !fromPreferences
    }

    /// `willstop`, `didstop` or an unlock.
    mutating func screenSaverStopped() {
        sessionRuns = false
    }

    /// Whether to launch the app now; records the launch when so.
    mutating func shouldLaunch(at now: TimeInterval, appRunning: Bool) -> Bool {
        guard sessionRuns, !appRunning else { return false }
        if let lastLaunch, now - lastLaunch < Self.retryInterval { return false }
        lastLaunch = now
        return true
    }

    /// `didstart`'s `runFromPref`, however it is written (a number, a boolean or text).
    static func isFromPreferences(_ userInfo: [AnyHashable: Any]?) -> Bool {
        switch userInfo?["runFromPref"] {
        case let number as NSNumber: return number.boolValue
        case let text as String: return text == "1" || text.lowercased() == "true" || text.lowercased() == "yes"
        default: return false
        }
    }
}
