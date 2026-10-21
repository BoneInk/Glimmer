import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Effects at their layer's on-screen size (`SceneEffectDetail`, `GSSceneDetail.matchDisplay`) and
/// the scene target matched to the display (`SceneRenderResolution`).
final class SceneEffectDetailTests: XCTestCase {
    // MARK: - Scale

    func testTheScaleCoversTheFootprintAndKeepsTheAspect() {
        XCTAssertEqual(SceneEffectDetail.neededScale(footprint: SIMD2(690, 1117), imageSize: SIMD2(2760, 4466)), 1117.0 / 4466,
                       accuracy: 1e-6, "the larger axis wins")
        XCTAssertEqual(SceneEffectDetail.neededScale(footprint: SIMD2(5000, 5000), imageSize: SIMD2(2760, 4466)), 1,
                       "never above the image")
        XCTAssertEqual(SceneEffectDetail.quantized(0.2501), 0.3125, "rounded up to a sixteenth, never below the footprint")
        XCTAssertEqual(SceneEffectDetail.quantized(0.001), SceneEffectDetail.step)
        XCTAssertEqual(SceneEffectDetail.quantized(0.95), 1, "nearly the whole image is the image")
        XCTAssertEqual(SceneEffectDetail.copySize(SIMD2(2760, 4466), scale: 0.25), SIMD2(690, 1117))
        XCTAssertEqual(SceneEffectDetail.copySize(SIMD2(2760, 4466), scale: 1), SIMD2(2760, 4466))
    }

    func testTheScaleGrowsAtOnceAndShrinksOnlyAfterStayingSmaller() {
        var scale = SceneEffectDetail.Scale()
        XCTAssertEqual(scale.update(needed: 0.24), 1, "starts whole; shrinking waits")
        for _ in 1..<(SceneEffectDetail.shrinkFrames - 1) { _ = scale.update(needed: 0.24) }
        XCTAssertEqual(scale.update(needed: 0.24), 0.25, "after shrinkFrames frames at under shrinkRatio")
        XCTAssertEqual(scale.update(needed: 0.4), 0.4375, "grows the same frame")
        for _ in 0..<200 { _ = scale.update(needed: 0.36) }
        XCTAssertEqual(scale.update(needed: 0.36), 0.4375, "within shrinkRatio: kept, no reallocation")
        var bouncing = SceneEffectDetail.Scale()
        for frame in 0..<200 { _ = bouncing.update(needed: frame % 10 == 0 ? 1 : 0.2) }
        XCTAssertEqual(bouncing.update(needed: 0.2), 1, "a footprint that keeps coming back never shrinks the copy")
    }

    // MARK: - Scene target

    func testALargerSceneIsDrawnAtTheDisplaysSize() {
        let tsunade = SIMD2<Float>(3840, 2987), fullHD = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: tsunade, drawableSize: fullHD, floorsAtAuthoredSize: true), 1,
                       "floored as WE's captures: never below the authored size")
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: tsunade, drawableSize: fullHD), 0.5,
                       "the display's size, rounded up to a 64th")
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(1920, 1080), drawableSize: SIMD2(3840, 2160)), 2,
                       "a smaller scene still gets the display's density")
        let narrow = SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(100_000, 100), drawableSize: SIMD2(10, 10))
        XCTAssertLessThanOrEqual(narrow, SceneRenderResolution.maximumTextureDimension / 100_000, "the texture limit still rules")
        XCTAssertEqual(SceneRenderResolution.pixelsPerUnit(sceneSize: SIMD2(100_000, 100), drawableSize: SIMD2(10, 10),
                                                           floorsAtAuthoredSize: true),
                       SceneRenderResolution.maximumTextureDimension / 100_000, "a floored scene is fitted to the texture limit")
    }

    func testSettingsReachTheRenderer() {
        var settings = GlobalSettings()
        XCTAssertEqual(settings.sceneDetail, .matchDisplay, "effects no larger than on screen by default")
        XCTAssertEqual(settings.renderResolution, .yourDisplay)
        settings.sceneDetail = .full
        settings.renderResolution = .full
        let render = SceneRenderSettings(settings)
        XCTAssertEqual(render.sceneDetail, .full)
        XCTAssertEqual(render.renderResolution, .full)
        XCTAssertEqual(SceneRenderSettings().sceneDetail, .full, "a settings-less renderer draws as WE does")
    }

    func testStoredSettingsWithoutTheNewKeysKeepTheirDefaults() throws {
        let stored = Data(#"{"textureResolution":"highPerformance"}"#.utf8)
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: stored)
        XCTAssertEqual(settings.textureResolution, .highPerformance)
        XCTAssertEqual(settings.sceneDetail, .matchDisplay)
        let round = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
    }

    // MARK: - Effect chains (needs the toolchain and a WE install)

    static func graph() throws -> (EffectGraphRenderer, SceneEffectPlanBuilder, MTLCommandQueue, URL) {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-detail-\(UUID().uuidString)")
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let root = ShaderVariantTests.weAssets
        let builder = SceneEffectPlanBuilder(translator: translator,
                                             readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
                                             loadTexture: { _, _ in nil })
        return (renderer, builder, try XCTUnwrap(device.makeCommandQueue()), cache)
    }

    static func plan(_ file: String, _ builder: SceneEffectPlanBuilder) throws -> SceneEffectPlan {
        try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file":"\#(file)"}"#.utf8)))
    }

    static func texture(_ device: MTLDevice, _ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// A pattern, so a pass that moves the image shows.
    static func fill(_ texture: MTLTexture, queue: MTLCommandQueue) throws {
        let pixels = SceneMipMappedFrameBufferTests.bytes({ x, y in [UInt8(x * 4 % 256), UInt8(y * 4 % 256), UInt8((x ^ y) % 256), 255] },
                                                          width: texture.width, height: texture.height)
        texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: texture.width * 4)
    }

    static func context(time: Double, footprint: SIMD2<Float>? = nil) -> EffectGraphRenderer.Context {
        var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: time), values: EffectGraphTests.FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
        context.footprint = footprint
        return context
    }

    func testAChainRunsAtTheFootprintAndBackAtFullSizeWhenItGrows() throws {
        let (renderer, builder, queue, cache) = try Self.graph()
        defer {
            renderer.pipelineArchive?.flush()
            try? FileManager.default.removeItem(at: cache)
        }
        let tint = try Self.plan("effects/tint/effect.json", builder)
        XCTAssertTrue(renderer.waitUntilReady([tint], width: 64, height: 64))
        let image = try Self.texture(queue.device, 256, 128)
        func draw(_ footprint: SIMD2<Float>?) throws -> MTLTexture {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([tint], to: image, layerID: "layer",
                                                      context: Self.context(time: 1, footprint: footprint), commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            return output
        }
        XCTAssertEqual(try draw(nil).width, 256, "as WE: the image's size")
        XCTAssertEqual(try draw(SIMD2(1000, 1000)).width, 256, "never above the image")
        var output = try draw(SIMD2(60, 30))
        for _ in 0..<SceneEffectDetail.shrinkFrames { output = try draw(SIMD2(60, 30)) }
        XCTAssertEqual([output.width, output.height], [64, 32], "the footprint, rounded up to a sixteenth of the image")
        XCTAssertEqual(try draw(SIMD2(200, 100)).width, 208, "a grown footprint the same frame")
    }
}
