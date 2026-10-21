import Metal
import XCTest
@testable import OpenWallpaperEngine

/// An animated layer's effects start from its current sprite frame, not the whole atlas.
final class SceneSpriteFrameInputsTests: XCTestCase {
    func testCutsTheCurrentFrameOutOfTheAtlas() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // A 4x2 atlas of two 2x2 frames: the left one 10s, the right one 200s.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 2, mipmapped: false)
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8]()
        for _ in 0..<2 { pixels += [10, 10, 10, 255, 10, 10, 10, 255, 200, 200, 200, 255, 200, 200, 200, 255] }
        atlas.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 16)
        let inputs = SceneSpriteFrameInputs(device: device)
        func frame(_ x: Float) -> RenderTextureFrame {
            RenderTextureFrame(texture: atlas, duration: 0.1, uvOrigin: SIMD2(x, 0), uvAxisX: SIMD2(0.5, 0), uvAxisY: SIMD2(0, 1))
        }
        func cut(_ x: Float) throws -> (SceneSpriteFrameInputs.Input, [UInt8]) {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let input = try XCTUnwrap(inputs.input(frame(x), layerID: "1", commandBuffer: buffer))
            let readable = try XCTUnwrap(device.makeBuffer(length: 16))
            let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
            blit.copy(from: input.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: readable, destinationOffset: 0,
                      destinationBytesPerRow: 8, destinationBytesPerImage: 16)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            return (input, Array(UnsafeBufferPointer(start: readable.contents().assumingMemoryBound(to: UInt8.self), count: 16)))
        }
        let (first, left) = try cut(0)
        XCTAssertEqual(first.texture.width, 2)
        XCTAssertEqual(first.texture.height, 2)
        XCTAssertEqual(left[0], 10)
        let (second, right) = try cut(0.5)
        XCTAssertEqual(right[0], 200)
        XCTAssertNotEqual(first.version, second.version, "a new frame is a new input version")
        XCTAssertEqual(try cut(0.5).0.version, second.version, "the same frame isn't copied again")
        // The whole texture is drawn as it is.
        XCTAssertNil(SceneSpriteFrameInputs.region(of: RenderTextureFrame(
            texture: atlas, duration: 0, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1))))
    }
}
