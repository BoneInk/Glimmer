import Foundation
import OWEInspectorKit

/// Feeds a preview's stats overlay (`RenderStatsFeed`) from its scene's renderer: while some view
/// watches, the renderer of `instance()` counts its frames (`SceneMetalRenderer.frameStats`) and
/// the numbers are read twice a second; a new instance (the preview reloaded another wallpaper)
/// is counted from the next read. The last viewer gone, the renderer stops counting.
@MainActor
final class SceneRenderStatsSampler {
    private let instance: () -> SceneWallpaperInstance?
    private var counted: (instance: SceneWallpaperInstance, recorder: SceneFrameStatsRecorder)?
    private var timer: Timer?
    private weak var feed: RenderStatsFeed?

    init(instance: @escaping () -> SceneWallpaperInstance?) {
        self.instance = instance
    }

    /// A feed driven by this sampler (which it keeps alive while the feed lives).
    func makeFeed() -> RenderStatsFeed {
        RenderStatsFeed(defaults: .app, start: { [self] feed in start(feed) }, stop: { [self] in stop() })
    }

    private func start(_ feed: RenderStatsFeed) {
        self.feed = feed
        sample()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        detach()
        feed = nil
    }

    private func sample() {
        guard let current = instance() else {
            detach()
            feed?.publish(nil)
            return
        }
        if counted?.instance !== current {
            detach()
            let recorder = SceneFrameStatsRecorder()
            // Thread boundary: main → render thread, where frames are counted.
            current.renderLoop.perform { $0.frameStats = recorder }
            counted = (current, recorder)
            return
        }
        feed?.publish(counted.map { Self.stats($0.recorder.latest) })
    }

    private func detach() {
        guard let counted else { return }
        counted.instance.renderLoop.perform { $0.frameStats = nil }
        self.counted = nil
    }

    nonisolated static func stats(_ frame: SceneFrameStats) -> RenderStats {
        var stats = RenderStats()
        stats.framesPerSecond = frame.framesPerSecond
        stats.gpuMilliseconds = frame.gpuMilliseconds
        stats.drawCalls = frame.drawCalls
        stats.primitives = frame.primitives
        stats.shaderPrograms = frame.shaderPrograms
        stats.renderTargetChanges = frame.renderTargetChanges
        stats.framebufferCopies = frame.framebufferCopies
        stats.textureBytes = frame.textureBytes
        stats.particleCount = frame.particleCount
        stats.particleBytes = frame.particleBytes
        stats.particleMilliseconds = frame.particleMilliseconds
        stats.scriptMilliseconds = frame.scriptMilliseconds
        stats.lightCount = frame.lightCount
        stats.videoTextureCount = frame.videoTextureCount
        stats.clippingMaskPasses = frame.clippingMaskPasses
        stats.expensiveEffects = frame.expensiveEffects
        stats.veryExpensiveEffects = frame.veryExpensiveEffects
        return stats
    }
}
