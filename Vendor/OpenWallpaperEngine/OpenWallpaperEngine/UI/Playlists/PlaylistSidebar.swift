import SwiftUI

/// The playlists, in the main window's sidebar on the Playlists tab. Choosing one makes it the
/// active playlist.
struct PlaylistSidebar: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var playlistName = ""
    @FocusState private var isNameFocused: Bool

    /// A click on empty space deselects a List; the active playlist stays set instead.
    private var selection: Binding<UUID?> {
        Binding(
            get: { wallpaperViewModel.activePlaylistID },
            set: { id in
                if let id { wallpaperViewModel.activePlaylistID = id }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(wallpaperViewModel.playlists) { playlist in
                    PlaylistSidebarRow(playlist: playlist, isPlaying: isPlaying(playlist))
                        .tag(playlist.id)
                }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button {
                        playlistName = ""
                        isNameFocused = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .help("Create playlist")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("New playlist", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
                    .onSubmit(create)
                Button(action: create) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Create playlist")
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
    }

    /// The playlist that is changing the wallpaper now, as Music marks the one playing.
    private func isPlaying(_ playlist: WallpaperPlaylist) -> Bool {
        wallpaperViewModel.playlistEnabled && playlist.id == wallpaperViewModel.activePlaylistID
    }

    private func create() {
        guard !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        wallpaperViewModel.createPlaylist(named: playlistName)
        playlistName = ""
    }
}

/// A playlist in the sidebar: its cover, name and wallpaper count, and a speaker on the one
/// playing.
private struct PlaylistSidebarRow: View {
    let playlist: WallpaperPlaylist
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            PlaylistCover(urls: PlaylistSummary.coverURLs(of: playlist), size: 32, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: playlist.name)
                    .lineLimit(1)
                Text("\(playlist.items.count) wallpapers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(Text("Playing"))
                    .help("Playing")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
