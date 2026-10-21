import CoreGraphics
import Foundation

/// Character Sheet Creation's OK, as WE's editor finishes it: "The existing layer will be removed
/// along with any effects or settings and a new texture with the character sheet for puppet warp
/// will be imported." The sheet is kept as `<texture>_sheet` with the edits' files and becomes a
/// new image layer (WE's import: its own material, the sheet's size) where the layer was; one
/// undo step.
extension SceneEditSession {
    /// Replaces the layer with the sheet; returns the new layer's id.
    @discardableResult
    public func replaceWithCharacterSheet(_ sheet: CGImage, layerID: Int, store: EditorAssetStore, readFile: (String) -> Data?,
                                          actionName: String) throws -> Int {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile),
              let texture = material.texture else { throw ImageToolError.noPicture }
        let title = ImageLayerMaterial.baseName(of: texture) + "_sheet"
        let sheetTexture = try store.writePicture(sheet, title: title)
        let name = String(sheetTexture.dropFirst("editor/".count))
        let size = SIMD2(Double(sheet.width), Double(sheet.height))
        let imported = try store.writeImageMaterial(name: name, texture: sheetTexture, normalMap: nil, size: size, title: title)
        // WE puts the sheet's layer at the scene's centre, without the old image's `cropoffset`
        // (WE 2.8.0.42, capture 545: origin 960 540 in a 1920 × 1080 scene).
        let transform = storedTransform(of: layerID)
        let parented = layer.parentID.flatMap(outline.layer) != nil
        let centre: SIMD2<Double>? = parented ? nil : outline.size.map { SIMD2($0.x / 2, $0.y / 2) }
        let origin: SIMD2<Double> = centre ?? SIMD2(transform.origin.x, transform.origin.y)
        var object = SceneLayerFactory.image(name: title, model: imported.model, size: size, origin: origin)
        if let parent = layer.parentID, outline.layer(parent) != nil { object["parent"] = .number(Double(parent)) }
        let id = nextObjectID
        var order = outline.layers.map(\.id)
        let position = order.firstIndex(of: layerID) ?? order.count
        var next = overlay
        let removed = Set(subtree(of: layerID))
        next.removeObjects(removed)
        next.addObject(.object(object), id: id)
        order.insert(id, at: position)
        next.order = order.filter { !removed.contains($0) }
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = id
        return id
    }
}
