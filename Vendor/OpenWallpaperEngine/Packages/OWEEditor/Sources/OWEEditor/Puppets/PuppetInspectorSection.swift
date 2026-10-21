import OWESceneEditing
import SwiftUI

/// The inspector's Puppet Warp section for an image layer: what its rig has, and the button that
/// opens the puppet editor (creating a rig for an image without one).
struct PuppetInspectorSection: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    let assets: PuppetEditorAssets
    @State private var isEditing = false
    @State private var rigPath: String?

    var body: some View {
        Section {
            if let document = session.puppet(of: layer.id) {
                summary(document)
                Label(PL("Edited in the editor"), systemImage: "pencil.circle").foregroundStyle(.secondary)
            } else if let rigPath {
                LabeledContent(PL("Rig")) { Text(rigPath).lineLimit(1).truncationMode(.middle) }
            }
            Button(session.puppet(of: layer.id) != nil || rigPath != nil ? PL("Edit Puppet…") : PL("Create Puppet…")) {
                isEditing = true
            }
        } header: {
            Text(PL("Puppet Warp"))
        } footer: {
            if session.puppet(of: layer.id) != nil {
                Text(PL("Save as New Wallpaper writes the puppet's files."))
            }
        }
        .onAppear { rigPath = Self.rigPath(of: layer, assets: assets) }
        .sheet(isPresented: $isEditing) {
            PuppetWorkspaceView(session: session, layer: layer, assets: assets)
        }
    }

    @ViewBuilder private func summary(_ document: PuppetDocument) -> some View {
        LabeledContent(PL("Bones"), value: String(document.bones.count))
        LabeledContent(PL("Vertices"), value: String(document.mesh.vertices.count))
        LabeledContent(PL("Animations"), value: String(document.clips.count))
    }

    /// The `puppet` the layer's model names.
    static func rigPath(of layer: SceneLayer, assets: PuppetEditorAssets) -> String? {
        guard let model = layer.fields["image"]?.stringValue, let data = assets.readFile(model),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["puppet"] as? String
    }
}
