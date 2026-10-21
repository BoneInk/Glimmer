import Metal
import QuartzCore

/// Shows Chromium frames in a `CAMetalLayer`: each frame's IOSurface (already a Metal texture, no
/// copy across processes) is blitted into the layer's drawable and presented. A page's own view
/// and each display mirroring it (`WebPageMirrorView`) have one, all fed the same frames.
final class ChromiumFramePresenter: @unchecked Sendable { // `lock` guards the waiting frame.
    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue?
    /// Presents off the XPC queue, one frame at a time; a frame that arrives while one is being
    /// presented replaces the waiting one.
    private let presentQueue = DispatchQueue(label: "owe.chromium.present", qos: .userInteractive)
    private let lock = NSLock()
    private var waitingFrame: ChromiumFrame?
    private var presenting = false

    init(device: MTLDevice?) {
        queue = device?.makeCommandQueue()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false // the frame is blitted in
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
    }

    /// Presents `frame` (any thread).
    func enqueue(_ frame: ChromiumFrame) {
        let start: Bool = lock.withLock {
            waitingFrame = frame
            guard !presenting else { return false }
            presenting = true
            return true
        }
        if start { presentQueue.async { [weak self] in self?.presentWaiting() } }
    }

    private func presentWaiting() {
        while let frame = lock.withLock({ () -> ChromiumFrame? in
            let frame = waitingFrame
            waitingFrame = nil
            if frame == nil { presenting = false }
            return frame
        }) {
            present(frame)
        }
    }

    private func present(_ frame: ChromiumFrame) {
        guard let queue else { return }
        let size = CGSize(width: frame.texture.width, height: frame.texture.height)
        if layer.drawableSize != size { layer.drawableSize = size }
        guard let drawable = layer.nextDrawable(),
              drawable.texture.width == frame.texture.width, drawable.texture.height == frame.texture.height,
              let commands = queue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: frame.texture, to: drawable.texture)
        blit.endEncoding()
        // The surface stays referenced until the copy is done; the helper reuses it a few frames on.
        commands.addCompletedHandler { _ in _ = frame.surface }
        commands.present(drawable)
        commands.commit()
    }
}
