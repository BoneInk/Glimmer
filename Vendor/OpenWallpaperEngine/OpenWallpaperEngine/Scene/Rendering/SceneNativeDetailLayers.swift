import simd

/// Which "detail" layers draw at the output's backing pixels instead of in the scene pass.
///
/// When the scene target has fewer pixels than the output (an Upscaling render scale below 1, or
/// Render Resolution 4K or Full on a larger display) it is scaled up onto it, which stretches
/// text and the media artwork. A detail layer (text, or an image whose texture is the now-playing artwork) whose
/// pixels nothing after it reads or covers can instead be drawn onto the output once the scene is
/// placed there: the same quad, opacity, colour and blend over the same pixels beneath it, so the
/// frame layers exactly as before, only sharper. Everything else stays in the scene pass.
///
/// When the post-process does more than place the scene (`Mode.patch`), the promoted layers still
/// go into the scene target after everything else whenever something reads the finished scene
/// (WE's bloom, `_rt_MipMappedFrameBuffer`), so the glow and reflections come from them as before
/// and the low-resolution frame is the plain one. Their sharp copy is drawn into a patch of output
/// pixels over the upscaled scene as it was without them, the bloom's `_rt_Bloom` is added as
/// `combine_ldr` adds it, and the patch runs through WE's colour correction and camera fade and the
/// composite's own adjustments before it replaces that part of the output. Every step after the
/// bloom works per pixel, so the patch is what the low-resolution path shows there, drawn at the
/// output's pixels. Not promoted: frames drawn in HDR or to EDR (`combine_hdr` samples the bloom
/// around each pixel and the frame converts), with WE's volumetrics running (they add light over
/// the finished scene from its depth), and under the app's blur (not per pixel).
enum SceneNativeDetailLayers {
    typealias Rect = SceneSnapshotTracker.Rect

    /// One object of the scene pass, in WE's draw order.
    enum Item: Equatable {
        /// A layer drawn this frame: its index, its pixels in the scene target (nil for a layer
        /// whose footprint isn't known, such as one placed through a 3D camera), whether it reads
        /// the scene drawn before it, and whether it may be promoted on its own (`isCandidate`).
        case layer(index: Int, bounds: SceneSnapshotTracker.Rect?, readsScene: Bool, candidate: Bool)
        /// A model or particle system: its footprint isn't tracked, so it covers everything.
        case unbounded
    }

    /// A layer may leave the scene pass when it is a detail layer (text or the media artwork),
    /// drawn and visible, not sampled by a model or another layer, without effects of its own
    /// (its text's font effects are in its raster), not reading the scene, not a puppet and drawn
    /// in the scene's plane (no 3D placement, which tests the scene's depth).
    static func isCandidate(isText: Bool, isMediaImage: Bool, visible: Bool, compositeSource: Bool,
                            hasLayerEffects: Bool, readsScene: Bool, isPuppet: Bool, placed3D: Bool) -> Bool {
        (isText || isMediaImage) && visible && !compositeSource && !hasLayerEffects && !readsScene
            && !isPuppet && !placed3D
    }

    /// Whether drawing at the output gains any pixels: the output has more of them per scene unit
    /// than the scene pass (Display on a Retina panel, or a render scale below 1). Not at Retina
    /// with no render scale, where the two match.
    static func gainsDetail(scenePixelsPerUnit: Float, outputPixelsPerUnit: Float) -> Bool {
        scenePixelsPerUnit > 0 && outputPixelsPerUnit.isFinite && outputPixelsPerUnit > scenePixelsPerUnit * 1.01
    }

    /// The layers of `items` promoted to the native pass. Walking from the last object drawn back,
    /// a candidate is promoted when nothing kept in the scene pass after it reads the scene or
    /// touches its pixels (`padding` scene-target pixels around it, for the upscale's filter). A
    /// later promoted layer doesn't block it: the native pass keeps their order.
    static func promoted(_ items: [Item], padding: Int = 1) -> Set<Int> {
        var promoted = Set<Int>()
        var covered: [SceneSnapshotTracker.Rect] = []
        var blocked = false
        for item in items.reversed() {
            switch item {
            case .unbounded:
                blocked = true
            case let .layer(index, bounds, readsScene, candidate):
                if candidate, !blocked, let bounds {
                    let grown = SceneSnapshotTracker.Rect(x: bounds.x - padding, y: bounds.y - padding,
                                                          width: bounds.width + 2 * padding,
                                                          height: bounds.height + 2 * padding)
                    if !covered.contains(where: { $0.intersection(grown) != nil }) {
                        promoted.insert(index)
                        continue
                    }
                }
                if readsScene { blocked = true }
                // The later layer's own pixels are filtered by the upscale too: grow it alike.
                if let bounds {
                    covered.append(SceneSnapshotTracker.Rect(x: bounds.x - padding, y: bounds.y - padding,
                                                             width: bounds.width + 2 * padding,
                                                             height: bounds.height + 2 * padding))
                } else {
                    blocked = true
                }
            }
        }
        return promoted
    }

