import Foundation

extension SceneRenderSettings {
    /// The part of the settings a content is built for: HDR (decided at load, 0x14010e612…
    /// 0x14010e6da), the shadow and volumetrics qualities (the engine combos and the volumetric
    /// passes are compiled for them), the particle budget, the texture reduction and "Optimise textures" (textures load
    /// for them). The rest WE applies per frame, and so does the renderer: the reflection copy
    /// (render flag 0x80, 0x140180a8c), whether bloom runs (flag 0x40, 0x140180a41), the render
    /// resolution and the scene detail. Changing only those needs no new content (test-risks LR19,
    /// LR24).
    struct ContentKey: Equatable {
        var hdr: Bool
        var shadows: GSLightingQuality
        var volumetrics: GSLightingQuality
        var particleBudget: GSParticleBudget
        var textureReduction: Int
        var optimiseTextures: Bool
    }

    var contentKey: ContentKey {
        ContentKey(hdr: postProcessing.allowsHDR, shadows: shadows, volumetrics: volumetrics,
                   particleBudget: particleBudget, textureReduction: textureReduction,
                   optimiseTextures: optimiseTextures)
    }
}
