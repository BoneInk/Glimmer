import AppKit
import Metal
import MetalPerformanceShaders

/// One web or WebM loop of the screen saver's layout drawn live: the frames of a Chromium page,
/// copied into its ring of surfaces (`ScreenSaverFramePublisher`) on the GPU as they come. WebKit
/// can't be drawn from while the screen saver covers its window (the page counts as occluded and
/// stops), so the screen saver always uses Chromium, whichever engine the desktop uses.
///
/// - When the desktop already shows the wallpaper in Chromium on the loop's display, its page is
///   drawn from (`ScreenSaverPageSharing`), held playing and silent while the screen saver runs.
/// - Otherwise a windowless page of its own: a web wallpaper with the whole bridge
///   (`WebWallpaperViewModel`: properties, audio, media), a WebM video in its player
///   (`WebKitVideoPlayer`, with its music sync). Silent; the pointer never moves.
///
/// Chromium paints only what changes, so a still page sends no frames: the newest is drawn again
/// (`repeatNewest`) whenever none came for `heartbeat`, or the savers would take it as stopped.
@MainActor
final class ScreenSaverLiveWeb {
    enum Kind: Equatable {
        case web
        case webm
    }

    /// Frames further apart than this are repeated.
    nonisolated static let heartbeat: TimeInterval = 0.25

    let ring: Int
    private let publisher: ScreenSaverFramePublisher
    private let copier: Copier
    private let page: ChromiumBrowserPage
    private var held: ScreenSaverPageSharing?
    private var viewModel: WebWallpaperViewModel?
    private var player: WebKitVideoPlayer?
    private var timer: Timer?

    /// The page's pixels per point for `settings`, at the display's `backingScale` (`WebPageScale`).
    static func pixelsPerPoint(_ settings: GlobalSettings, backingScale: CGFloat) -> CGFloat {
        WebPageScale.pixelsPerPoint(standardResolution: settings.webStandardResolution,
                                    halfResolution: WebPageScale.halfResolution(settings), backingScale: backingScale)
    }

    /// The ring's size for a loop of `points` drawn at `pixelsPerPoint`: the page's own pixels.
    nonisolated static func pixels(points: SIMD2<Int>, pixelsPerPoint: CGFloat) -> SIMD2<Int> {
        SIMD2(max(1, Int((CGFloat(points.x) * pixelsPerPoint).rounded())),
              max(1, Int((CGFloat(points.y) * pixelsPerPoint).rounded())))
    }

