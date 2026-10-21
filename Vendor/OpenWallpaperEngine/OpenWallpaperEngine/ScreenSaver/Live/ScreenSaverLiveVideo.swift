import AVFoundation
import AppKit
import CoreVideo
import Metal
import QuartzCore

/// A display's desktop video player that the live screen saver draws from instead of opening a
/// player of its own (`ScreenSaverLiveVideo`): the AVKit path's shared player
/// (`VideoWallpaperViewModel`). While held, the video plays, silent, whatever the playback rules
/// (the lock pauses the desktop) and the windows covering it (the screen saver does) say.
@MainActor
protocol ScreenSaverVideoSharing: AnyObject {
    /// The player whose current item shows the video.
    var sharedPlayer: AVPlayer { get }
    func holdForScreenSaver(_ hold: Bool)
}

/// One video wallpaper's loop of the screen saver's layout drawn live: the decoded frames of the
/// desktop's player when a display already plays the video (`ScreenSaverVideoSharing`), else of a
/// player of its own (hardware decode, muted, looping, at the wallpaper's speed), read through an
/// `AVPlayerItemVideoOutput` and drawn with the desktop's placement into the loop's ring of
/// surfaces (`ScreenSaverFramePublisher`) on the GPU, one draw per decoded frame. No file is
/// linked or copied: the saver shows the frames like a scene's.
///
/// Paced by a display link of the loop's display at the video's own frame rate (the smallest
/// whole divisor of the refresh at or above it), capped by the user's rate and the power policy.
/// A frame that brings nothing new draws nothing; the newest is repeated after `heartbeat`
/// without one (a loop's seek back to the start, a still video), or the savers would take it as
/// stopped. A video the desktop shows on the Metal path is drawn from its running scene instead
/// (`ScreenSaverSharedScene`).
@MainActor
final class ScreenSaverLiveVideo {
    /// Frames further apart than this are repeated.
    nonisolated static let heartbeat: TimeInterval = 0.25

    let ring: Int
    private let pump: Pump
    private let thread: SceneRenderThread
    private var link: CADisplayLink?
    private let player: AVPlayer
    private var held: ScreenSaverVideoSharing?
    private var itemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var preparation: Task<Void, Never>?
    private var output: AVPlayerItemVideoOutput?
    /// The item `output` reads.
    private weak var outputItem: AVPlayerItem?
    private let outputSize: SIMD2<Int>?
    /// Whether the frames come from the desktop's player.
    var sharesDesktopPlayer: Bool { held != nil }

    /// The ring's pixels for a loop of `loop` pixels showing a video of `video` pixels with
    /// `placement`: the loop's, made smaller (its aspect kept) where the placed video would be
    /// enlarged, so a 1080p video on a 5K display isn't copied at 5K; the saver scales it up
    /// (`contentsGravity`). The loop's when the video's size isn't known yet.
    nonisolated static func ringPixels(loop: SIMD2<Int>, video: SIMD2<Int>?, placement: WallpaperPlacement) -> SIMD2<Int> {
        guard let video, video.x > 0, video.y > 0, loop.x > 0, loop.y > 0 else { return loop }
        let scaleX = Double(loop.x) / Double(video.x), scaleY = Double(loop.y) / Double(video.y)
        let scale = switch placement {
        case .fit, .center: min(scaleX, scaleY)
        case .fill, .zoom, .stretch: max(scaleX, scaleY)
        }
        guard scale > 1 else { return loop }
        return SIMD2(max(1, Int((Double(loop.x) / scale).rounded())), max(1, Int((Double(loop.y) / scale).rounded())))
    }

    /// The link's rate for a video of `videoRate` fps (0: unknown) on a display refreshing at
    /// `refresh`, at most `limit` (the user's rate and the power policy, `FramePacing.cadence`):
    /// the smallest whole divisor of the refresh at or above the video's rate, so every frame is
    /// shown (24 fps on 60 Hz ticks at 30).
    nonisolated static func frameRate(videoRate: Double, refresh: Int, limit: Int) -> Int {
        let limit = max(1, limit)
        guard videoRate > 0, refresh > 0 else { return limit }
        let wanted = max(1, Int((videoRate - 0.01).rounded(.up)))
        var divisor = 1
        while refresh / (divisor + 1) >= wanted { divisor += 1 }
        return min(refresh / divisor, limit)
    }

