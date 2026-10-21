import XCTest
import AppKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// A particle material drawn through a 3D camera (docs/models-plan.md §2.4, §2.12): its sprites
/// are WE's vertices, so they take WE's front-face rule (D3D's `FrontCounterClockwise = FALSE`,
/// counter-clockwise in the translated clip space, as models) and a material that culls back faces
/// (`genericparticle`'s default) still shows them; and its camera built-ins follow a camera that
/// moves between frames (`UniformProgram`'s camera signature).
final class ParticleCameraTests: XCTestCase {
    private static let size = 256
    private static let fov: Float = 60
    private static let eye = SIMD3<Float>(300, 200, 400)

    private static func camera(eye: SIMD3<Float> = eye, center: SIMD3<Float> = .zero) -> SceneFrameCamera {
        let forward = simd_normalize(center - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: center, up: SIMD3(0, 1, 0)),
                                projection: SceneCamera.perspective(fovDegrees: fov, aspect: 1, near: 1, far: 5000),
                                eye: eye, forward: forward, up: simd_cross(right, forward), fieldOfView: fov)
    }

    /// Engine defaults but blending: test on, back faces culled (translucent, so no write).
    private static let culling = SceneRasterState(depthTest: true, depthWrite: false, cullsBackFaces: true)

    /// Steps the systems on the GPU, which writes the records the draws read.
    private var simulator: ParticleGPUSimulator!

    override func setUpWithError() throws {
        simulator = try ParticleGPUSimulator(device: try device())
    }

    func testACullingMaterialShowsItsParticlesThroughAPerspectiveCamera() throws {
        _ = try Fixtures.assets()
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: try device()))
        let system = try system(position: .zero)
        let camera = Self.camera()
        let drawn = try render(system, renderer: renderer, placement: .init(camera: camera), depth: .scene)
        let box = try XCTUnwrap(drawn.coverage, "a culling material's sprite faces the camera: it is drawn")
        XCTAssertEqual(box.center.x, Float(Self.size) / 2, accuracy: 1)
        XCTAssertEqual(box.center.y, Float(Self.size) / 2, accuracy: 1)
        XCTAssertGreaterThan(drawn.fill, 0.97)

        // The planar reflection's pass: the mirrored view flips the winding, and its states the front.
        let mirrored = try render(system, renderer: renderer,
                                  placement: .init(camera: ScenePlanarReflection.mirrored(camera)), depth: .mirrored)
        XCTAssertNotNil(mirrored.coverage, "drawn in the mirrored pass too")
    }

    func testTheParticlesFollowACameraThatMoves() throws {
        _ = try Fixtures.assets()
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: try device()))
        let system = try system(position: .zero)
        let first = Self.camera()
        let shift = SIMD3<Float>(60, -40, 0)
        let second = Self.camera(eye: Self.eye + shift, center: shift)
        let before = try XCTUnwrap(try render(system, renderer: renderer, placement: .init(camera: first), depth: .scene).coverage)
        XCTAssertEqual(before.center.x, Float(Self.size) / 2, accuracy: 1)
        // The same system and program the next frame, the camera moved.
        let after = try XCTUnwrap(try render(system, renderer: renderer, placement: .init(camera: second), depth: .scene).coverage)
        let expected = Self.pixel(of: .zero, through: second)
        XCTAssertGreaterThan(simd_distance(expected, before.center), 20, "the camera moved the origin on screen")
        XCTAssertEqual(after.center.x, expected.x, accuracy: 1.5, "g_ModelViewProjectionMatrix follows the camera")
        XCTAssertEqual(after.center.y, expected.y, accuracy: 1.5)
        // And back: the first camera's matrix is written again.
        let back = try XCTUnwrap(try render(system, renderer: renderer, placement: .init(camera: first), depth: .scene).coverage)
        XCTAssertEqual(back.center.x, before.center.x, accuracy: 0.5)
        XCTAssertEqual(back.center.y, before.center.y, accuracy: 0.5)
    }

    /// The 2D path: no camera; without depth nothing culls, with an orthographic scene's depth
    /// (a scene with models) the same rule as in 3D keeps the sprite. Both draw it in one place.
    func testOrthographicParticlesAreUnchanged() throws {
        _ = try Fixtures.assets()
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: try device()))
        let system = try system(position: SIMD2(96, 64))
        let flat = try XCTUnwrap(try render(system, renderer: renderer, placement: nil, depth: .none).coverage)
        // Scene units, y up: 64 above the bottom row.
        XCTAssertEqual(flat.center.x, 96, accuracy: 0.5)
        XCTAssertEqual(flat.center.y, Float(Self.size) - 64, accuracy: 0.5)
        XCTAssertEqual(flat.width, 40, accuracy: 1)
        let withDepth = try XCTUnwrap(try render(system, renderer: renderer, placement: nil, depth: .scene).coverage)
        XCTAssertEqual(withDepth.center.x, flat.center.x, accuracy: 0.5)
        XCTAssertEqual(withDepth.center.y, flat.center.y, accuracy: 0.5)
        XCTAssertEqual(withDepth.width, flat.width, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func device() throws -> MTLDevice { try XCTUnwrap(MTLCreateSystemDefaultDevice()) }

    /// Where `point` lands in the target's pixels (rows top-down) through `camera`.
    private static func pixel(of point: SIMD3<Float>, through camera: SceneFrameCamera) -> SIMD2<Float> {
        let clip: SIMD4<Float> = camera.viewProjection * SIMD4(point, 1)
        let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
        let side = Float(size)
        return SIMD2<Float>((ndc.x + 1) / 2 * side, (1 - ndc.y) / 2 * side)
    }

    private func whiteTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(try device().makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                        withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
        return texture
    }

    /// `solid.json`'s sprite through the emulated geometry stage, culling back faces.
    private func plan() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        let built = try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                      baseTexture: .image(NSImage()), spriteSheet: nil)
        var plan = ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                        blending: built.blending,
                                        stages: built.stages.filter { $0.geometry == .emulated(vertexCount: 6) },
                                        trailLengths: built.trailLengths, spriteSheet: nil)
        plan.raster = Self.culling
        return plan
    }

    private func system(position: SIMD2<Float>) throws -> ParticleSystemRuntime {
        let plan = try plan()
        var configuration = SceneMetalParticleSystem(
            source: .image(NSImage()), origin: .zero, emissionRate: 0, maximumParticleCount: 10, rendererName: "sprite",
            trailLength: 1, trailSegments: 4, ropeSubdivision: 1, fadeTrailAlpha: false, fadeTrailSize: false, spriteSheet: nil,
            animationMode: "sequence", sequenceMultiplier: 1, opacityMultiplier: 1, refractive: false, blending: plan.blending)
        configuration.material = plan
        configuration = ParticleMaterialRenderTests.placing([ParticleMaterialRenderTests.Placed(position: position, size: 40)],
                                                            in: configuration)
        return ParticleSystemRuntime(texture: try whiteTexture(), configuration: configuration)
    }

    enum Depth { case none, scene, mirrored }

    struct Pixels {
        var coverage: (width: Float, height: Float, center: SIMD2<Float>)?
        var fill: Float
    }

    /// One frame of `system` through `placement`, in a pass with the scene's depth states (or the
    /// mirrored ones, or none). Frames are drawn until the pipeline for the pass has compiled.
    private func render(_ system: ParticleSystemRuntime, renderer: ParticleMaterialRenderer,
                        placement: ParticleMaterialUniforms.Placement?, depth: Depth) throws -> Pixels {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let states: SceneDepthStates? = switch depth {
        case .none: nil
        case .scene: try XCTUnwrap(SceneDepthStates(device: device))
        case .mirrored: try XCTUnwrap(SceneDepthStates(device: device, mirrored: true))
        }
        let depthFormat: MTLPixelFormat = states == nil ? .invalid : SceneDepthStates.format
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.size, height: Self.size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var depthTexture: MTLTexture?
        if states != nil {
            let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SceneDepthStates.format, width: Self.size,
                                                                           height: Self.size, mipmapped: false)
            depthDescriptor.usage = .renderTarget
            depthDescriptor.storageMode = .private
            depthTexture = device.makeTexture(descriptor: depthDescriptor)
        }
        let start = renderer.drawsEncoded
        let deadline = Date().addingTimeInterval(60)
        while renderer.drawsEncoded == start {
            XCTAssertLessThan(Date(), deadline, "the pipeline never compiled")
            if Date() > deadline { break }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            if let depthTexture {
                pass.depthAttachment.texture = depthTexture
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = SceneDepthStates.clearDepth
                pass.depthAttachment.storeAction = .dontCare
            }
            let buffer = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(ParticleMaterialRenderTests.step(system, renderer: renderer, simulator: simulator, pixelFormat: .rgba8Unorm,
                                                           depthFormat: depthFormat, sceneSize: SIMD2(Float(Self.size), Float(Self.size)),
                                                           commandBuffer: buffer))
            let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
            renderer.draw(system, encoder: encoder, commandBuffer: buffer, context: .init(
                sceneSize: SIMD2(Float(Self.size), Float(Self.size)), frame: BuiltinFrameContext(), values: NoValues(),
                assetTexture: { _, _ in nil }, sceneSnapshot: nil, depth: states, placement: placement))
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            if renderer.drawsEncoded == start { Thread.sleep(forTimeInterval: 0.02) }
        }
        var bytes = [UInt8](repeating: 0, count: Self.size * Self.size * 4)
        target.getBytes(&bytes, bytesPerRow: Self.size * 4, from: MTLRegionMake2D(0, 0, Self.size, Self.size), mipmapLevel: 0)
        var low = SIMD2<Int>(Int.max, Int.max), high = SIMD2<Int>(Int.min, Int.min), covered = 0
        for y in 0..<Self.size {
            for x in 0..<Self.size where bytes[(y * Self.size + x) * 4] > 127 {
                low = simd_min(low, SIMD2(x, y))
                high = simd_max(high, SIMD2(x, y))
                covered += 1
            }
        }
        guard covered > 0 else { return Pixels(coverage: nil, fill: 0) }
        let width = Float(high.x - low.x + 1), height = Float(high.y - low.y + 1)
        let center = SIMD2<Float>(Float(low.x + high.x + 1), Float(low.y + high.y + 1)) / 2
        return Pixels(coverage: (width, height, center), fill: Float(covered) / (width * height))
    }

    struct NoValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
        func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
    }
}
