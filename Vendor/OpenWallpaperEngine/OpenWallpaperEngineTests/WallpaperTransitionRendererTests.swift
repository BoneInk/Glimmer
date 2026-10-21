import Metal
import simd
import XCTest
@testable import OpenWallpaperEngine

/// WE's playlist transitions, drawn headless and laid over an incoming picture the way the app
/// composites them (premultiplied, source-over): each starts on the outgoing wallpaper, ends on
/// the incoming one, and is somewhere in between halfway.
final class WallpaperTransitionRendererTests: XCTestCase {
    private static let width = 160
    private static let height = 90

    /// One renderer and one pair of pictures for the class.
    private final class Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: WallpaperTransitionRenderer
        let outgoing: MTLTexture
        let outgoingPixels: [SIMD4<Float>]
        let incomingPixels: [SIMD4<Float>]

        init() throws {
            device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            queue = try XCTUnwrap(device.makeCommandQueue())
            renderer = try WallpaperTransitionRenderer(device: device)
            let width = WallpaperTransitionRendererTests.width, height = WallpaperTransitionRendererTests.height
            var outgoingPixels: [SIMD4<Float>] = []
            var incomingPixels: [SIMD4<Float>] = []
            for y in 0..<height {
                for x in 0..<width {
                    // Outgoing: a red/green gradient with a checker in blue. Incoming: blue with stripes.
                    let checker: Float = ((x / 8 + y / 8) % 2 == 0) ? 0.3 : 0
                    outgoingPixels.append(SIMD4<Float>(0.2 + 0.8 * Float(x) / Float(width), 0.9 - 0.7 * Float(y) / Float(height),
                                                       0.1 + checker, 1))
                    let stripe: Float = (x / 5) % 2 == 0 ? 0.25 : 0
                    incomingPixels.append(SIMD4<Float>(0.05, 0.1 + stripe, 0.85, 1))
                }
            }
            self.outgoingPixels = Fixture.quantized(outgoingPixels)
            self.incomingPixels = Fixture.quantized(incomingPixels)
            outgoing = try Fixture.texture(device: device, pixels: self.outgoingPixels, width: width, height: height)
        }

        /// As an 8-bit texture holds them.
        static func quantized(_ pixels: [SIMD4<Float>]) -> [SIMD4<Float>] {
            pixels.map { ($0 * 255).rounded(.toNearestOrAwayFromZero) / 255 }
        }

