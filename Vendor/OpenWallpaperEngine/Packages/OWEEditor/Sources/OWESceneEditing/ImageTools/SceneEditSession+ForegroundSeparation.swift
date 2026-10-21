import CoreGraphics
import Foundation

/// Foreground Separation's OK, as WE's editor finishes it (`finishCharacterSeparation`): "The
/// existing image layer will be replaced with the new background image and a new layer with the
/// foreground image will be added." The background becomes the layer's picture (a copy of its
/// material drawing it); the foreground is a new image layer just above it, with the layer's
/// place, size and look. Both pictures are kept with the edits' files; it is one undo step.
extension SceneEditSession {
    /// Applies a separation of the layer's picture; returns the new foreground layer's id.
    @discardableResult
    public func applyForegroundSeparation(_ result: ForegroundSeparator.Result, to layerID: Int, store: EditorAssetStore,
                                          readFile: (String) -> Data?, foregroundName: String, actionName: String) throws -> Int {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile),
              let texture = material.texture else { throw ImageToolError.noPicture }
        guard let background = result.background.cgImage, let foreground = result.foreground.cgImage else {
            throw ImageToolError.unreadablePicture
        }
        let base = ImageLayerMaterial.baseName(of: texture)
        let backgroundTexture = try store.writePicture(background, title: base + "_background")
        let backgroundModel = try store.writeLayerMaterial(material.materialWithTexture(backgroundTexture), basedOn: material)
        let foregroundTexture = try store.writePicture(foreground, title: base + "_foreground")
        let foregroundModel = try store.writeLayerMaterial(material.materialWithTexture(foregroundTexture), basedOn: material)
        guard let applied = appliedObject(layerID), case .object(var object)? = SceneJSONValue(any: applied) else {
            throw ImageToolError.noPicture
        }
        var next = overlay
        next.setField("image", to: .string(backgroundModel), of: layerID)
        let foregroundID = nextObjectID
        object["id"] = nil
        object["name"] = .string(foregroundName)
        object["image"] = .string(foregroundModel)
        // WE separates only layers without effects; anything scripted stays on the original.
        object["effects"] = nil
        next.addObject(.object(object), id: foregroundID)
        var order = outline.layers.map(\.id)
        let after = subtree(of: layerID).compactMap { order.firstIndex(of: $0) }.max() ?? (order.count - 1)
        order.insert(foregroundID, at: min(after + 1, order.count))
        next.order = order
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = foregroundID
        return foregroundID
    }
}

extension EditorAssetStore {
    /// Keeps a picture an image tool made as a PNG texture (`materials/editor/<title>-<hash>.png`);
    /// returns its texture path.
    public func writePicture(_ image: CGImage, title: String) throws -> String {
        guard let png = Self.pngData(image) else { throw ImageToolError.unreadablePicture }
        let name = Self.assetName(title, data: png)
        try write(png, to: "materials/editor/\(name).png")
        return "editor/\(name)"
    }
}
