import Foundation

/// Which transition a wallpaper change shows (`WallpaperViewModel.setWallpaper`).
enum WallpaperChangeTransition: Equatable {
    /// None: restoring, rules, imports, the control channel, previews.
    case none
    /// Chosen by hand in the library: Settings' transition (WE's `browsetransition`).
    case manual
    /// A playlist's change: the playlist's own.
    case playlist(WallpaperTransitionSettings)

    /// The settings the change uses; nil for none.
    func settings(manual: WallpaperTransitionSettings) -> WallpaperTransitionSettings? {
        switch self {
        case .none: return nil
        case .manual: return manual
        case .playlist(let settings): return settings
        }
    }
}

/// Plays transitions on the wallpaper windows (`WallpaperTransitionCoordinator`).
@MainActor
protocol WallpaperTransitionPerforming: AnyObject {
    /// Settings' transition for wallpapers chosen by hand.
    var manualSettings: WallpaperTransitionSettings { get }
    /// Captures what `screens` (displays, split regions, or the source of a clone or stretch) show,
    /// calls `apply` (which changes their wallpapers) once, then plays `kind` over `duration` on
    /// every display that shows them. `apply` runs at once when nothing can be captured.
    func perform(_ kind: WallpaperTransitionKind, duration: TimeInterval, on screens: Set<String>,
                 apply: @escaping @MainActor () -> Void)
    /// Applies a change still waiting for its capture now, before the next change.
    func flushPending()
}
