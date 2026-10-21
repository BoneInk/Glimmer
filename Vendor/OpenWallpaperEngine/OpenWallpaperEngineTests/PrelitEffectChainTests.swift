import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A lit layer's effects start from its prelit image, which is redrawn into the same texture every
/// frame (docs/test-risks.md LF1): a chain that is static on its own (an identity tint) still runs
/// every frame, so the layer follows its lights; kept outputs (`EffectGraphRenderer.staticPrefix`,
/// the static chain) never outlive the image they were made from.
final class PrelitEffectChainTests: XCTestCase {
    private typealias Lit = ImageMaterialLightingTests
    private typealias Stage = SceneMipMappedFrameBufferTests

    func testAPrelitLayersStaticChainRunsEveryFrame() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ShaderVariantTests.weAssets.appending(path: "shaders/genericimage4.frag").path),
                          "bundled WE shaders missing")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-prelit-chain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let assets = ShaderVariantTests.weAssets
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let effectBuilder = SceneEffectPlanBuilder(translator: translator,
                                                   readFile: { FileManager.default.contents(atPath: assets.appending(path: $0).path) },
                                                   loadTexture: { _, _ in nil })
        let tint = try effectBuilder.build(try JSONDecoder().decode(WEObjectEffect.self, from: Data(
            #"{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":0}}]}"#.utf8)))
        let roots = [Fixtures.url("ImageMaterials"), assets]
        let normal = try Lit.image(Lit.normal), mask = try Lit.image(Lit.mask)
        let budget = WELightConfig(point: 1)
        let materials = ImageMaterialPlanBuilder(
            translator: translator,
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { name, _ in name == "lit_normal" ? .image(normal) : name == "lit_mask" ? .image(mask) : nil },
            sceneEngineCombos: SceneEngineCombos(sceneOrtho: true, lightBudget: budget))

        let size = 128
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let scene = SIMD2<Float>(Float(size), Float(size))
        let gradient = try ImageMaterialReflectionTests.image(width: 16, height: 16, pixels: Stage.bytes({ x, y in
            [UInt8(x * 16), 200, UInt8(y * 16), 255] }, width: 16, height: 16))
        var layer = Stage.layer("lit", image: gradient, size: scene)
        layer.weEffects = [tint]
        layer.imageMaterial = try materials.build(materialPath: "materials/lit.json", colorBlendMode: nil, prelit: true)
        var content = Stage.content(layers: [layer], size: scene)
        var point = SceneLight(kind: .point)
        point.intensity = 3
        point.radius = 120
        content.lighting.settings.lightConfig = budget
        content.lighting.lights = [SceneLightObject(id: "9", authored: WESceneLight(kind: .point), light: point,
                                                    depth: SceneLightDepth(originZ: 25))]
        content.transforms = SceneTransformHierarchy(nodes: [
            "lit": .init(parentID: nil, local: SceneLocalTransform(origin: layer.position, scale: SIMD2(1, 1), angle: 0)),
            "9": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(40, 90), scale: SIMD2(1, 1), angle: 0)),
        ])
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(30)
        while renderer.imageMaterialPrelitDraws < 2 || renderer.effectPassesEncoded < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            // Every frame drawn, as if something changed: a still scene would otherwise go idle.
            renderer.layerAnalysis?.invalidateAll()
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        XCTAssertGreaterThan(renderer.effectPassesEncoded, 0, "the chain never ran")
        let passes = renderer.effectPassesEncoded, prelit = renderer.imageMaterialPrelitDraws
        for _ in 0..<3 {
            renderer.layerAnalysis?.invalidateAll()
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        XCTAssertEqual(renderer.imageMaterialPrelitDraws - prelit, 3, "the prepass runs every frame")
        XCTAssertEqual(renderer.effectPassesEncoded - passes, 3, "and so does the chain on it, static as it is")
    }
}
