import simd

/// WE's "Texture Resolution" setting (config `resolution`: `full`, `half` or `auto`), as
/// `wallpaper64.exe` applies it.
///
/// - The setting sets engine flag 0x20 (`half`) or 0x10 (`auto`) (0x1401155f6…0x14011562f). The
///   engine compares the value with `full` and `half` only: any other (`auto`, no value, or a
///   `quarter` written by hand, which WE keeps in its config) is `auto`. There is no quarter
///   reduction; WE's captures with `quarter` at 1920 × 1080 are as sharp as `full`. At scene
///   load the engine's reduction is 1 + (whether to reduce) (0x140187e3c), and whether to reduce is
///   (0x14017e6f0): never with `full`, always with `half`, and with `auto` by the scene and the
///   window (`g_Screen`'s size, 0x1400d84eb). In a scene whose `general.orthogonalprojection` has a
///   size (engine flag 0x400, 0x1401875df…0x14018768a) when the scene's pixels exceed 3.9 × the
///   window's (0x140492848): a 3840 × 2160 scene on a 1920 × 1080 window reduces, a 1920 × 1080 one
///   never does. In any other scene when the window is under 0.95 × 1920 × 1080 = 1 969 920 pixels
///   (0x140492970).
/// - With a reduction over 1 the `.tex` loader skips the first mipmap of every image stored with
///   more than one (0x14015d3fd, load flag 2 from 0x1400ec44e); a texture with one mipmap loads
///   whole. The texture keeps its header's sizes, so a layer sized by its image keeps its size.
/// - A layer's effect buffers are its image's size (a composite or solid layer's own size) over the
///   reduction, except a fullscreen layer's (0x1402092c0…0x14020933c); WE's buffers then match the
///   halved image. `g_TextureReductionScale` is the reduction (0x1400d9958), which shaders that
///   offset vertices in texels multiply back (`effects/skew`).
enum TextureReduction {
    /// Below this many window pixels, `auto` reduces a scene without an orthographic size
    /// (0x140492970: 0.95 × 1920 × 1080).
    static let automaticPixelThreshold: Float = 1_969_920
    /// Above this many times the window's pixels, `auto` reduces a scene with an orthographic size
    /// (0x140492848).
    static let automaticSceneOverWindow: Float = 3.9

    /// The engine's reduction for `setting` on an output of `outputPixels` (the largest display's
    /// drawable): 1 or 2. `sceneSize` is the scene's orthographic size when it has one
    /// (`orthographicSize(of:)`), nil otherwise.
    static func factor(_ setting: GSTextureResolutionQuality, outputPixels: SIMD2<Float>,
                       sceneSize: SIMD2<Float>? = nil) -> Int {
        switch setting {
        case .highQuality: return 1
        case .highPerformance: return 2
        case .automatic:
            let area = outputPixels.x * outputPixels.y
            // No display known yet: WE's window always has a size; full resolution until one does.
            guard area > 0 else { return 1 }
            if let sceneSize {
                return sceneSize.x * sceneSize.y > automaticSceneOverWindow * area ? 2 : 1
            }
            return area < automaticPixelThreshold ? 2 : 1
        }
    }

    /// The size `auto` weighs a scene by when engine flag 0x400 is set, nil when it isn't: an
    /// orthographic scene's width and height (the flag needs both nonzero, 0x1401875b5…0x1401875df),
    /// zero for `{"auto": true}` (the flag is set but the sizes stay 0, 0x140187565, so `auto` never
    /// reduces it), nil for a perspective scene.
    static func orthographicSize(of scene: WEScene) -> SIMD2<Float>? {
        switch scene.general.projection {
        case .orthographic(let width, let height): return SIMD2(Float(width), Float(height))
        case .orthographicAuto: return .zero
        case .perspective: return nil
        }
    }

    /// The mipmap WE loads of an image stored with `mipmapCount` mipmaps: the second under a
    /// reduction when there is one, else the first.
    static func loadedMipmap(reduction: Int, mipmapCount: Int) -> Int {
        reduction > 1 && mipmapCount > 1 ? 1 : 0
    }

    /// A side of `side` pixels at mipmap `level`: halved per level, rounded down, at least 1 (the
    /// library's `.tex` files store 2760 × 4466 → 1380 × 2233 → 690 × 1116).
    static func mipmapSide(_ side: Int, level: Int) -> Int {
        max(1, side >> max(level, 0))
    }
}
