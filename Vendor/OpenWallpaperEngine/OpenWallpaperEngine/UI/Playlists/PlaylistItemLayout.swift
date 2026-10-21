import Foundation

/// How the Playlists tab shows a playlist's wallpapers: a grid of tiles, as Photos shows an
/// album (the default), or a list of rows. Kept in the app's defaults, so the choice survives a
/// relaunch; `-PlaylistItemLayout list` or `grid` on the command line picks one for a launch.
enum PlaylistItemLayout: String, CaseIterable {
    case grid, list

    static let defaultsKey = "PlaylistItemLayout"
    /// For anyone who hasn't chosen, and for a stored value this version doesn't know.
    static let defaultLayout = PlaylistItemLayout.grid
}
