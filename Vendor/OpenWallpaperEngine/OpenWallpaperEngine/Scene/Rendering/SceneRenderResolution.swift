import simd

/// How many render-target pixels one scene unit gets. Render Resolution (`GSRenderResolution`)
/// alone chooses the size the target is drawn for (`drawableSize`): the displays' backing pixels,
/// 4K at their shape, or the scene's authored size; the scene covers it (`pixelsPerUnit`), larger
/// or smaller than authored. A renderer that floors the target at the authored size
/// (`SceneRenderSettings.floorsAtAuthoredSize`: a settings-less renderer and the exports) never
/// draws below it, as WE's captures don't. The GPU's largest texture caps every target.
enum SceneRenderResolution {
    /// The least pixels per unit a scene gets (a display 16× smaller than the scene).
    static let minimumPixelsPerUnit: Float = 1.0 / 16
    /// The largest 2D texture side every Mac GPU the app runs on can allocate. A target that
    /// would be larger is fitted into it rather than failing to allocate every frame.
    static let maximumTextureDimension: Float = 16384

    /// Pixels per scene unit for a scene of `sceneSize` covering `drawableSize` pixels: exactly,
    /// so a scene of the drawable's shape gets a target of exactly its size (a desktop window's
    /// size is fixed). `quantised` (a target that follows a live-resizing window: the editors'
    /// previews) rounds up to eighths, to 64ths below 1, so a resize doesn't reallocate the
    /// target every frame. `floorsAtAuthoredSize` never draws below the authored size, unless that
    /// exceeds what Metal can allocate.
    static func pixelsPerUnit(sceneSize: SIMD2<Float>, drawableSize: SIMD2<Float>, floorsAtAuthoredSize: Bool = false,
                              quantised: Bool = false) -> Float {
        let scene = simd_max(sceneSize, SIMD2(1, 1))
        let fitsTexture = maximumTextureDimension / max(scene.x, scene.y)
        guard fitsTexture.isFinite, fitsTexture > 0 else { return 1 }
        // The hardware limit is the only thing that draws a floored scene below its authored size.
        if floorsAtAuthoredSize, fitsTexture < 1 { return fitsTexture }
        guard drawableSize.x > 0, drawableSize.y > 0 else { return min(1, fitsTexture) }
        var wanted = max(drawableSize.x / scene.x, drawableSize.y / scene.y)
        guard wanted.isFinite else { return min(1, fitsTexture) }
        if floorsAtAuthoredSize { wanted = max(wanted, 1) }
        guard quantised else { return min(max(wanted, minimumPixelsPerUnit), fitsTexture) }
        let quantized = wanted < 1 ? max(minimumPixelsPerUnit, (wanted * 64).rounded(.up) / 64) : (wanted * 8).rounded(.up) / 8
        guard quantized > fitsTexture else { return quantized }
        return fitsTexture >= 1 ? max(1, (fitsTexture * 8).rounded(.down) / 8) : fitsTexture
    }

    /// The size, in pixels, the scene target is drawn for (`GSRenderResolution`): the largest of
    /// `viewports`' backing pixels for `yourDisplay` (one target pixel per display pixel), 4K at
    /// their shape for `uhd4K` (fitted to each display by the final composite: downsampled on a
    /// smaller one, scaled up on a larger one), or the scene's authored size for `full` (placed
    /// onto each display by the final composite, as WE places it).
    static func drawableSize(_ viewports: [SceneViewport], resolution: GSRenderResolution,
                             sceneSize: SIMD2<Float>) -> SIMD2<Float> {
        switch resolution {
        case .yourDisplay: return SceneViewport.largestDrawable(viewports)
        case .uhd4K: return uhd4KSize(shapedLike: SceneViewport.largestDrawable(viewports))
        case .full: return simd_max(sceneSize, SIMD2(1, 1))
        }
    }

    /// 4K at `display`'s shape: its long side `GSRenderResolution.uhd4KLongSide` (16:9 3840×2160,
    /// 16:10 3840×2400); 3840×2160 for a display without a size yet.
    static func uhd4KSize(shapedLike display: SIMD2<Float>) -> SIMD2<Float> {
        let longSide = GSRenderResolution.uhd4KLongSide
        guard display.x > 0, display.y > 0 else { return SIMD2(longSide, longSide * 9 / 16) }
        return (display * (longSide / max(display.x, display.y))).rounded(.toNearestOrAwayFromZero)
    }

    /// The pixels per unit the scene pass draws at when it draws `scale` of each side of a target
    /// of `pixelsPerUnit` and is upscaled to it by the composite; `pixelsPerUnit` when not scaled.
    static func drawnPixelsPerUnit(_ pixelsPerUnit: Float, scale: Float) -> Float {
        guard scale.isFinite, scale > 0, scale < 1 else { return pixelsPerUnit }
        return pixelsPerUnit * scale
    }

    /// The render target's size in pixels.
    static func targetSize(sceneSize: SIMD2<Float>, pixelsPerUnit: Float) -> SIMD2<Int> {
        let size = (simd_max(sceneSize, SIMD2(1, 1)) * pixelsPerUnit).rounded(.toNearestOrAwayFromZero)
        func side(_ pixels: Float) -> Int { pixels.isFinite ? Int(min(max(pixels, 1), maximumTextureDimension)) : 1 }
        return SIMD2(side(size.x), side(size.y))
    }
}
