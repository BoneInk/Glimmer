import simd

/// The rect of the mesh's space (the image's pixels, centred, y up) a puppet's albedo target
/// covers. WE draws a puppet in the scene through its mesh (docs/models-plan.md §2.13), so
/// vertices a pose moves past the image's rect still draw; with effects the bind-pose mesh goes
/// into the image-sized buffer the effects start from, and the posed mesh lays their output out
/// over the canvas. The canvas covers the posed mesh as well as the image; the layer's quad grows to
/// it, and every texture laid out through the mesh keeps its layout (the canvas in the image's
/// texels).
struct ScenePuppetCanvas: Equatable {
    var min: SIMD2<Float>
    var max: SIMD2<Float>

    static func image(_ size: SIMD2<Float>) -> ScenePuppetCanvas { ScenePuppetCanvas(min: -size / 2, max: size / 2) }

    var size: SIMD2<Float> { max - min }

    /// The share of `canvas` an image of `imageSize` covers, per axis (1 for the image's rect).
    static func imageShare(imageSize: SIMD2<Float>, canvas: ScenePuppetCanvas) -> SIMD2<Float> {
        let size = canvas.size
        return SIMD2(size.x > 0 ? Swift.min(1, imageSize.x / size.x) : 1, size.y > 0 ? Swift.min(1, imageSize.y / size.y) : 1)
    }
    var center: SIMD2<Float> { (min + max) / 2 }

    /// The image's rect grown to cover `bounds`, each side in steps of an eighth of the image (so
    /// a moving pose doesn't resize it every frame), never smaller than `current`.
    static func covering(_ bounds: (min: SIMD2<Float>, max: SIMD2<Float>)?, imageSize: SIMD2<Float>,
                         current: ScenePuppetCanvas?) -> ScenePuppetCanvas {
        let image = ScenePuppetCanvas.image(imageSize)
        var canvas = current ?? image
        guard let bounds else { return canvas }
        let step = imageSize / 8
        func grown(_ over: SIMD2<Float>) -> SIMD2<Float> {
            let steps = (simd_max(over, .zero) / step).rounded(.up)
            return steps * step
        }
        canvas.min = simd_min(canvas.min, image.min - grown(image.min - bounds.min))
        canvas.max = simd_max(canvas.max, image.max + grown(bounds.max - image.max))
        return canvas
    }

    /// Canvas pixels onto the viewport: x min…max → −1…1, y max → −1 (GL clip, the target's first
    /// row, as the translated stage flips y), z ±1000 → 0…1.
    var projection: simd_float4x4 {
        let size = self.size, center = self.center
        return simd_float4x4(columns: (SIMD4(2 / size.x, 0, 0, 0), SIMD4(0, -2 / size.y, 0, 0),
                                       SIMD4(0, 0, 1 / 2000, 0), SIMD4(-2 * center.x / size.x, 2 * center.y / size.y, 0.5, 1)))
    }
}
