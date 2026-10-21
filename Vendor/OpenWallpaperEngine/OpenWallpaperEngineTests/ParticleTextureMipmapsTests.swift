import Metal
import XCTest
@testable import OpenWallpaperEngine

final class ParticleTextureMipmapsTests: XCTestCase {
    func testAFullChainHasALevelPerHalving() {
        XCTAssertEqual(ParticleTextureMipmaps.levelCount(width: 1, height: 1), 1)
        XCTAssertEqual(ParticleTextureMipmaps.levelCount(width: 256, height: 256), 9)
        XCTAssertEqual(ParticleTextureMipmaps.levelCount(width: 300, height: 17), 9)
    }

    /// A one-level upload gets its chain, whose smallest level averages the image; a texture that
    /// already has levels is kept.
    func testAOneLevelTextureGetsAGeneratedChain() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // Left half white, right half black: the 1×1 level is mid grey.
        var texels = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for y in 0..<4 { for x in 0..<2 { for c in 0..<4 { texels[(y * 4 + x) * 4 + c] = 255 } } }
        source.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0, withBytes: texels, bytesPerRow: 16)
        let chained = ParticleTextureMipmaps.mipmapped(source, device: device, queue: queue)
        XCTAssertEqual(chained.mipmapLevelCount, 3)
        XCTAssertFalse(ParticleTextureMipmaps.needsChain(chained))
        XCTAssertTrue(ParticleTextureMipmaps.mipmapped(chained, device: device, queue: queue) === chained)

        let readable = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        readable.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: readable))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: chained, sourceSlice: 0, sourceLevel: 2, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixel = [UInt8](repeating: 0, count: 4)
        target.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(Int(pixel[0]), 128, accuracy: 2)
    }
}
