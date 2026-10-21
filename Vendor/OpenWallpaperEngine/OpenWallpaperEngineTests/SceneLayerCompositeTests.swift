import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Layers sampling other layers' images (`_rt_imageLayerComposite_<id>_a` in scene.json pass
/// `textures`, roadmap notes §8 item 14): WE registers a layer's first composite buffer under that name
/// (0x1401ea7a3 → 0x1400d3198) and a material's texture lookup finds it (0x14014cf90); `_b` is
/// never registered. The renderer prepares every sampled layer, hidden or not, before its readers.
final class SceneLayerCompositeTests: XCTestCase {
    private struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    // MARK: - Preparation order

    func testASampledLayerIsPreparedBeforeItsReader() {
        // 2176097362: `blue` (index 0) reads `alpha blue` (index 2), which the list has later.
        let order = SceneLayerCompositeOrder(layers: [("354", ["349"]), ("10", []), ("349", []), ("11", [])])
        XCTAssertEqual(order.sources, ["349"])
        XCTAssertEqual(order.sequence, [2, 0, 1, 3])
    }

    func testTheListOrderStandsWithoutSources() {
        let order = SceneLayerCompositeOrder(layers: [("1", []), ("2", ["99"]), ("3", [])])
        XCTAssertTrue(order.sources.isEmpty, "a layer that isn't there samples nothing")
        XCTAssertEqual(order.sequence, [0, 1, 2])
    }

    func testChainsAndCyclesKeepEveryLayerOnce() {
        // 2350874185's compose layer reads nine layers listed before it; a chain; a cycle.
        let chain = SceneLayerCompositeOrder(layers: [("a", ["b"]), ("b", ["c"]), ("c", [])])
        XCTAssertEqual(chain.sequence, [2, 1, 0])
        let cycle = SceneLayerCompositeOrder(layers: [("a", ["b"]), ("b", ["a"]), ("c", ["c"])])
        XCTAssertEqual(cycle.sequence.sorted(), [0, 1, 2])
        XCTAssertEqual(cycle.sources, ["a", "b"], "a layer reading itself isn't a source")
    }

    /// GP6: a sampled layer that reads the scene makes its image inside the scene pass, and every
    /// layer sampling it (directly or through another) runs there after it, as WE renders objects
    /// in order and registers each composite as it goes (0x1401ea7a3).
    func testLayersSamplingALayerThatReadsTheSceneRunInTheScenePass() {
        let order = SceneLayerCompositeOrder(layers: [("bg", []), ("refract", []), ("reader", ["refract"]),
                                                      ("second", ["reader"]), ("plain", ["bg"])],
                                             readingScene: ["refract", "plain"])
        XCTAssertEqual(order.inScene, ["refract", "reader", "second"])
        XCTAssertTrue(SceneLayerCompositeOrder(layers: [("a", ["b"]), ("b", [])], readingScene: ["a"]).inScene.isEmpty,
                      "a reader that reads the scene samples a source made before the pass")
    }

    // MARK: - Effect plans

    private func builder(cache: URL) -> SceneEffectPlanBuilder {
        let root = ShaderVariantTests.weAssets
        return SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
    }

    private func blend(sampling name: String, builder: SceneEffectPlanBuilder) throws -> SceneEffectPlan {
        // 3378346807's clock overlay: WE's blend effect over a fullscreen layer, its blend texture
        // another layer's composite.
        let json = #"{"file":"effects/blend/effect.json","passes":[{"combos":{"BLENDMODE":0},"textures":[null,""#
            + name + #""]}]}"#
        return try builder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(json.utf8)))
    }

    func testTheCompositeNameBindsAnotherLayersImage() throws {
        _ = try Fixtures.assets()
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-composite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let builder = builder(cache: cache)
        let plan = try blend(sampling: "_rt_imageLayerComposite_255_a", builder: builder)
        guard case .fbo(let name)? = plan.passes.first?.textures[1] else {
            return XCTFail("slot 1 isn't the composite: \(String(describing: plan.passes.first?.textures[1]))")
        }
        XCTAssertEqual(name, "_rt_imageLayerComposite_255_a")
        XCTAssertEqual(plan.compositeLayerIDs, ["255"])
        XCTAssertTrue(plan.carriesFrames, "another layer's image changes whatever this layer's input does")
        // `_b` is never registered: an unknown render target (WE's error texture; unbound here).
        let unknown = try blend(sampling: "_rt_imageLayerComposite_255_b", builder: builder)
        XCTAssertTrue(unknown.compositeLayerIDs.isEmpty)
        if case .fbo? = unknown.passes.first?.textures[1] { XCTFail("an unregistered name binds nothing") }
    }

    func testThePassSamplesTheCompositeTheRendererHandsIt() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-composite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        let plan = try blend(sampling: "_rt_imageLayerComposite_7_a", builder: builder(cache: cache))
        XCTAssertTrue(renderer.waitUntilReady([plan], width: 32, height: 32))
        let layer = try ImageMaterialRenderTests.solidTexture(device: device, color: [0, 255, 0, 255])
        let other = try ImageMaterialRenderTests.solidTexture(device: device, color: [255, 0, 0, 255])

        func run(composites: [String: MTLTexture], id: String) throws -> [UInt8] {
            var context = EffectGraphRenderer.Context(frame: BuiltinFrameContext(), values: NoValues(),
                                                      assetTexture: { _, _ in nil }, sceneSnapshot: nil,
                                                      layerColor: SIMD3(repeating: 1), layerAlpha: 1)
            context.layerComposite = { composites[$0] }
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let output = try XCTUnwrap(renderer.apply([plan], to: layer, layerID: id, context: context, commandBuffer: buffer))
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            return try TextureUploadTests.read(output, device: device)
        }
        let bound = try run(composites: ["7": other], id: "reader")
        XCTAssertEqual(Array(bound[0..<3]), [255, 0, 0], "normal blend at full amount: the other layer's image")
        let missing = try run(composites: [:], id: "reader-missing")
        XCTAssertNotEqual(Array(missing[0..<3]), [255, 0, 0])
    }
}
