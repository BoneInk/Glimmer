import Foundation
import OWESceneEditing
import WEFormat

/// The context menus' commands that take the selection: a right-clicked layer that is selected
/// stands for every selected layer, another one for itself.
extension LayerActions {
    /// The layers a command on `layerID` acts on.
    func targets(_ layerID: Int) -> [Int] {
        session.isSelected(layerID) && session.selectedLayers.count > 1 ? session.selectedRoots : [layerID]
    }

    func duplicateSelection(_ layerID: Int) {
        let copies = session.duplicate(targets(layerID), copyName: { name in
            name.isEmpty ? L("Copy") : L("\(name) Copy")
        }, actionName: L("Duplicate Layer"))
        if copies.count > 1 { session.select(Set(copies), primary: copies.last) }
    }

    func deleteSelection(_ layerID: Int) { session.delete(targets(layerID), actionName: L("Delete Layer")) }

    // MARK: Transforms

    func copyTransforms(_ layerID: Int) { tools.copiedTransform = session.copiedTransform(of: layerID) }

    func pasteTransforms(_ layerID: Int) {
        guard let transform = tools.copiedTransform else { return }
        session.pasteTransform(transform, onto: targets(layerID), actionName: LC("Paste Transforms"))
    }

    /// Rotate CW turns by −90°, Rotate CCW by +90°, about z.
    func rotate(_ layerID: Int, clockwise: Bool) {
        session.rotate(targets(layerID), by: clockwise ? -.pi / 2 : .pi / 2, actionName: L("Rotate Layer"))
    }

    func center(_ layerID: Int) { session.center(targets(layerID), actionName: LC("Center Layer")) }

    /// The `cropoffset` of the layer's image model (an image Wallpaper Engine cropped to its
    /// opaque part when it was imported keeps where the crop was): Align with Background puts it
    /// back where it was on the full image.
    func cropOffset(_ layerID: Int) -> SIMD2<Double>? {
        guard let model = session.outline.layer(layerID)?.fields["image"]?.stringValue, let data = services.readFile(model),
              let json = try? TolerantJSON.object(from: data) as? [String: Any], // no crop offset when the model can't be read
              let text = json["cropoffset"] as? String else { return nil }
        let components = SceneVector.components(.string(text))
        return components.count >= 2 ? SIMD2(components[0], components[1]) : nil
    }

    func alignWithBackground(_ layerID: Int) {
        session.center(targets(layerID), offset: { cropOffset($0) }, actionName: LC("Align with Background"))
    }

    // MARK: Effects

    func copyAllEffects(_ layerID: Int) { tools.copiedEffects = session.effectConfigs(of: layerID) }

    func pasteAllEffects(_ layerID: Int) {
        guard !tools.copiedEffects.isEmpty else { return }
        prepareEffects(tools.copiedEffects)
        session.addEffects(tools.copiedEffects, to: layerID, actionName: LC("Paste Effects"))
    }

    func copyEffect(_ effectKey: String, of layerID: Int) { tools.copiedEffect = session.effectConfig(effectKey, of: layerID) }

    func pasteEffect(on layerID: Int) {
        guard let effect = tools.copiedEffect else { return }
        prepareEffects([effect])
        session.addEffects([effect], to: layerID, actionName: LC("Paste Effect"))
    }

    func pasteEffectSettings(onto effectKey: String, of layerID: Int) {
        guard let effect = tools.copiedEffect else { return }
        session.applyEffectSettings(effect, onto: effectKey, of: layerID, actionName: LC("Paste Effect Settings"))
    }

    /// Whether the copied effect is the same effect as `effect` (Paste Effect Settings needs it).
    func canPasteSettings(onto effect: SceneLayerEffect) -> Bool {
        guard case .object(let copied)? = tools.copiedEffect else { return false }
        return copied["file"]?.stringValue == effect.file
    }

    func duplicateEffect(_ effectKey: String, of layerID: Int) {
        guard let effect = session.effectConfig(effectKey, of: layerID) else { return }
        session.addEffects([effect], to: layerID, after: effectKey, actionName: LC("Duplicate Effect"))
    }

    /// A pasted built-in effect's files go into the project as when it is added from the catalog
    /// (an effect copied from another window's wallpaper may not have them).
    private func prepareEffects(_ effects: [SceneJSONValue]) {
        let catalog = services.effectCatalog()
        for effect in effects {
            guard case .object(let object) = effect, let file = object["file"]?.stringValue,
                  let entry = catalog.first(where: { $0.file == file }) else { continue }
            do {
                try services.prepareEffect(entry)
            } catch {
                tools.problem = L("“\(entry.title)” couldn’t be added: \(error.localizedDescription)")
            }
        }
    }
}
