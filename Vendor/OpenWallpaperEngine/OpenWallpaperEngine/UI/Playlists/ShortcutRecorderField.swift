import AppKit
import SwiftUI

/// A shortcut recorder: click it, then press the keys. Esc stops listening, Delete clears the
/// shortcut, and a shortcut without ⌘, ⌥ or ⌃ is refused with a hint.
struct ShortcutRecorderField: View {
    let shortcut: GlobalShortcut?
    @Binding var isRecording: Bool
    var onRecord: (GlobalShortcut) -> Void
    var onClear: () -> Void
    /// Told when listening starts and stops, so the registered shortcuts don't fire meanwhile.
    var onRecordingChange: (Bool) -> Void = { _ in }
    /// What the shortcut does, for the field's tooltip.
    var help: LocalizedStringKey = "Starts this playlist from any app. Click, then press the keys."

    @State private var monitor: Any?
    @State private var showsModifierHint = false

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isRecording.toggle()
            } label: {
                Group {
                    if isRecording {
                        Text("Type Shortcut")
                    } else if let shortcut {
                        Text(verbatim: shortcut.symbols)
                    } else {
                        Text("Record Shortcut")
                    }
                }
                .frame(minWidth: 110)
            }
            .glassButtonStyle(isRecording ? .prominent : .standard)
            .help(help)
            if shortcut != nil, !isRecording {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Shortcut")
                .accessibilityLabel(Text("Clear Shortcut"))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsModifierHint {
                Text("Include ⌘, ⌥ or ⌃.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(y: 18)
            }
        }
        .onChange(of: isRecording) { _, recording in
            recording ? startListening() : stopListening()
        }
        .onDisappear {
            if isRecording { isRecording = false }
            stopListening()
        }
    }

    private func startListening() {
        guard monitor == nil else { return }
        onRecordingChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(GlobalShortcut.modifierMask)
            if modifiers.isEmpty, event.keyCode == 53 { // Esc
                isRecording = false
                return nil
            }
            if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 { // Delete, Forward Delete
                isRecording = false
                onClear()
                return nil
            }
            guard let shortcut = GlobalShortcut(event: event), shortcut.isValid else {
                showsModifierHint = true
                NSSound.beep()
                return nil
            }
            showsModifierHint = false
            isRecording = false
            onRecord(shortcut)
            return nil
        }
    }

    private func stopListening() {
        showsModifierHint = false
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        onRecordingChange(false)
    }
}
