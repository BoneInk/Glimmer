import AppKit
import Metal
import QuartzCore

/// Plays one transition for one changing wallpaper: renders each frame once on the GPU, at the
/// wallpaper's size, for every display showing it, through their overlays
/// (`WallpaperTransitionOverlayView`). The frames are drawn and presented off the main thread
/// (`WallpaperTransitionFrameLoop`), so the incoming wallpaper loading on the main thread doesn't
/// hold them up; this keeps the overlays, which only the main thread adds and removes, and frees
/// everything when it ends.
@MainActor
final class WallpaperTransitionPlayer {
    let kind: WallpaperTransitionKind
    let duration: TimeInterval
    /// The display, region or group source it plays for.
    let target: String
    private(set) var overlays: [WallpaperTransitionOverlayView]
    /// Its frames; nil once it ended.
    private(set) var frames: WallpaperTransitionFrameLoop?
    private let clock: WallpaperTransitionClock
    private var onFinish: ((WallpaperTransitionPlayer) -> Void)?
    /// Ends it if its frames don't (a display that stopped refreshing).
    private var deadline: Task<Void, Never>?
    /// Its frame and main-thread measurements, at the Verbose log level only.
    private let metrics: WallpaperTransitionMetrics?

    /// WE's lead-in (`WallpaperTransitionClock.leadIn`).
    static let leadIn = WallpaperTransitionClock.leadIn
    /// How long after its end it is ended without its frames.
    static let deadlineGrace: TimeInterval = 0.5

    /// Errors setting one up: the change then applies without it.
    enum Failure: Error, CustomStringConvertible {
        case commandBuffer

        var description: String {
            switch self {
            case .commandBuffer: return "no command buffer"
            }
        }
    }

    var isFinished: Bool { frames == nil }

    init(kind: WallpaperTransitionKind, duration: TimeInterval, target: String, outgoing: MTLTexture,
         pixelSize: SIMD2<Int>, renderer: WallpaperTransitionRenderer, queue: MTLCommandQueue,
         seed: WallpaperTransitionSeed = .random(), startTime: CFTimeInterval = CACurrentMediaTime(),
         overlays: [WallpaperTransitionOverlayView]) throws {
        self.kind = kind
        self.target = target
        clock = WallpaperTransitionClock(startTime: startTime, duration: duration)
        self.duration = clock.duration
        self.overlays = overlays
        guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.commandBuffer }
        commandBuffer.label = "Transition outgoing"
        let prepared = try renderer.prepareOutgoing(outgoing, for: kind, commandBuffer: commandBuffer)
        commandBuffer.commit()
        for overlay in overlays {
            overlay.prepare(device: renderer.device, pixelSize: pixelSize, copiesFrames: overlays.count > 1)
        }
        let refresh = overlays.first?.window?.screen?.minimumRefreshInterval ?? 1.0 / 60
        metrics = WallpaperTransitionMetrics.isEnabled ? WallpaperTransitionMetrics(refreshInterval: refresh) : nil
        frames = WallpaperTransitionFrameLoop(kind: kind, target: target, clock: clock, seed: seed, outgoing: prepared,
                                              layers: overlays.map(\.metalLayer), renderer: renderer, queue: queue,
                                              metrics: metrics)
        metrics?.start()
    }

    /// Draws the first frame (progress 0: the outgoing picture), shown with this update, so the
    /// overlays cover the displays before the wallpaper underneath changes.
    func showFirstFrame() throws {
        try frames?.presentFirstFrame()
    }

    /// Plays it out from now; `onFinish` runs once it ended or was stopped.
    func run(onFinish: @escaping (WallpaperTransitionPlayer) -> Void) {
        self.onFinish = onFinish
        guard let frames, !overlays.isEmpty else { return stop() }
        frames.start { [weak self] in self?.stop() }
        let wait = max(clock.end - CACurrentMediaTime(), 0) + Self.deadlineGrace
        deadline = Task { @MainActor [weak self] in
            // Cancelled when it ends first; a cancelled sleep only ends the wait early.
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    /// The progress at `time` (`CACurrentMediaTime`), after WE's lead-in.
    func progress(at time: CFTimeInterval) -> Float {
        clock.progress(at: time)
    }

    /// Ends it: the frames stop, the overlays leave the windows and the outgoing picture is freed.
    func stop() {
        guard let frames else { return }
        frames.stop()
        self.frames = nil
        if let metrics {
            OWELog.debug(.perf, "Transition \(kind) on \(target): \(metrics.finish())")
        }
        deadline?.cancel()
        deadline = nil
        for overlay in overlays { overlay.removeFromSuperview() }
        overlays = []
        let finish = onFinish
        onFinish = nil
        finish?(self)
    }
}
