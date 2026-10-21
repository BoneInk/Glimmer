import SwiftUI
import OWESceneEditing

/// The canvas's gizmo buttons in its upper left corner, as Wallpaper Engine's editor has them:
/// Multi (2D scenes), Translate, Rotate and Scale, clicking the active one again for none; then
/// World Space (the planet) and Local Space (the house), which only Translate and Rotate can switch.
struct GizmoToolbar: View {
    @ObservedObject var tools: EditorTools
    /// A 3D scene: no Multi.
    let isSpatial: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GizmoMode.offered(spatial: isSpatial)) { mode in
                button(mode.title, symbol: mode.symbol, active: tools.gizmoMode == mode, help: mode.title) { tools.toggleGizmoMode(mode) }
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach(GizmoSpace.allCases) { space in
                button(space.title, symbol: space == .world ? "globe" : "house",
                       active: tools.gizmoSpace == space && tools.gizmoMode != .none,
                       help: space == .world ? G("The handles follow the scene’s axes") : G("The handles follow the selected object’s own axes")) {
                    tools.gizmoSpace = space
                }
                .disabled(!tools.gizmoMode.hasSpaceChoice)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(G("Gizmo"))
        .accessibilityHint(G("Move, rotate or scale the selection with the canvas’s handles"))
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .editorGlass(in: Capsule())
        .padding(12)
    }

    private func button(_ title: String, symbol: String, active: Bool, help: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 20)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(help)
    }
}

extension GizmoMode {
    var title: String {
        switch self {
        case .translate: return G("Translate")
        case .rotate: return G("Rotate")
        case .scale: return G("Scale")
        case .multi: return G("Multi")
        case .none: return ""
        }
    }

    var symbol: String {
        switch self {
        case .translate: return "arrow.up.and.down.and.arrow.left.and.right"
        case .rotate: return "arrow.clockwise"
        // WE's Scale gizmo shows four diagonal arrows.
        case .scale: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .multi: return "cube.transparent"
        case .none: return ""
        }
    }
}

extension GizmoSpace {
    var title: String {
        switch self {
        case .world: return G("World Space")
        case .local: return G("Local Space")
        }
    }
}
