import Foundation
import Metal
import QuartzCore

/// One frame's numbers for the Wallpaper Editor's stats overlay, as WE's editor shows them
/// (`renderStats`, `ui_editor_stats_*`): what the frame drew and what its scene holds.
struct SceneFrameStats: Equatable, Sendable {
    /// Frames drawn in the last second.
    var framesPerSecond = 0
    /// The GPU's time for the last finished frame, in milliseconds.
    var gpuMilliseconds = 0.0
    var drawCalls = 0
    /// Triangles, lines and points drawn (instances counted).
    var primitives = 0
    /// Distinct render pipelines (shader programs) the frame set.
    var shaderPrograms = 0
    /// Render passes begun: each is a change of render target.
    var renderTargetChanges = 0
    /// Texture copies (the scene's frame buffer copied for effects that read it).
    var framebufferCopies = 0
    /// The textures the frame read or drew into, in bytes.
    var textureBytes = 0
    var particleCount = 0
    var particleBytes = 0
    /// The CPU's time stepping the particle systems this frame, in milliseconds.
    var particleMilliseconds = 0.0
    /// The scripts' CPU time for their last frame, in milliseconds.
    var scriptMilliseconds = 0.0
    var lightCount = 0
    var videoTextureCount = 0
    /// The puppets' clipping mask passes: one per clipped draw of each visible puppet's last drawing.
    var clippingMaskPasses = 0
    /// Visible effects whose effect.json says `"performance": "expensive"` / `"veryexpensive"`.
    var expensiveEffects = 0
    var veryExpensiveEffects = 0
}

/// Counts what a renderer's frames draw while the stats overlay shows (`SceneMetalRenderer.frameStats`;
/// nil the rest of the time, so a renderer nobody watches pays nothing). The frame's command
/// buffer is wrapped (`SceneStatsCommandBuffer`), which counts the draws, passes, pipelines,
/// textures and copies of every encoder made from it; the renderer adds the scene's own numbers
/// when the frame ends. Counting happens on the render thread; `latest` is read from any thread.
final class SceneFrameStatsRecorder {
    private let lock = NSLock()
    /// Guarded by `lock`: the last finished frame's numbers.
    private var published = SceneFrameStats()

    // Render thread only: the frame being drawn.
    private var current = SceneFrameStats()
    private var programs = Set<ObjectIdentifier>()
    private var textures: [ObjectIdentifier: Int] = [:]
    private var frameTimes: [CFTimeInterval] = []

    init() {}

    /// The last finished frame's numbers.
    var latest: SceneFrameStats {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// The frame's command buffer, counted.
    func wrap(_ commandBuffer: MTLCommandBuffer?) -> MTLCommandBuffer? {
        guard let commandBuffer else { return nil }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            let milliseconds = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            guard let self, milliseconds > 0 else { return }
            self.lock.lock()
            self.published.gpuMilliseconds = milliseconds
            self.lock.unlock()
        }
        return SceneStatsCommandBuffer.wrap(commandBuffer, recorder: self)
    }

    // MARK: Counting (render thread)

    func draw(_ type: MTLPrimitiveType, vertices: Int, instances: Int = 1) {
        current.drawCalls += 1
        let count: Int
        switch type {
        case .triangle: count = vertices / 3
        case .triangleStrip: count = max(0, vertices - 2)
        case .line: count = vertices / 2
        case .lineStrip: count = max(0, vertices - 1)
        case .point: count = vertices
        @unknown default: count = 0
        }
        current.primitives += count * max(1, instances)
    }

    /// An indirect draw: its counts are on the GPU.
    func drawIndirect() {
        current.drawCalls += 1
    }

    func program(_ pipeline: MTLRenderPipelineState) {
        programs.insert(ObjectIdentifier(pipeline))
    }

    func texture(_ texture: MTLTexture?) {
        guard let texture else { return }
        let key = ObjectIdentifier(texture)
        if textures[key] == nil { textures[key] = texture.allocatedSize }
    }

    func renderPass(_ descriptor: MTLRenderPassDescriptor) {
        current.renderTargetChanges += 1
        for index in 0..<8 { texture(descriptor.colorAttachments[index].texture) }
        texture(descriptor.depthAttachment.texture)
    }

    func copy() {
        current.framebufferCopies += 1
    }

    // MARK: Frames

    /// Ends the frame with the scene's own numbers and publishes it.
    func finishFrame(_ scene: (inout SceneFrameStats) -> Void, now: CFTimeInterval = CACurrentMediaTime()) {
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        current.framesPerSecond = frameTimes.count
        current.shaderPrograms = programs.count
        current.textureBytes = textures.values.reduce(0, +)
        scene(&current)
        lock.lock()
        let gpu = published.gpuMilliseconds
        published = current
        published.gpuMilliseconds = gpu
        lock.unlock()
        current = SceneFrameStats()
        programs.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
    }
}
