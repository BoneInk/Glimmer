import SwiftUI

/// The quick rotation options under a playlist's header: Rotate automatically (Play without
/// changing the wallpaper now), Repeat, Change when video ends and the wallpaper duration.
/// Playlist Settings holds the rest.
struct PlaylistRotationOptions: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let playlist: WallpaperPlaylist

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { toggles; duration }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 24) { toggles }
                duration
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassBackground(in: RoundedRectangle(cornerRadius: 12, style: .continuous)) { content in
            content.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder private var toggles: some View {
        Toggle("Rotate automatically", isOn: $wallpaperViewModel.playlistEnabled)
        // A scheduled playlist's slots pick the wallpaper, not the order.
        Toggle("Repeat", isOn: $wallpaperViewModel.playlistRepeats)
            .disabled(playlist.timing.isScheduled)
        Toggle("Change when video ends", isOn: Binding(
            get: { playlist.changeWhenVideoEnds },
            set: { wallpaperViewModel.setPlaylistChangeWhenVideoEnds($0, playlistID: playlist.id) }
        ))
        .disabled(!playlist.timing.usesTimerOptions)
    }

    private var duration: some View {
        HStack(spacing: 8) {
            Text("Wallpaper duration")
            // No `step:` (AppKit would draw a tick per step); the binding snaps instead.
            Slider(value: Binding(
                get: { playlist.duration },
                set: { wallpaperViewModel.setPlaylistDuration(PlaylistDurationFormat.snapped($0), playlistID: playlist.id) }
            ), in: PlaylistDurationFormat.range)
            .frame(minWidth: 120, maxWidth: 240)
            Text(PlaylistDurationFormat.label(playlist.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
                .fixedSize()
        }
        .disabled(playlist.timing != .timer)
    }
}
