import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// The `layerimage` emitter (`ParticleEmitterImagePoints`, the GPU step's `emitFromImage`), from
/// `wallpaper64.exe`: defaults 0x1401b9930, points 0x1401d3ae0, spawn 0x140238c45. WE's element
/// preview (`scenes/particleelementpreviews/layerimage`) against WE's capture is in
/// `WEParticleGalleryTests`.
final class ParticleEmitterImageTests: XCTestCase {
    func testTheReducedImageIsAQuarterOfTheLayersImage() {
        XCTAssertEqual(ParticleEmitterImagePoints.targetSize(imageSize: SIMD2(256, 256)), SIMD2(64, 64))
        XCTAssertEqual(ParticleEmitterImagePoints.targetSize(imageSize: SIMD2(1001, 7)), SIMD2(250, 2), "at least 2")
        // Larger than 3840 × 2160: fitted into it with its aspect first.
        XCTAssertEqual(ParticleEmitterImagePoints.targetSize(imageSize: SIMD2(5000, 1000)), SIMD2(960, 192))
        XCTAssertEqual(ParticleEmitterImagePoints.targetSize(imageSize: SIMD2(1000, 4000)), SIMD2(135, 540))
    }

    /// Every texel with alpha 127 or more is a point at its centre in the image's pixels from the
    /// image's centre (y up), with its colour; columns first, as WE walks them.
    func testPointsAreTheOpaqueTexelsCentres() {
        // A 2 × 2 reduction of an 8 × 8 image: texels (0,0) opaque red, (1,0) alpha 126, (0,1)
        // alpha 127 green, (1,1) opaque blue.
        let rgba: [UInt8] = [255, 0, 0, 255, 9, 9, 9, 126,
                             0, 255, 0, 127, 0, 0, 255, 255]
        let points = ParticleEmitterImagePoints.points(rgba: rgba, target: SIMD2(2, 2), imageSize: SIMD2(8, 8))
        XCTAssertEqual(points, [SIMD4(-2, 2, 0xFF0000, 0), SIMD4(-2, -2, 0x00FF00, 0), SIMD4(2, -2, 0x0000FF, 0)])
    }

