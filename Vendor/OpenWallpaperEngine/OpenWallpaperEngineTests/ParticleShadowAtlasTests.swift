import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A lit particle material under a shadowed light reads `_rt_shadowAtlas` (`genericparticle`'s
/// `g_Texture4`, `LIGHTS_SHADOW_MAPPING`) as models and images do: the plan names the frame's
/// atlas, and the draw binds the atlas it is handed (the maps `SceneShadowPass` drew, or the
/// cleared stand-in) through WE's comparison sampler, and draws nothing without one.
final class ParticleShadowAtlasTests: XCTestCase {
    private static let litMaterial = Data(#"""
    {"passes": [{"shader": "genericparticle", "blending": "translucent", "cullmode": "nocull",
                 "depthtest": "disabled", "depthwrite": "disabled", "combos": {"LIGHTING": 1},
                 "textures": ["solid"]}]}
    """#.utf8)

    func testALitParticleMaterialReadsTheFramesShadowAtlas() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        var builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in
                path == "materials/lit.json" ? Self.litMaterial
                    : roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            },
            loadTexture: { _, _ in nil })
        builder.sceneEngineCombos = SceneEngineCombos(sceneOrtho: true, lightBudget: WELightConfig(spot: 1, spotShadow: 1),
                                                      shadowQuality: 4)
        let built = try builder.build(materialPath: "materials/lit.json",
                                      renderer: try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8)),
                                      flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        let stages = built.stages.filter { $0.geometry == .emulated(vertexCount: 6) }
        let stage = try XCTUnwrap(stages.first)
        XCTAssertEqual(stage.variant.combos["LIGHTS_SHADOW_MAPPING"], 1)
        guard case .fbo(SceneShadowAtlas.name)? = stage.textures[4] else {
            return XCTFail("g_Texture4 is the frame's shadow atlas: \(String(describing: stage.textures[4]))")
        }
        let plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending, stages: [stage], trailLengths: built.trailLengths,
                                        spriteSheet: nil)

        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm), "pipelines still compiling")
        XCTAssertNil(renderer.pipelineFailure(stage, plan: plan, pixelFormat: .rgba8Unorm))
        let white = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneShadowAtlas.pixelFormat, width: 2, height: 2,
                                                                       mipmapped: false)
        atlasDescriptor.usage = [.renderTarget, .shaderRead]
        atlasDescriptor.storageMode = .private
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: atlasDescriptor))
        let target = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget]
            return descriptor
        }()))
        let simulator = try ParticleGPUSimulator(device: device)
        var draws: [Int] = []
        for bound in [nil, atlas] as [MTLTexture?] {
            let system = ParticleSystemRuntime(texture: white, configuration: ParticleMaterialRenderTests.configuration(
                plan: plan, placing: [ParticleMaterialRenderTests.Placed(position: SIMD2(32, 32), size: 20)]))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .dontCare
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(ParticleMaterialRenderTests.step(system, renderer: renderer, simulator: simulator,
                                                           pixelFormat: .rgba8Unorm, sceneSize: SIMD2(64, 64), commandBuffer: buffer))
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            let before = renderer.drawsEncoded
            renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
                sceneSize: SIMD2(64, 64), frame: BuiltinFrameContext(), values: EffectGraphTests.FixedValues(),
                assetTexture: { _, _ in white }, sceneSnapshot: nil, shadowAtlas: bound))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            draws.append(renderer.drawsEncoded - before)
        }
        XCTAssertEqual(draws, [0, 1], "without the atlas nothing draws; with it the system draws")
    }
}
