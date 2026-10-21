import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Risks #10 and I13: a scene-input layer resamples the scene under its quad
/// (`SceneRegionResample`, `sceneCopyFragment`) and is then drawn back through that quad
/// (`sceneVertex`). With a pass-through in between, every pixel inside the quad must come out as
/// the scene pixel that was there: no flip, offset, mirror or rotation, whatever the quad does.
final class SceneRegionResampleTests: XCTestCase {
    private static let sceneSize = SIMD2<Float>(200, 100)
    private static let pixelsPerUnit: Float = 2
    private static let target = (width: 400, height: 200)

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var copyPipeline: MTLRenderPipelineState!
    private var drawPipeline: MTLRenderPipelineState!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let library = try XCTUnwrap(SceneMetalLibrary.make(device: device))
        let copy = MTLRenderPipelineDescriptor()
        copy.vertexFunction = library.makeFunction(name: "sceneVertex")
        copy.fragmentFunction = library.makeFunction(name: "sceneCopyFragment")
        copy.colorAttachments[0].pixelFormat = .rgba8Unorm
        copyPipeline = try device.makeRenderPipelineState(descriptor: copy)
        let draw = MTLRenderPipelineDescriptor()
        draw.vertexFunction = library.makeFunction(name: "sceneVertex")
        draw.fragmentFunction = library.makeFunction(name: "sceneFragment")
        draw.colorAttachments[0].pixelFormat = .rgba8Unorm
        drawPipeline = try device.makeRenderPipelineState(descriptor: draw)
    }

    /// The scene: red grows to the right, green grows downwards (row 0 is the scene's top).
    /// Linear, so bilinear resampling reproduces it exactly away from the quad's edges.
    private func sceneSnapshot() throws -> MTLTexture {
        var pixels = [UInt8](repeating: 255, count: Self.target.width * Self.target.height * 4)
        for y in 0..<Self.target.height {
            for x in 0..<Self.target.width {
                let index = (y * Self.target.width + x) * 4
                pixels[index] = UInt8(x * 255 / (Self.target.width - 1))
                pixels[index + 1] = UInt8(y * 255 / (Self.target.height - 1))
                pixels[index + 2] = 128
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.target.width,
                                                                  height: Self.target.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, Self.target.width, Self.target.height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: Self.target.width * 4)
        return texture
    }

    private func renderTarget(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func pass(_ target: MTLTexture, _ commands: MTLCommandBuffer, body: (MTLRenderCommandEncoder) -> Void) throws {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        descriptor.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: descriptor))
        body(encoder)
        encoder.endEncoding()
    }

    /// Resamples the scene under `quad` and draws the result back through `quad`, as the renderer
    /// does for a scene-input layer whose effects pass the image through.
    private func roundTrip(_ quad: SceneQuadGeometry, snapshot: MTLTexture) throws -> [UInt8] {
        let size = try XCTUnwrap(SceneRegionResample.targetSize(quad, pixelsPerUnit: Self.pixelsPerUnit))
        let region = try renderTarget(width: size.x, height: size.y)
        let output = try renderTarget(width: Self.target.width, height: Self.target.height)
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        try pass(region, commands) { encoder in
            var uniform = SceneRegionResample.uniform(quad, sceneSize: Self.sceneSize, targetSize: size)
            encoder.setRenderPipelineState(copyPipeline)
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(snapshot, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        try pass(output, commands) { encoder in
            // The renderer's layer draw: scene units onto the target, the quad's own axes.
            let scale = Self.pixelsPerUnit
            let targetSize = SIMD2<Float>(Float(Self.target.width), Float(Self.target.height))
            var uniform = LayerUniform(position: quad.center * scale, size: quad.extent * scale, sceneSize: targetSize,
                                       opacity: 1, particleShape: 0, rotation: 0, color: SIMD4(repeating: 1),
                                       uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                                       effects: SIMD4(1, 1, 1, 0), blur: 0, colorEffects: SIMD4(0, 1, 0, 0.7),
                                       transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
            uniform.quadAxisX = quad.axisX * scale
            uniform.quadAxisY = quad.axisY * scale
            encoder.setRenderPipelineState(drawPipeline)
            encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
            encoder.setFragmentTexture(region, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)
        var bytes = [UInt8](repeating: 0, count: Self.target.width * Self.target.height * 4)
        output.getBytes(&bytes, bytesPerRow: Self.target.width * 4,
                        from: MTLRegionMake2D(0, 0, Self.target.width, Self.target.height), mipmapLevel: 0)
        return bytes
    }

    /// Compares every target pixel well inside `quad` with the scene pixel at the same place.
    private func assertShowsTheSceneBeneath(_ quad: SceneQuadGeometry, _ label: String,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let snapshot = try sceneSnapshot()
        var scene = [UInt8](repeating: 0, count: Self.target.width * Self.target.height * 4)
        snapshot.getBytes(&scene, bytesPerRow: Self.target.width * 4,
                          from: MTLRegionMake2D(0, 0, Self.target.width, Self.target.height), mipmapLevel: 0)
        let output = try roundTrip(quad, snapshot: snapshot)
        let axes = simd_float2x2(columns: (quad.axisX, quad.axisY))
        let toLocal = axes.inverse
        var compared = 0, wrong = 0, worst = 0
        for y in 0..<Self.target.height {
            for x in 0..<Self.target.width {
                // The pixel centre in scene units (y up).
                let point = SIMD2<Float>((Float(x) + 0.5) / Self.pixelsPerUnit,
                                         Self.sceneSize.y - (Float(y) + 0.5) / Self.pixelsPerUnit)
                let local = toLocal * (point - quad.center)
                guard abs(local.x) < 0.45, abs(local.y) < 0.45 else { continue }
                compared += 1
                let index = (y * Self.target.width + x) * 4
                let delta = (0..<3).map { abs(Int(output[index + $0]) - Int(scene[index + $0])) }.max()!
                worst = max(worst, delta)
                if delta > 3 { wrong += 1 }
            }
        }
        XCTAssertGreaterThan(compared, 100, "\(label): the quad covers the target", file: file, line: line)
        XCTAssertEqual(wrong, 0, "\(label): \(wrong) of \(compared) pixels differ (worst \(worst))", file: file, line: line)
    }

    private func quad(center: SIMD2<Float>, angle: Float, scale: SIMD2<Float> = SIMD2(1, 1)) -> SceneQuadGeometry {
        let world = SceneAffineTransform(SceneLocalTransform(origin: center, scale: scale, angle: angle))
        return SceneQuadGeometry(world: world, size: SIMD2(60, 40), alignment: nil)
    }

    func testRotatedQuadsShowTheSceneBeneath() throws {
        for degrees: Float in [0, 45, 90, 180, 270] {
            try assertShowsTheSceneBeneath(quad(center: SIMD2(100, 50), angle: degrees * .pi / 180), "\(degrees)°")
        }
    }

    func testMirroredAndShearedQuadsShowTheSceneBeneath() throws {
        try assertShowsTheSceneBeneath(quad(center: SIMD2(80, 60), angle: 0, scale: SIMD2(-1, 1)), "mirrored x")
        try assertShowsTheSceneBeneath(quad(center: SIMD2(80, 60), angle: 0.3, scale: SIMD2(1, -1.5)), "mirrored y")
        let sheared = SceneQuadGeometry(center: SIMD2(100, 50), axisX: SIMD2(60, 10), axisY: SIMD2(-15, 40))
        try assertShowsTheSceneBeneath(sheared, "sheared")
    }

    func testPartlyOffscreenQuadShowsTheSceneBeneath() throws {
        try assertShowsTheSceneBeneath(quad(center: SIMD2(195, 50), angle: 0.2), "half off the right edge")
        try assertShowsTheSceneBeneath(quad(center: SIMD2(100, 2), angle: -0.4), "half below the bottom edge")
    }

    func testFullyOffscreenQuadStillResamples() throws {
        let offscreen = quad(center: SIMD2(500, -300), angle: 0.5)
        XCTAssertNotNil(SceneRegionResample.targetSize(offscreen, pixelsPerUnit: Self.pixelsPerUnit))
        _ = try roundTrip(offscreen, snapshot: try sceneSnapshot())
    }

    func testDegenerateQuadsCoverNoPixels() {
        let flat = SceneQuadGeometry(center: SIMD2(10, 10), axisX: SIMD2(0, 0), axisY: SIMD2(0, 50))
        XCTAssertNil(SceneRegionResample.targetSize(flat, pixelsPerUnit: 2))
        let broken = SceneQuadGeometry(center: SIMD2(10, 10), axisX: SIMD2(.nan, 0), axisY: SIMD2(0, .infinity))
        XCTAssertNil(SceneRegionResample.targetSize(broken, pixelsPerUnit: 2))
    }

    /// A composition layer scaled up (3453730450's, 3742916237's 2000 × 2000 ring at 4.1×) draws its
    /// effects at its own size, as WE's buffers are, not at the scaled quad's (67 megapixels).
    func testAScaledUpLayerKeepsItsOwnSize() {
        let scaled = SceneQuadGeometry(center: SIMD2(100, 100), axisX: SIMD2(8200, 0), axisY: SIMD2(0, 8200))
        XCTAssertEqual(SceneRegionResample.targetSize(scaled, layerSize: SIMD2(2000, 2000), pixelsPerUnit: 1), SIMD2(2000, 2000))
        XCTAssertEqual(SceneRegionResample.targetSize(scaled, layerSize: SIMD2(2000, 2000), pixelsPerUnit: 2), SIMD2(4000, 4000),
                       "at the target's density")
        let shrunk = SceneQuadGeometry(center: SIMD2(100, 100), axisX: SIMD2(500, 0), axisY: SIMD2(0, 250))
        XCTAssertEqual(SceneRegionResample.targetSize(shrunk, layerSize: SIMD2(2000, 2000), pixelsPerUnit: 1), SIMD2(500, 250),
                       "a smaller quad keeps its own pixels")
    }

    func testWholeSceneQuadUsesTheSnapshotAsIs() {
        let whole = SceneQuadGeometry(center: Self.sceneSize / 2, axisX: SIMD2(Self.sceneSize.x, 0), axisY: SIMD2(0, Self.sceneSize.y))
        XCTAssertTrue(SceneRegionResample.coversWholeScene(whole, sceneSize: Self.sceneSize))
        XCTAssertFalse(SceneRegionResample.coversWholeScene(quad(center: SIMD2(100, 50), angle: 0), sceneSize: Self.sceneSize))
    }
}
