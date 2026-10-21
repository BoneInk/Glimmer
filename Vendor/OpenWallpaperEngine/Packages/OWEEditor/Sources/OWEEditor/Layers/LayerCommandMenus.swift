import SwiftUI
import OWESceneEditing

/// A layer's context menu entries from Wallpaper Engine's editor: Center, Align with Background
/// (an image cropped on import), Rotate CW and CCW, Copy and Paste Transforms, Move to Custom
/// Position, and Copy and Paste all Effects. With several layers selected they act on them all.
struct LayerCommandItems: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    let actions: LayerActions

    var body: some View {
        Divider()
        // WE offers these for a 2D scene's layers that have transforms.
        if session.outline.size != nil, layer.kind != .sound {
            Button(LC("Center")) { actions.center(layer.id) }
            if actions.cropOffset(layer.id) != nil {
                Button(LC("Align with Background")) { actions.alignWithBackground(layer.id) }
            }
            Button(LC("Rotate CW")) { actions.rotate(layer.id, clockwise: true) }
            Button(LC("Rotate CCW")) { actions.rotate(layer.id, clockwise: false) }
            Divider()
        }
        if layer.kind != .sound {
            Button(LC("Copy Transforms")) { actions.copyTransforms(layer.id) }
            Button(LC("Paste Transforms")) { actions.pasteTransforms(layer.id) }
                .disabled(actions.tools.copiedTransform == nil)
        }
        // Top-level layers only, as WE's editor offers it.
        if layer.parentID.flatMap(session.outline.layer) == nil, session.outline.layers.count > 1 {
            Button(LC("Move to Custom Position…")) { actions.tools.choosingListPosition = layer.id }
        }
        if layer.kind == .image || layer.kind == .text || !layer.effects.isEmpty {
            Divider()
            Button(LC("Copy All Effects")) { actions.copyAllEffects(layer.id) }
                .disabled(layer.effects.isEmpty)
            Button(LC("Paste All Effects")) { actions.pasteAllEffects(layer.id) }
                .disabled(actions.tools.copiedEffects.isEmpty)
        }
    }
}

/// An effect's menu entries from Wallpaper Engine's editor: Copy Effect, Paste Effect, Paste
/// Effect Settings (onto the same effect) and Duplicate Effect (just after it).
struct EffectClipboardItems: View {
    let actions: LayerActions
    let layer: SceneLayer
    let effect: SceneLayerEffect

    var body: some View {
        Button(LC("Copy Effect")) { actions.copyEffect(effect.key, of: layer.id) }
        Button(LC("Paste Effect")) { actions.pasteEffect(on: layer.id) }
            .disabled(actions.tools.copiedEffect == nil)
        Button(LC("Paste Effect Settings")) { actions.pasteEffectSettings(onto: effect.key, of: layer.id) }
            .disabled(!actions.canPasteSettings(onto: effect))
        Divider()
        Button(LC("Duplicate Effect")) { actions.duplicateEffect(effect.key, of: layer.id) }
    }
}

/// Move to Custom Position's question, as WE's editor asks it: a row of the list between the top
/// (1) and the bottom.
struct ListPositionSheet: View {
    @ObservedObject var session: SceneEditSession
    @ObservedObject var tools: EditorTools
    let layerID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var position = 1

    var body: some View {
        let number = session.listRows.count
        VStack(alignment: .leading, spacing: 14) {
            Text(LC("Enter Layer Position")).font(.headline)
            Text(LC("Move this layer to a new position between the top (1) or the bottom (\(number)) of the list."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(LC("Position"), value: $position, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(LC("Move"), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { position = (session.listRows.firstIndex(of: layerID) ?? 0) + 1 }
    }

    private func commit() {
        session.moveToListPosition(layerID, position: position, actionName: L("Reorder Layers"))
        dismiss()
    }
}
