import SwiftUI

/// The selected playlist, in the main window's detail column, as Music shows a playlist: the
/// header, then its wallpapers as a list or a grid. `PlaylistSidebar` lists the playlists.
struct PlaylistView: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    /// The playlist whose Delete button was clicked, until the confirmation is answered.
    @State private var playlistPendingDeletion: WallpaperPlaylist?
    @ObservedObject private var shortcuts = AppDelegate.shared.playlistShortcuts
    @State private var isRecordingShortcut = false
    /// A recorded shortcut something else uses, until the warning is answered.
    @State private var pendingShortcut: PendingShortcut?
    /// The playlist whose Playlist Settings sheet is open.
    @State private var configuredPlaylist: WallpaperPlaylist?
    /// Opens a wallpaper in the Installed tab.
    let showInInstalled: (WEWallpaper) -> Void
    @State private var selectedItems: Set<UUID> = []
    /// Set to start renaming the playlist (a new one starts with its name being edited).
    @State private var isEditingName = false
    /// In the app's defaults: the main window is an AppKit window, where SwiftUI scene storage keeps
    /// nothing and never changes, so the List/Grid control couldn't switch.
    @AppStorage(PlaylistItemLayout.defaultsKey, store: .app) private var layout = PlaylistItemLayout.defaultLayout

    private struct PendingShortcut {
        let shortcut: GlobalShortcut
        let playlistID: UUID
        let conflicts: [GlobalShortcutConflict]
    }

    var body: some View {
        playlistDetail
            .confirmationDialog(
                "Delete the playlist \u{201C}\(playlistPendingDeletion?.name ?? "")\u{201D}?",
                isPresented: Binding(
                    get: { playlistPendingDeletion != nil },
                    set: { if !$0 { playlistPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: playlistPendingDeletion
            ) { playlist in
                // Removes only the playlist; its wallpapers stay installed.
                Button("Delete", role: .destructive) {
                    wallpaperViewModel.deletePlaylist(playlist)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Its wallpapers stay in your library.")
            }
            .alert(
                Text("\(pendingShortcut?.shortcut.symbols ?? "") is already in use"),
                isPresented: Binding(
                    get: { pendingShortcut != nil },
                    set: { if !$0 { pendingShortcut = nil } }
                ),
                presenting: pendingShortcut
            ) { pending in
                Button("Use Anyway") {
                    shortcuts.assign(pending.shortcut, to: pending.playlistID, resolving: pending.conflicts)
                }
                Button("Choose Another") { isRecordingShortcut = true }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(verbatim: pending.conflicts.map(\.message).joined(separator: "\n\n"))
            }
            .sheet(item: $configuredPlaylist) { playlist in
                PlaylistSettingsSheet(wallpaperViewModel: wallpaperViewModel, playlist: playlist)
            }
    }

    /// Saves a recorded shortcut, or first warns about what already uses it.
    private func record(_ shortcut: GlobalShortcut, for playlistID: UUID) {
        let conflicts = shortcuts.conflicts(for: shortcut, playlistID: playlistID)
        if conflicts.isEmpty {
            shortcuts.assign(shortcut, to: playlistID)
        } else {
            pendingShortcut = PendingShortcut(shortcut: shortcut, playlistID: playlistID, conflicts: conflicts)
        }
    }

    @ViewBuilder private var playlistDetail: some View {
        if let playlist = wallpaperViewModel.activePlaylist {
            let actions = PlaylistItemActions(wallpaperViewModel: wallpaperViewModel, playlist: playlist,
                                              showInInstalled: showInInstalled)
            Group {
                if playlist.items.isEmpty || layout == .grid {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            header(playlist)
                            if playlist.items.isEmpty {
                                emptyPlaylist
                            } else {
                                itemsHeader
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 176, maximum: 260), spacing: 16)],
                                          alignment: .leading, spacing: 16) {
                                    ForEach(playlist.items) { item in
                                        PlaylistItemTile(item: item, actions: actions)
                                            .draggable(item.id.uuidString)
                                            .dropDestination(for: String.self) { ids, _ in
                                                drop(ids, onto: item, in: playlist)
                                            }
                                    }
                                }
                            }
                        }
                        .padding(24)
                    }
                } else {
                    itemList(playlist, actions: actions)
                }
            }
            .animation(.snappy, value: playlist.items)
        } else {
            ContentUnavailableView {
                Label("No Playlists", systemImage: "rectangle.stack.badge.plus")
            } description: {
                Text("Create a playlist to manage wallpaper rotation.")
            } actions: {
                Button("Create Playlist") {
                    wallpaperViewModel.createPlaylist(named: String(localized: "Untitled Playlist", comment: "Name of a new playlist until the user renames it"))
                    isEditingName = true
                }
                .glassButtonStyle(.prominent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The list layout: rows to drag into a new order, select with the keyboard, and Delete.
    private func itemList(_ playlist: WallpaperPlaylist, actions: PlaylistItemActions) -> some View {
        List(selection: $selectedItems) {
            header(playlist)
                .padding(.vertical, 16)
                .listRowSeparator(.hidden)
                .selectionDisabled()
            Section {
                ForEach(playlist.items) { item in
                    PlaylistItemRow(item: item, actions: actions)
                        .tag(item.id)
                }
                .onMove { sources, destination in
                    guard let source = sources.first else { return }
                    wallpaperViewModel.movePlaylistItem(itemID: playlist.items[source].id, toOffset: destination,
                                                        playlistID: playlist.id)
                }
            } header: {
                itemsHeader
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let item = playlist.items.first(where: { ids.contains($0.id) }) {
                PlaylistItemMenu(item: item, actions: actions)
            } else if !ids.isEmpty {
                Button("Remove from playlist", role: .destructive) { actions.remove(Array(ids)) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let item = playlist.items.first(where: { ids.contains($0.id) }) {
                actions.setAsWallpaper(item)
            }
        }
        .onDeleteCommand {
            actions.remove(Array(selectedItems))
            selectedItems = []
        }
    }

    private func header(_ playlist: WallpaperPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            PlaylistHeader(
                wallpaperViewModel: wallpaperViewModel,
                playlist: playlist,
                isRecordingShortcut: $isRecordingShortcut,
                unregisteredShortcut: playlist.shortcut != nil && shortcuts.unregisteredPlaylists.contains(playlist.id),
                onRecordShortcut: { record($0, for: playlist.id) },
                onClearShortcut: { shortcuts.assign(nil, to: playlist.id) },
                onSettings: { configuredPlaylist = playlist },
                onDelete: { playlistPendingDeletion = playlist },
                isEditingName: $isEditingName
            )
            PlaylistRotationOptions(wallpaperViewModel: wallpaperViewModel, playlist: playlist)
        }
    }

    private var itemsHeader: some View {
        HStack {
            Text("Wallpapers")
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Spacer()
            Picker("Layout", selection: $layout) {
                Label("Grid", systemImage: "square.grid.2x2").tag(PlaylistItemLayout.grid)
                Label("List", systemImage: "list.bullet").tag(PlaylistItemLayout.list)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the wallpapers as a list or a grid")
        }
        .padding(.vertical, 4)
    }

    private var emptyPlaylist: some View {
        ContentUnavailableView {
            Label("No Wallpapers", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("In Installed, right-click a wallpaper and choose Add to Playlist.")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// A tile dropped on another in the grid takes its place, as dragging a row does.
    private func drop(_ ids: [String], onto target: WallpaperPlaylistItem, in playlist: WallpaperPlaylist) -> Bool {
        guard let id = ids.first.flatMap(UUID.init(uuidString:)),
              let source = playlist.items.firstIndex(where: { $0.id == id }),
              let destination = playlist.items.firstIndex(where: { $0.id == target.id }), source != destination else { return false }
        withAnimation(.snappy) {
            wallpaperViewModel.movePlaylistItem(itemID: id, toOffset: destination > source ? destination + 1 : destination,
                                                playlistID: playlist.id)
        }
        return true
    }
}
