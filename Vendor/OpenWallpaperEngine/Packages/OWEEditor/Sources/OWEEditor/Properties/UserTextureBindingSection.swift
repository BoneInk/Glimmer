import SwiftUI
import OWESceneEditing

/// The layers whose texture follows a `scenetexture` or `usershortcut` property: WE's editor binds
/// one from a layer's Advanced Texture Settings (Albedo › Bind User Property); here the property
/// lists its layers and binds more. A user texture replaces the layer's image with the user's
/// image or video; a shortcut shows its icon there.
struct UserTextureBindingSection: View {
    @ObservedObject var authoring: EditorAuthoringModel
    let property: UserPropertyDraft

    private var properties: UserPropertyAuthoring { authoring.properties }

    var body: some View {
        let bindings = properties.textureBindings(of: property.key)
        let bound = Set(bindings.map(\.layer))
        Section {
            if bindings.isEmpty {
                Text(L("No layer uses it yet."))
                    .foregroundStyle(.secondary)
            }
            ForEach(bindings, id: \.self) { binding in
                HStack {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text(layerTitle(binding.layer)).lineLimit(1)
                    Spacer()
                    Button {
                        properties.unbindTexture(binding, actionName: L("Unbind User Property"))
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("The layer shows its own texture again"))
                    .accessibilityLabel(L("Unbind User Property"))
                }
            }
            let free = properties.textureLayers.filter { !bound.contains($0.id) }
            Menu {
                ForEach(free) { layer in
                    Button(layer.title) {
                        properties.bindTexture(UserTextureBinding(layer: layer.id), to: property.key,
                                               actionName: L("Bind User Property"))
                    }
                }
            } label: {
                Label(L("Bind to Layer"), systemImage: "plus")
            }
            .disabled(free.isEmpty)
            .fixedSize()
        } header: {
            Text(L("Layers"))
        } footer: {
            Text(property.kind == .userShortcut
                 ? L("Scripts open the shortcut with engine.openUserShortcut('\(property.key)'). A bound layer shows its icon; keep it square, at most 256 × 256.")
                 : L("The user’s image or video replaces the layer’s texture; the layer’s own image shows until they pick one. A small placeholder scaled up saves memory."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func layerTitle(_ id: Int) -> String {
        authoring.session.outline.layer(id)?.title ?? String(id)
    }
}
