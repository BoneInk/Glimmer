import SwiftUI

/// The top of a playlist's page, as Music heads a playlist: the cover, the name (click to rename),
/// how many wallpapers and how long a round takes, when it changes and with which transition, and
/// the Play, Shuffle and Settings buttons.
struct PlaylistHeader: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let playlist: WallpaperPlaylist
    @Binding var isRecordingShortcut: Bool
    let unregisteredShortcut: Bool
    let onRecordShortcut: (GlobalShortcut) -> Void
    let onClearShortcut: () -> Void
    let onSettings: () -> Void
    let onDelete: () -> Void
    @Binding var isEditingName: Bool

    @State private var name = ""
    @FocusState private var isNameFocused: Bool

    private var isPlaying: Bool {
        wallpaperViewModel.playlistEnabled && wallpaperViewModel.activePlaylistID == playlist.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleBlock
            controls
        }
        .onAppear { name = playlist.name }
        .onChange(of: playlist.id) { _ in name = playlist.name }
        .onChange(of: playlist.name) { newName in if !isNameFocused { name = newName } }
        .onChange(of: isEditingName) { editing in if editing { isNameFocused = true } }
        .onChange(of: isNameFocused) { focused in
            if !focused { commitName() }
            isEditingName = focused
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .bottom, spacing: 24) {
            PlaylistCover(urls: PlaylistSummary.coverURLs(of: playlist), size: 168, cornerRadius: 12)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                nameField
                counts
                timingSummary
                if unregisteredShortcut {
                    Label("This shortcut may not work: another app uses it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name, edited in place: Return or clicking away saves it, Esc puts it back.
    private var nameField: some View {
        TextField("Playlist name", text: $name)
            .textFieldStyle(.plain)
            .font(.largeTitle.bold())
            .focused($isNameFocused)
            .onSubmit { commitName(); isNameFocused = false }
            .onExitCommand { name = playlist.name; isNameFocused = false }
            .help("Click to rename the playlist")
            .accessibilityLabel(Text("Playlist name"))
    }

    private var counts: some View {
        HStack(spacing: 8) {
            Text("\(playlist.items.count) wallpapers")
            if let total = PlaylistSummary.totalDuration(of: playlist), let label = Self.totalFormatter.string(from: total) {
                Text(verbatim: "·").accessibilityHidden(true)
                Text(verbatim: label)
                    .monospacedDigit()
            }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }

    private var timingSummary: some View {
        HStack(spacing: 16) {
            Label {
                if playlist.timing == .timer {
                    Text("\(Text(playlist.timing.title)), every \(PlaylistDurationFormat.label(playlist.duration))",
                         comment: "Playlist header: the timing and its duration, as On a timer, every 5m")
                } else {
                    Text(playlist.timing.title)
                }
            } icon: {
                Image(systemName: Self.symbol(for: playlist.timing))
            }
            if let transition = PlaylistSummary.transitionTitle(playlist.transition) {
                Label {
                    Text("\(Text(transition)), \(playlist.transition.duration.formatted(.number.precision(.fractionLength(0...1)))) s",
                         comment: "Playlist header: the transition and its length in seconds, as Fade, 1.5 s")
                } icon: {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                if isPlaying {
                    Button {
                        wallpaperViewModel.playlistEnabled = false
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(minWidth: 64)
                    }
                    .glassButtonStyle(.prominent)
                    .help("Stops changing the wallpaper automatically")
                } else {
                    Button {
                        wallpaperViewModel.startPlaylist(id: playlist.id)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(minWidth: 64)
                    }
                    .glassButtonStyle(.prominent)
                    .disabled(playlist.items.isEmpty)
                    .help("Shows this playlist on the selected displays and changes the wallpaper automatically")
                }
                // A scheduled playlist's slots pick the wallpaper, not the order.
                Toggle(isOn: $wallpaperViewModel.playlistShuffle) {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .toggleStyle(.button)
                .glassButtonStyle()
                .disabled(playlist.timing.isScheduled)
                .help("Shuffle")
                Button {
                    wallpaperViewModel.previousPlaylistWallpaper()
                } label: {
                    Label("Previous", systemImage: "backward.fill").labelStyle(.iconOnly)
                }
                .glassButtonStyle()
                .help("Previous")
                Button {
                    wallpaperViewModel.nextPlaylistWallpaper()
                } label: {
                    Label("Next", systemImage: "forward.fill").labelStyle(.iconOnly)
                }
                .glassButtonStyle()
                .help("Next")
                Button(action: onSettings) {
                    Label("Configure", systemImage: "gearshape")
                }
                .glassButtonStyle()
                .help("Playlist Settings: when the wallpaper changes, and the transition")
                Spacer(minLength: 8)
                ShortcutRecorderField(
                    shortcut: playlist.shortcut,
                    isRecording: $isRecordingShortcut,
                    onRecord: onRecordShortcut,
                    onClear: onClearShortcut,
                    // The hotkeys and the playlists' shortcuts stop while it listens.
                    onRecordingChange: { recording in
                        let hotKeys = AppDelegate.shared.globalHotKeys
                        recording ? hotKeys.suspend() : hotKeys.resume()
                    }
                )
                Button(role: .destructive, action: onDelete) {
                    Label("Delete playlist", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .glassButtonStyle()
                .help("Delete playlist")
            }
        }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            name = playlist.name
        } else {
            wallpaperViewModel.renamePlaylist(playlist.id, to: trimmed)
        }
    }

    static func symbol(for timing: PlaylistTiming) -> String {
        switch timing {
        case .logon: return "person.crop.circle"
        case .timer: return "timer"
        case .daytime: return "sun.horizon"
        case .dayofweek: return "calendar"
        case .never: return "hand.raised"
        }
    }

    /// A round's length: "25 min", "1 hr, 30 min", "7 days".
    private static let totalFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 2
        return formatter
    }()
}
