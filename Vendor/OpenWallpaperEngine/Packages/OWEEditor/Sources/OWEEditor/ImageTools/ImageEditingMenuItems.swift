import OWESceneEditing
import SwiftUI

/// The layer context menu's Image Editing submenu (WE's `ui_editor_context_menu_image_editing`),
/// for an image layer with a picture of its own. WE runs its tools only on layers without
/// effects ("Image Layer has Effects").
struct ImageEditingMenuItems: View {
    let layer: SceneLayer
    let actions: LayerActions

    var body: some View {
        if layer.imageRole == .picture {
            Menu(IL("Image Editing")) {
                Button(IL("Foreground Separation")) { open(.foregroundSeparation) }
                Button(IL("Character Sheet Creation")) { open(.characterSheet) }
            }
            .disabled(actions.services.assetStore == nil)
        }
    }

    private func open(_ tool: ImageToolRequest.Tool) {
        guard layer.effects.isEmpty else {
            actions.tools.problem = IL("This functionality is not available on image layers with existing effects. Please either remove all image effects from this layer or re-import a copy of this image with a different name, then try again.")
            return
        }
        actions.tools.imageTool = ImageToolRequest(tool: tool, layerID: layer.id)
    }
}
