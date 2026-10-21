import Foundation

/// What an application rule's load action shows while the rule matches (WE's `loadwallpaper`,
/// `loadplaylist` and `loadprofile`, whose target the rule stores in `file`).
struct ApplicationRuleLoad: Equatable {
    enum Kind: String, Equatable {
        case wallpaper, playlist, profile
    }

    var kind: Kind
    /// The wallpaper's folder, the playlist's id or the profile's name.
    var file: String
}

/// Where application rules load wallpapers, playlists and profiles, and put back what was shown.
@MainActor
protocol ApplicationRuleLoadTarget: AnyObject {
    /// What is shown now: the displays' wallpapers, the playlist and the profile state.
    associatedtype RestorePoint
    func restorePoint() -> RestorePoint
    /// Shows `load`; false when it can't (the wallpaper, playlist or profile is gone).
    func load(_ load: ApplicationRuleLoad) -> Bool
    func restore(_ point: RestorePoint)
}

/// Applies the load the matching application rules ask for, and restores what was shown before
/// when no rule asks for one any more, as WE does when the application quits, loses focus or
/// leaves the display.
///
/// What was shown is recorded once, just before the first load. Another load replacing it (a
/// different rule now matches first) keeps that record, so the restore goes back to the state
/// before any rule loaded something, not to another rule's.
@MainActor
final class ApplicationRuleLoader<Target: ApplicationRuleLoadTarget> {
    private let target: Target
    /// The load shown now; nil while no rule loads anything.
    private(set) var current: ApplicationRuleLoad?
    private var restorePoint: Target.RestorePoint?

    init(target: Target) {
        self.target = target
    }

    /// Whether a rule's load is shown, so what was shown before is waiting to come back.
    var isHoldingRestorePoint: Bool { restorePoint != nil }

    /// Follows the load the rules ask for now (`PlaybackRules.load`); nil restores.
    func update(_ wanted: ApplicationRuleLoad?) {
        guard wanted != current else { return }
        guard let wanted else {
            current = nil
            if let restorePoint {
                self.restorePoint = nil
                OWELog.info(.app, "Application rules: no rule loads anything now; restoring what was shown before")
                target.restore(restorePoint)
            }
            return
        }
        if restorePoint == nil { restorePoint = target.restorePoint() }
        current = wanted
        OWELog.info(.app, "Application rules: loading \(wanted.kind.rawValue) \(wanted.file)")
        if !target.load(wanted) {
            OWELog.error(.app, "Application rules: the \(wanted.kind.rawValue) \(wanted.file) can't be loaded; it was removed or renamed")
        }
    }
}
