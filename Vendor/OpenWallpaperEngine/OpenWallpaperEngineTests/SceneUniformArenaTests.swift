import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Risk I11: uniform blocks over 4 KB are sub-allocated from reused buffers.
final class SceneUniformArenaTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    private func block(_ value: UInt8, _ length: Int = 5000) -> [UInt8] { [UInt8](repeating: value, count: length) }

    func testSlicesShareAChunkAlignedAndKeepTheirBytes() throws {
        let arena = SceneUniformArena(device: device, chunkSize: 64 << 10)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try XCTUnwrap(block(1).withUnsafeBytes { arena.allocate($0, for: commands) })
        let second = try XCTUnwrap(block(2).withUnsafeBytes { arena.allocate($0, for: commands) })
        XCTAssertTrue(first.buffer === second.buffer)
        XCTAssertEqual(first.offset % SceneUniformArena.alignment, 0)
        XCTAssertEqual(second.offset % SceneUniformArena.alignment, 0)
        XCTAssertGreaterThanOrEqual(second.offset, first.offset + 5000)
        let bytes = first.buffer.contents().assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(bytes[first.offset + 4999], 1, "a later slice doesn't overwrite an earlier one")
        XCTAssertEqual(bytes[second.offset], 2)
        commands.commit()
        commands.waitUntilCompleted()
    }

    func testChunksInFlightAreNotReusedAndCompletedOnesAre() throws {
        let arena = SceneUniformArena(device: device, chunkSize: 16 << 10)
        // Three 5 000-byte slices fill a 16 KB chunk; the fourth starts another.
        let held = try XCTUnwrap(queue.makeCommandBuffer())
        var buffers: [MTLBuffer] = []
        for value in 0..<4 {
            buffers.append(try XCTUnwrap(block(UInt8(value)).withUnsafeBytes { arena.allocate($0, for: held) }).buffer)
        }
        XCTAssertEqual(arena.chunksCreated, 2)
        XCTAssertFalse(buffers[0] === buffers[3])
        // The full first chunk is still in use by an uncommitted command buffer: never handed out.
        let other = try XCTUnwrap(queue.makeCommandBuffer())
        for value in 0..<3 {
            let slice = try XCTUnwrap(block(UInt8(10 + value)).withUnsafeBytes { arena.allocate($0, for: other) })
            XCTAssertFalse(slice.buffer === buffers[0])
        }
        XCTAssertEqual(buffers[0].contents().assumingMemoryBound(to: UInt8.self)[0], 0)
        held.commit()
        other.commit()
        held.waitUntilCompleted()
        other.waitUntilCompleted()
        // Completion handlers run after waitUntilCompleted returns; give them a moment.
        let deadline = Date().addingTimeInterval(2)
        while arena.freeChunks == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertGreaterThan(arena.freeChunks, 0, "completed chunks come back")
    }

    func testSteadyFramesReuseTheSameChunks() throws {
        let arena = SceneUniformArena(device: device, chunkSize: 64 << 10)
        for frame in 0..<200 {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            for _ in 0..<20 { _ = block(UInt8(frame % 256)).withUnsafeBytes { arena.allocate($0, for: commands) } }
            commands.commit()
            commands.waitUntilCompleted()
        }
        // 200 frames × 20 draws × 5 KB is 20 MB of uniforms; a handful of chunks carries it all.
        XCTAssertLessThanOrEqual(arena.chunksCreated, 4)
    }

    func testSmallBlocksStayInline() throws {
        let arena = SceneUniformArena(device: device)
        let target = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 4, height: 4, mipmapped: false)
            descriptor.usage = .renderTarget
            return descriptor
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass))
        block(1, 4096).withUnsafeBytes { arena.bind($0, index: 0, to: encoder, commandBuffer: commands) }
        XCTAssertEqual(arena.chunksCreated, 0)
        block(1, 4097).withUnsafeBytes { arena.bind($0, index: 0, to: encoder, commandBuffer: commands) }
        XCTAssertEqual(arena.chunksCreated, 1)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }
}
