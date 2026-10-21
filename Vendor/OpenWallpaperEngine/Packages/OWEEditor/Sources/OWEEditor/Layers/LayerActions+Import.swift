import Foundation
import OWESceneEditing

extension LayerActions {
    /// Imports `urls` with the importer's options as new image layers: one layer each, or one
    /// animated layer for the whole sequence; MP4s become video image layers.
    func importImages(_ urls: [URL], options: TextureImportOptions, asSequence: Bool, at point: SIMD2<Double>? = nil) {
        guard let store = services.assetStore else { return }
        if asSequence, urls.count > 1 {
            do {
                let image = try store.importImageSequence(from: urls, options: options)
                session.addLayer(SceneLayerFactory.image(name: image.title, model: image.model, size: image.size,
                                                         origin: point ?? sceneCentre), actionName: L("Add Image Layer"))
            } catch {
                tools.problem = L("The image sequence couldn’t be added: \(error.localizedDescription)")
            }
            return
        }
        for url in urls {
            do {
                let image = try store.importImage(from: url, options: options)
                // A cropped picture's content stays where it was in the full picture (WE's `cropoffset`).
                let origin = (point ?? sceneCentre) + (image.cropOffset ?? .zero)
                session.addLayer(SceneLayerFactory.image(name: image.title, model: image.model, size: image.size,
                                                         origin: origin), actionName: L("Add Image Layer"))
            } catch {
                tools.problem = L("“\(url.lastPathComponent)” couldn’t be added: \(error.localizedDescription)")
            }
        }
    }
}
