import Cocoa
import MetalKit
import CryptoKit

enum SceneMetalTextureSource {
    case image(NSImage)
    case dxt(TEXCompressedTexture)
    case animated(TEXAnimatedImages)
    /// Frames arrive from AVFoundation each frame rather than being decoded up front.
    case video(VideoTextureStream)
    /// A decoded image already on the GPU: only its sizes are kept, so the renderer's copy of the
    /// content holds no pixels (`uploaded`). Anything that uploads again loads the file again.
    case uploaded(SceneUploadedTexture)

    /// The image's own size in texels when it is smaller than the texture it is uploaded into
    /// (`g_TextureNResolution.zw`). Decoded images are already cropped to their content, so
    /// only block-compressed uploads, which keep the .tex padding, report one.
    var contentSize: SIMD2<Float>? {
        switch self {
        case let .dxt(texture):
            return SIMD2(Float(texture.contentWidth), Float(texture.contentHeight))
        case let .uploaded(info):
            return info.contentSize
        case let .image(image):
            // A raw .tex image is uploaded as its padded allocation, like a block-compressed one.
            guard let raw = TEXRawImageRep.of(image), raw.isPadded else { return nil }
            return SIMD2(Float(raw.pixelsWide), Float(raw.pixelsHigh))
        case .animated, .video:
            return nil
        }
    }

    /// The image's size in pixels, which WE sizes an unsized layer by. An `NSImage`'s `size` is in
    /// points and follows the file's DPI (a 144-dpi PNG reports half its pixels), so it isn't used.
    var pixelSize: SIMD2<Float> {
        switch self {
        case let .image(image): return Self.pixelSize(of: image)
        case let .dxt(texture): return SIMD2(Float(texture.contentWidth), Float(texture.contentHeight))
        case let .animated(animation): return animation.images.first.map(Self.pixelSize(of:)) ?? .zero
        case let .video(stream): return stream.frameSize
        case let .uploaded(info): return info.pixelSize
        }
    }

    /// The size WE gives an image object that names none (an `autosize` model placed without a
    /// `size`, e.g. by `thisScene.createLayer('models/x.json')`): a sprite sheet's frame, the
    /// first `TEXS` frame's edges, not the atlas it is packed in; any other image's own size.
    var unsizedLayerSize: SIMD2<Float> {
        if case let .uploaded(info) = self { return info.unsizedLayerSize }
        guard case let .animated(animation) = self, let frame = animation.frames.first else { return pixelSize }
        return SIMD2(simd_length(SIMD2(frame.width, frame.widthY)), simd_length(SIMD2(frame.heightX, frame.height)))
    }

    /// What is kept once the pixels are on the GPU: decoded images and block-compressed data give
    /// way to their sizes; a video stays, since its frames keep arriving.
    var uploaded: SceneMetalTextureSource {
        switch self {
        case .image, .dxt, .animated:
            return .uploaded(SceneUploadedTexture(pixelSize: pixelSize, contentSize: contentSize,
                                                  unsizedLayerSize: unsizedLayerSize,
                                                  sheetPixelSize: sheetPixelSize))
        case .video, .uploaded:
            return self
        }
    }

    /// The texture's pixels that a `.tex-json` sprite-sheet frame size is measured in: the whole
    /// allocated texture (TEXS frame rects include the .tex padding). An image's pixels come from
    /// its bitmap: an `NSImage` made from a `CGImage` reports its representation's `pixelsWide` at
    /// the screen's backing scale (twice the bitmap on a Retina display). Nil without an image.
    var sheetPixelSize: SIMD2<Double>? {
        let size: SIMD2<Float>
        switch self {
        case let .dxt(texture): size = SIMD2(Float(texture.width), Float(texture.height))
        case let .uploaded(info): return info.sheetPixelSize
        case let .image(image):
            if let raw = TEXRawImageRep.of(image) {
                size = SIMD2(Float(raw.rowPixels), Float(raw.allocationRows))
            } else {
                size = pixelSize
            }
        case .animated, .video: size = pixelSize
        }
        return size.x > 0 && size.y > 0 ? SIMD2<Double>(size) : nil
    }

    static func pixelSize(of image: NSImage) -> SIMD2<Float> {
        if let raw = TEXRawImageRep.of(image) { return SIMD2(Float(raw.pixelsWide), Float(raw.pixelsHigh)) }
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return SIMD2(Float(cgImage.width), Float(cgImage.height))
        }
        return SIMD2(Float(image.size.width), Float(image.size.height))
    }
}

