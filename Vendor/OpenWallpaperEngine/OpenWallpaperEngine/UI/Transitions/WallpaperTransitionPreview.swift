import AppKit
import Metal
import SwiftUI

/// A small looping preview of a transition between two pictures (two of the playlist's
/// previews), drawn by the transitions' own renderer: the incoming picture under the transition's
/// frames, as on a display. Random previews a kind from its pool each time round.
struct WallpaperTransitionPreview: NSViewRepresentable {
    let settings: WallpaperTransitionSettings
    let from: URL?
    let to: URL?

    func makeNSView(context: Context) -> WallpaperTransitionPreviewView {
        WallpaperTransitionPreviewView()
    }

    func updateNSView(_ view: WallpaperTransitionPreviewView, context: Context) {
        view.update(settings: settings, from: from, to: to)
    }

    static func dismantleNSView(_ view: WallpaperTransitionPreviewView, coordinator: ()) {
        view.stop()
    }
}

/// `WallpaperTransitionPreview`'s view: the incoming picture as its layer's contents, the
/// transition's frames (IOSurfaces) in an overlay layer, paced by the view's display link while
/// it is in a window.
final class WallpaperTransitionPreviewView: NSView {
    /// The preview's pixel size: enough for a thumbnail, cheap to draw.
    static let pixelSize = SIMD2<Int>(320, 180)
    /// The outgoing picture holds this long before and the incoming one after each run.
    static let hold: TimeInterval = 0.4

    private let overlay = CALayer()
    private var settings = WallpaperTransitionSettings.unset
    private var sources: (URL?, URL?) = (nil, nil)
    private var renderer: WallpaperTransitionRenderer?
    private var queue: MTLCommandQueue?
    private var outgoing: MTLTexture?
    private var prepared: [WallpaperTransitionKind: MTLTexture] = [:]
    private var surfaces: [(surface: IOSurface, texture: MTLTexture)] = []
    private var nextSurface = 0
    private var link: CADisplayLink?
    private var ticker: WallpaperTransitionTicker?
    private var cycleStart: CFTimeInterval?
    private var kind: WallpaperTransitionKind?
    private var seed = WallpaperTransitionSeed.random()
    private var frameInFlight = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        overlay.contentsGravity = .resizeAspectFill
        overlay.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        overlay.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopLink() } else { startLink() }
    }

    func update(settings: WallpaperTransitionSettings, from: URL?, to: URL?) {
        let changedSources = sources.0 != from || sources.1 != to
        guard settings != self.settings || changedSources else { return }
        self.settings = settings
        if changedSources {
            sources = (from, to)
            loadPictures()
        }
        cycleStart = nil
    }

    /// Frees the preview's textures and frames.
    func stop() {
        stopLink()
        outgoing = nil
        prepared = [:]
        surfaces = []
        overlay.contents = nil
    }

    private func loadPictures() {
        let size = Self.pixelSize
        layer?.contents = sources.1.flatMap(Self.image(at:))
        guard let device = setUpRenderer(), let image = sources.0.flatMap(Self.image(at:)) else {
            outgoing = nil
            return
        }
        outgoing = WallpaperTransitionCapture.texture(of: image, pixelSize: size, placement: .fill, device: device)
        prepared = [:]
    }

    private func setUpRenderer() -> MTLDevice? {
        if let renderer { return renderer.device }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            renderer = try WallpaperTransitionRenderer(device: device)
            queue = device.makeCommandQueue()
            surfaces = try (0..<WallpaperTransitionSurface.count).map { _ in
                try WallpaperTransitionSurface.make(Self.pixelSize, device: device)
            }
            return device
        } catch {
            OWELog.error(.app, "Transition preview: \(error)")
            renderer = nil
            return nil
        }
    }

    private static func image(at url: URL) -> CGImage? {
        // Local previews only: a remote one would load on the main thread.
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 512,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func startLink() {
        guard link == nil else { return }
        let ticker = WallpaperTransitionTicker { [weak self] link in self?.tick(link) }
        let link = displayLink(target: ticker, selector: #selector(WallpaperTransitionTicker.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        ticker = nil
    }

    private func tick(_ link: CADisplayLink) {
        guard let renderer, let queue, let outgoing, !frameInFlight, !surfaces.isEmpty else { return }
        let now = link.timestamp
        let duration = max(settings.duration, 0.05)
        let cycle = duration + 2 * Self.hold
        if cycleStart == nil || now - (cycleStart ?? now) >= cycle {
            cycleStart = now
            kind = settings.pick()
            seed = .random()
        }
        guard let kind else {
            overlay.contents = nil
            return
        }
        let progress = Float(min(max((now - (cycleStart ?? now) - Self.hold) / duration, 0), 1))
        do {
            if prepared[kind] == nil {
                try renderer.preparePipelines(for: kind, pixelFormat: .bgra8Unorm)
                guard let commands = queue.makeCommandBuffer() else { return }
                prepared[kind] = try renderer.prepareOutgoing(outgoing, for: kind, commandBuffer: commands)
                commands.commit()
            }
            guard let picture = prepared[kind], let commands = queue.makeCommandBuffer() else { return }
            let index = nextSurface
            nextSurface = (nextSurface + 1) % surfaces.count
            try renderer.encode(kind, progress: progress, outgoing: picture, seed: seed,
                                into: surfaces[index].texture, commandBuffer: commands)
            frameInFlight = true
            commands.addCompletedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.frameInFlight = false
                        guard self.surfaces.indices.contains(index) else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.overlay.contents = self.surfaces[index].surface
                        CATransaction.commit()
                    }
                }
            }
            commands.commit()
        } catch {
            OWELog.error(.app, "Transition preview of \(kind): \(error)")
            stopLink()
        }
    }
}
