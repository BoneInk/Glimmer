import SwiftUI

/// Settings › General › Hotkeys: a system-wide shortcut for each of Wallpaper Engine's hotkey
/// actions (`GlobalHotKeyAction`), in WE's groups. A shortcut something else uses asks first,
/// naming what uses it (`GlobalShortcutConflict`).
struct HotKeysSection: View {
    @ObservedObject var hotKeys: GlobalHotKeyController
    /// The wallpapers' and profiles' hotkeys, WE's Change Wallpaper group.
    @ObservedObject var userHotKeys: UserHotKeyController = AppDelegate.shared.userHotKeys
    @State private var recordingAction: GlobalHotKeyAction?
    /// A recorded shortcut something else uses, until the warning is answered.
    @State private var pending: Pending?

    private struct Pending {
        let shortcut: GlobalShortcut
        let action: GlobalHotKeyAction
        let conflicts: [GlobalShortcutConflict]
    }

    var body: some View {
        ForEach(Array(GlobalHotKeyAction.Group.allCases.enumerated()), id: \.offset) { index, group in
            Section {
                ForEach(group.actions) { action in
                    row(action)
                }
            } header: {
                if index == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Hotkeys", systemImage: "command")
                        Text(group.title).font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text(group.title)
                }
            } footer: {
                if index == GlobalHotKeyAction.Group.allCases.count - 1 {
                    Text("Hotkeys work in every app and need no permission. Each needs ⌘, ⌥ or ⌃. Playlists have their own, set in the playlist's header.")
                }
            }
            .settingsAnchor(index == 0 ? SettingsAnchor.hotKeys : "\(SettingsAnchor.hotKeys).\(index)")
        }
        changeWallpaperSection
        .alert(
            Text("\(pending?.shortcut.symbols ?? "") is already in use"),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button("Use Anyway") {
                hotKeys.assign(pending.shortcut, to: pending.action, resolving: pending.conflicts)
            }
            Button("Choose Another") { recordingAction = pending.action }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(verbatim: pending.conflicts.map { $0.message(forHotKey: true) }.joined(separator: "\n\n"))
        }
    }

    /// WE's Change Wallpaper group: the hotkeys assigned to wallpapers and profiles, each with
    /// what it loads and a Remove button.
    private var changeWallpaperSection: some View {
        Section {
            if userHotKeys.hotKeys.isEmpty {
                Text("You can assign hotkeys to wallpapers in their context menu, and to profiles in the Displays sheet's Profile menu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(userHotKeys.hotKeys) { hotKey in
                LabeledContent {
                    HStack(spacing: 6) {
                        if userHotKeys.unregistered.contains(hotKey.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                                .help("Another app holds this shortcut, so it may not work.")
                                .accessibilityLabel(Text("Another app holds this shortcut, so it may not work."))
                        }
                        Text(verbatim: hotKey.shortcut.symbols)
                            .monospaced()
                        Button {
                            userHotKeys.remove(hotKey.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove Hotkey")
                        .accessibilityLabel(Text("Remove Hotkey"))
                    }
                } label: {
                    Text(verbatim: hotKey.title)
                    Text(hotKey.isProfile ? "Choose profile" : "Choose wallpaper")
                }
            }
        } header: {
            Text("Change Wallpaper", comment: "Settings › Hotkeys group: the hotkeys of wallpapers and display profiles")
        }
        .settingsAnchor("\(SettingsAnchor.hotKeys).user")
    }

    private func row(_ action: GlobalHotKeyAction) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                if hotKeys.bindings[action] != nil, hotKeys.unregisteredActions.contains(action) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Another app holds this shortcut, so it may not work.")
                        .accessibilityLabel(Text("Another app holds this shortcut, so it may not work."))
                }
                ShortcutRecorderField(
                    shortcut: hotKeys.bindings[action],
                    isRecording: Binding(
                        get: { recordingAction == action },
                        set: { recording in
                            if recording { recordingAction = action } else if recordingAction == action { recordingAction = nil }
                        }),
                    onRecord: { record($0, for: action) },
                    onClear: { hotKeys.assign(nil, to: action) },
                    onRecordingChange: { $0 ? hotKeys.suspend() : hotKeys.resume() },
                    help: "Runs this command from any app. Click, then press the keys.")
            }
        } label: {
            Text(action.title)
        }
    }

    /// Saves a recorded shortcut, or first warns about what already uses it.
    private func record(_ shortcut: GlobalShortcut, for action: GlobalHotKeyAction) {
        let conflicts = hotKeys.conflicts(for: shortcut, action: action)
        if conflicts.isEmpty {
            hotKeys.assign(shortcut, to: action)
        } else {
            pending = Pending(shortcut: shortcut, action: action, conflicts: conflicts)
        }
    }
}