    /// Where the composite puts the scene on the output: its rect in output pixels (origin at the
    /// top left, as a Metal viewport takes it), from the composite's quad (`layerUniform` of the
    /// whole scene, centred on the output for every placement).
    static func placedViewport(center: SIMD2<Float>, size: SIMD2<Float>, outputSize: SIMD2<Float>)
        -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        (SIMD2(center.x - size.x / 2, outputSize.y - center.y - size.y / 2), size)
    }

    // MARK: - The detail patch

    /// How the promoted layers reach the output this frame.
    enum Mode: Equatable {
        /// Drawn straight over the composited output: the post-process only places the scene.
        case direct
        /// Drawn into a patch of the output's pixels over the upscaled scene, which then runs
        /// through the frame's per-pixel post-process (the bloom's combine, colour correction, the
        /// camera fade, the app's saturation and hue) and replaces that part of the output.
        case patch
    }

    /// The smallest rect holding every non-empty rect of `rects`; nil when there is none.
    static func union(_ rects: [Rect]) -> Rect? {
        let filled = rects.filter { $0.width > 0 && $0.height > 0 }
        guard let first = filled.first else { return nil }
        var low = SIMD2(first.x, first.y)
        var high = SIMD2(first.maxX, first.maxY)
        for rect in filled.dropFirst() {
            low = pointwiseMin(low, SIMD2(rect.x, rect.y))
            high = pointwiseMax(high, SIMD2(rect.maxX, rect.maxY))
        }
        return Rect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

    /// The output pixels the scene target's `texels` land on through the composite, which puts
    /// the `sceneTexels` target on `placed` (origin at the top left, output pixels): rounded out
    /// to whole pixels with one more on each side, and kept within the placed scene and the
    /// output. Nil when none of them is on the output.
    static func outputRect(ofTexels texels: Rect, sceneTexels: SIMD2<Int>,
                           placed: (origin: SIMD2<Float>, size: SIMD2<Float>), outputSize: SIMD2<Int>) -> Rect? {
        guard sceneTexels.x > 0, sceneTexels.y > 0 else { return nil }
        let perTexel = placed.size / SIMD2(Float(sceneTexels.x), Float(sceneTexels.y))
        let low = placed.origin + SIMD2(Float(texels.x), Float(texels.y)) * perTexel
        let high = placed.origin + SIMD2(Float(texels.maxX), Float(texels.maxY)) * perTexel
        let output = SIMD2(Float(outputSize.x), Float(outputSize.y))
        let lowest = simd_max(placed.origin.rounded(.down), SIMD2<Float>(0, 0))
        let highest = simd_min((placed.origin + placed.size).rounded(.up), output)
        let from = simd_clamp((low - 1).rounded(.down), lowest, highest)
        let to = simd_clamp((high + 1).rounded(.up), lowest, highest)
        guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite, to.x > from.x, to.y > from.y else { return nil }
        return Rect(x: Int(from.x), y: Int(from.y), width: Int(to.x - from.x), height: Int(to.y - from.y))
    }

    /// The scene target's texels the composite's linear filter reads for the output pixels
    /// `outputRect` (the inverse of `outputRect(ofTexels:…)`, one texel more on each side), within
    /// the target.
    static func texels(under outputRect: Rect, sceneTexels: SIMD2<Int>,
                       placed: (origin: SIMD2<Float>, size: SIMD2<Float>)) -> Rect {
        let texels = SIMD2(Float(sceneTexels.x), Float(sceneTexels.y))
        let perPixel = texels / simd_max(placed.size, SIMD2<Float>(1, 1))
        let low = (SIMD2(Float(outputRect.x), Float(outputRect.y)) - placed.origin) * perPixel
        let high = (SIMD2(Float(outputRect.maxX), Float(outputRect.maxY)) - placed.origin) * perPixel
        let from = simd_clamp((low - 1).rounded(.down), SIMD2<Float>(0, 0), texels)
        let to = simd_clamp((high + 1).rounded(.up), SIMD2<Float>(0, 0), texels)
        return Rect(x: Int(from.x), y: Int(from.y), width: max(Int(to.x - from.x), 0), height: max(Int(to.y - from.y), 0))
    }

    /// The texture coordinates that read the scene target's texel space from a copy of its
    /// `region` alone: the copy's origin and axes for a quad whose corners span the whole scene
    /// (`LayerUniform.uvOrigin`, `uvAxisX`, `uvAxisY`). The linear filter then reads the copy at
    /// the texels it would read in the target.
    static func copyUV(of region: Rect, sceneTexels: SIMD2<Int>)
        -> (origin: SIMD2<Float>, axisX: SIMD2<Float>, axisY: SIMD2<Float>) {
        let size = SIMD2(Float(max(region.width, 1)), Float(max(region.height, 1)))
        return (SIMD2(-Float(region.x), -Float(region.y)) / size,
                SIMD2(Float(sceneTexels.x) / size.x, 0), SIMD2(0, Float(sceneTexels.y) / size.y))
    }

    /// The position (y up, as `sceneVertex` takes it) of a quad centred at `center` (y up, output
    /// pixels) when drawn into the patch `rect` of an `outputHeight`-pixel output instead.
    static func patchPosition(_ center: SIMD2<Float>, rect: Rect, outputHeight: Int) -> SIMD2<Float> {
        center - SIMD2(Float(rect.x), Float(outputHeight - rect.maxY))
    }
}
