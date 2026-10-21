import Foundation
import IOSurface
import Metal

/// Research-only transport adapter. No window, display, app or upstream runtime initialization.
public final class IOSurfaceFramePool: @unchecked Sendable {
    public enum Failure: Error { case invalidSize, invalidSequence, allocation, backpressure, closed, staleToken, wrongPhase }
    public struct Lease {
        public let token: SceneFrameToken
        public let surface: IOSurface
        public let texture: MTLTexture
    }
    private enum Phase { case available, rendering, published }
    private struct Slot {
        let id = UUID()
        let surface: IOSurface
        let texture: MTLTexture
        var phase = Phase.available
        var sequence: UInt64 = 0
    }
    private let lock = NSLock()
    private let sessionID: UUID
    private let generation: UInt64
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int
    private var slots: [Slot] = []
    private var isClosed = false
    private var lastSequence: UInt64?

    public init(device: MTLDevice, sessionID: UUID, generation: UInt64, width: Int, height: Int) throws {
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, width > 0, height > 0, width <= 8192, height <= 8192,
              pixelCount <= 16_777_216 else { throw Failure.invalidSize }
        self.sessionID = sessionID; self.generation = generation
        self.width = width; self.height = height
        bytesPerRow = (width * 4 + 255) & ~255
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        for _ in 0..<3 {
            guard let surface = IOSurface(properties: [
                .width: width, .height: height, .bytesPerElement: 4,
                .bytesPerRow: bytesPerRow, .allocSize: bytesPerRow * height,
                .pixelFormat: UInt32(0x42475241)
            ]), let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
            else { throw Failure.allocation }
            slots.append(Slot(surface: surface, texture: texture))
        }
    }

    public func acquire(sequence: UInt64) throws -> Lease {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { throw Failure.closed }
        guard lastSequence.map({ sequence > $0 }) ?? true else { throw Failure.invalidSequence }
        guard let index = slots.firstIndex(where: { $0.phase == .available }) else { throw Failure.backpressure }
        lastSequence = sequence
        slots[index].phase = .rendering; slots[index].sequence = sequence
        let slot = slots[index]
        let token = SceneFrameToken(sessionID: sessionID, generation: generation, sequence: sequence,
            slotID: slot.id, width: width, height: height, bytesPerRow: bytesPerRow, pixelFormat: "BGRA8Unorm")
        return Lease(token: token, surface: slot.surface, texture: slot.texture)
    }

    /// Call only after GPU completion was verified; a failed frame is never published.
    public func complete(_ token: SceneFrameToken, gpuSucceeded: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let index = try indexFor(token)
        guard slots[index].phase == .rendering else { throw Failure.wrongPhase }
        slots[index].phase = gpuSucceeded ? .published : .available
    }

    /// Parent must finish sampling before ack; never overwrite an unacknowledged IOSurface.
    public func acknowledge(_ token: SceneFrameToken) throws {
        lock.lock(); defer { lock.unlock() }
        let index = try indexFor(token)
        guard slots[index].phase == .published else { throw Failure.wrongPhase }
        slots[index].phase = .available
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        isClosed = true; slots.removeAll()
    }

    private func indexFor(_ token: SceneFrameToken) throws -> Int {
        guard !isClosed else { throw Failure.closed }
        guard token.sessionID == sessionID, token.generation == generation,
              token.width == width, token.height == height, token.bytesPerRow == bytesPerRow,
              token.pixelFormat == "BGRA8Unorm",
              let index = slots.firstIndex(where: { $0.id == token.slotID && $0.sequence == token.sequence })
        else { throw Failure.staleToken }
        return index
    }
}
