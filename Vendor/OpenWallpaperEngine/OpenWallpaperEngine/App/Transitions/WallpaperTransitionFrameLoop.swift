import Foundation
import Metal
import QuartzCore

/// Draws one transition's frames off the main thread. A `CAMetalDisplayLink` on the first
/// overlay's layer, run on a thread of its own, renders each frame once into that layer's
/// drawable, copies it into the other overlays' drawables (a clone's or a stretch's other
/// displays, which show their part through the layer's `contentsRect`) and presents them with the
/// command buffer, so no frame waits for the main thread. The progress runs on WE's clock at each
/// frame's presentation time.
///
/// Thread-safe: made, started and stopped on the main thread, called by the display link on its
/// thread. `lock` guards `resources`, `link`, `runLoop` and `onEnd`; everything else is set once.
/// The layers are only asked for drawables off the main thread, which `CAMetalLayer` allows.
final class WallpaperTransitionFrameLoop: NSObject, @unchecked Sendable {
    /// What frames draw with; dropped when it stops, which frees the outgoing picture once the
    /// GPU is done with the last frame.
    private struct Resources {
        let outgoing: MTLTexture
        let layers: [CAMetalLayer]
    }

    enum Failure: Error, CustomStringConvertible {
        case commandBuffer
        case drawable

        var description: String {
            switch self {
            case .commandBuffer: return "no command buffer"
            case .drawable: return "no drawable"
            }
        }
    }

    let kind: WallpaperTransitionKind
    let target: String
    let clock: WallpaperTransitionClock
    private let seed: WallpaperTransitionSeed
    private let renderer: WallpaperTransitionRenderer
    private let queue: MTLCommandQueue
    private let metrics: WallpaperTransitionMetrics?

    private let lock = NSLock()
    // Guarded by `lock`.
    private var resources: Resources?
    private var link: CAMetalDisplayLink?
    private var runLoop: CFRunLoop?
    private var onEnd: (@MainActor @Sendable () -> Void)?

    init(kind: WallpaperTransitionKind, target: String, clock: WallpaperTransitionClock, seed: WallpaperTransitionSeed,
         outgoing: MTLTexture, layers: [CAMetalLayer], renderer: WallpaperTransitionRenderer, queue: MTLCommandQueue,
         metrics: WallpaperTransitionMetrics?) {
        self.kind = kind
        self.target = target
        self.clock = clock
        self.seed = seed
        self.renderer = renderer
        self.queue = queue
        self.metrics = metrics
        resources = Resources(outgoing: outgoing, layers: layers)
    }

    /// Whether it stopped: it draws nothing more and holds nothing.
    var isStopped: Bool { lock.withLock { resources == nil } }

    /// Draws the first frame (progress 0: the outgoing picture) with the main thread's Core
    /// Animation transaction, so the overlays cover the displays in the same update that changes
    /// the wallpapers under them. Main thread.
    func presentFirstFrame() throws {
        guard let resources = lock.withLock({ resources }) else { return }
        for layer in resources.layers { layer.presentsWithTransaction = true }
        defer { for layer in resources.layers { layer.presentsWithTransaction = false } }
        guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.commandBuffer }
        let drawables = try encodeFrame(progress: 0, linkDrawable: nil, resources, into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()
        for drawable in drawables { drawable.present() }
    }

    /// Plays it out on its own thread. `onEnd` runs on the main thread once, when the progress
    /// reached 1 or a frame couldn't be drawn; not after `stop`.
    func start(onEnd: @escaping @MainActor @Sendable () -> Void) {
        guard let first = lock.withLock({ resources?.layers.first }) else { return }
        let link = CAMetalDisplayLink(metalLayer: first)
        link.delegate = self
        lock.withLock {
            self.link = link
            self.onEnd = onEnd
        }
        let thread = Thread { [self] in run(link) }
        thread.name = "Transition \(kind) on \(target)"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// The thread's body: runs the display link until `stop`.
    private func run(_ link: CAMetalDisplayLink) {
        let current = CFRunLoopGetCurrent()
        let stopped = lock.withLock { () -> Bool in
            guard resources != nil else { return true }
            runLoop = current
            return false
        }
        if stopped { return link.invalidate() }
        link.add(to: .current, forMode: .default)
        CFRunLoopRun()
    }

    /// Stops it: no frame is drawn after this, and it lets go of the outgoing picture and the
    /// layers. The display link ends on its thread, which then exits. Any thread.
    func stop() {
        let (runLoop, link) = lock.withLock { () -> (CFRunLoop?, CAMetalDisplayLink?) in
            resources = nil
            onEnd = nil
            defer {
                self.runLoop = nil
                self.link = nil
            }
            return (self.runLoop, self.link)
        }
        // Not running yet: the thread sees it stopped and ends the link itself.
        guard let runLoop, let link else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            link.invalidate()
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Reached the end: stops drawing and tells the main thread, once.
    private func end(_ link: CAMetalDisplayLink) {
        link.isPaused = true
        guard let onEnd = lock.withLock({ () -> (@MainActor @Sendable () -> Void)? in
            defer { self.onEnd = nil }
            return self.onEnd
        }) else { return }
        Task { @MainActor in onEnd() }
    }

    /// Renders `progress` once into the first layer's drawable (`linkDrawable` when the display
    /// link gave it) and copies it into the others'. Returns the drawables to present.
    private func encodeFrame(progress: Float, linkDrawable: CAMetalDrawable?, _ resources: Resources,
                             into commandBuffer: MTLCommandBuffer) throws -> [CAMetalDrawable] {
        guard let first = linkDrawable ?? resources.layers.first?.nextDrawable() else { throw Failure.drawable }
        commandBuffer.label = "Transition \(kind)"
        try renderer.encode(kind, progress: progress, outgoing: resources.outgoing, seed: seed,
                            into: first.texture, commandBuffer: commandBuffer)
        var drawables = [first]
        // A display whose drawable is late this refresh keeps its last frame.
        let copies = resources.layers.dropFirst().compactMap { $0.nextDrawable() }
        if !copies.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for copy in copies {
                let size = MTLSize(width: min(first.texture.width, copy.texture.width),
                                   height: min(first.texture.height, copy.texture.height), depth: 1)
                blit.copy(from: first.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                          sourceSize: size, to: copy.texture, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin())
            }
            blit.endEncoding()
            drawables += copies
        }
        return drawables
    }
}

extension WallpaperTransitionFrameLoop: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard let resources = lock.withLock({ resources }) else { return }
        let progress = clock.progress(at: update.targetPresentationTimestamp)
        guard progress < 1 else { return end(link) }
        do {
            guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.commandBuffer }
            let drawables = try encodeFrame(progress: progress, linkDrawable: update.drawable, resources,
                                            into: commandBuffer)
            if let metrics {
                drawables[0].addPresentedHandler { drawable in
                    if drawable.presentedTime > 0 { metrics.recordPresent(at: drawable.presentedTime) }
                }
            }
            for drawable in drawables { commandBuffer.present(drawable) }
            commandBuffer.commit()
            metrics?.recordSubmitted(at: CACurrentMediaTime())
        } catch {
            OWELog.error(.app, "Transition \(kind) on \(target) stopped: \(error)")
            end(link)
        }
    }
}
