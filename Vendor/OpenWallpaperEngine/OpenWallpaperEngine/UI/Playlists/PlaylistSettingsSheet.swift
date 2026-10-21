import SwiftUI

/// WE's Playlist Settings dialog: when the playlist changes wallpaper (on a timer, at login, by
/// time of day, by day of week, or never), the timer's options and the transition. Edits a copy;
/// Done saves it as WE's dialog does (`WallpaperViewModel.updatePlaylistSettings`).
struct PlaylistSettingsSheet: View {
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WallpaperPlaylist
    /// Asked before Done removes the wallpapers after the seventh of a day-of-week playlist.
    @State private var confirmsTrim = false

    init(wallpaperViewModel: WallpaperViewModel, playlist: WallpaperPlaylist) {
        self.wallpaperViewModel = wallpaperViewModel
        _draft = State(initialValue: playlist)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                timingSection
                if draft.timing == .daytime {
                    PlaylistTimeOfDayEditor(playlist: $draft)
                }
                if draft.timing == .dayofweek {
                    PlaylistDayOfWeekList(playlist: draft)
                }
                Section {
                    WallpaperTransitionEditor(settings: $draft.transition, label: "Show wallpaper transition")
                    WallpaperTransitionPreview(settings: draft.transition,
                                               from: draft.items.first.flatMap(PlaylistSettingsSheet.previewURL),
                                               to: draft.items.dropFirst().first.flatMap(PlaylistSettingsSheet.previewURL)
                                                ?? draft.items.first.flatMap(PlaylistSettingsSheet.previewURL))
                        .frame(width: 192, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("Transition preview"))
                } header: {
                    Text("Transitions")
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Reset") { reset() }
                    .help("Puts every setting back to a new playlist's.")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { save() }
                    .keyboardShortcut(.defaultAction)
                    .glassButtonStyle(.prominent)
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
        .confirmationDialog("Day of Week Playlist", isPresented: $confirmsTrim, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { save(trimming: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Day of Week playlist does not support more than 7 wallpapers. Remove excess wallpapers now?")
        }
    }

    @ViewBuilder private var timingSection: some View {
        Section {
            Picker("Change wallpaper", selection: $draft.timing) {
                ForEach(PlaylistTiming.menuOrder) { timing in
                    Text(timing.title).tag(timing)
                }
            }
            if draft.timing == .timer {
                LabeledContent("Wallpaper duration") {
                    HStack {
                        // No `step:` (AppKit would draw a tick per step); the binding snaps instead.
                        Slider(value: Binding(get: { draft.duration },
                                              set: { draft.duration = PlaylistDurationFormat.snapped($0) }),
                               in: PlaylistDurationFormat.range)
                        Text(PlaylistDurationFormat.label(draft.duration))
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 64, alignment: .trailing)
                            .fixedSize()
                    }
                }
            }
            // WE's dialog offers these only on a timer.
            Group {
                Toggle("Change wallpaper when a video ends", isOn: $draft.changeWhenVideoEnds)
                Toggle("Allow wallpaper to change while paused", isOn: $draft.changesWhilePaused)
                Toggle("Always begin with the first wallpaper", isOn: $draft.beginsWithFirst)
                Toggle("First wallpaper played at startup only", isOn: $draft.playsFirstAtStartupOnly)
                    .disabled(!draft.beginsWithFirst)
            }
            .disabled(!draft.timing.usesTimerOptions)
        } header: {
            Text("Change wallpaper")
        } footer: {
            Text(Self.footer(for: draft.timing))
        }
    }

    static func footer(for timing: PlaylistTiming) -> LocalizedStringResource {
        switch timing {
        case .logon: return LocalizedStringResource("The playlist moves on one wallpaper each time Open Wallpaper Engine starts.")
        case .timer: return LocalizedStringResource("The playlist moves on after the duration, or when a video ends.")
        case .daytime: return LocalizedStringResource("Each wallpaper shows from its start time until the next one's.")
        case .dayofweek: return LocalizedStringResource("Up to seven wallpapers share the week, from its first day.")
        case .never: return LocalizedStringResource("Only Next and Previous change the wallpaper.")
        }
    }

    private func reset() {
        let fresh = WallpaperPlaylist(name: draft.name)
        draft.timing = fresh.timing
        draft.duration = fresh.duration
        draft.changeWhenVideoEnds = fresh.changeWhenVideoEnds
        draft.changesWhilePaused = fresh.changesWhilePaused
        draft.beginsWithFirst = fresh.beginsWithFirst
        draft.playsFirstAtStartupOnly = fresh.playsFirstAtStartupOnly
        draft.transition = fresh.transition
        for index in draft.items.indices { draft.items[index].daytimeEnd = nil }
    }

    private func save(trimming: Bool = false) {
        if draft.timing == .dayofweek, draft.items.count > PlaylistTiming.maxDayOfWeekItems, !trimming {
            confirmsTrim = true
            return
        }
        let edited = draft
        wallpaperViewModel.updatePlaylistSettings(edited.id) { playlist in
            playlist.timing = edited.timing
            playlist.duration = edited.duration
            playlist.changeWhenVideoEnds = edited.changeWhenVideoEnds
            playlist.changesWhilePaused = edited.changesWhilePaused
            playlist.beginsWithFirst = edited.beginsWithFirst
            playlist.playsFirstAtStartupOnly = edited.playsFirstAtStartupOnly
            playlist.transition = edited.transition
            // The items may have changed while the sheet was open: ends go to the same items.
            let ends = Dictionary(edited.items.map { ($0.id, $0.daytimeEnd) }, uniquingKeysWith: { first, _ in first })
            for index in playlist.items.indices { playlist.items[index].daytimeEnd = ends[playlist.items[index].id] ?? nil }
            if trimming, playlist.items.count > PlaylistTiming.maxDayOfWeekItems {
                playlist.items.removeSubrange(PlaylistTiming.maxDayOfWeekItems...)
            }
        }
        dismiss()
    }

    static func previewURL(_ item: WallpaperPlaylistItem) -> URL? {
        item.wallpaper.previewURL
    }
}
