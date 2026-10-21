import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// `g_LayerModelMatrix` reaches an effect's shaders: the fixture's vertex stage reads the layer's
/// scale (`length(g_LayerModelMatrix[0].xy)`, as Workshop effects do) and its origin, and its
/// fragment stage shows them (scale / 4 in red and green, origin x / 1000 in blue).
final class LayerModelMatrixEffectTests: XCTestCase {
    private var cache: URL!

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    func testEffectReadsTheLayerMatrix() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-layermatrix-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() }
        let fixture = Fixtures.url("Effects/layermatrix")
        let assets = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { path in
                FileManager.default.contents(atPath: fixture.appending(path: path).path)
                    ?? FileManager.default.contents(atPath: assets.appending(path: path).path)
            },
            loadTexture: { _, _ in nil })
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file": "effects/layermatrix/effect.json"}"#.utf8))
        let plan = try builder.build(effect)
        XCTAssertNotNil(plan.passes.first?.variant)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 8, height: 8), "pipelines still compiling")
        func pixel(layer: simd_float4x4?) throws -> [UInt8] {
            var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 0), values: NoValues(),
                                                      assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                      layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
            context.layerModelMatrix = layer
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "layer", context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            return Array(try TextureUploadTests.read(output, device: device)[(4 * 8 + 4) * 4..<(4 * 8 + 4) * 4 + 4])
        }
        let world = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 20), scale: SIMD2(2, 3), angle: 0.4))
        let scaled = try pixel(layer: BuiltinPassContext.layerModelMatrix(world))
        XCTAssertEqual(Int(scaled[0]), 128, accuracy: 2, "x scale 2: \(scaled)")
        XCTAssertEqual(Int(scaled[1]), 191, accuracy: 2, "y scale 3: \(scaled)")
        XCTAssertEqual(Int(scaled[2]), 128, accuracy: 2, "origin x 500: \(scaled)")
        // The chain's output is kept while nothing it reads changes; a rescaled layer redraws it.
        let rescaled = try pixel(layer: BuiltinPassContext.layerModelMatrix(
            SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 20), scale: SIMD2(4, 1), angle: 0))))
        XCTAssertEqual(Int(rescaled[0]), 255, accuracy: 2, "\(rescaled)")
        XCTAssertEqual(Int(rescaled[1]), 64, accuracy: 2, "\(rescaled)")
        // A chain that isn't a layer's: the pass's own (identity) model matrix.
        let plain = try pixel(layer: nil)
        XCTAssertEqual(Int(plain[0]), 64, accuracy: 2, "\(plain)")
        XCTAssertEqual(Int(plain[1]), 64, accuracy: 2, "\(plain)")
        XCTAssertEqual(Int(plain[2]), 0, accuracy: 2, "\(plain)")
    }
}
