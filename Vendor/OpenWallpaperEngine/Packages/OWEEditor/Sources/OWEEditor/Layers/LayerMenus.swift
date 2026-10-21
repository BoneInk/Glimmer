import SwiftUI
import OWESceneEditing

/// The toolbar's Add menu: the layers WE's editor adds (its Add Asset dialog: renderables, then
/// utility layers, then presets).
struct AddLayerMenu: View {
    let actions: LayerActions
    @State private var isPickingModel = false
    @State private var isBrowsingPresets = false

    var body: some View {
        Menu {
            Button { actions.chooseImages() } label: { Label(L("Image…"), systemImage: "photo") }
                .disabled(actions.services.assetStore == nil)
            Menu {
                Button(L("Text")) { actions.addText() }
                Button(L("Clock")) { actions.addText(script: .clock) }
                Button(L("Date")) { actions.addText(script: .date) }
            } label: {
                Label(L("Text"), systemImage: "textformat")
            }
            Button { actions.chooseSounds() } label: { Label(L("Sound…"), systemImage: "speaker.wave.2") }
                .disabled(actions.services.assetStore == nil)
            Menu {
                ForEach(SceneLayerFactory.LightKind.allCases, id: \.self) { kind in
                    Button { actions.addLight(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                }
            } label: {
                Label(L("Light"), systemImage: "lightbulb")
            }
            Button { isPickingModel = true } label: { Label(L("Model…"), systemImage: "cube") }
            Divider()
            Button { actions.addSolid() } label: { Label(L("Solid Color"), systemImage: "square.fill") }
            Button { actions.addSolidPlaceholder() } label: { Label(L("Solid Placeholder"), systemImage: "square.dashed") }
                .disabled(actions.services.assetStore == nil)
            Button { actions.addComposition() } label: { Label(L("Composition Layer"), systemImage: "square.on.square.dashed") }
            Button { actions.addFullscreen() } label: { Label(L("Fullscreen Layer"), systemImage: "rectangle.inset.filled") }
            if actions.is2D {
                Button { actions.addFullComposition() } label: {
                    Label(L("Full Composition Layer"), systemImage: "rectangle.stack")
                }
            }
            Button { actions.addCamera() } label: { Label(L("Camera"), systemImage: "video") }
            Divider()
            Button { isBrowsingPresets = true } label: { Label(L("Preset…"), systemImage: "wand.and.stars") }
                .disabled(actions.services.assetStore == nil)
        } label: {
            Label(L("Add Layer"), systemImage: "plus")
        }
        .help(L("Add a layer to the scene"))
        .sheet(isPresented: $isPickingModel) {
            ModelPickerView(models: actions.modelChoices(), imported: actions.importedModels(),
                            importFiles: actions.services.assetStore == nil ? nil : { actions.chooseModels() }) { actions.addModel($0) }
        }
        .sheet(isPresented: $isBrowsingPresets) {
            PresetBrowserView(presets: actions.services.layerPresets().filter { $0.tag.isEmpty || $0.is3D != actions.is2D },
                              hasWEAssets: actions.services.hasWEAssets(), openAssetsSetup: actions.services.openAssetsSetup) {
                actions.addPreset($0, variant: $1)
            }
        }
    }
}

/// A layer's context menu in the list and on the canvas.
struct LayerContextMenu: View {
    @ObservedObject var session: SceneEditSession
    let layer: SceneLayer
    let actions: LayerActions

    var body: some View {
        Button(L("Rename")) { actions.tools.renaming = layer.id }
            .disabled(!session.isEditable("name", of: layer.id))
        Button(L("Duplicate")) { actions.duplicateSelection(layer.id) }
        Button(L("Delete"), role: .destructive) { actions.deleteSelection(layer.id) }
        ExternalEditMenuItems(session: session, layer: layer, actions: actions)
        ImageEditingMenuItems(layer: layer, actions: actions)
        Divider()
        Menu(L("Arrange")) {
            Button(L("Bring to Front")) { actions.bringToFront(layer.id) }
            Button(L("Bring Forward")) { actions.bringForward(layer.id) }
            Button(L("Send Backward")) { actions.sendBackward(layer.id) }
            Button(L("Send to Back")) { actions.sendToBack(layer.id) }
        }
        if layer.isPlanar, session.outline.size != nil {
            Menu(L("Align to Scene")) {
                AlignmentButtons(actions: actions, layerID: layer.id)
            }
        }
        LayerCommandItems(session: session, layer: layer, actions: actions)
        Divider()
        Button(L("Group")) { actions.group(layer.id) }
        if !session.outline.children(of: layer.id).isEmpty {
            Button(L("Ungroup")) { actions.ungroup(layer.id) }
        }
        if layer.parentID.flatMap(session.outline.layer) != nil {
            Button(L("Move Out of Group")) { actions.unparent(layer.id) }
        }
        let groups: [SceneLayer] = session.outline.layers.filter { (candidate: SceneLayer) -> Bool in
            guard candidate.id != layer.id else { return false }
            let isGroupLike: Bool = candidate.kind == .group || candidate.kind == .other
            return isGroupLike && session.canParent(layer.id, to: candidate.id)
        }
        if !groups.isEmpty {
            Menu(L("Move Into Group")) {
                ForEach(groups) { group in
                    Button(group.title) { actions.parent(layer.id, to: group.id) }
                }
            }
        }
    }
}

/// Align to the scene's edges and centre lines.
struct AlignmentButtons: View {
    let actions: LayerActions
    let layerID: Int

    var body: some View {
        Button { actions.align(layerID, horizontal: 0) } label: { Label(L("Align Left Edges"), systemImage: "align.horizontal.left") }
        Button { actions.align(layerID, horizontal: 1) } label: { Label(L("Align Horizontal Centers"), systemImage: "align.horizontal.center") }
        Button { actions.align(layerID, horizontal: 2) } label: { Label(L("Align Right Edges"), systemImage: "align.horizontal.right") }
        Divider()
        Button { actions.align(layerID, vertical: 2) } label: { Label(L("Align Top Edges"), systemImage: "align.vertical.top") }
        Button { actions.align(layerID, vertical: 1) } label: { Label(L("Align Vertical Centers"), systemImage: "align.vertical.center") }
        Button { actions.align(layerID, vertical: 0) } label: { Label(L("Align Bottom Edges"), systemImage: "align.vertical.bottom") }
        Divider()
        Button { actions.align(layerID, horizontal: 1, vertical: 1) } label: { Label(L("Center on Scene"), systemImage: "plus.viewfinder") }
    }
}