/// The sizes of an image `SceneMetalTextureSource.uploaded` stands for.
struct SceneUploadedTexture: Equatable {
    let pixelSize: SIMD2<Float>
    let contentSize: SIMD2<Float>?
    let unsizedLayerSize: SIMD2<Float>
    let sheetPixelSize: SIMD2<Double>?
}

struct SceneMetalLayer {
    let id: String
    let name: String
    /// Replaced by its sizes (`SceneMetalTextureSource.uploaded`) once the renderer uploaded it.
    var source: SceneMetalTextureSource
    /// `origin`, relative to the parent object (see `SceneMetalContent.transforms`).
    let position: SIMD2<Float>
    let size: SIMD2<Float>
    let scale: SIMD2<Float>
    let opacity: Float
    let brightness: Float
    let color: SIMD4<Float>
    let text: SceneMetalText?
    let parallaxDepth: SIMD3<Float>
    let perspective: Bool
    let rotation: Float
    /// `angles.x` and `angles.y` (radians): the orthographic squash of a tilted object.
    var tilt: SIMD2<Float> = .zero
    /// Set for video layers so the picture can pulse with the music the way the AVKit path does.
    var musicSync: VideoMusicSyncVisuals? = nil
    /// Authored effects, run through Wallpaper Engine's own shaders.
    var weEffects: [SceneEffectPlan] = []
    /// Composition, fullscreen and project layers: the base image is the scene rendered so far
    /// under the layer (`_rt_FullFrameBuffer`), not a texture.
    var sceneInput = false
    /// A scene-input layer authored `"copybackground": false`: its base image is the scene's colour
    /// with alpha 0, so only what its effects draw shows. WE swaps the layer's material for
    /// `materials/util/composelayer_clearalpha.json` (`CLEARALPHA` 1), its only use in the binary
    /// next to the `copybackground` key.
    var clearsSceneAlpha = false
    /// A layer whose material has no texture (a solid layer's `flat`, a shape): its fill as
    /// straight RGBA. Its quad stretches a 1×1 source, but WE sizes its effect buffers to the
    /// layer's `size`, rounded (`wallpaper64.exe` 0x140209206…0x14020923c), so its effects start
    /// from the fill at that size (`SceneMetalRenderer.solidEffectInput`).
    var solidFill: SIMD4<Float>? = nil
    /// A solid layer's own material's blending (`flat` in `materials/util/solidlayer.json`), which
    /// WE copies into the layer's last effect pass when that pass draws into the scene through the
    /// layer's quad (`SceneMetalRenderer.lastPassDrawsIntoScene`). Nil for any other layer.
    var solidBlending: String? = nil
    /// The layer's quad adds to the scene instead of blending over it. A `shape` object's blend
    /// state is WE's `additive` (the shape class's +0x108, `wallpaper64.exe` 0x140260790, writes
    /// blending 2, which `0x140157e0e` names `additive`), where an image's is its material's.
    var additive = false
    /// A texture WE supplies at run time in place of the layer's image (its `instance`'s
    /// `usertextures` slot 0, e.g. the now-playing artwork); the image stands in while there is none.
    var systemImage: SceneSystemTexture? = nil
    /// Index of the object in scene.json: layers and particle systems draw in that order.
    var order = 0
    /// `alignment` (images) or the text block's aligned edge: where the quad sits against `position`.
    var alignment: String? = nil
    /// `fullscreen` models cover the scene whatever their parent is.
    var fillsScene = false
    /// User-bound transform/colour values, re-resolved each frame.
    var bindings = SceneLayerBindings()
    /// The image object's own material, drawn through WE's shader; nil draws the layer natively.
    var imageMaterial: ImageMaterialPlan? = nil
    /// A Puppet Warp image's mesh: it draws the layer image each frame (`ScenePuppetRenderer`),
    /// which the layer's effects and its own draw then read in place of `source`.
    var puppet: ScenePuppetPlan? = nil
    /// An animated texture's name (`textures[0]` of the image's material): every layer drawing the
    /// same texture shares its clock (docs/timeline-plan.md §2.7). Nil for a still one.
    var textureKey: String? = nil

    /// The renderer must interrupt the scene pass for this layer to give it the scene so far.
    var readsScene: Bool {
        sceneInput || imageMaterial?.readsSceneSnapshot == true || effectsReadScene
    }

