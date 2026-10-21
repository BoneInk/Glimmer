import AppKit
import Metal
import QuartzCore

/// A transition over a display's wallpaper: a Metal layer the transition's frames are presented
/// to (premultiplied), which the compositor lays over the incoming wallpaper's view. It sits in
/// the display options' transform with the wallpaper's view, so it lands where the picture does,
/// shows its `contentsRect` of the frame, and takes no mouse events.
final class WallpaperTransitionOverlayView: NSView {
    let metalLayer = CAMetalLayer()

    init(frame: CGRect, contentsRect: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.isOpaque = false
        metalLayer.contentsGravity = .resize
        metalLayer.contentsRect = contentsRect
        // Frames presented as they come, not animated.
        metalLayer.actions = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Takes frames of `pixelSize` in sRGB. `copiesFrames`: its drawables are copied to or from,
    /// for a transition several displays show.
    func prepare(device: MTLDevice, pixelSize: SIMD2<Int>, copiesFrames: Bool) {
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = !copiesFrames
        metalLayer.drawableSize = CGSize(width: pixelSize.x, height: pixelSize.y)
    }
}
