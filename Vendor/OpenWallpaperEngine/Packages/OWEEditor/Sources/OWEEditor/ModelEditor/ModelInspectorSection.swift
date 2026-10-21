import OWEModelImport
import OWESceneEditing
import SwiftUI

/// The inspector's section for a model layer: what its model has, and Configure Model, which
/// opens the Model Editor for a model imported in the editor (its source is with the edits'
/// files). A model the wallpaper or WE ships has no source to compile again.
struct ModelInspectorSection: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    let services: WallpaperEditorServices
    @State private var isEditing = false

    private var model: String? { session.value("model", of: layer.id)?.stringValue }

    var body: some View {
        if let model, model.lowercased().hasSuffix(".mdl") {
            Section {
                LabeledContent(ML("Model")) { Text(model).lineLimit(1).truncationMode(.middle) }
                if let store = services.assetStore, store.modelSource(for: model) != nil {
                    Button(ML("Configure Model…")) { isEditing = true }
                        .sheet(isPresented: $isEditing) {
                            ModelEditorView(session: session, layer: layer,
                                            editor: ModelEditorModel(model: model, store: store, readFile: services.readFile))
                        }
                }
            } header: {
                Text(ML("Model Editor"))
            } footer: {
                if services.assetStore?.modelSource(for: model) == nil {
                    Text(ML("Models imported from FBX or OBJ files can be configured."))
                }
            }
        }
    }
}