    /// An effect pass reads the scene: it may sample any of it, not just what is under the layer.
    var effectsReadScene: Bool {
        weEffects.contains { $0.passes.contains(where: \.readsSceneSnapshot) }
    }
}

/// Audio-reactive transforms applied to a video layer each frame.
struct VideoMusicSyncVisuals {
    let zoomAmount: Float
    let tiltAmount: Float
    let saturationAmount: Float
    /// Supplied by the video stream so sync can follow the wallpaper's own soundtrack rather than
    /// the system-wide capture, which cannot tell the two apart.
    var levelSource: (() -> Double)? = nil
}

struct SceneMetalText {
    var value: String
    var font: String?
    var pointSize: CGFloat
    var horizontalAlignment: String?
    var verticalAlignment: String?
    /// Inset from the layer's own bounds; every authored text object declares one.
    var padding: SIMD2<Float>
    /// The width lines wrap at: `maxwidth` while `limitwidth` is on, else nil.
    var maxWidth: Float?
    /// The rows kept: `maxrows` while `limitrows` is on, else nil.
    var maxRows: Int?
    var useEllipsis: Bool
    /// WE's `anchor` (none, center, top, topright, …, 0x14025a22b). WE's text translates its model
    /// matrix by four render-context floats per anchor (0x1402585c0), but nothing in
    /// `wallpaper64.exe` writes the first two, and WE's text captures (all `center`) sit where
    /// the unanchored layout puts them, so it moves nothing here (roadmap notes §8.13).
    var anchor: String?
    var blockAlign: Bool
    /// `outline`, `blur` and `dropshadow` (`SceneTextEffects`); nil for plain text.
    var effects: SceneTextEffects? = nil
    /// `maxwidth` and `maxrows` as authored (or WE's defaults), kept while their limit is off so a
    /// script that turns `limitwidth` / `limitrows` on wraps at them.
    var maxWidthValue = Float(WETextDefaults.maxWidth)
    var maxRowsValue = WETextDefaults.maxRows
    /// Loads a font a script names (`thisLayer.font`) that the scene didn't; nil keeps the
    /// fonts the scene registered.
    var fonts: SceneTextFontLoader? = nil
    /// `opaquebackground` and `backgroundcolor` (WE 2.x): the block (the lines' bounds plus
    /// `padding`) filled with the colour behind the glyphs. WE's text object keeps the switch as
    /// flag 0x2 at +0x594 and the colour at +0x4d0 (default black, constructor 0x140256baf); with
    /// it on, the text's buffer is sized with its padding (0x140258966) and cleared to the colour
    /// with the object's alpha (+0x33c), times `backgroundbrightness` (+0x4dc) under engine flag
    /// 0x2000, before the glyphs are drawn into it with that alpha too (0x140257c30, 0x140258015).
    /// So at an alpha below 1 the box shows through the glyphs: WE 2.8.0.42 (capture 537) draws
    /// white text at alpha 0.5 over a (0.2, 0.4, 0.8) box as (156, 170, 197), not a flat grey.
    var opaqueBackground = false
    var backgroundColor = SIMD3<Float>(repeating: 0)
    /// `backgroundbrightness` (default 1).
    var backgroundBrightness: Float = 1
    /// The box is drawn as its own quad under the glyphs (`SceneMetalRenderer`) rather than into
    /// the raster: set for a layer without effects, whose raster then holds the glyphs alone.
    var drawsBackgroundSeparately = false

    /// The box's colour in the raster, or nil without one (or when it is drawn separately).
    var background: SIMD3<Float>? { opaqueBackground && !drawsBackgroundSeparately ? backgroundColor : nil }

    /// Whether the raster holds the text's colours (font effects, or a background box) instead of
    /// white coverage the draw tints: such text draws natively, in its raster's colours.
    var rastersInColor: Bool { effects != nil || opaqueBackground }
    /// `spacing` (WE 2.8's letter spacing): added to each glyph's advance (x) and to the line
    /// height (y), in scene units (`SceneTextLayout`).
    var spacing = WETextDefaults.spacing

    /// Everything but `value` and `pointSize` that changes the laid-out raster, for the text cache.
    var layoutKey: String {
        "\(font ?? "")|\(horizontalAlignment ?? "")|\(verticalAlignment ?? "")|\(padding.x),\(padding.y)"
            + "|\(maxWidth.map { "\($0)" } ?? "")|\(maxRows.map { "\($0)" } ?? "")|\(useEllipsis)|\(blockAlign)|\(spacing.x),\(spacing.y)"
            + (background.map { "|bg\($0.x),\($0.y),\($0.z)" } ?? "") + (drawsBackgroundSeparately ? "|bgquad" : "")
    }
}

