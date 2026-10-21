import XCTest
import Metal
@testable import OpenWallpaperEngine

/// The GPU simulation's shared structures: Swift and Metal lay them out alike.
final class ParticleGPULayoutTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    func testSwiftAndMetalLayoutsAgree() throws {
        let library = try device.makeDefaultLibrary(bundle: Bundle(for: ParticleGPUSimulator.self))
        let function = try XCTUnwrap(library.makeFunction(name: "particleLayoutSizes"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let sizes = try XCTUnwrap(device.makeBuffer(length: 14 * 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sizes, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let metal = Array(UnsafeBufferPointer(start: sizes.contents().bindMemory(to: UInt32.self, capacity: 14), count: 14)).map(Int.init)
        XCTAssertEqual(metal, [MemoryLayout<ParticleGPUState>.stride, MemoryLayout<ParticleGPUParameters>.stride,
                               MemoryLayout<ParticleGPUFrame>.stride, MemoryLayout<ParticleSpriteInstance>.stride,
                               MemoryLayout<ParticleRopeSegmentInstance>.stride, MemoryLayout<LayerUniform>.stride,
                               MemoryLayout<ParticleGPUInstance>.stride, MemoryLayout<ParticleCollisionPlacement>.stride,
                               MemoryLayout<ParticleGPULinkedPoints>.stride, MemoryLayout<ParticleGPUEmitter>.stride,
                               MemoryLayout<ParticleGPUEmitterStep>.stride, MemoryLayout<ParticleGPUEmitterState>.stride,
                               ParticleGPUSystem.pointStateStride, ParticleGPUSystem.serialStateStride])
    }
}
