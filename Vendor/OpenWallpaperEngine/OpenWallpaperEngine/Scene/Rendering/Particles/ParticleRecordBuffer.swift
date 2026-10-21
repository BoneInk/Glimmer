import Metal

/// A growable shared buffer of records, ring-buffered so the CPU never rewrites a buffer an
/// in-flight frame still reads.
final class ParticleRecordBuffer {
    private let device: MTLDevice
    private var ring: [MTLBuffer?]
    private var index = 0
    /// How many frames may be in flight at once (the drawable count).
    static let ringSize = 3

    init(device: MTLDevice) {
        self.device = device
        ring = Array(repeating: nil, count: Self.ringSize)
    }

    /// The next buffer in the ring, at least `bytes` long; grows geometrically.
    func next(bytes: Int) -> MTLBuffer? {
        index = (index + 1) % Self.ringSize
        if let buffer = ring[index], buffer.length >= bytes { return buffer }
        let length = max(bytes * 2, 4096)
        ring[index] = device.makeBuffer(length: length, options: .storageModeShared)
        return ring[index]
    }
}
