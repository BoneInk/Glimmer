import MetalKit
import simd

/// One display showing a scene, as a frame needs it: the size of its drawable and of its view,
/// and where the cursor is on it. A shared scene renders one frame for all of its displays
/// (`SceneMetalRenderer.renderShared`), at the largest scene target any of them needs.
struct SceneViewport {
    /// The drawable, in pixels.
    var drawableSize: SIMD2<Float>
    /// The view, in points.
    var pointSize: SIMD2<Float>
    /// The cursor in the view's points (origin bottom-left), nil while it is on another display.
    var cursor: SIMD2<Float>?
    /// The view's frame-rate limit (WE's fps setting steers particles' half steps).
    var frameRateLimit: Int
    /// The display is part of a stretch: the sizes and the cursor are the canvas's.
    var spansCanvas = false

    var pixelsPerPoint: Float { pointSize.x > 0 ? drawableSize.x / pointSize.x : 1 }

    /// The cursor in drawable pixels, origin bottom-left.
    var cursorPixels: SIMD2<Float>? {
        cursor.map { $0 * drawableSize / simd_max(pointSize, SIMD2(1, 1)) }
    }

    /// The cursor in drawable pixels from the top-left (`input.cursorScreenPosition`).
    var cursorScreenPixels: SIMD2<Double>? {
        guard let cursor, pointSize.x > 0, pointSize.y > 0 else { return nil }
        return SIMD2(Double(cursor.x) * Double(drawableSize.x) / Double(pointSize.x),
                     Double(pointSize.y - cursor.y) * Double(drawableSize.y) / Double(pointSize.y))
    }

    /// The largest drawable of `viewports`, side by side: the scene target that serves them all.
    static func largestDrawable(_ viewports: [SceneViewport]) -> SIMD2<Float> {
        viewports.reduce(SIMD2<Float>(repeating: 0)) { simd_max($0, $1.drawableSize) }
    }
}

extension SceneViewport {
    /// `view` now: its drawable's size (`drawableSize` when it has none yet), and the cursor
    /// when it is on the view's display. On the main thread, like every draw.
    init(_ view: MTKView, drawableSize: SIMD2<Float>? = nil) {
        self.drawableSize = drawableSize ?? SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        // A view drawn on a render thread is read through its main-thread snapshot.
        if let snapshot = SceneViewSnapshots.snapshot(of: view) {
            frameRateLimit = snapshot.frameRateLimit
            if let canvas = snapshot.canvas {
                // A stretched display needs the whole canvas at its own density (WE renders a span
                // once); it presents its rect of it (`SceneMetalRenderer.present(in:)`).
                let pixelsPerPoint = snapshot.pointSize.x > 0 ? self.drawableSize.x / snapshot.pointSize.x : 1
                pointSize = SIMD2(Float(canvas.width), Float(canvas.height))
                self.drawableSize = (pointSize * pixelsPerPoint).rounded(.toNearestOrAwayFromZero)
                cursor = snapshot.canvasCursor(at: NSEvent.mouseLocation)
                spansCanvas = true
                return
            }
            pointSize = snapshot.pointSize
            cursor = snapshot.cursor(at: NSEvent.mouseLocation)
            return
        }
        pointSize = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
        frameRateLimit = view.preferredFramesPerSecond
        cursor = nil
        let mouse = NSEvent.mouseLocation
        guard let window = view.window, let screen = window.screen, screen.frame.contains(mouse) else { return }
        let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        guard view.bounds.contains(point) else { return }
        // A flipped clone shows the view mirrored (`NSView.isMirroredOnScreen`).
        let x = view.isMirroredOnScreen ? view.bounds.width - point.x : point.x
        cursor = SIMD2(Float(x), Float(point.y))
    }
}

/// Where one frame of `SceneMetalRenderer` goes: a view's drawable, or (with no pass yet) a
/// shared scene's finished frame, which its displays present.
struct SceneFrameDestination {
    /// A shared frame's clear colour, the same as a view's default.
    static let clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    var descriptor: MTLRenderPassDescriptor?
    var drawable: CAMetalDrawable?
    var pixelFormat: MTLPixelFormat
    /// The placement the post-process composites with (`.stretch` onto a shared frame).
    var placement: WallpaperPlacement
    /// The displays the frame is for; never empty, the driving display first.
    var viewports: [SceneViewport]

    /// The highest frame-rate limit among the displays.
    var frameRateLimit: Int { viewports.map(\.frameRateLimit).max() ?? 60 }
}
