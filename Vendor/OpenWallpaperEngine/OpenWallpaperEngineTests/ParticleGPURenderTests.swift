import XCTest
import Metal
import AppKit
import simd
@testable import OpenWallpaperEngine

/// Particle systems stepped on the GPU and drawn through their WE material from the records and
/// indirect arguments the step wrote.
final class ParticleGPURenderTests: XCTestCase {
    private static let size = 256
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var materials: ParticleMaterialRenderer!
    private var simulator: ParticleGPUSimulator!
    private var builder: ParticleMaterialPlanBuilder!
    private var white: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        materials = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        simulator = try ParticleGPUSimulator(device: device)
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        white = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        white.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                      withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
    }

    func testSpritesDrawFromTheGPUsRecords() throws {
        _ = try Fixtures.assets()
        try assertDraws(renderer: "sprite")
    }

    func testRopeDrawsFromTheGPUsRecords() throws {
        _ = try Fixtures.assets()
        try assertDraws(renderer: "rope")
    }

    func testRopeTrailsDrawFromTheGPUsRecords() throws {
        _ = try Fixtures.assets()
        try assertDraws(renderer: "ropetrail")
    }

    func testRopeRenderVarHoldsTheGPUsPointCount() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan(renderer: "rope")
        let gpu = ParticleSystemRuntime(texture: white, configuration: system(renderer: "rope", plan: plan).configuration, seed: 3)
        var renderVar: (buffer: MTLBuffer, offset: Int)?
        for _ in 0..<40 {
            let simulated = try XCTUnwrap(materials.prepareSimulated(gpu, pixelFormat: .rgba8Unorm))
            renderVar = simulated.renderVar
            try step(gpu, simulated: simulated)
        }
        let target = try XCTUnwrap(renderVar, "the rope shader reads g_RenderVar0")
        let values = target.buffer.contents().advanced(by: target.offset).bindMemory(to: Float.self, capacity: 4)
        let count = Float(try XCTUnwrap(gpu.gpu).completedCount)
        XCTAssertGreaterThan(count, 10)
        XCTAssertEqual([values[0], values[1], values[2], values[3]], [count, 0, 1, count])
    }

    /// I4: 10 000 GPU-simulated sprites draw from buffers made once, not every frame.
    func testTenThousandSpritesReuseTheirBuffers() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan(renderer: "sprite")
        var system = system(renderer: "sprite", plan: plan)
        system.maximum = 10_000
        system.emissionRate = 1_000_000
        system.lifetime = 100...100
        let runtime = ParticleSystemRuntime(texture: white, configuration: system.configuration, seed: 5)
        var records = Set<ObjectIdentifier>(), particles = Set<ObjectIdentifier>()
        for frame in 0..<100 {
            let simulated = try XCTUnwrap(materials.prepareSimulated(runtime, pixelFormat: .rgba8Unorm))
            try step(runtime, simulated: simulated)
            guard frame > 0, let gpu = runtime.gpu, let recordBuffer = gpu.records, let state = gpu.particles else { continue }
            records.insert(ObjectIdentifier(recordBuffer))
            particles.insert(ObjectIdentifier(state))
            // A step holds last step's particles until the ones that died aging are compacted
            // away, and its spawns: at most twice the maximum.
            XCTAssertLessThanOrEqual(recordBuffer.length, 20_000 * MemoryLayout<ParticleSpriteInstance>.stride + 16)
        }
        XCTAssertEqual(runtime.gpu?.completedCount, 10_000)
        XCTAssertEqual(records.count, 1, "one record buffer for 99 frames")
        XCTAssertEqual(particles.count, 1, "one particle buffer for 99 frames")
    }

    // MARK: - Helpers

    private func system(renderer: String, plan: ParticleMaterialPlan) -> ParticleTestSystem {
        var system = ParticleTestSystem()
        system.origin = SIMD2(128, 128)
        system.spawnExtent = SIMD2(60, 40)
        system.emissionRate = 120
        system.minimumVelocity = SIMD2(-30, -30)
        system.maximumVelocity = SIMD2(30, 30)
        system.rendererName = renderer
        system.trailSegments = 5
        system.trailLength = 0.5
        system.material = plan
        return system
    }

    private func plan(renderer: String) throws -> ParticleMaterialPlan {
        let decoded = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"\#(renderer)"}"#.utf8))
        let built = try builder.build(materialPath: "materials/solid.json", renderer: decoded, flags: 0,
                                      baseTexture: .image(NSImage()), spriteSheet: nil)
        // WE's rope default subdivides each segment (`TRAILSUBDIVISION` 4), which grows the stage's
        // vertex count.
        let stages = built.stages.filter { if case .emulated = $0.geometry { return true } else { return false } }
        let plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending, stages: stages, trailLengths: built.trailLengths,
                                        spriteSheet: nil)
        XCTAssertTrue(materials.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm))
        return plan
    }

    /// One GPU step, optionally drawn into `target`.
    private func step(_ system: ParticleSystemRuntime, simulated: ParticleMaterialRenderer.Simulated,
                      drawingInto target: MTLTexture? = nil) throws {
        let inputs = ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: .zero)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let kind = ParticleGPUDrawKind.material(simulated.format, rendererName: system.configuration.rendererName)
        simulator.encode([.init(system: system, inputs: inputs, kind: kind, materialVertexCount: simulated.vertexCount,
                                renderVar: simulated.renderVar)],
                         sceneSize: SIMD2(Float(Self.size), Float(Self.size)),
                         targetSize: SIMD2(Float(Self.size), Float(Self.size)), commandBuffer: commandBuffer)
        if let target { try draw(system, into: target, commandBuffer: commandBuffer) }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
    }

    private func draw(_ system: ParticleSystemRuntime, into target: MTLTexture, commandBuffer: MTLCommandBuffer) throws {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        materials.draw(system, encoder: encoder, commandBuffer: commandBuffer, context: .init(
            sceneSize: SIMD2(Float(Self.size), Float(Self.size)), frame: BuiltinFrameContext(),
            values: ParticleMaterialRenderTests.NoValues(), assetTexture: { _, _ in nil }))
        encoder.endEncoding()
    }

    private func makeTarget() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.size,
                                                                  height: Self.size, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func pixels(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
        texture.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        return bytes
    }

    private func assertDraws(renderer: String, frames: Int = 60) throws {
        let plan = try self.plan(renderer: renderer)
        let configuration = system(renderer: renderer, plan: plan).configuration
        let gpu = ParticleSystemRuntime(texture: white, configuration: configuration, seed: 9)
        let target = try makeTarget()
        for frame in 0..<frames {
            let simulated = try XCTUnwrap(materials.prepareSimulated(gpu, pixelFormat: .rgba8Unorm))
            try step(gpu, simulated: simulated, drawingInto: frame == frames - 1 ? target : nil)
        }
        let actual = pixels(target)
        let lit = stride(from: 0, to: actual.count, by: 4).filter { actual[$0] > 32 }.count
        XCTAssertGreaterThan(lit, 500, "\(renderer): the GPU frame draws something")
    }
}
