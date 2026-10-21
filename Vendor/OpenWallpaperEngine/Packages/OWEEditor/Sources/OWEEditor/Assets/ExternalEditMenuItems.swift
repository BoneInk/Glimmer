import SwiftUI
import OWESceneEditing

/// The layer context menu's Edit with External Image Editor (an image layer with a picture of
/// its own) and the choice of the editor.
struct ExternalEditMenuItems: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    let actions: LayerActions

    var body: some View {
        if let editing = actions.services.externalEditing, layer.imageRole == .picture {
            Divider()
            Button(L("Edit with External Image Editor")) {
                editor(editing).edit(layer, session: session, services: actions.services, tools: actions.tools)
            }
            .disabled(actions.services.assetStore == nil)
            Button(L("Choose External Image Editor…")) { editor(editing).chooseApplication() }
        }
    }

    private func editor(_ editing: ExternalImageEditing) -> ExternalImageEditor {
        if let existing = actions.tools.externalEditor { return existing }
        let made = ExternalImageEditor(editing: editing)
        actions.tools.externalEditor = made
        return made
    }
}
