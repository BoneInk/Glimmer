import SwiftUI
import OWEInspectorKit
import OWESceneEditing

/// Editing a text layer's text where it is on the canvas: a field over the layer, Return (or
/// clicking away) keeps the text, Escape leaves it as it was. Option-Return starts a new line.
struct CanvasTextEditor: View {
    @Environment(\.appAccentColor) private var accentColor
    @ObservedObject var session: SceneEditSession
    let layerID: Int
    let viewport: CanvasViewport
    @State private var text = ""
    @State private var original = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let geometry = session.geometry(of: layerID) {
            let corners = geometry.corners.map(viewport.canvasPoint)
            let xs = corners.map(\.x), ys = corners.map(\.y)
            let width = max((xs.max() ?? 0) - (xs.min() ?? 0), 120)
            let height = max((ys.max() ?? 0) - (ys.min() ?? 0), 28)
            let centre = SIMD2((xs.max()! + xs.min()!) / 2, (ys.max()! + ys.min()!) / 2)
            TextField(L("Text"), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .multilineTextAlignment(alignment)
                .font(.system(size: min(max(height / 3, 12), 48)))
                .padding(6)
                .frame(width: width, alignment: .center)
                .frame(minHeight: height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(accentColor, lineWidth: 1.5))
                .position(x: centre.x, y: centre.y)
                .focused($focused)
                .onAppear {
                    original = session.textContent(of: layerID) ?? ""
                    text = original
                    focused = true
                }
                .onSubmit(commit)
                .onExitCommand {
                    text = original
                    session.editingText = nil
                }
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
    }

    private var alignment: TextAlignment {
        switch session.value("horizontalalign", of: layerID)?.stringValue {
        case "left": return .leading
        case "right": return .trailing
        default: return .center
        }
    }

    private func commit() {
        guard session.editingText == layerID else { return }
        session.editingText = nil
        if text != original { session.setText(text, of: layerID, actionName: L("Change Text"), coalescing: false) }
    }
}
