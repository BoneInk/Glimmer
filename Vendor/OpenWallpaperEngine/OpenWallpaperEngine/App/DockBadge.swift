import AppKit

/// What a copy of the app shows on its Dock icon, so it's never mistaken for the user's own copy:
/// a "TEST" badge on a test or development copy running with isolated state, a "Dev" badge on a
/// local build (one without the release update key), nothing on a release. Both are the system
/// badge and the tile's content view is never replaced, so the Dock keeps drawing the real icon in
/// every icon style (Light, Dark, Tinted, Clear).
enum DockBadge: Equatable {
    case none
    case test
    case dev

    static func kind(isIsolated: Bool, isReleaseBuild: Bool) -> DockBadge {
        if isIsolated { return .test }
        return isReleaseBuild ? .none : .dev
    }

    static var current: DockBadge {
        kind(isIsolated: AppStorageLocation.current.isIsolated, isReleaseBuild: AppUpdateConfiguration.main.isConfigured)
    }

    var badgeLabel: String? {
        switch self {
        case .none: nil
        case .test: "TEST"
        case .dev: "Dev"
        }
    }

    @MainActor
    func apply(to tile: NSDockTile = NSApp.dockTile) {
        tile.contentView = nil
        tile.badgeLabel = badgeLabel
        tile.display()
    }
}
