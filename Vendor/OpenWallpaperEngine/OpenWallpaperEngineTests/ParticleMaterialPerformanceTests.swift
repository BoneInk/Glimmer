import XCTest
import Metal
import AppKit
@testable import OpenWallpaperEngine

/// GPU cost of the emulated geometry stage, which reruns the whole geometry body for every
/// output vertex: a rope segment at `TRAILSUBDIVISION` S draws `3·(2 + 2S)` vertices, each
/// evaluating `4 + 2S` emits. Prints the timings; the bound only catches a pathological slowdown.
final class ParticleMaterialPerformanceTests: XCTestCase {
    func testSubdividedRopeTrailCost() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        let simulator = try ParticleGPUSimulator(device: device)
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let target = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            return descriptor
        }()))
        let sceneSize = SIMD2<Float>(1920, 1080)

        // 200 trails of 10 segments: 2 000 segments across the scene, from particles moving 8 units
        // a sample (80 a second, a sample every tenth of a second).
        var trails = ParticleTestSystem()
        trails.origin = sceneSize / 2
        trails.emitterName = "boxrandom"
        trails.spawnExtent = SIMD2(900, 500)
        trails.emissionRate = 0
        trails.instantaneous = 200
        trails.maximum = 200
        trails.lifetime = 10...10
        trails.size = 12...12
        trails.alpha = 1...1
        trails.minimumVelocity = SIMD2(80, 0)
        trails.maximumVelocity = SIMD2(80, 0)
        trails.minimumColor = SIMD4(repeating: 1)
        trails.maximumColor = SIMD4(repeating: 1)
        trails.rotation = 0...0
        trails.angularVelocity = 0...0
        trails.rendererName = "ropetrail"
        trails.trailLength = 1
        trails.trailSegments = 10
        var report: [String] = []
        for subdivision in [0, 4, 8] {
            let rendererJSON = #"{"name":"ropetrail","subdivision":\#(subdivision)}"#
            let built = try builder.build(materialPath: "materials/solid.json",
                                          renderer: try JSONDecoder().decode(WEParticleRenderer.self, from: Data(rendererJSON.utf8)),
                                          flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
            let stages = built.stages.filter { if case .emulated = $0.geometry { return true } else { return false } }
            let plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                            blending: built.blending, stages: stages, trailLengths: built.trailLengths,
                                            spriteSheet: nil)
            XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm))
            trails.ropeSubdivision = subdivision
            trails.material = plan
            let system = ParticleSystemRuntime(texture: texture, configuration: trails.configuration, seed: 1)
            // A second and a half fills every trail's history.
            for _ in 0..<90 {
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(ParticleMaterialRenderTests.step(system, renderer: renderer, simulator: simulator,
                                                               pixelFormat: .bgra8Unorm, sceneSize: sceneSize, commandBuffer: buffer))
                buffer.commit()
                buffer.waitUntilCompleted()
            }
            XCTAssertEqual(simulator.records(system, as: ParticleRopeSegmentInstance.self, queue: queue).records.count, 2_000)

            var gpu: [Double] = []
            for frame in 0..<25 {
                // The step in a command buffer of its own: the timing is the draw's.
                let step = try XCTUnwrap(queue.makeCommandBuffer())
                XCTAssertTrue(ParticleMaterialRenderTests.step(system, renderer: renderer, simulator: simulator,
                                                               pixelFormat: .bgra8Unorm, sceneSize: sceneSize, commandBuffer: step))
                step.commit()
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
                renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
                    sceneSize: SIMD2(1920, 1080), frame: BuiltinFrameContext(), values: ParticleMaterialRenderTests.NoValues(),
                    assetTexture: { _, _ in nil }))
                encoder.endEncoding()
                buffer.commit()
                buffer.waitUntilCompleted()
                XCTAssertNil(buffer.error)
                if frame >= 5 { gpu.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
            }
            let median = gpu.sorted()[gpu.count / 2]
            report.append(String(format: "S=%d: %d vertices/segment, median %.3f ms GPU", subdivision,
                                 3 * (2 + 2 * subdivision), median))
            XCTAssertLessThan(median, 50, "2 000 rope segments at subdivision \(subdivision)")
        }
        print("Rope trail cost (2 000 segments, 1920×1080): " + report.joined(separator: "; "))
    }

    /// The CPU cost of a GPU-simulated system's material draw a frame (`prepareSimulated` and
    /// `draw`): its uniforms and bindings. Prints the median; the bound only catches a pathology.
    func testMaterialDrawEncodeCost() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        let simulator = try ParticleGPUSimulator(device: device)
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let plan = try builder.build(materialPath: "materials/solid.json",
                                     renderer: try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8)),
                                     flags: 0, baseTexture: .image(NSImage()), spriteSheet: nil)
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm))
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)))
        let target = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1920, height: 1080,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            return descriptor
        }()))
        var configuration = ParticleTestSystem().configuration
        configuration.material = plan
        let system = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
        var times: [Double] = []
        for frame in 0..<200 {
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            let start = CACurrentMediaTime()
            let simulated = try XCTUnwrap(renderer.prepareSimulated(system, pixelFormat: .bgra8Unorm))
            let prepared = CACurrentMediaTime() - start
            simulator.encode([.init(system: system, inputs: ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: .zero),
                                    kind: .material(simulated.format, rendererName: "sprite"),
                                    materialVertexCount: simulated.vertexCount, renderVar: simulated.renderVar)],
                             sceneSize: SIMD2(1920, 1080), targetSize: SIMD2(1920, 1080), commandBuffer: buffer)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            let drawStart = CACurrentMediaTime()
            renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
                sceneSize: SIMD2(1920, 1080), frame: BuiltinFrameContext(), values: ParticleMaterialRenderTests.NoValues(),
                assetTexture: { _, _ in nil }))
            let drawn = CACurrentMediaTime() - drawStart
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            if frame >= 20 { times.append((prepared + drawn) * 1000) }
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "Particle material draw encode: median %.4f ms, least %.4f ms a system", median, times.min() ?? 0))
        XCTAssertLessThan(median, 5)
    }
}
