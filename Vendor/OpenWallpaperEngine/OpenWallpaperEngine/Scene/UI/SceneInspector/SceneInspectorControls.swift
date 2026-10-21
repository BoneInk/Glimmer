import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

/// A layer's opacity: the slider shows the value as it moves and saves it when the drag ends (an
/// object JSON edit reloads the scene).
struct SceneLayerOpacitySlider: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var draft: Double?

    var body: some View {
        let shown = draft ?? value
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Opacity")
                Spacer()
                Text(shown, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { draft ?? value }, set: { draft = $0 }), in: 0...1, onEditingChanged: { editing in
                guard !editing, let draft else { return }
                onCommit(draft)
                self.draft = nil
            })
        }
    }
}

/// Arrow keys nudge the selected object while this panel has keyboard focus.
struct ArrowKeyMove: ViewModifier {
    let onMove: (MoveCommandDirection) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand(perform: onMove)
    }
}

/// A native group box around a block of controls.
struct GroupBoxed: ViewModifier {
    func body(content: Content) -> some View {
        GroupBox { content }
    }
}

/// Ties a `FocusState` to the window's search field, where the OS can (`searchFocused`, macOS 15).
struct SearchFieldFocus: ViewModifier {
    let isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.searchFocused(isFocused)
        } else {
            content
        }
    }
}
