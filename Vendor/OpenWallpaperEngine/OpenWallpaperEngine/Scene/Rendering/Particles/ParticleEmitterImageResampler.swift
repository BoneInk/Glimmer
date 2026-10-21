import Foundation
import Metal

/// Samples a `layerimage` emitter's layer again while the wallpaper runs (flag 0x20000, "update
/// emission bitmap periodically"): WE marks the layer's points stale once a second of emitting
/// (0x140238d4f → 0x1401d42b0), draws the layer's texture as it is then through its downsample,
/// keeps spawning from the old points while that runs, and takes the new ones (with their bones on
/// a rigged layer) at its next step after the read back (0x1401d3ae0: state 0 → 1 → 2).
///
/// Here the downsample goes to the GPU in a command buffer of its own, committed at once; its
/// completion hands the texels to a background queue, which makes the points, and the render
/// thread takes them (`ParticleSystemRuntime.replaceImagePoints`), which uploads them only when
/// they changed. The render thread never waits. Render thread only, apart from the queue's work.
final class ParticleEmitterImageResampler {
    private struct Key: Hashable {
        var system: ObjectIdentifier
        var slot: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let work = DispatchQueue(label: "ParticleEmitterImageResampler", qos: .utility)
    /// The reduction's pipeline, made on `work` (`pipelineLock` owns it).
    private var pipeline: MTLComputePipelineState?
    private let pipelineLock = NSLock()
    /// Samplings on their way, by system and image slot: one at a time each.
    private var pending: Set<Key> = []
    /// Whether a sampling is on its way.
    var hasPending: Bool { !pending.isEmpty }
    /// Runs a block on the render thread (`SceneMetalRenderer.performOnRenderThread`).
    private let deliver: (@escaping () -> Void) -> Void

    init(device: MTLDevice, queue: MTLCommandQueue, deliver: @escaping (@escaping () -> Void) -> Void) {
        self.device = device
        self.queue = queue
        self.deliver = deliver
        work.async { [weak self] in
            guard let self else { return }
            do {
                let made = try ParticleEmitterImagePoints.reducePipeline(device: device)
                self.pipelineLock.withLock { self.pipeline = made }
            } catch {
                OWELog.error(.scene, "A layerimage emitter's layer can't be sampled again: \(error)")
            }
        }
    }

    /// Samples image `slot` of `system` from `source` unless a sampling of it is on its way. Until
    /// the reduction's pipeline is ready a request is dropped; the emitter asks again a second later.
    func request(_ system: ParticleSystemRuntime, slot: Int, source: ParticleEmitterImagePoints.Source) {
        ThreadGuards.assertRenderThread("ParticleEmitterImageResampler.request")
        let key = Key(system: ObjectIdentifier(system), slot: slot)
        guard !pending.contains(key), source.imageSize.x > 0, source.imageSize.y > 0,
              let pipeline = pipelineLock.withLock({ self.pipeline }) else { return }
        let target = ParticleEmitterImagePoints.targetSize(imageSize: source.imageSize)
        let output: MTLBuffer
        guard let commands = queue.makeCommandBuffer() else { return }
        commands.label = "Particle layer image sampling"
        do {
            output = try ParticleEmitterImagePoints.encodeReduce(source.sampling, target: target, pipeline: pipeline, into: commands)
        } catch {
            OWELog.error(.scene, "A layerimage emitter's layer can't be sampled again: \(error)")
            return
        }
        pending.insert(key)
        let work = work, deliver = deliver
        commands.addCompletedHandler { [weak self, weak system] buffer in
            let failed = buffer.error
            work.async {
                var points: [SIMD4<Int32>]?
                if let failed {
                    OWELog.error(.scene, "A layerimage emitter's layer sampling failed on the GPU: \(failed)")
                } else {
                    ThreadGuards.assertBackground("ParticleEmitterImageResampler points")
                    points = ParticleEmitterImagePoints.points(rgba: ParticleEmitterImagePoints.bytes(of: output), target: target,
                                                               imageSize: source.imageSize, rig: source.rig)
                }
                deliver {
                    self?.pending.remove(key)
                    if let points { system?.replaceImagePoints(points, slot: slot) }
                }
            }
        }
        commands.commit()
    }
}
