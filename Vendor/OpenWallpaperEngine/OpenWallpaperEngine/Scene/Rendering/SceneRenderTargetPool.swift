import Metal
import QuartzCore

/// Shared scratch render targets, bucketed by size, format and usage.
///
/// Every texture handed out is leased:
/// - `texture(...)` leases it for the current frame. Two requests in one frame never get the same
///   texture, so each caller may write it without overwriting another's content. `endFrame()`
///   returns frame leases to the pool.
/// - `persistentTexture(...)` leases it until `release(_:)`, for content that must survive from
///   one frame to the next (feedback targets). It is never evicted or handed to anyone else.
///
/// Only free textures are evicted: the least recently used first once the pool holds more than
/// `byteBudget`, and any left unused for `maxIdleSeconds` (wall time, so the same at every refresh
/// rate) at `endFrame()`. Eviction drops the pool's reference only; a texture still in flight on
/// the GPU stays alive until its command buffer completes.
///
/// Not thread-safe: owned by one renderer and used on its render thread.
final class SceneRenderTargetPool {
    private struct Key: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
        let usage: UInt
    }

    private struct Entry {
        let texture: MTLTexture
        let key: Key
        var lease: Lease
        /// `now()` when it was last handed out.
        var lastUse: TimeInterval
        /// Order of the last hand-out, to break ties between uses at the same instant.
        var useOrder: UInt64
    }

    private enum Lease {
        case free, frame, persistent
    }

    private let device: MTLDevice
    let byteBudget: Int
    let maxIdleSeconds: TimeInterval
    private let now: () -> TimeInterval
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var useCounter: UInt64 = 0

    /// `now` is a monotonic clock in seconds (injectable for tests).
    init(device: MTLDevice, byteBudget: Int = 256 << 20, maxIdleSeconds: TimeInterval = 10,
         now: @escaping () -> TimeInterval = CACurrentMediaTime) {
        self.device = device
        self.byteBudget = byteBudget
        self.maxIdleSeconds = maxIdleSeconds
        self.now = now
    }

    /// Textures currently held by the pool (leased or free), and their allocated size in bytes.
    var textureCount: Int { entries.count }
    var residentBytes: Int { entries.values.reduce(0) { $0 + $1.texture.allocatedSize } }

    /// A target leased for the current frame; never one leased to anyone else, nor any of
    /// `avoiding` (e.g. the texture being copied from).
    func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                 usage: MTLTextureUsage = [.renderTarget, .shaderRead], avoiding: [MTLTexture]) -> MTLTexture? {
        lease(width: width, height: height, pixelFormat: pixelFormat, usage: usage, avoiding: avoiding, as: .frame)
    }

    func texture(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                 usage: MTLTextureUsage = [.renderTarget, .shaderRead], avoiding: MTLTexture? = nil) -> MTLTexture? {
        texture(width: width, height: height, pixelFormat: pixelFormat, usage: usage, avoiding: avoiding.map { [$0] } ?? [])
    }

    /// A target leased until `release(_:)`: its content survives across frames.
    func persistentTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat,
                           usage: MTLTextureUsage = [.renderTarget, .shaderRead]) -> MTLTexture? {
        lease(width: width, height: height, pixelFormat: pixelFormat, usage: usage, avoiding: [], as: .persistent)
    }

    /// Returns a persistent (or frame) lease to the pool now.
    func release(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        guard entries[id] != nil else { return }
        entries[id]!.lease = .free
    }

    /// Ends the frame: frame leases return to the pool, and free textures idle longer than
    /// `maxIdleSeconds` are dropped.
    func endFrame() {
        let cutoff = now() - maxIdleSeconds
        for (id, entry) in entries {
            if entry.lease == .frame { entries[id]!.lease = .free }
            if entries[id]!.lease == .free, entry.lastUse < cutoff { entries[id] = nil }
        }
    }

    /// Drops every free texture; leased ones stay with their holders.
    func removeAll() {
        entries = entries.filter { $0.value.lease != .free }
    }

    private func lease(width: Int, height: Int, pixelFormat: MTLPixelFormat, usage: MTLTextureUsage,
                       avoiding: [MTLTexture], as lease: Lease) -> MTLTexture? {
        let key = Key(width: width, height: height, pixelFormat: pixelFormat, usage: usage.rawValue)
        let avoided = Set(avoiding.map(ObjectIdentifier.init))
        useCounter += 1
        // The most recently used free texture, so the rest can idle out.
        if let id = entries.filter({ $0.value.key == key && $0.value.lease == .free && !avoided.contains($0.key) })
            .max(by: { $0.value.useOrder < $1.value.useOrder })?.key {
            entries[id]!.lease = lease
            entries[id]!.lastUse = now()
            entries[id]!.useOrder = useCounter
            return entries[id]!.texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height,
                                                                    mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let id = ObjectIdentifier(texture)
        entries[id] = Entry(texture: texture, key: key, lease: lease, lastUse: now(), useOrder: useCounter)
        evictOverBudget()
        return texture
    }

    /// Drops free textures, least recently used first, until the pool fits its budget (leased
    /// ones may keep it above).
    private func evictOverBudget() {
        var total = residentBytes
        guard total > byteBudget else { return }
        let free = entries.filter { $0.value.lease == .free }.sorted { $0.value.useOrder < $1.value.useOrder }
        for (id, entry) in free {
            guard total > byteBudget else { break }
            total -= entry.texture.allocatedSize
            entries[id] = nil
        }
    }
}
