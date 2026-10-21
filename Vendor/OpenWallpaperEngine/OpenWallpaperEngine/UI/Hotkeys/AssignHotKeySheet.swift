import AppKit
import SwiftUI

/// WE's Assign Hotkey dialog (`browseAssignHotkey`, "Assign Hotkey to Wallpaper {{name}}"; its
/// profile dialog's hotkey field): records a shortcut for a wallpaper on one display, or for a
/// display profile. A shortcut something else uses asks first, naming what uses it
/// (`GlobalShortcutConflict`); OK saves it, and Remove Hotkey clears the one it has.
struct AssignHotKeySheet: View {
    let target: UserHotKey.Target
    @ObservedObject var hotKeys: UserHotKeyController
    /// Every global shortcut stops while the recorder listens (`GlobalHotKeyController.suspend`).
    let suspendAll: (Bool) -> Void
    let dismiss: () -> Void

    @State private var shortcut: GlobalShortcut?
    @State private var resolving: [GlobalShortcutConflict] = []
    @State private var isRecording = false
    @State private var pending: Pending?

    private struct Pending {
        let shortcut: GlobalShortcut
        let conflicts: [GlobalShortcutConflict]
    }

    init(target: UserHotKey.Target, hotKeys: UserHotKeyController,
         suspendAll: @escaping (Bool) -> Void, dismiss: @escaping () -> Void) {
        self.target = target
        self.hotKeys = hotKeys
        self.suspendAll = suspendAll
        self.dismiss = dismiss
        _shortcut = State(initialValue: hotKeys.hotKeys.first { $0.target == target }?.shortcut)
    }

    private var existing: UserHotKey? { hotKeys.hotKeys.first { $0.target == target } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: Self.title(for: target))
                .font(.headline)
            LabeledContent {
                ShortcutRecorderField(
                    shortcut: shortcut,
                    isRecording: $isRecording,
                    onRecord: record,
                    onClear: {
                        shortcut = nil
                        resolving = []
                    },
                    onRecordingChange: suspendAll,
                    help: "Loads it from any app. Click, then press the keys.")
            } label: {
                Text("Enter Hotkey:", comment: "Assign Hotkey dialog: the label of the shortcut recorder")
            }
            Text(verbatim: Self.footnote(for: target))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if existing != nil {
                    Button("Remove Hotkey", role: .destructive) {
                        hotKeys.assign(nil, to: target)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle()
                Button("OK") {
                    hotKeys.assign(shortcut, to: target, resolving: resolving)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(.prominent)
                .disabled(shortcut == nil || isRecording)
            }
        }
        .padding(20)
        .frame(width: 420)
        .alert(
            Text("\(pending?.shortcut.symbols ?? "") is already in use"),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { pending in
            Button("Use Anyway") {
                shortcut = pending.shortcut
                resolving = pending.conflicts
            }
            Button("Choose Another") { isRecording = true }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(verbatim: pending.conflicts.map { $0.message(forHotKey: true) }.joined(separator: "\n\n"))
        }
    }

    /// Takes a recorded shortcut, or first warns about what already uses it.
    private func record(_ recorded: GlobalShortcut) {
        let conflicts = hotKeys.conflicts(for: recorded, target: target)
        if conflicts.isEmpty {
            shortcut = recorded
            resolving = []
        } else {
            pending = Pending(shortcut: recorded, conflicts: conflicts)
        }
    }

    static func title(for target: UserHotKey.Target) -> String {
        switch target {
        case let .wallpaper(wallpaper, _):
            let name = wallpaper.project.displayTitle
            return String(localized: "Assign Hotkey to Wallpaper \u{201C}\(name)\u{201D}", comment: "Assign Hotkey dialog's title; the wallpaper's title")
        case let .profile(name):
            return String(localized: "Assign Hotkey to Profile \u{201C}\(name)\u{201D}", comment: "Assign Hotkey dialog's title; the display profile's name")
        }
    }

    static func footnote(for target: UserHotKey.Target) -> String {
        switch target {
        case let .wallpaper(_, location):
            let screenId = UserHotKey.screenId(ofLocation: location, connected: DisplayIdentity.connected())
            let screen = NSScreen.screens.first { WallpaperViewModel.screenId(for: $0) == screenId.map(DisplayLayoutResolution.screen(of:)) }
            let display = screen.map(WallpaperViewModel.screenName(for:)) ?? location
            return String(localized: "Pressing the hotkey in any app sets this wallpaper on \u{201C}\(display)\u{201D}, the display it was assigned on.", comment: "Assign Hotkey dialog for a wallpaper; the display's name")
        case .profile:
            return String(localized: "Pressing the hotkey in any app loads this profile on your displays.", comment: "Assign Hotkey dialog for a display profile")
        }
    }
}

/// Shows `AssignHotKeySheet` as a sheet of the window in front (the main window, the Displays
/// sheet), or on its own when no window is.
@MainActor
enum AssignHotKeyPresenter {
    static func present(_ target: UserHotKey.Target, hotKeys: UserHotKeyController,
                        suspendAll: @escaping (Bool) -> Void) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let parent = NSApp.keyWindow
        let close: () -> Void = { [weak panel] in
            guard let panel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        }
        panel.contentViewController = NSHostingController(rootView: AssignHotKeySheet(
            target: target, hotKeys: hotKeys, suspendAll: suspendAll, dismiss: close))
        panel.isReleasedWhenClosed = false
        if let parent {
            parent.beginSheet(panel)
        } else {
            panel.title = AssignHotKeySheet.title(for: target)
            panel.center()
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
