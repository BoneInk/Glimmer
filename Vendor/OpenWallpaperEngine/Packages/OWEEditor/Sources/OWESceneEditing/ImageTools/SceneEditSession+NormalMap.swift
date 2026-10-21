import CoreGraphics
import Foundation

/// Normal Map Generation's result applied to an image layer, as WE's editor imports it: the map
/// written as the picture's `<texture>_normal` (RG88, WE's `rg88`), set as the material's normal map
/// (`g_Texture1`). The material and model are copies in the edits' files and the layer's `image`
/// names the copy, so the wallpaper's own files never change and Undo puts the old `image` back.
extension SceneEditSession {
    /// Writes `normalMap` for the layer and makes it the layer's normal map; one undo step.
    /// Returns the normal map's texture path.
    @discardableResult
    public func applyNormalMap(_ normalMap: CGImage, to layerID: Int, store: EditorAssetStore,
                               readFile: (String) -> Data?, actionName: String) throws -> String {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile),
              let texture = material.texture else { throw ImageToolError.noPicture }
        let normalTexture = try store.writeNormalMap(normalMap, forTexture: texture)
        let model = try store.writeLayerMaterial(material.materialWithNormalMap(normalTexture), basedOn: material)
        edit(actionName: actionName) { overlay in overlay.setField("image", to: .string(model), of: layerID) }
        return normalTexture
    }

    /// Takes the layer's normal map away (WE's Remove Normal Map); one undo step.
    public func removeNormalMap(of layerID: Int, store: EditorAssetStore, readFile: (String) -> Data?, actionName: String) throws {
        guard let layer = outline.layer(layerID), let material = ImageLayerMaterial(layer: layer, readFile: readFile) else {
            throw ImageToolError.noPicture
        }
        guard material.normalMap != nil else { return }
        let model = try store.writeLayerMaterial(material.materialWithNormalMap(nil), basedOn: material)
        edit(actionName: actionName) { overlay in overlay.setField("image", to: .string(model), of: layerID) }
    }
}

/// Why an image tool can't run on a layer.
public enum ImageToolError: Error, Equatable, LocalizedError {
    /// Not an image layer with a picture of its own (WE: "Only for Image Layers").
    case noPicture
    /// The picture can't be read.
    case unreadablePicture

    public var errorDescription: String? {
        switch self {
        case .noPicture: return "This functionality is only available on image layers."
        case .unreadablePicture: return "The layer’s picture can’t be read."
        }
    }
}
