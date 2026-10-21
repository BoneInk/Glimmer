import ImageIO
import MetalKit

/// One display's view of a shared scene (`SceneWallpaperInstance`): it holds the instance while the
/// display shows it and hands the instance the view's draws. Everything else (loading, scripts,
/// particles, sound) belongs to the instance.
final class SceneWallpaperPresenter: NSObject, MTKViewDelegate {
    typealias Lease = WallpaperInstanceLease<WallpaperInstanceKey, SceneWallpaperInstance>

    private var lease: Lease?
    /// The preview, shown until the live scene draws. Main thread.
    private(set) var placeholder: ScenePreviewPlaceholder?
    /// The instance's render side, set in `show` before the view's link starts; read by `draw(in:)`.
    private var renderLoop: SceneRenderLoop?
    /// Render thread: the live scene's first frame was drawn and the preview told to go.
    private var shownContent = false

    @MainActor var instance: SceneWallpaperInstance? { lease?.instance }

    /// Shows `lease`'s instance in `view`, on the display `screenID`.
    @MainActor
    func show(_ lease: Lease, in view: MTKView, screenID: String) {
        self.lease = lease
        renderLoop = lease.instance.renderLoop
        // A display joining a scene already drawn needs no preview.
        if !lease.instance.hasContent {
            // The view isn't in its window yet: its display is the one `screenID` names.
            let screen = view.window?.screen ?? NSScreen.screens.first { WallpaperViewModel.screenId(for: $0) == screenID }
            placeholder = ScenePreviewPlaceholder(in: view, wallpaperDirectory: lease.instance.viewModel.currentWallpaper.wallpaperDirectory,
                                                  screen: screen, snapshots: lease.instance.loadingSnapshotStore)
        }
        lease.instance.attach(self, view: view, screenID: screenID)
    }

    /// Stops showing the instance; it stops too once no display shows it.
    @MainActor
    func stop() {
        placeholder?.remove()
        placeholder = nil
        guard let lease else { return }
        lease.instance.detach(self)
        lease.release()
        self.lease = nil
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Render thread: the view's display link draws it there (`SceneRenderLoop`).
    func draw(in view: MTKView) {
        guard let renderLoop, renderLoop.draw(ObjectIdentifier(self), in: view), !shownContent else { return }
        shownContent = true
        // Thread boundary: the live scene drew its first complete frame; crossfade to it on the main thread.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.instance?.hasContent = true
                self?.placeholder?.fadeOut()
                self?.placeholder = nil
            }
        }
    }
}

/// A picture of a scene wallpaper over its view while the scene loads, crossfaded out once the
/// live scene draws a complete frame (WE shows a wallpaper's preview while it loads too), so
/// setting a wallpaper never shows an empty desktop: the scene's own loading snapshot for this
/// display (`SceneLoadingSnapshotStore`, the nearest size scaled when none matches), else its
/// Workshop preview. The image is looked up and decoded off the main thread, at the display's size.
@MainActor
final class ScenePreviewPlaceholder {
    static let fadeDuration: CFTimeInterval = 0.25
    nonisolated static let previewNames = ["preview.jpg", "preview.png", "preview.gif", "preview.webp"]
    /// Its own serial queue: the global queues are busy with the scene's loading, which kept the
    /// picture (a few milliseconds of work) waiting about a second on an empty view.
    nonisolated private static let imageQueue = DispatchQueue(label: "app.openwallpaperengine.scene-preview",
                                                              qos: .userInteractive)

    let layer = CALayer()
    private(set) var isFading = false

    init(in view: NSView, wallpaperDirectory: URL, screen: NSScreen? = nil, snapshots: SceneLoadingSnapshotStore? = nil) {
        view.wantsLayer = true
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.zPosition = 1
        view.layer?.addSublayer(layer)
        let screen = screen ?? view.window?.screen ?? NSScreen.main
        let pixelSize = screen.map { SIMD2(Int($0.frame.width * $0.backingScaleFactor), Int($0.frame.height * $0.backingScaleFactor)) }
            ?? SIMD2(3840, 2160)
        let maxPixels = max(pixelSize.x, pixelSize.y)
        Self.imageQueue.async { [weak self] in
            let snapshot = snapshots?.bestSnapshot(forWallpaperAt: wallpaperDirectory, pixelSize: pixelSize)
            let image = snapshot.flatMap { Self.image(at: $0, maxPixels: maxPixels) }
                ?? Self.previewImage(in: wallpaperDirectory, maxPixels: maxPixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isFading, let image else { return }
                    self.layer.contents = image
                }
            }
        }
    }

    /// The wallpaper's preview, downsampled to `maxPixels` on its longer side (a GIF's first frame).
    nonisolated static func previewImage(in directory: URL, maxPixels: Int) -> CGImage? {
        for name in previewNames {
            if let image = image(at: directory.appending(path: name), maxPixels: maxPixels) { return image }
        }
        return nil
    }

    /// The image at `url` (a GIF's first frame), downsampled to `maxPixels` on its longer side.
    nonisolated static func image(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Crossfades to the live scene underneath, then removes the preview.
    func fadeOut() {
        guard !isFading else { return }
        isFading = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeDuration)
        CATransaction.setCompletionBlock { [layer] in layer.removeFromSuperlayer() }
        layer.opacity = 0
        CATransaction.commit()
    }

    func remove() {
        isFading = true
        layer.removeFromSuperlayer()
    }
}
