import XCTest
import AppKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// Particles drawn through a perspective camera (docs/models-plan.md §2.12, §4.3 M10): each
/// renderer orientation takes WE's axes from the frame camera (0x1402298b0), and a screen-facing
/// sprite drawn through WE's `genericparticle` faces the camera from any direction.
final class ParticleOrientation3DTests: XCTestCase {
    private static let size = 256
    private static let fov: Float = 60
    private static let eye = SIMD3<Float>(300, 200, 400)

    private static var camera: SceneFrameCamera {
        let forward = simd_normalize(-eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0)),
                                projection: SceneCamera.perspective(fovDegrees: fov, aspect: 1, near: 1, far: 5000),
                                eye: eye, forward: forward, up: simd_cross(right, forward), fieldOfView: fov)
    }

    // MARK: - The axes

    func testEachOrientationTakesItsAxesFromThePerspectiveCamera() throws {
        let camera = Self.camera
        let placement = ParticleMaterialUniforms.Placement(camera: camera)
        func axes(_ json: String) throws -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
            let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(json.utf8))
            return ParticleOrientation(renderer).axes(linear: matrix_identity_float2x2, cameraForward: placement.direction(camera.forward),
                                                      cameraUp: placement.direction(camera.up))
        }
        func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String, line: UInt = #line) {
            XCTAssertLessThan(simd_distance(a, b), 1e-5, "\(message): \(a) vs \(b)", line: line)
        }
        // Screen: forward is the camera's reversed, up the object's y made square to it (the
        // camera's up here, as its up is world y), right completes them.
        let screen = try axes(#"{"name": "sprite"}"#)
        near(screen.forward, -camera.forward, "screen forward")
        near(screen.up, camera.up, "screen up")
        near(screen.right, simd_cross(camera.up, -camera.forward), "screen right")
        // Flag 1: the camera's own up, whatever the object's.
        let cameraUp = try axes(#"{"name": "sprite", "flags": 1}"#)
        near(cameraUp.up, camera.up, "flag 1 up")
        // Upright: up is the axis; the sprite only turns about it to face the camera.
        let upright = try axes(#"{"name": "sprite", "orientation": "upright", "axis": "0 1 0"}"#)
        near(upright.up, SIMD3(0, 1, 0), "upright up")
        XCTAssertEqual(simd_dot(upright.right, SIMD3(0, 1, 0)), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_dot(upright.right, camera.forward), 0, accuracy: 1e-6, "upright right is square to the view")
        // Fixed: the axis basis, whatever the camera.
        let fixed = try axes(#"{"name": "sprite", "orientation": "fixed", "axis": "0 0 1"}"#)
        near(fixed.forward, SIMD3(0, 0, 1), "fixed forward")
        let turned = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name": "sprite", "orientation": "fixed", "axis": "0 0 1"}"#.utf8))
        let elsewhere = ParticleOrientation(turned).axes(linear: matrix_identity_float2x2, cameraForward: SIMD3(1, 0, 0),
                                                         cameraUp: SIMD3(0, 0, 1))
        near(elsewhere.forward, fixed.forward, "fixed ignores the camera")
    }

    func testTheUniformsCarryTheCameraIntoARotatedSystemsSpace() throws {
        _ = try Fixtures.assets()
        // A system turned a quarter about y: the camera's forward in its space is turned back.
        let camera = Self.camera
        let turn = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0)))
        let placement = ParticleMaterialUniforms.Placement(camera: camera, model: turn)
        let plan = try self.plan()
        let system = ParticleSystemRuntime(texture: try whiteTexture(), configuration: Self.configuration(plan))
        let uniforms = ParticleMaterialUniforms(plan: plan, system: system, sceneSize: SIMD2(256, 256), texture0: nil,
                                                placement: placement)
        let back = simd_float3x3(simd_quatf(angle: -.pi / 2, axis: SIMD3(0, 1, 0)))
        XCTAssertLessThan(simd_distance(uniforms.orientationForward, back * -camera.forward), 1e-5)
        let worldForward = simd_float3x3(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))) * uniforms.orientationForward
        XCTAssertLessThan(simd_distance(worldForward, -camera.forward), 1e-5, "drawn through the model it faces the eye")
        // WE's built-ins stay the world's: the shaders take the eye into the system's space through
        // g_ModelMatrixInverse, and light at mul(position, g_ModelMatrix).
        XCTAssertLessThan(simd_distance(uniforms.eyePosition, camera.eye), 1e-3, "g_EyePosition in the world")
        XCTAssertEqual(uniforms.modelMatrix, turn, "g_ModelMatrix is the system's model")
        let local = uniforms.modelMatrix.inverse * SIMD4(uniforms.eyePosition, 1)
        XCTAssertLessThan(simd_distance(SIMD3(local.x, local.y, local.z), back * camera.eye), 1e-3,
                          "the eye the trails face, in the system's space")
    }

    // MARK: - On the GPU

    /// One sprite at the origin, which the camera looks at from above and aside: WE's shader
    /// expands it along the camera's axes, so it projects to a square centred on the target, as
    /// wide as its size at the eye's distance. Drawn in the scene's plane (the 2D axes) it would
    /// be a squashed, sheared quad.
    func testAScreenSpriteFacesTheCameraInAPerspectiveScene() throws {
        _ = try Fixtures.assets()
        let plan = try self.plan()
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: try device()))
        let quad: Float = 100
        let pixels = try render(plan, renderer: renderer, size: quad,
                                placement: ParticleMaterialUniforms.Placement(camera: Self.camera))
        let box = try XCTUnwrap(pixels.coverage, "the sprite is drawn")
        let focal = Float(Self.size) / 2 / tan(Self.fov / 2 * .pi / 180)
        let expected = quad * focal / simd_length(Self.eye)
        XCTAssertEqual(box.width, expected, accuracy: 2, "as wide as its size at the eye's distance")
        XCTAssertEqual(box.height, box.width, accuracy: 1.5, "a square: it faces the camera")
        XCTAssertEqual(box.center.x, Float(Self.size) / 2, accuracy: 1)
        XCTAssertEqual(box.center.y, Float(Self.size) / 2, accuracy: 1)
        XCTAssertGreaterThan(pixels.fill, 0.97, "it fills its box: no shear")

        // Laid in the plane instead, the same sprite seen from here is not a square.
        let flat = try render(plan, renderer: renderer, size: quad, placement: nil, flatThrough: Self.camera)
        let flatBox = try XCTUnwrap(flat.coverage)
        XCTAssertGreaterThan(abs(flatBox.width - flatBox.height) + (1 - flat.fill) * 100, 3, "the control differs")
    }

    // MARK: - Helpers

    private func device() throws -> MTLDevice { try XCTUnwrap(MTLCreateSystemDefaultDevice()) }

    private func whiteTexture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        let texture = try XCTUnwrap(try device().makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                        withBytes: [UInt8](repeating: 255, count: 64), bytesPerRow: 16)
        return texture
    }

    /// `solid.json`'s sprite through the emulated geometry stage.
    private func plan() throws -> ParticleMaterialPlan {
        let roots = [Fixtures.url("Particles"), ShaderVariantTests.weAssets]
        let builder = ParticleMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        let renderer = try JSONDecoder().decode(WEParticleRenderer.self, from: Data(#"{"name":"sprite"}"#.utf8))
        let built = try builder.build(materialPath: "materials/solid.json", renderer: renderer, flags: 0,
                                      baseTexture: .image(NSImage()), spriteSheet: nil)
        return ParticleMaterialPlan(materialPath: built.materialPath, shader: built.shader, format: built.format,
                                    blending: built.blending, stages: built.stages.filter { $0.geometry == .emulated(vertexCount: 6) },
                                    trailLengths: built.trailLengths, spriteSheet: nil)
    }

    private static func configuration(_ plan: ParticleMaterialPlan) -> SceneMetalParticleSystem {
        var system = SceneMetalParticleSystem(
            source: .image(NSImage()), origin: .zero, emissionRate: 0, maximumParticleCount: 10, rendererName: "sprite",
            trailLength: 1, trailSegments: 4, ropeSubdivision: 1, fadeTrailAlpha: false, fadeTrailSize: false, spriteSheet: nil,
            animationMode: "sequence", sequenceMultiplier: 1, opacityMultiplier: 1, refractive: false, blending: plan.blending)
        system.material = plan
        return system
    }

    struct Pixels {
        /// The covered pixels' bounding box, nil when nothing is covered.
        var coverage: (width: Float, height: Float, center: SIMD2<Float>)?
        /// Covered pixels over the box's area.
        var fill: Float
    }

    /// Draws one sprite of quad width `size` at the origin, through `placement`; with
    /// `flatThrough` it is laid in the xy plane instead and drawn through that camera.
    private func render(_ plan: ParticleMaterialPlan, renderer: ParticleMaterialRenderer, size: Float,
                        placement: ParticleMaterialUniforms.Placement?, flatThrough: SceneFrameCamera? = nil) throws -> Pixels {
        let device = try device()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .rgba8Unorm), "pipelines still compiling")
        var configuration = Self.configuration(plan)
        var drawn = placement
        if let flatThrough {
            // The control: the sprite laid in the system's xy plane (a `fixed` renderer on z),
            // drawn through the same camera.
            drawn = ParticleMaterialUniforms.Placement(camera: flatThrough)
            let fixed = try JSONDecoder().decode(WEParticleRenderer.self,
                                                 from: Data(#"{"name": "sprite", "orientation": "fixed", "axis": "0 0 1"}"#.utf8))
            configuration.orientation = ParticleOrientation(fixed)
        }
        configuration = ParticleMaterialRenderTests.placing([ParticleMaterialRenderTests.Placed(position: .zero, size: size)],
                                                            in: configuration)
        let system = ParticleSystemRuntime(texture: try whiteTexture(), configuration: configuration)
        let simulator = try ParticleGPUSimulator(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: Self.size, height: Self.size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
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
            sceneSize: SIMD2(Float(Self.size), Float(Self.size)), frame: BuiltinFrameContext(), values: NoValues(),
            assetTexture: { _, _ in nil }, sceneSnapshot: nil, placement: drawn))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
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
