import Foundation

/// Where application rules' load actions land in the app (`ApplicationRuleLoader`): a wallpaper
/// on every display, a playlist started on its displays, or a saved display profile; and what
/// was shown before, put back when the rules stop asking.
///
/// A rule's wallpaper doesn't enter the displays' history or the recent wallpapers, since the
/// user didn't choose it, and the playlist holds still while it shows. A wallpaper that runs code
/// and isn't trusted yet isn't loaded: a rule can't answer the trust question for the user.
/// After a profile, the display layout, the displays' wallpapers (regions included) and the
/// playlist come back.
@MainActor
final class WallpaperRuleLoadTarget: ApplicationRuleLoadTarget {
    struct RestorePoint {
        var wallpapers: [String: WEWallpaper]
        var displayLayout: DisplayLayoutConfiguration
        var activePlaylistID: UUID?
        var playlistEnabled: Bool
        var selectedScreenId: String
        var selectedScreenIds: Set<String>
    }

    private let viewModel: WallpaperViewModel
    /// The library's wallpapers, to find a rule's by its folder.
    private let library: () -> [WEWallpaper]
    private let profiles: () -> any DisplayProfileLoading

    init(viewModel: WallpaperViewModel, library: @escaping () -> [WEWallpaper],
         profiles: @escaping () -> any DisplayProfileLoading) {
        self.viewModel = viewModel
        self.library = library
        self.profiles = profiles
    }

    func restorePoint() -> RestorePoint {
        RestorePoint(wallpapers: viewModel.wallpapers, displayLayout: viewModel.displayLayout,
                     activePlaylistID: viewModel.activePlaylistID, playlistEnabled: viewModel.playlistEnabled,
                     selectedScreenId: viewModel.selectedScreenId, selectedScreenIds: viewModel.selectedScreenIds)
    }

    func load(_ load: ApplicationRuleLoad) -> Bool {
        switch load.kind {
        case .wallpaper:
            guard let wallpaper = library().first(where: { $0.identityPath == load.file }) else { return false }
            if !WallpaperViewModel.mayRunWithoutAsking(wallpaper) {
                OWELog.info(.app, "Application rules: \"\(wallpaper.project.title)\" runs code and isn't trusted yet; apply it once by hand to trust it")
                return true
            }
            guard viewModel.confirmApply?(wallpaper) ?? true else { return true }
            viewModel.playlistEnabled = false
            var wallpapers = viewModel.wallpapers
            for screenId in viewModel.connectedScreenIds().union(wallpapers.keys) {
                wallpapers[screenId] = wallpaper
            }
            viewModel.wallpapers = wallpapers
            return true
        case .playlist:
            guard let id = UUID(uuidString: load.file), viewModel.playlists.contains(where: { $0.id == id }) else { return false }
            viewModel.startPlaylist(id: id)
            return true
        case .profile:
            // A deleted profile changes nothing; the loader logs it.
            return profiles().load(name: load.file)
        }
    }

    func restore(_ point: RestorePoint) {
        // The playlist's timer stays off until its state is back, so it can't step in between.
        viewModel.playlistEnabled = false
        viewModel.activePlaylistID = point.activePlaylistID
        if viewModel.displayLayout != point.displayLayout { viewModel.displayLayout = point.displayLayout }
        viewModel.selectedScreenId = point.selectedScreenId
        viewModel.selectedScreenIds = point.selectedScreenIds
        // A display the point had gets all its selections back, so a profile's regions go. A
        // display connected since the load keeps the rule's wallpaper; it had none before.
        let screens = Set(point.wallpapers.keys.map(DisplayLayoutResolution.screen(of:)))
        let restored = viewModel.wallpapers.filter { !screens.contains(DisplayLayoutResolution.screen(of: $0.key)) }
            .merging(point.wallpapers) { _, before in before }
        let changed = restored.count != viewModel.wallpapers.count || restored.contains { screenId, wallpaper in
            viewModel.wallpapers[screenId].map { !$0.isSameWallpaper(as: wallpaper) } ?? true
        }
        if changed { viewModel.wallpapers = restored }
        viewModel.playlistEnabled = point.playlistEnabled
    }
}