    /// Draws `url` (a video wallpaper's file) into ring `ring` of `publisher` at `pixels`, paced
    /// by `screen` at `frameRate`: from `sharing`'s player when given, else from a player of its own
    /// at `rate`. Nil without Metal.
    init?(url: URL, name: String, ring: Int, pixels: SIMD2<Int>, frameRate: Int, rate: Float, placement: WallpaperPlacement,
          screen: NSScreen?, sharing: ScreenSaverVideoSharing?, publisher: ScreenSaverFramePublisher,
          device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let drawer = VideoFrameDrawer(device: device) else {
            OWELog.error(.app, "Live screen saver: no Metal to draw \(name)")
            return nil
        }
        self.ring = ring
        thread = SceneRenderThread(name: "OWE screen saver video \(name)")
        pump = Pump(drawer: drawer, ring: ring, publisher: publisher, placement: placement)
        // The decoder hands frames at the placed size when that is smaller than the video's (a 4K
        // video in a 1080p ring), so it never converts more pixels than are drawn.
        let info = ScreenSaverVideoSource.cachedInfo(of: url)
        outputSize = info.map { Self.decodedPixels(video: $0.size, ring: pixels, placement: placement) }
        if let sharing {
            player = sharing.sharedPlayer
            held = sharing
            sharing.holdForScreenSaver(true)
            attachOutput(to: player.currentItem)
            itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                MainActor.assumeIsolated { self?.attachOutput(to: player.currentItem) }
            }
            OWELog.info(.app, "Live screen saver: drawing \(name) from the desktop's player at \(pixels.x)×\(pixels.y), \(frameRate) fps, ring \(ring)")
        } else {
            let player = WallpaperAVPlayer.make()
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            self.player = player
            // A file that keeps its parameter sets in band plays from its repaired copy, as on the
            // desktop (`RepairedVideoCache`; made once, off the main thread).
            preparation = Task { [weak self] in
                let playable = await Task.detached(priority: .userInitiated) {
                    RepairedVideoCache.current.playableURL(for: url)
                }.value
                guard let self, !Task.isCancelled else { return }
                let item = AVPlayerItem(url: playable)
                self.attachOutput(to: item)
                player.replaceCurrentItem(with: item)
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                          queue: .main) { [player] _ in
                    player.seek(to: .zero)
                }
                player.rate = rate > 0 ? rate : 1
            }
            OWELog.info(.app, "Live screen saver: playing \(name) for the screen saver at \(pixels.x)×\(pixels.y), \(frameRate) fps, ring \(ring)")
        }
        startLink(screen: screen, frameRate: frameRate)
    }

    /// Stops the frames; the desktop's player goes back to its own rules, a player of its own stops.
    func shutdown() {
        preparation?.cancel()
        preparation = nil
        itemObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let link = link
        self.link = nil
        thread.perform { link?.invalidate() }
        thread.stop()
        attachOutput(to: nil)
        if let held {
            held.holdForScreenSaver(false)
            self.held = nil
        } else {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    /// The decoded frames' size: the video placed in the ring, when that is smaller than the video.
    nonisolated static func decodedPixels(video: SIMD2<Int>, ring: SIMD2<Int>, placement: WallpaperPlacement) -> SIMD2<Int> {
        let placed = WallpaperTransitionCapture.placedRect(imageSize: CGSize(width: video.x, height: video.y),
                                                           in: CGSize(width: ring.x, height: ring.y), placement: placement).size
        // Even sides: the decoder's 4:2:0 frames convert without an odd edge.
        let width = min(video.x, Int(placed.width.rounded()) & ~1), height = min(video.y, Int(placed.height.rounded()) & ~1)
        return SIMD2(max(2, width), max(2, height))
    }

    /// Reads `item`'s frames (the desktop's player can change items: another wallpaper, a repair).
    private func attachOutput(to item: AVPlayerItem?) {
        guard output == nil || item !== outputItem else { return }
        if let output, let outputItem { outputItem.remove(output) }
        output = nil
        outputItem = nil
        pump.setOutput(nil)
        guard let item else { return }
        var attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        if let outputSize {
            attributes[kCVPixelBufferWidthKey as String] = outputSize.x
            attributes[kCVPixelBufferHeightKey as String] = outputSize.y
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        self.output = output
        outputItem = item
        pump.setOutput(output)
    }

    private func startLink(screen: NSScreen?, frameRate: Int) {
        guard let screen = screen ?? NSScreen.main else {
            OWELog.error(.app, "Live screen saver: no display to pace the video by")
            return
        }
        let link = screen.displayLink(target: pump, selector: #selector(Pump.tick(_:)))
        let rate = Float(frameRate)
        // A fixed rate, as the scenes' links: a range lets macOS tick a windowless app slower.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        self.link = link
        thread.perform { [thread] in link.add(to: thread.runLoop, forMode: .default) }
    }

    /// The display link's target, on the render thread: the newest decoded frame, drawn into the ring.
    final class Pump: NSObject, @unchecked Sendable { // `lock` owns `output`; the rest is the render thread's.
        private let drawer: VideoFrameDrawer
        private let ring: Int
        private let publisher: ScreenSaverFramePublisher
        private let placement: WallpaperPlacement
        private let lock = NSLock()
        private var output: AVPlayerItemVideoOutput?
        private var lastDrawn: CFTimeInterval = 0

        init(drawer: VideoFrameDrawer, ring: Int, publisher: ScreenSaverFramePublisher, placement: WallpaperPlacement) {
            self.drawer = drawer
            self.ring = ring
            self.publisher = publisher
            self.placement = placement
        }

        func setOutput(_ output: AVPlayerItemVideoOutput?) {
            lock.withLock { self.output = output }
        }

        @objc func tick(_ link: CADisplayLink) {
            pump(at: link.targetTimestamp)
        }

        /// One tick at host time `time`: the frame due then, if it is new; else the newest again
        /// once `heartbeat` passed without one.
        func pump(at time: CFTimeInterval) {
            publisher.ticked(ring: ring)
            let now = CACurrentMediaTime()
            guard let output = lock.withLock({ output }) else { return }
            let itemTime = output.itemTime(forHostTime: time)
            if output.hasNewPixelBuffer(forItemTime: itemTime),
               let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                if drawer.draw(buffer, ring: ring, placement: placement, publisher: publisher) { lastDrawn = now }
            } else if lastDrawn > 0, now - lastDrawn >= ScreenSaverLiveVideo.heartbeat {
                lastDrawn = now
                publisher.repeatNewest(ring: ring, on: drawer.queue)
            }
        }
    }
}

/// Draws decoded video frames into a ring's surfaces with a placement: one render pass per frame
/// that clears to black and draws the frame's quad, sampled bilinearly. Thread-safe for one caller
/// at a time (the pump's render thread).
final class VideoFrameDrawer: @unchecked Sendable {
    let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct OWESaverVideoVertex { float4 position [[position]]; float2 uv; };
    vertex OWESaverVideoVertex owe_saver_video_vertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 corner = float2(float(id & 1), float(id >> 1));
        OWESaverVideoVertex out;
        out.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.y, rect.w, corner.y), 0, 1);
        out.uv = float2(corner.x, 1 - corner.y);
        return out;
    }
    fragment float4 owe_saver_video_fragment(OWESaverVideoVertex in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge);
        return float4(frame.sample(linear, in.uv).rgb, 1);
    }
    """

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache,
              let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Live screen saver video"
            descriptor.vertexFunction = library.makeFunction(name: "owe_saver_video_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "owe_saver_video_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            OWELog.error(.app, "Live screen saver: can't build the video pipeline: \(error)")
            return nil
        }
        self.queue = queue
        textureCache = cache
    }

    /// The frame's quad in normalised device coordinates (x0, y0, x1, y1) for `placement` in a
    /// target of `target` pixels.
    static func quad(frame: SIMD2<Int>, target: SIMD2<Int>, placement: WallpaperPlacement) -> SIMD4<Float> {
        let rect = WallpaperTransitionCapture.placedRect(imageSize: CGSize(width: frame.x, height: frame.y),
                                                         in: CGSize(width: target.x, height: target.y), placement: placement)
        func x(_ value: CGFloat) -> Float { Float(value / CGFloat(max(target.x, 1)) * 2 - 1) }
        func y(_ value: CGFloat) -> Float { Float(value / CGFloat(max(target.y, 1)) * 2 - 1) }
        return SIMD4(x(rect.minX), y(rect.minY), x(rect.maxX), y(rect.maxY))
    }

    /// Draws `buffer` (BGRA) into ring `ring`'s next slot and stamps it once the GPU is done; false
    /// when nothing was drawn.
    @discardableResult
    func draw(_ buffer: CVPixelBuffer, ring: Int, placement: WallpaperPlacement, publisher: ScreenSaverFramePublisher) -> Bool {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var made: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
                                                        width, height, 0, &made) == kCVReturnSuccess,
              let made, let frame = CVMetalTextureGetTexture(made),
              let target = publisher.target(ring: ring), let commandBuffer = queue.makeCommandBuffer() else { return false }
        commandBuffer.label = "Live screen saver video frame"
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var rect = Self.quad(frame: SIMD2(width, height), target: SIMD2(target.texture.width, target.texture.height),
                             placement: placement)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let held = HeldVideoFrame(made, cache: textureCache)
        let slot = target.slot, generation = target.generation
        commandBuffer.addCompletedHandler { done in
            // The decoder reuses the frame's buffer once let go: held until drawn, with its cache,
            // which this drawer's owner may free meanwhile (`HeldVideoFrame`).
            withExtendedLifetime(held) {}
            guard done.status == .completed else { return }
            publisher.drawn(ring: ring, slot: slot, generation: generation)
        }
        commandBuffer.commit()
        CVMetalTextureCacheFlush(textureCache, 0)
        return true
    }
}
