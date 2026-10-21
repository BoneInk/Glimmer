import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A lit particle in a perspective scene is lit where its model matrix puts it: WE sets a particle
/// draw's `g_ModelMatrix` to the system's model and `g_EyePosition` to the frame camera's eye in
/// the world (`ParticleMaterialUniforms.modelMatrix`, `wallpaper64.exe` 0x1400d83b0), and
/// `genericparticle` lights `mul(position, g_ModelMatrix)` against the lights in the world.
final class ParticleLightingTests: XCTestCase {
    private static let size = 64
    private static let litMaterial = Data(#"""
    {"passes": [{"shader": "genericparticle", "blending": "translucent", "cullmode": "nocull",
                 "depthtest": "disabled", "depthwrite": "disabled", "combos": {"LIGHTING": 1},
                 "textures": ["solid"]}]}
    """#.utf8)

    private static var camera: SceneFrameCamera {
        let eye = SIMD3<Float>(0, 0, 1000)
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0)),
                                projection: SceneCamera.perspective(fovDegrees: 50, aspect: 1, near: 1, far: 5000),
                                eye: eye, forward: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0), fieldOfView: 50)
    }

    /// Moving the system and its light together leaves the particle's light as it was; with the
    /// light left behind (out of its radius) it is lit by the ambient alone.
    func testALitParticleIsLitWhereItsModelMatrixPutsIt() throws {
        _ = try Fixtures.assets()
        let plan = try litPlan()
        let back = Self.translation(SIMD3(0, 0, -500))
        let atOrigin = try centre(plan, model: matrix_identity_float4x4, light: SIMD3(0, 0, 60))
        let movedTogether = try centre(plan, model: back, light: SIMD3(0, 0, -440))
        let lightLeftBehind = try centre(plan, model: back, light: SIMD3(0, 0, 60))
        for channel in 0..<3 {
            XCTAssertEqual(Float(movedTogether[channel]), Float(atOrigin[channel]), accuracy: 2,
                           "channel \(channel): lit the same where the model puts it")
        }
        let lit = Float(atOrigin[0]) - Float(lightLeftBehind[0])
        XCTAssertGreaterThan(lit, 40, "the light out of reach leaves only the ambient: \(atOrigin) against \(lightLeftBehind)")
    }

    private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    private func litPlan() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        var builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in
                path == "materials/lit.json" ? Self.litMaterial
                    : roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            },
            loadTexture: { _, _ in nil })
        builder.sceneEngineCombos = SceneEngineCombos(sceneOrtho: false, lightBudget: WELightConfig(point: 1))
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        let built = try builder.build(materialPath: "materials/lit.json", renderer: renderer, flags: 0,
                                      baseTexture: .image(NSImage()), spriteSheet: nil)
        let stages = built.stages.filter { $0.geometry == .emulated(vertexCount: 6) }
        XCTAssertEqual(stages.first?.variant.combos["LIGHTING"], 1)
        return ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                    blending: built.blending, stages: stages, trailLengths: built.trailLengths, spriteSheet: nil)
    }

    /// The centre pixel of one white particle at the system's origin, drawn through `model` with a
    /// point light at `light` (world), RGBA bytes.
    private func centre(_ plan: ParticleMaterialPlan, model: simd_float4x4, light: SIMD3<Float>) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm), "pipelines still compiling")
        XCTAssertNil(renderer.pipelineFailure(try XCTUnwrap(plan.stages.first), plan: plan, pixelFormat: .rgba8Unorm))
        let white = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4),
                      bytesPerRow: 4)
        let system = ParticleSystemRuntime(texture: white, configuration: ParticleMaterialRenderTests.configuration(
            plan: plan, placing: [ParticleMaterialRenderTests.Placed(position: .zero, size: 200)]))
        let simulator = try ParticleGPUSimulator(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.size,
                                                                  height: Self.size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var frame = BuiltinFrameContext()
        frame.screenSize = SIMD2(Float(Self.size), Float(Self.size))
        var point = LightingReference.Light(kind: .point, position: light)
        point.radius = 200
        point.intensity = 2
        frame.lighting = SceneFrameLighting(ambient: SIMD3(repeating: 0.1), skylight: SIMD3(repeating: 0.1),
                                            arrays: ImageMaterialLightingTests.packed([point]))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(ParticleMaterialRenderTests.step(system, renderer: renderer, simulator: simulator, pixelFormat: .rgba8Unorm,
                                                       sceneSize: SIMD2(Float(Self.size), Float(Self.size)), commandBuffer: buffer))
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
            sceneSize: SIMD2(Float(Self.size), Float(Self.size)), frame: frame, values: EffectGraphTests.FixedValues(),
            assetTexture: { _, _ in white }, sceneSnapshot: nil,
            placement: ParticleMaterialUniforms.Placement(camera: Self.camera, model: model)))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        var bytes = [UInt8](repeating: 0, count: 4)
        let middle = Self.size / 2
        target.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(middle, middle, 1, 1), mipmapLevel: 0)
        XCTAssertGreaterThan(Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2]), 0, "the particle covers the centre")
        return bytes
    }
}

