import SwiftUI

/// What the Playlists tab can do with one of a playlist's items, from its row, tile, menu or the
/// keyboard.
@MainActor
struct PlaylistItemActions {
    let wallpaperViewModel: WallpaperViewModel
    let playlist: WallpaperPlaylist
    let showInInstalled: (WEWallpaper) -> Void

    func isFirst(_ item: WallpaperPlaylistItem) -> Bool { playlist.items.first?.id == item.id }
    func isLast(_ item: WallpaperPlaylistItem) -> Bool { playlist.items.last?.id == item.id }

    func move(_ item: WallpaperPlaylistItem, by offset: Int) {
        withAnimation(.snappy) { wallpaperViewModel.movePlaylistItem(itemID: item.id, offset: offset, playlistID: playlist.id) }
    }

    func remove(_ itemIDs: [UUID]) {
        withAnimation(.snappy) {
            for id in itemIDs { wallpaperViewModel.removeFromPlaylist(itemID: id, playlistID: playlist.id) }
        }
    }

    func setAsWallpaper(_ item: WallpaperPlaylistItem) { wallpaperViewModel.inspectAndApply(item.wallpaper) }

    /// How long the item shows under the playlist's timing, or nil when it isn't timed.
    func durationLabel(_ item: WallpaperPlaylistItem) -> String? {
        guard let index = playlist.items.firstIndex(where: { $0.id == item.id }) else { return nil }
        switch PlaylistSummary.share(ofItemAt: index, in: playlist) {
        case .duration(let seconds): return PlaylistDurationFormat.label(seconds)
        case .days(let days): return Self.daysFormatter.string(from: DateComponents(day: days))
        case .untimed: return nil
        }
    }

    private static let daysFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day]
        formatter.unitsStyle = .full
        return formatter
    }()
}

/// The right-click menu of a playlist item.
struct PlaylistItemMenu: View {
    let item: WallpaperPlaylistItem
    let actions: PlaylistItemActions

    var body: some View {
        Button("Set as Wallpaper") { actions.setAsWallpaper(item) }
        Button("Show in Installed") { actions.showInInstalled(item.wallpaper) }
        Divider()
        Button("Move Up") { actions.move(item, by: -1) }
            .disabled(actions.isFirst(item))
        Button("Move Down") { actions.move(item, by: 1) }
            .disabled(actions.isLast(item))
        Divider()
        Button("Remove from playlist", role: .destructive) { actions.remove([item.id]) }
    }
}