struct SceneBloomSettings {
    let enabled: Bool
    let strength: Float
    let threshold: Float
    let tint: SIMD3<Float>
    /// `hdr` and `bloomhdr*`; HDR also needs `enabled` and the user's post-processing setting.
    var hdr = SceneHDRBloomSettings()
}

struct SceneMetalContent {
    let size: SIMD2<Float>
    let layers: [SceneMetalLayer]
    let particleSystems: [SceneMetalParticleSystem]
    let bloom: SceneBloomSettings
    /// Every object's parent and authored transform; layer positions are relative to their parent.
    var transforms: SceneTransformHierarchy = .empty
    /// Objects that aren't drawn layers (groups, particle systems), by id: how their own
    /// transform moves, so what hangs below them follows.
    var motions: [String: SceneObjectMotion] = [:]
    var camera = SceneCameraEffects()
    /// The scene's `general`, which `camera` was resolved from: the renderer resolves it again
    /// when a property bound to it changes.
    var general: WESceneGeneral?
    /// The projection, camera settings, camera layers and paths, model objects and draw-order mode
    /// of WE's 3D runtime (`SceneSpatialContentBuilder`; docs/models-plan.md § Seams).
    var spatial = SceneSpatialContent()
    /// `general.clearcolor`, resolved against the user properties: the scene target's clear colour.
    var clearColor = SceneGeneralDefaults.clearColor
    /// `general.clearenabled`, resolved against the user properties: whether the scene target is
    /// cleared before each frame.
    var clearEnabled = true
    /// The wallpaper instance's key in the user-property store (its directory path).
    var wallpaperKey = ""
    /// Every object's own `visible` before scripts (authored, user-bound or the app's toggle), by
    /// id. Hidden objects are built anyway: scripts can show them (plan §4.3).
    var visibility: [String: Bool] = [:]
    /// What `visibility` and the effects' `visible` follow, which the renderer takes again when a
    /// user property changes (`SceneUserVisibility`).
    var userVisibility = SceneUserVisibility()
    /// The id of each object of scene.json, in scene order.
    var objectIDs: [Int] = []
    /// The scene's SceneScripts; nil when it has none.
    var scripts: SceneScriptSceneContent?
    /// The document the instance's timelines come from; nil for a preview or a video.
    var timelines: SceneTimelineSource?
    /// The scene's sound layers.
    var sounds: [SceneSoundContent] = []
    /// `general`'s lighting settings and the scene's light objects.
    var lighting = SceneLightingContent()
    /// WE's volumetric lights, planned for the user's volumetrics setting; nil when it is
    /// disabled or no light casts volumetrics (`SceneVolumetricsPlan`).
    var volumetrics: SceneVolumetricsPlan?
    /// The combos WE's engine sets on every material of this content (`SceneEngineCombos`).
    var engineCombos = SceneEngineCombos()
    /// WE's LDR bloom passes, planned with the content's engine combos; nil without a shader
    /// toolchain. Planned for every scene: a script or user property can turn `bloom` on.
    var bloomChain: SceneBloomChain?
    /// WE's HDR bloom and combines, planned when the content draws in HDR (`engineCombos.hdr`),
    /// in place of `bloomChain`; nil otherwise or without a shader toolchain.
    var hdrChain: SceneHDRChain?
    /// WE's colour correction (`ccsimple`) for the user's image filter and colour options; nil
    /// without a shader toolchain.
    var colorCorrection: SceneColorCorrection?
    /// WE's camera fade, made for a scene with camera paths; nil otherwise or without a shader
    /// toolchain.
    var cameraFade: SceneCameraFade?
    /// A HDR video drawn as linear light (`VideoTextureStream` in HDR mode): the HDR frame is
    /// finished by `combine_video_hdr` instead of `combine_srgb` (WE's render flag 0x10000).
    var videoHDR = false
}

/// `scene.json` as the content was built from it, for the wallpaper instance's `SceneAnimationSet`
/// (docs/timeline-plan.md §2.1). A renderer keeps its set, clocks and all, across content rebuilt
/// from the same document (a user property changed a layer), as it keeps the scripts.
struct SceneTimelineSource {
    var wallpaperID: String
    var document: SceneJSON
    var signature: String
}