    func testLayerImageEmitterDefaults() throws {
        func shape(_ json: String, pixels: Bool = true) throws -> ParticleEmitterShape {
            let emitter = try JSONDecoder().decode(WEParticleEmitter.self, from: Data(json.utf8))
            return ParticleSystemBuilder.emitterShape(emitter, defaults: ParticleDefaults(pixelUnits: pixels))
        }
        let plain = try shape(#"{"name": "layerimage", "rate": 5000}"#)
        XCTAssertEqual(plain.kind, .image)
        XCTAssertTrue(plain.takesImageColor, "flags 0x10000 by default")
        XCTAssertFalse(plain.offsetsRandomly)
        XCTAssertEqual(plain.distanceMinimum, SIMD3(-5, -5, 0))
        XCTAssertEqual(plain.distanceMaximum, SIMD3(5, 5, 0))
        let world = try shape(#"{"name": "layerimage"}"#, pixels: false)
        XCTAssertEqual(world.distanceMinimum, .zero)
        XCTAssertEqual(world.distanceMaximum, .zero)
        let offset = try shape(#"{"name": "layerimage", "flags": 524288, "offsetmin": "-1 -2 0", "offsetmax": "3 4 0"}"#)
        XCTAssertFalse(offset.takesImageColor, "an authored flags without 0x10000")
        XCTAssertTrue(offset.offsetsRandomly)
        XCTAssertEqual(offset.distanceMaximum, SIMD3(3, 4, 0))
    }

    func testEmitterImageDependenciesBindByIndex() throws {
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
        {"id": 19, "particle": "p.json", "dependencies": [{"id": 38, "index": 1, "type": "emitterimage"},
                                                          {"id": 40, "index": 0, "type": "collisionmodel"}]}
        """#.utf8))
        let images = ParticleEmitterImage.bound(object.dependencies ?? [])
        XCTAssertEqual(images.map(\.layerID), ["", "38"])
    }

    /// A spawn lands on one of the points, through the layer's transform into the system's space, and
    /// takes the point's colour; without flag 0x80000 it doesn't move off it.
    func testASpawnLandsOnAPointInTheLayersSpace() throws {
        let points: [SIMD4<Int32>] = [SIMD4(-10, 20, 0x8040FF, 0), SIMD4(30, -40, 0xFFFFFF, 0)]
        let layer = SceneAffineTransform(linear: simd_float2x2(diagonal: SIMD2<Float>(2, 2)), translation: SIMD2(100, 50))
        let gpu = try ParticleGPUStepper()
        let runtime = try imageSystem(points: points, burst: 16, gpu: gpu)
        gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero,
                                                              layerWorld: { $0 == "4" ? layer : nil }))
        let spawned = gpu.particles(runtime)
        XCTAssertEqual(spawned.count, 16)
        for particle in spawned {
            let first = simd_distance(particle.position, SIMD2<Float>(80, 90)) < 1e-3
            XCTAssertTrue(first || simd_distance(particle.position, SIMD2<Float>(160, -30)) < 1e-3, "\(particle.position)")
            let color: SIMD3<Float> = first ? SIMD3<Float>(128, 64, 255) / 255 : SIMD3<Float>(repeating: 1)
            for channel in 0..<3 {
                XCTAssertEqual(particle.color[channel], color[channel], accuracy: 1e-5, "\(particle.position)")
            }
            XCTAssertEqual(particle.velocity, .zero, "at rest without flag 0x40000")
        }
        let empty = try imageSystem(points: [], burst: 16, gpu: gpu)
        gpu.step(empty, inputs: ParticleFrameInputs.advance(empty, deltaTime: 1 / 60, cursor: .zero,
                                                            layerWorld: { $0 == "4" ? layer : nil }))
        XCTAssertEqual(gpu.particles(empty).count, 0, "no points, no spawn")
    }

    /// A system at the scene's origin bursting `burst` particles from one `layerimage` emitter on
    /// layer "4"'s `points`, which they keep at rest, white, unless the emitter colours or launches them.
    private func imageSystem(points: [SIMD4<Int32>], burst: Int, gpu: ParticleGPUStepper) throws -> ParticleSystemRuntime {
        var test = ParticleTestSystem()
        test.origin = .zero
        test.emissionRate = 0
        test.instantaneous = burst
        test.lifetime = 10...10
        test.minimumVelocity = .zero
        test.maximumVelocity = .zero
        test.minimumColor = SIMD4(repeating: 1)
        test.maximumColor = SIMD4(repeating: 1)
        var configuration = test.configuration
        configuration.program.operators = []
        configuration.emitter.kind = .image
        configuration.emitterImages = [ParticleEmitterImage(layerID: "4", points: points)]
        return ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration)
    }

    /// WE's downsample (`downsample_quarter`, `WRITEALPHA`) on the GPU: a uniform image reduces to itself.
    func testTheReductionKeepsAUniformImage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 16, height: 8, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let texels = [UInt8](repeating: 0, count: 16 * 8 * 4).enumerated().map { index, _ in [UInt8(200), 100, 50, 128][index % 4] }
        texels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 16, 8), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64) }
        let target = ParticleEmitterImagePoints.targetSize(imageSize: SIMD2(16, 8))
        let reduced = try XCTUnwrap(ParticleEmitterImagePoints.reduce(.init(texture: texture), target: target,
                                                                      device: device, queue: queue))
        XCTAssertEqual(target, SIMD2(4, 2))
        XCTAssertEqual(reduced, [UInt8]((0..<8).flatMap { _ in [UInt8(200), 100, 50, 128] }))
        XCTAssertEqual(ParticleEmitterImagePoints.points(rgba: reduced, target: target, imageSize: SIMD2(16, 8)).count, 8)
    }
}
