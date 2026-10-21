import Metal

/// GPU time of each effect pass, for profiling (the frame benchmark); nil in the app. It samples
/// the GPU's timestamp counter at the start of each pass's vertex stage and the end of its fragment
/// stage (`MTLCounterSamplingPoint.atStageBoundary`), then turns the ticks into nanoseconds against
/// the CPU clock. Passes of one command buffer overlap on a tile GPU, so the times are each pass's
/// own span, not a partition of the frame.
final class EffectPassTimer {
    struct Sample {
        let label: String
        let pixels: Int
        let nanoseconds: Double
    }

    private let device: MTLDevice
    private let buffer: MTLCounterSampleBuffer
    private let capacity: Int
    private var labels: [(label: String, pixels: Int)] = []

    /// nil when the GPU can't sample timestamps at stage boundaries.
    init?(device: MTLDevice, passes: Int = 512) {
        guard device.supportsCounterSampling(.atStageBoundary),
              let timestamps = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else {
            return nil
        }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = timestamps
        descriptor.sampleCount = passes * 2
        descriptor.storageMode = .shared
        do {
            buffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
        } catch {
            OWELog.error(.scene, "Effect pass timer: no counter sample buffer: \(error)")
            return nil
        }
        self.device = device
        capacity = passes
    }

    /// Starts a frame's samples.
    func reset() {
        labels.removeAll(keepingCapacity: true)
    }

    /// Samples the pass `descriptor` describes, under `label`; passes past the capacity aren't timed.
    func attach(to descriptor: MTLRenderPassDescriptor, label: String, pixels: Int) {
        guard labels.count < capacity else { return }
        let attachment = descriptor.sampleBufferAttachments[0]!
        attachment.sampleBuffer = buffer
        attachment.startOfVertexSampleIndex = labels.count * 2
        attachment.endOfFragmentSampleIndex = labels.count * 2 + 1
        attachment.startOfFragmentSampleIndex = MTLCounterDontSample
        attachment.endOfVertexSampleIndex = MTLCounterDontSample
        labels.append((label, pixels))
    }

    /// The frame's passes, once its command buffer has completed. `ticksPerNanosecond` comes from
    /// two `device.sampleTimestamps` calls some time apart (`tickRate`).
    func samples(ticksPerNanosecond: Double) -> [Sample] {
        guard !labels.isEmpty else { return [] }
        let resolved: Data?
        do {
            resolved = try buffer.resolveCounterRange(0..<(labels.count * 2))
        } catch {
            OWELog.error(.scene, "Effect pass timer: the samples can't be resolved: \(error)")
            return []
        }
        guard let data = resolved else { return [] }
        let stamps = data.withUnsafeBytes { Array($0.bindMemory(to: MTLCounterResultTimestamp.self)) }
        return labels.enumerated().compactMap { index, entry in
            guard index * 2 + 1 < stamps.count else { return nil }
            let start = stamps[index * 2].timestamp, end = stamps[index * 2 + 1].timestamp
            guard start != MTLCounterErrorValue, end != MTLCounterErrorValue, end >= start else { return nil }
            return Sample(label: entry.label, pixels: entry.pixels, nanoseconds: Double(end - start) / ticksPerNanosecond)
        }
    }

    /// GPU ticks per nanosecond: the device's GPU clock sampled `wallSeconds` apart (by
    /// `CACurrentMediaTime`) moved from `first` to `second` ticks.
    static func tickRate(from first: MTLTimestamp, to second: MTLTimestamp, wallSeconds: Double) -> Double {
        let ticks = Double(second &- first)
        return ticks > 0 && wallSeconds > 0 ? ticks / (wallSeconds * 1e9) : 1
    }
}
