import Foundation

extension SceneMetalRenderer {
    /// `layer` with its decoded pixels replaced by their sizes, once they are on the GPU: the
    /// renderer's content keeps no CPU copy of an image. Nothing
    /// uploads a prepared layer again; a rebuild loads the files again.
    static func droppingPixels(_ layer: SceneMetalLayer) -> SceneMetalLayer {
        var layer = layer
        layer.source = layer.source.uploaded
        return layer
    }

    /// The same for a particle system's texture and its built-in draw's copy.
    static func dropPixels(_ system: inout SceneMetalParticleSystem) {
        system.source = system.source.uploaded
        system.fallbackSource = system.fallbackSource?.uploaded
    }
}
