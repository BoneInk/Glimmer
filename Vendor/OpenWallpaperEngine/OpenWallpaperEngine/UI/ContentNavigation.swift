import Observation
import SwiftUI

/// The main window's tabs and panes: which tab shows, which sidebars and inspectors are open, the
/// library's tile size, and whether the window is staged and the app active.
@MainActor @Observable
final class ContentNavigation {
    /// The main window's tab (`TopTabBar`'s tags, stored by `UpdateRelaunchState`).
    var topTabBarSelection: Int = 0
    /// The Installed and Workshop filter sidebars, kept across launches.
    var isFilterReveal: Bool = UserDefaults.app.object(forKey: Keys.filterReveal) as? Bool ?? false {
        didSet { UserDefaults.app.set(isFilterReveal, forKey: Keys.filterReveal) }
    }
    /// The Playlists tab's list of playlists, in the main window's sidebar.
    var isPlaylistSidebarReveal = true
    /// The Installed tab's Details inspector.
    var isDetailsReveal = true
    /// The main window's content is shown: off while the window is closed.
    var isStaging = false
    var isApplicationActive = true
    /// The side of a tile in the Installed, Workshop and Discover grids, kept across launches.
    var explorerIconSize: Double = UserDefaults.app.object(forKey: Keys.explorerIconSize) as? Double ?? 200 {
        didSet { UserDefaults.app.set(explorerIconSize, forKey: Keys.explorerIconSize) }
    }

    /// The `UserDefaults.app` keys, as `@AppStorage` stored them.
    private enum Keys {
        static let filterReveal = "FilterReveal"
        static let explorerIconSize = "ExplorerIconSize"
    }

    /// Animated, so the sidebar slides in and out as it did before it was a split view column.
    func toggleFilter() {
        withAnimation { isFilterReveal.toggle() }
    }
}
