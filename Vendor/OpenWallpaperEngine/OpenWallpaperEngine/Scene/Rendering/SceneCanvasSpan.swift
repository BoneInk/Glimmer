import simd

/// A stretched display's part of a shared frame (WE's span): the frame is placed on the whole
/// canvas, at the display's density, and the display shows its own rect of it. Gaps between
/// displays are canvas no display shows.
struct SceneCanvasSpan: Equatable {
    /// The canvas in the display's pixels.
    var canvasPixels: SIMD2<Float>
    /// The bottom-left of the display's rect on the canvas, in its pixels (y up).
    var origin: SIMD2<Float>

    init(canvasPixels: SIMD2<Float>, origin: SIMD2<Float>) {
        self.canvasPixels = canvasPixels
        self.origin = origin
    }

    /// The span of the view `snapshot` was taken of, with `pixelsPerPoint` drawable pixels per
    /// point; nil while its display isn't stretched.
    init?(snapshot: SceneViewSnapshot, pixelsPerPoint: Float) {
        guard let canvas = snapshot.canvas, let rect = snapshot.rectInCanvas else { return nil }
        canvasPixels = SIMD2(Float(canvas.width), Float(canvas.height)) * pixelsPerPoint
        origin = SIMD2(Float(rect.minX), Float(rect.minY)) * pixelsPerPoint
    }

    /// A canvas point (pixels, y up) on the display's drawable.
    func drawablePoint(_ canvasPoint: SIMD2<Float>) -> SIMD2<Float> { canvasPoint - origin }

    /// Moves a quad placed on the canvas (`sceneSize` the canvas) onto the display's drawable of
    /// `drawableSize` pixels: what falls outside the display's rect is clipped.
    func apply(to uniform: inout LayerUniform, drawableSize: SIMD2<Float>) {
        uniform.position = drawablePoint(uniform.position)
        uniform.sceneSize = drawableSize
    }
}
