import Metal

/// Uniform blocks too large for `setVertexBytes` (over 4 KB), sub-allocated from a few reused
/// buffers instead of a new `MTLBuffer` per draw.
///
/// Allocations bump through a chunk and are never overwritten while a command buffer that uses
/// them may still run: a chunk is recycled only once it is full and every command buffer that
/// took a slice of it has completed. In steady state the same chunks cycle frame after frame.
///
/// Thread-safe: `lock` owns every chunk's state and the free list, since completion handlers run
/// on Metal's threads. Allocation happens on the render thread.
final class SceneUniformArena {
    /// Constant-buffer offsets must be multiples of 256 on some Macs (Intel and AMD GPUs).
    static let alignment = 256
    /// `setVertexBytes`' limit. A test may lower `inlineLimit` to send every block through the arena.
    static let maximumInlineLength = 4096
    var inlineLimit = SceneUniformArena.maximumInlineLength

    private final class Chunk {
        let buffer: MTLBuffer
        var offset = 0
        /// Command buffers holding a slice, not yet completed.
        var users = 0
        /// No more allocations; recycled once `users` reaches zero.
        var retired = false
        /// The command buffer that took the last slice (so each registers its completion once).
        var lastUser: ObjectIdentifier?

        init(buffer: MTLBuffer) { self.buffer = buffer }
    }

    private let device: MTLDevice
    let chunkSize: Int
    private let lock = NSLock()
    private var current: Chunk?
    private var free: [Chunk] = []
    private var created = 0

    init(device: MTLDevice, chunkSize: Int = 256 << 10) {
        self.device = device
        self.chunkSize = chunkSize
    }

    /// Binds a uniform block to `index` of both stages: inline when it fits, from the arena otherwise.
    func bind(_ bytes: UnsafeRawBufferPointer, index: Int, to encoder: MTLRenderCommandEncoder,
              commandBuffer: MTLCommandBuffer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        if bytes.count <= inlineLimit {
            encoder.setVertexBytes(base, length: bytes.count, index: index)
            encoder.setFragmentBytes(base, length: bytes.count, index: index)
        } else if let slice = allocate(bytes, for: commandBuffer) {
            encoder.setVertexBuffer(slice.buffer, offset: slice.offset, index: index)
            encoder.setFragmentBuffer(slice.buffer, offset: slice.offset, index: index)
        }
    }

    /// Copies `bytes` into the arena for use by `commandBuffer` (not yet committed).
    func allocate(_ bytes: UnsafeRawBufferPointer, for commandBuffer: MTLCommandBuffer) -> (buffer: MTLBuffer, offset: Int)? {
        let length = bytes.count
        let aligned = (length + Self.alignment - 1) / Self.alignment * Self.alignment
        lock.lock()
        defer { lock.unlock() }
        if let chunk = current, chunk.offset + aligned > chunk.buffer.length {
            chunk.retired = true
            if chunk.users == 0 { recycle(chunk) }
            current = nil
        }
        if current == nil {
            guard let chunk = takeChunk(minimumLength: aligned) else { return nil }
            current = chunk
        }
        let chunk = current!
        let offset = chunk.offset
        chunk.offset += aligned
        if let base = bytes.baseAddress { chunk.buffer.contents().advanced(by: offset).copyMemory(from: base, byteCount: length) }
        let user = ObjectIdentifier(commandBuffer)
        if chunk.lastUser != user {
            chunk.lastUser = user
            chunk.users += 1
            commandBuffer.addCompletedHandler { [weak self] _ in self?.completed(chunk, user: user) }
        }
        return (chunk.buffer, offset)
    }

    /// Buffers made so far, and those free for reuse; for tests and diagnostics.
    var chunksCreated: Int { lock.withLock { created } }
    var freeChunks: Int { lock.withLock { free.count } }

    /// Drops the free chunks (memory pressure). Chunks in use are kept.
    func trim() {
        lock.withLock { free.removeAll() }
    }

    private func completed(_ chunk: Chunk, user: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        chunk.users -= 1
        // A later command buffer may reuse this one's address; it must register again.
        if chunk.lastUser == user { chunk.lastUser = nil }
        if chunk.retired && chunk.users == 0 { recycle(chunk) }
    }

    /// Caller holds `lock`.
    private func recycle(_ chunk: Chunk) {
        chunk.offset = 0
        chunk.retired = false
        chunk.lastUser = nil
        // A chunk made for one oversized block isn't worth keeping.
        if chunk.buffer.length == chunkSize { free.append(chunk) }
    }

    /// Caller holds `lock`.
    private func takeChunk(minimumLength: Int) -> Chunk? {
        if minimumLength <= chunkSize, let chunk = free.popLast() { return chunk }
        guard let buffer = device.makeBuffer(length: max(chunkSize, minimumLength), options: .storageModeShared) else {
            OWELog.error(.scene, "Could not allocate a \(max(chunkSize, minimumLength)) byte uniform buffer")
            return nil
        }
        buffer.label = "OWE uniform arena"
        created += 1
        return Chunk(buffer: buffer)
    }
}