        static func texture(device: MTLDevice, pixels: [SIMD4<Float>], width: Int, height: Int) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                      mipmapped: false)
            descriptor.usage = .shaderRead
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var bytes: [UInt8] = []
            bytes.reserveCapacity(pixels.count * 4)
            for pixel in pixels {
                let scaled: SIMD4<Float> = pixel * 255
                bytes += [UInt8(scaled.z), UInt8(scaled.y), UInt8(scaled.x), UInt8(scaled.w)]
            }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes,
                            bytesPerRow: width * 4)
            return texture
        }
    }

    private static let fixture = Result { try Fixture() }

    private var fixture: Fixture { get throws { try Self.fixture.get() } }

    // MARK: - Tests

    func testEveryKindsPipelineCompiles() throws {
        let renderer = try fixture.renderer
        for kind in WallpaperTransitionKind.allCases {
            XCTAssertNoThrow(try renderer.preparePipelines(for: kind, pixelFormat: .bgra8Unorm), "\(kind)")
        }
    }

    /// The mean absolute difference allowed at the ends, per kind, where WE's own math leaves
    /// something there.
    private struct Expectation {
        var start: Float = 0.01
        var end: Float = 0.01
    }

    private static let expectations: [WallpaperTransitionKind: Expectation] = [
        // At exactly 0 and 1 WE's hole has no size, so `smoothstep(0, 0, dist)` is 1 everywhere:
        // the picture squared at 0 and black at 1 (DX's divide by zero, kept by `hlslSmoothstep`).
        .blackHole: Expectation(start: 0.25, end: 0.45),
        // At exactly 0 `impactTimer` is 0, so the cracks' fade-out `smoothstep(0, 0, …)` is 1 and
        // the crack pattern already shows.
        .bullets: Expectation(start: 0.2),
        // At 0 the grid is (10 + height) × aspect cells, not one per pixel: a slight resample.
        .pixelate: Expectation(start: 0.02),
    ]

    func testEveryKindGoesFromOutgoingToIncoming() throws {
        let fixture = try fixture
        let seed = WallpaperTransitionSeed(hash: 0.37, hash2: 0.61, random: 0.5)
        for kind in WallpaperTransitionKind.allCases {
            let expectation = Self.expectations[kind] ?? Expectation()
            let start = try composite(kind, progress: 0, seed: seed)
            let middle = try composite(kind, progress: 0.5, seed: seed)
            let end = try composite(kind, progress: 1, seed: seed)

            let startError = Self.meanDifference(start, fixture.outgoingPixels)
            let endError = Self.meanDifference(end, fixture.incomingPixels)
            XCTAssertLessThan(startError, expectation.start, "\(kind) at 0 should show the outgoing picture (\(startError))")
            XCTAssertLessThan(endError, expectation.end, "\(kind) at 1 should show the incoming picture (\(endError))")
            let fromOutgoing = Self.meanDifference(middle, fixture.outgoingPixels)
            let fromIncoming = Self.meanDifference(middle, fixture.incomingPixels)
            XCTAssertGreaterThan(fromOutgoing, 0.02, "\(kind) halfway should have left the outgoing picture")
            XCTAssertGreaterThan(fromIncoming, 0.02, "\(kind) halfway should not have reached the incoming picture")
        }
    }

    func testCRTAndIceSampleAMipChainAndOthersTheTextureItself() throws {
        let fixture = try fixture
        let commandBuffer = try XCTUnwrap(fixture.queue.makeCommandBuffer())
        for kind in WallpaperTransitionKind.allCases {
            let prepared = try fixture.renderer.prepareOutgoing(fixture.outgoing, for: kind, commandBuffer: commandBuffer)
            if kind == .crt || kind == .ice {
                XCTAssertFalse(prepared === fixture.outgoing, "\(kind) samples a copy")
                XCTAssertEqual(prepared.mipmapLevelCount, 8, "\(kind): 160×90 down to 1×1")
                XCTAssertEqual(prepared.width, Self.width)
            } else {
                XCTAssertTrue(prepared === fixture.outgoing, "\(kind) samples the outgoing texture itself")
            }
        }
        // The chain's levels blur the picture without shifting its colour.
        let chain = try fixture.renderer.prepareOutgoing(fixture.outgoing, for: .crt, commandBuffer: commandBuffer)
        let level = 2
        let levelWidth = chain.width >> level, levelHeight = chain.height >> level
        let buffer = try XCTUnwrap(fixture.device.makeBuffer(length: levelWidth * levelHeight * 4, options: .storageModeShared))
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: chain, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: levelWidth, height: levelHeight, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: levelWidth * 4, destinationBytesPerImage: levelWidth * levelHeight * 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let blurred = Self.pixels(buffer.contents(), count: levelWidth * levelHeight)
        let blurredMean = Self.mean(blurred), sourceMean = Self.mean(fixture.outgoingPixels)
        XCTAssertEqual(blurredMean.x, sourceMean.x, accuracy: 0.03)
        XCTAssertEqual(blurredMean.y, sourceMean.y, accuracy: 0.03)
        XCTAssertEqual(blurredMean.z, sourceMean.z, accuracy: 0.03)
    }

    func testBoiloverTexturesComeFromTheAssetsWhenThereAreAny() throws {
        let device = try fixture.device
        let textures = try WallpaperTransitionTextures.load(device: device, assetsDirectory: WallpaperEngineAssets.directory)
        XCTAssertEqual(textures.source, WallpaperEngineAssets.directory == nil ? .generated : .wallpaperEngine)
        XCTAssertEqual(textures.noise.width, 256)
        XCTAssertEqual(textures.clouds.width, 256)
    }

    func testGeneratedTexturesAreTheSameEveryTime() {
        XCTAssertEqual(WallpaperTransitionTextures.generatedNoise(size: 16), WallpaperTransitionTextures.generatedNoise(size: 16))
        let clouds = WallpaperTransitionTextures.generatedClouds(size: 32)
        XCTAssertEqual(clouds, WallpaperTransitionTextures.generatedClouds(size: 32))
        XCTAssertEqual(clouds.min(), 0, "the clouds span the full range")
        XCTAssertEqual(clouds.max(), 255)
    }

    func testFacetsTileTheTargetAndAreTheSameEveryTime() {
        let vertices = WallpaperTransitionFacets.make()
        let again = WallpaperTransitionFacets.make()
        XCTAssertEqual(vertices.count, again.count)
        XCTAssertEqual(MemoryLayout<WallpaperTransitionFacets.Vertex>.stride, 44, "11 packed floats, as the shader reads them")
        var frontArea: Float = 0
        var backVertices = 0
        for start in stride(from: 0, to: vertices.count, by: 3) {
            let a = vertices[start], b = vertices[start + 1], c = vertices[start + 2]
            if a.position.z < 0 || b.position.z < 0 || c.position.z < 0 { backVertices += 1; continue }
            guard a.normal.z == 1 else { continue }
            let ab = SIMD2<Float>(b.position.x - a.position.x, b.position.y - a.position.y)
            let ac = SIMD2<Float>(c.position.x - a.position.x, c.position.y - a.position.y)
            frontArea += abs(ab.x * ac.y - ab.y * ac.x) * 0.5
        }
        XCTAssertEqual(frontArea, 4, accuracy: 0.001, "the front faces cover [-1, 1]² exactly once")
        XCTAssertGreaterThan(backVertices, 0, "the pieces have sides reaching back")
        XCTAssertEqual(vertices.first?.position.x, again.first?.position.x)
    }

    // MARK: - Helpers

    /// `kind` at `progress` laid premultiplied over the incoming picture, as the compositor does.
    private func composite(_ kind: WallpaperTransitionKind, progress: Float, seed: WallpaperTransitionSeed) throws -> [SIMD4<Float>] {
        let fixture = try fixture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Self.width,
                                                                  height: Self.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(fixture.device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(fixture.device.makeBuffer(length: Self.width * Self.height * 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(fixture.queue.makeCommandBuffer())
        let outgoing = try fixture.renderer.prepareOutgoing(fixture.outgoing, for: kind, commandBuffer: commandBuffer)
        try fixture.renderer.encode(kind, progress: progress, outgoing: outgoing, seed: seed, into: target,
                                    commandBuffer: commandBuffer)
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: Self.width, height: Self.height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: Self.width * 4, destinationBytesPerImage: Self.width * Self.height * 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error, "\(kind)")
        let drawn = Self.pixels(buffer.contents(), count: Self.width * Self.height)
        return zip(drawn, fixture.incomingPixels).map { out, incoming in
            let rgb: SIMD3<Float> = SIMD3<Float>(out.x, out.y, out.z) + SIMD3<Float>(incoming.x, incoming.y, incoming.z) * (1 - out.w)
            return SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1)
        }
    }

    /// BGRA8 bytes as RGBA in 0…1.
    private static func pixels(_ contents: UnsafeMutableRawPointer, count: Int) -> [SIMD4<Float>] {
        let bytes = contents.bindMemory(to: UInt8.self, capacity: count * 4)
        return (0..<count).map { index in
            let base = index * 4
            return SIMD4<Float>(Float(bytes[base + 2]), Float(bytes[base + 1]), Float(bytes[base]), Float(bytes[base + 3])) / 255
        }
    }

    /// The mean absolute difference of the colour channels.
    private static func meanDifference(_ lhs: [SIMD4<Float>], _ rhs: [SIMD4<Float>]) -> Float {
        var total: Float = 0
        for (a, b) in zip(lhs, rhs) {
            let difference: SIMD4<Float> = simd_abs(a - b)
            total += difference.x + difference.y + difference.z
        }
        return total / Float(lhs.count * 3)
    }

    private static func mean(_ pixels: [SIMD4<Float>]) -> SIMD4<Float> {
        var total = SIMD4<Float>(0, 0, 0, 0)
        for pixel in pixels { total += pixel }
        return total / Float(pixels.count)
    }
}
