import Foundation
import Metal
import simd

/// The user's quality settings that change how WE draws a scene (`wallpaper64.exe` 0x14010ed80;
/// docs/lighting-plan.md §2.2, §2.6), and the app's particle budget (`ParticleBudget`). The app hands them to each wallpaper instance: the view model
/// (for what is decided at load, like HDR and the engine combos) and the renderer (per frame).
struct SceneRenderSettings: Equatable {
    var postProcessing = GSPostProcessingQuality.enabled
    var reflection = true
    var shadows = GSLightingQuality.medium
    var volumetrics = GSLightingQuality.medium
    /// "Cheaper shadows": shadow maps at half WE's size (`SceneShadowAtlas.mapSize`). Off draws
    /// them as WE does.
    var cheaperShadows = false
    /// The most particles a scene may hold (`ParticleBudget`); the content is built for it.
    var particleBudget = GSParticleBudget.medium
    /// WE's texture reduction (`TextureReduction`), 1 or 2: the user's setting resolved for the
    /// displays showing the scene and its size (`init(_:outputPixels:sceneSize:)`). Textures load for it.
    var textureReduction = 1
    /// "Optimise textures" (`TexturePreparation`): colour images load as prepared BC7 textures.
    /// Off without settings, so a settings-less renderer draws the images as they are.
    var optimiseTextures = false
    /// Large additive particle systems of a scene without depth draw into a half-resolution target
    /// that is added back in their place: a quarter of their fragments, softer edges. Off by default.
    var reducedResolutionParticles = false
    /// What the scene target is sized for (`GSRenderResolution`): the displays' backing pixels, 4K
    /// at their shape, or the scene's authored size. A settings-less renderer draws at the backing
    /// pixels, as WE does.
    var renderResolution = GSRenderResolution.yourDisplay
    /// The scene target is never smaller than the scene's authored size (`SceneRenderResolution`):
    /// a settings-less renderer's and the exports' floor (`LivePhotoRenderer.renderSettings`), so
    /// a smaller output is a downsampled full-size frame, as WE's captures are. Off for the user's
    /// settings, where Render Resolution alone sizes the target.
    var floorsAtAuthoredSize = true
    /// Draw the scene at `renderScale` of its target, which the composite scales up bilinearly.
    var upscaling = GSUpscaling.off
    var renderScale = GSRenderScale.percent75
    /// Effect Detail: layers' effects at their texture size as WE runs them (`full`, what a
    /// settings-less renderer does), or at most at the layer's size on screen.
    var sceneDetail = GSSceneDetail.full
    /// WE's `msaa`: the scene pass's samples per pixel.
    var antiAliasing = GSAntiAliasingQuality.none
    /// WE's "Video loading": a video wallpaper on the Metal path opens its file from disk or reads
    /// it into memory (`VideoFileSource`). Read when the video opens; not part of the content key.
    var videoReadMode = GSVideoReadMode.fromDisk

    init() {}

    init(_ settings: GlobalSettings) {
        postProcessing = settings.postProcessing
        reflection = settings.reflections
        shadows = settings.shadows
        volumetrics = settings.volumetrics
        cheaperShadows = settings.cheaperShadows
        particleBudget = settings.particleBudget
        renderResolution = settings.renderResolution
        floorsAtAuthoredSize = false
        sceneDetail = settings.sceneDetail
        upscaling = settings.upscaling
        renderScale = settings.renderScale
        antiAliasing = settings.antiAliasing
        optimiseTextures = settings.optimiseTextures
        reducedResolutionParticles = settings.reducedResolutionParticles
        videoReadMode = settings.videoReadMode
    }

    /// The share of each side of the scene target that is drawn: 1 without upscaling.
    var drawnScale: Float { upscaling == .off ? 1 : renderScale.factor }

    /// The scene pass's sample count on `device`: the setting's, or the most below it the GPU
    /// supports (1 always is).
    func sceneSampleCount(on device: MTLDevice) -> Int {
        var count = antiAliasing.sampleCount
        while count > 1, !device.supportsTextureSampleCount(count) { count /= 2 }
        return max(count, 1)
    }

    /// Whether a layer's `brightness` scales its colour. WE multiplies the colour it draws a layer
    /// with by `brightness` only under engine flag 0x2000 (`0x140207a2b…0x140207a72`, and
    /// likewise at `0x140207bd2` and `0x1402086e1`), which the `ultra` and `displayhdr`
    /// post-processing settings set (`0x14010e6ba`, `0x14010e6da`); otherwise it uses 1.
    var appliesBrightness: Bool {
        postProcessing == .ultra || postProcessing == .displayhdr
    }

    /// `settings` with the texture reduction WE's `resolution` setting gives on displays whose
    /// largest drawable is `outputPixels` (zero while none is known), for a scene of orthographic
    /// size `sceneSize` (`TextureReduction.orthographicSize(of:)`; nil when it has none). WE weighs
    /// the window it draws into; here that is the size Render Resolution draws for
    /// (`renderedPixels`), so 4K or Full doesn't halve the textures it draws larger for.
    init(_ settings: GlobalSettings, outputPixels: SIMD2<Float>, sceneSize: SIMD2<Float>? = nil) {
        self.init(settings)
        let rendered = Self.renderedPixels(settings.renderResolution, outputPixels: outputPixels, sceneSize: sceneSize)
        textureReduction = TextureReduction.factor(settings.textureResolution, outputPixels: rendered,
                                                   sceneSize: sceneSize)
    }

    /// The pixels `resolution` draws a scene for on displays whose largest drawable is
    /// `outputPixels` (zero while none is known): those, 4K at their shape, or the scene's
    /// orthographic size `sceneSize` (the displays' where it has none).
    static func renderedPixels(_ resolution: GSRenderResolution, outputPixels: SIMD2<Float>,
                               sceneSize: SIMD2<Float>?) -> SIMD2<Float> {
        guard outputPixels.x > 0, outputPixels.y > 0 else { return outputPixels }
        switch resolution {
        case .yourDisplay: return outputPixels
        case .uhd4K: return SceneRenderResolution.uhd4KSize(shapedLike: outputPixels)
        case .full:
            guard let sceneSize, sceneSize.x > 0, sceneSize.y > 0 else { return outputPixels }
            return sceneSize
        }
    }
}

extension GSPostProcessingQuality {
    /// Render flag 0x40: bloom can run (0x14010edab).
    var allowsBloom: Bool { self != .disabled }
    /// A scene with `bloom` and `hdr` draws in HDR (0x14010e612…0x14010e6da).
    var allowsHDR: Bool { self == .ultra || self == .displayhdr }
}