    init?(kind: Kind, wallpaper: WEWallpaper, propertyScope: WallpaperPropertyScope, ring: Int, points: SIMD2<Int>,
          pixelsPerPoint: CGFloat, frameRate: Int, placement: WallpaperPlacement, sharing: ScreenSaverPageSharing?,
          publisher: ScreenSaverFramePublisher) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let name = wallpaper.wallpaperDirectory.lastPathComponent
        self.ring = ring
        self.publisher = publisher
        copier = Copier(device: device, queue: queue, ring: ring, publisher: publisher)
        if let sharing, let shared = sharing.sharedPage {
            page = shared
            held = sharing
            sharing.holdForScreenSaver(true)
            OWELog.info(.app, "Live screen saver: drawing \(name) from the desktop's Chromium page, ring \(ring)")
        } else {
            page = ChromiumBrowserPage(startScripts: kind == .web ? WebWallpaperViewModel.documentStartScripts : [],
                                       frameRate: frameRate)
            page.resize(width: points.x, height: points.y, scale: Double(pixelsPerPoint))
            switch kind {
            case .web:
                let model = WebWallpaperViewModel(wallpaper: wallpaper, propertyScope: propertyScope,
                                                  media: AppDelegate.shared.mediaSession)
                model.page = page
                model.holdForScreenSaver(true)
                page.onMessage = { [weak model] name, body in model?.receivePageMessage(name: name, body: body) }
                let page = page
                page.onLoad = { [weak model, weak page] status in
                    if status < 0 { OWELog.error(.web, "Live screen saver: Chromium couldn't load \(name) (error \(status))") }
                    model?.pageDidFinishLoading()
                    page?.evaluate(WebWallpaperView.placementScript(placement))
                }
                model.onFrameRateChange = { [weak page] fps in page?.setFrameRate(fps) }
                ChromiumWebWallpaperView.load(page, viewModel: model)
                viewModel = model
            case .webm:
                let player = WebKitVideoPlayer(chromiumPage: page, url: wallpaper.mediaURL, readAccess: wallpaper.wallpaperDirectory)
                player.state = WebKitVideoPlayer.State(placement: placement, paused: false, muted: true, volume: 0, rate: 1)
                player.musicSync = VideoMusicSyncEffect(wallpaper)
                player.holdForScreenSaver(true)
                self.player = player
            }
            OWELog.info(.app, "Live screen saver: drawing \(name) in a page of its own at \(points.x)×\(points.y) pt × \(pixelsPerPoint), ring \(ring)")
        }
        page.addFrameObserver(self) { [copier] frame in copier.copy(frame) }
        let timer = Timer(timeInterval: Self.heartbeat, repeats: true) { [copier] _ in copier.repeatIfStill() }
        timer.tolerance = Self.heartbeat / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops the frames; the desktop's page goes back to its own rules, a page of its own closes.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        page.removeFrameObserver(self)
        if let held {
            held.holdForScreenSaver(false)
            self.held = nil
        } else if let player {
            player.stop()
        } else {
            page.close()
        }
        viewModel = nil
        player = nil
    }

    /// Copies each page frame into the ring on the GPU (scaled when Chromium's size differs by its
    /// rounding), and repeats the newest when the page goes still. XPC's queue and the main thread.
    private final class Copier: @unchecked Sendable { // `lock` owns `lastFrame`.
        private let queue: MTLCommandQueue
        private let scaler: MPSImageBilinearScale?
        private let ring: Int
        private let publisher: ScreenSaverFramePublisher
        private let lock = NSLock()
        private var lastFrame: TimeInterval = 0

        init(device: MTLDevice, queue: MTLCommandQueue, ring: Int, publisher: ScreenSaverFramePublisher) {
            self.queue = queue
            scaler = MPSSupportsMTLDevice(device) ? MPSImageBilinearScale(device: device) : nil
            self.ring = ring
            self.publisher = publisher
        }

        func copy(_ frame: ChromiumFrame) {
            lock.withLock { lastFrame = ProcessInfo.processInfo.systemUptime }
            publisher.ticked(ring: ring)
            guard let target = publisher.target(ring: ring), let buffer = queue.makeCommandBuffer() else { return }
            buffer.label = "Live screen saver page frame"
            let source = frame.texture
            if source.width == target.texture.width, source.height == target.texture.height,
               source.pixelFormat == target.texture.pixelFormat {
                guard let blit = buffer.makeBlitCommandEncoder() else { return }
                blit.copy(from: source, to: target.texture)
                blit.endEncoding()
            } else if let scaler {
                scaler.encode(commandBuffer: buffer, sourceTexture: source, destinationTexture: target.texture)
            } else {
                return
            }
            let publisher = publisher, ring = ring
            buffer.addCompletedHandler { done in
                // The helper reuses the frame's surface once handed on: held until copied.
                withExtendedLifetime(frame) {}
                guard done.status == .completed else { return }
                publisher.drawn(ring: ring, slot: target.slot, generation: target.generation)
            }
            buffer.commit()
        }

        func repeatIfStill() {
            let still = lock.withLock { ProcessInfo.processInfo.systemUptime - lastFrame >= ScreenSaverLiveWeb.heartbeat }
            guard still else { return }
            publisher.repeatNewest(ring: ring, on: queue)
        }
    }
}
