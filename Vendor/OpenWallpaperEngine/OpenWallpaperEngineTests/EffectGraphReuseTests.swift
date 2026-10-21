import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Static-chain reuse and target recycling with real WE effects (needs the toolchain and a WE install).
final class EffectGraphReuseTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var renderer: EffectGraphRenderer!
    private var builder: SceneEffectPlanBuilder!
    private var cache: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.path), "WE install not present")
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-reuse-\(UUID().uuidString)")
        // Not the user's pipeline archive: tests must not write to the app's caches.
        renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: translator,
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
    }

    override func tearDownWithError() throws {
        // A pending archive write must not see its directory vanish mid-write.
        renderer?.pipelineArchive?.flush()
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    private func tintPlan() throws -> SceneEffectPlan {
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(#"{"file":"effects/tint/effect.json"}"#.utf8))
        return try builder.build(effect)
    }

    private func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func context(color: SIMD3<Float> = SIMD3(1, 1, 1), alpha: Float = 1, version: UInt64 = 0) -> EffectGraphRenderer.Context {
        var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(time: 1), values: EffectGraphTests.FixedValues(),
                                                  assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                  layerColor: color, layerAlpha: alpha)
        context.inputVersion = version
        return context
    }

    @discardableResult
    private func apply(_ plan: SceneEffectPlan, _ input: MTLTexture, _ context: EffectGraphRenderer.Context) throws -> MTLTexture {
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(renderer.apply([plan], to: input, layerID: "layer", context: context, commandBuffer: buffer))
        buffer.commit()
        buffer.waitUntilCompleted()
        return output
    }

    func testStaticChainRerendersWhenColorAlphaOrInputVersionChange() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let input = try texture(64, 64)
        try apply(plan, input, context())
        try apply(plan, input, context())
        XCTAssertEqual(renderer.layersReused, 1)
        let encoded = renderer.passesEncoded
        try apply(plan, input, context(color: SIMD3(1, 0, 0)))
        try apply(plan, input, context(color: SIMD3(1, 0, 0), alpha: 0.5))
        try apply(plan, input, context(color: SIMD3(1, 0, 0), alpha: 0.5, version: 1))
        XCTAssertEqual(renderer.passesEncoded - encoded, 3, "each change re-renders")
        try apply(plan, try texture(64, 64), context(color: SIMD3(1, 0, 0), alpha: 0.5, version: 1))
        XCTAssertEqual(renderer.passesEncoded - encoded, 4, "a different texture object re-renders")
    }

    /// TF4: a chain whose only live input is a timeline is reused while the timeline's value
    /// stays (a paused, finished or start-paused one), and re-rendered when it moves.
    func testAnAnimatedConstantsChainIsReusedWhileItsValueStays() throws {
        let json = #"{"file": "effects/tint/effect.json", "passes": [{"constantshadervalues": {"color": {"value": "1 1 1", "#
            + #""animation": {"c0": [{"frame": 0, "value": 1}], "options": {"fps": 30, "length": 30}}}}}]}"#
        let effect = try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8))
        let plan = try builder.build(effect, owner: (object: 1, effect: 0))
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let input = try texture(64, 64)
        let timeline = Timeline()
        var context = context()
        context = EffectGraphRenderer.Context(frame: context.frame, values: timeline, assetTexture: { _, _ in nil },
                                              sceneSnapshot: nil, layerColor: context.layerColor, layerAlpha: context.layerAlpha)
        try apply(plan, input, context)
        try apply(plan, input, context)
        XCTAssertEqual(renderer.layersReused, 1, "paused: reused")
        let encoded = renderer.passesEncoded
        timeline.value = [0.5, 0.5, 0.5]
        try apply(plan, input, context)
        XCTAssertEqual(renderer.passesEncoded - encoded, 1, "moved: re-rendered")
        try apply(plan, input, context)
        XCTAssertEqual(renderer.layersReused, 2, "held again: reused")
    }

    private final class Timeline: SceneValueContext {
        var value: [Float] = [1, 0, 0]
        func userProperty(_ name: String) -> String? { nil }
        func animationValue(_ site: SceneAnimationSite) -> [Float]? {
            site == SceneAnimationSite(owner: .material(object: 1, effect: 0, pass: 0), key: "color") ? value : nil
        }
    }

    func testAlternatingInputSizesReuseTargets() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let small = try texture(40, 20), large = try texture(80, 20)
        let first = try apply(plan, small, context())
        XCTAssertEqual(first.width, 40)
        try apply(plan, large, context())
        let allocated = renderer.targetsAllocated
        for _ in 0..<4 {
            XCTAssertEqual(try apply(plan, small, context()).width, 40)
            XCTAssertEqual(try apply(plan, large, context()).width, 80)
        }
        XCTAssertEqual(renderer.targetsAllocated, allocated, "sizes seen before come from the spare list")
    }

    /// Text on a clock changes size with its content: every size it cycles through comes back
    /// from the spare list, however many there are (a count cap used to evict them past 32).
    func testAClockCyclingThroughManySizesReusesItsTargets() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        var inputs: [MTLTexture] = []
        for index in 0..<40 { inputs.append(try texture(40 + index, 20)) }
        for input in inputs { try apply(plan, input, context()) }
        let allocated = renderer.targetsAllocated
        for _ in 0..<2 {
            for input in inputs { XCTAssertEqual(try apply(plan, input, context()).width, input.width) }
        }
        XCTAssertEqual(renderer.targetsAllocated, allocated, "every size seen before is reused")
    }

    /// Reused targets give the same output as fresh ones: the size asked for, never a larger one.
    func testReusedTargetsGiveTheSameOutput() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let small = try texture(40, 20), large = try texture(80, 20)
        let first = try readBack(try apply(plan, small, context(color: SIMD3(1, 0.5, 0.25))))
        try apply(plan, large, context())
        let reused = try apply(plan, small, context(color: SIMD3(1, 0.5, 0.25)))
        XCTAssertEqual(reused.width, 40)
        XCTAssertEqual(reused.height, 20)
        XCTAssertEqual(try readBack(reused), first)
    }

    /// Spares idle past `spareIdleSeconds` are dropped even while nothing changes size, and the
    /// rest fit `spareByteBudget`, longest idle out first. A layer's own targets are never evicted.
    func testSparesIdleOutAndFitTheirBudget() throws {
        let clock = TestClock()
        // The renderer's targets are private render targets; the sizes below round to the same allocation.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 43, height: 20, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let one = try XCTUnwrap(device.makeTexture(descriptor: descriptor)).allocatedSize
        let timed = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives"),
                                                      spareByteBudget: 2 * one, spareIdleSeconds: 60,
                                                      now: { clock.seconds }))
        renderer.pipelineArchive?.flush()
        renderer = timed
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let sizes = [try texture(40, 20), try texture(41, 20), try texture(42, 20), try texture(43, 20)]
        for input in sizes {
            try apply(plan, input, context())
            clock.seconds += 1
        }
        XCTAssertEqual(renderer.spareTargetCount, 2, "three given back; the budget keeps two")
        XCTAssertLessThanOrEqual(renderer.spareTargetBytes, renderer.spareByteBudget)
        var allocated = renderer.targetsAllocated
        try apply(plan, sizes[2], context())
        XCTAssertEqual(renderer.targetsAllocated, allocated, "the newest spares are the ones kept")
        allocated = renderer.targetsAllocated
        try apply(plan, sizes[0], context())
        XCTAssertEqual(renderer.targetsAllocated, allocated + 1, "the longest idle was evicted")
        clock.seconds += 61
        let output = try apply(plan, sizes[0], context())
        XCTAssertEqual(renderer.spareTargetCount, 0, "idle spares are swept")
        XCTAssertEqual(output.width, 40, "the layer's own target stays and still renders")
    }

    private final class TestClock {
        var seconds: TimeInterval = 1000
    }

    private func readBack(_ texture: MTLTexture) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let shared = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, to: shared)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        shared.getBytes(&bytes, bytesPerRow: texture.width * 4,
                        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }

    /// Memory pressure drops spare targets and, when critical, pipelines idle since the last such
    /// trim; the pipelines layers keep drawing with stay.
    func testMemoryPressureDropsSpareTargetsAndIdlePipelinesOnly() throws {
        let plan = try tintPlan()
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64))
        let small = try texture(40, 20), large = try texture(80, 20)
        try apply(plan, small, context())
        try apply(plan, large, context())
        renderer.trimMemory(dropIdlePipelines: false)
        let allocated = renderer.targetsAllocated
        try apply(plan, small, context())
        XCTAssertGreaterThan(renderer.targetsAllocated, allocated, "the spare targets were dropped")
        XCTAssertEqual(renderer.pipelineCount, 1)
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 1, "drawn with since the last trim: kept")
        renderer.trimMemory(dropIdlePipelines: true)
        XCTAssertEqual(renderer.pipelineCount, 0, "idle since the last trim: dropped")
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 64, height: 64), "and rebuilt when needed again")
    }
}
