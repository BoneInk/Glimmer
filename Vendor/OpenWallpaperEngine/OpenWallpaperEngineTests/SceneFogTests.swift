import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

private struct FogPropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    func userProperty(_ name: String) -> String? { properties[name] }
}

/// WE's distance and height fog (`SceneFogSettings`, docs/lighting-plan.md §2.9): `general`'s
/// fields with WE's defaults, the `FOG_DIST`/`FOG_HEIGHT` engine combos on materials whose `FOG` is
/// on, the `g_Fog*` uniforms, and the volumetric ray march, whose samples the fog squares.
final class SceneFogTests: XCTestCase {
    private func general(_ json: String, properties: [String: String] = [:]) throws -> WESceneGeneral {
        try BoundDocument.decode(WESceneGeneral.self, from: Data(json.utf8), properties: properties)
    }

    // MARK: - general

    /// 3378346807's fog: distance on, its colour bound to the background colour property.
    func testTheFogFieldsAreDecodedWithTheirBindings() throws {
        let json = #"""
            {"fogdistance": true,
             "fogdistancecolor": {"user": "backgroundcolor", "value": "0.25490 0.31373 0.32549"},
             "fogdistanceend": 48.0, "fogdistanceenddensity": 1.0,
             "fogdistancestart": 1.0, "fogdistancestartdensity": 0.0}
            """#
        let general = try general(json)
        let fog = SceneLightingSettings(general, in: FogPropertyContext()).fog
        XCTAssertTrue(fog.distance)
        XCTAssertFalse(fog.height)
        XCTAssertEqual(fog.distanceColor.x, 0.2549, accuracy: 1e-4)
        XCTAssertEqual(fog.distanceParams, SIMD4<Float>(1, 47, 0, 1))
        let bound = SceneFogSettings(try self.general(json, properties: ["backgroundcolor": "1 0.5 0"]), in: FogPropertyContext())
        XCTAssertEqual(bound.distanceColor, SIMD3<Float>(1, 0.5, 0))
    }

    /// Without the fields: WE's constructor values (0x140187063…0x1401870a1).
    func testTheDefaultsAreWEs() throws {
        let fog = SceneFogSettings(try general("{}"), in: FogPropertyContext())
        XCTAssertFalse(fog.distance)
        XCTAssertFalse(fog.height)
        XCTAssertEqual(fog.distanceParams, SIMD4<Float>(1, 4, 0, 1))
        XCTAssertEqual(fog.heightParams, SIMD4<Float>(1, -4, 0, 1))
        XCTAssertEqual(fog.distanceColor, .zero)
    }

    // MARK: - Combos and uniforms

    /// `FOG_DIST`/`FOG_HEIGHT` go only to a material whose `FOG` is on, for the fog that is on.
    func testTheEngineGivesFogCombosToFogMaterials() {
        let both = SceneEngineCombos(fogDistance: true, fogHeight: true)
        XCTAssertEqual(both.combos(for: ["FOG": 1])["FOG_DIST"], 1)
        XCTAssertEqual(both.combos(for: ["FOG": 1])["FOG_HEIGHT"], 1)
        XCTAssertNil(both.combos(for: ["FOG": 0])["FOG_DIST"])
        XCTAssertNil(both.combos(for: [:])["FOG_DIST"], "a material without FOG")
        let distance = SceneEngineCombos(fogDistance: true)
        XCTAssertEqual(distance.combos(for: ["FOG": 1])["FOG_DIST"], 1)
        XCTAssertNil(distance.combos(for: ["FOG": 1])["FOG_HEIGHT"])
        XCTAssertNil(SceneEngineCombos().combos(for: ["FOG": 1])["FOG_DIST"], "no fog in the scene")
    }

    func testTheFogUniformsAreTheScenes() {
        var frame = BuiltinFrameContext()
        frame.lighting.fog.distanceColor = SIMD3(0.1, 0.2, 0.3)
        frame.lighting.fog.distanceStart = 2
        frame.lighting.fog.distanceEnd = 10
        frame.lighting.fog.distanceEndDensity = 0.5
        let pass = BuiltinPassContext(targetSize: SIMD2(1, 1))
        XCTAssertTrue(BuiltinUniforms.isBuiltin("g_FogDistanceParams"))
        XCTAssertEqual(BuiltinUniforms.value(named: "g_FogDistanceParams", frame: frame, pass: pass), [2, 8, 0, 0.5])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_FogDistanceColor", frame: frame, pass: pass), [0.1, 0.2, 0.3])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_FogHeightParams", frame: frame, pass: pass), [1, -4, 0, 1])
    }

    // MARK: - Volumetrics

    /// With the scene's distance fog, the front and fullscreen passes compile with `FOG_DIST`
    /// (`volumetricsfront.frag` defaults `FOG` to 1) and the back pass, which has no fog, without.
    /// The march then squares each sample (`shadowSample *= ApplyFogAlpha(shadowSample, …)`),
    /// which the stage does as the CPU model does.
    func testTheVolumetricRayMarchSquaresItsSamplesUnderFog() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-fog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let root = ShaderVariantTests.weAssets
        var builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        builder.sceneEngineCombos = SceneEngineCombos(fogDistance: true)
        let light = SceneVolumetricsTests.point()
        let settings = SceneVolumetricsTests.settings(.high)
        let plan = try XCTUnwrap(SceneVolumetricsPlan.build(lights: [SceneVolumetricsTests.object("p", light)],
                                                            settings: settings, builder: builder))
        XCTAssertEqual(plan.lights[0].front.variant.combos["FOG_DIST"], 1)
        XCTAssertEqual(plan.lights[0].fullscreen.variant.combos["FOG_DIST"], 1)
        XCTAssertNil(plan.lights[0].back.variant.combos["FOG_DIST"])

        // The orthographic eye is 2000 in front of the scene: fog from 1900 to 2100 reaches the
        // volume partly.
        var fog = SceneFogSettings()
        fog.distance = true
        fog.distanceStart = 1900
        fog.distanceEnd = 2100
        let camera = SceneVolumetricsTests.camera
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(128, 72, 0, 1)
        let stage = SceneVolumetrics(device: device)
        stage.setPlan(plan)
        XCTAssertTrue(try XCTUnwrap(stage.pipelines).waitUntilReady(plan, sceneFormat: .rgba8Unorm))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 144, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let scene = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        var frame = BuiltinFrameContext()
        frame.camera = camera
        frame.lighting.fog = fog
        frame.lighting.objects = [SceneFrameLightObject(id: "p", world: world, visible: true)]
        stage.encode(SceneFrameStageContext(scene: scene, commandBuffer: commands, sceneSize: SIMD2(256, 144),
                                            frame: frame, settings: settings))
        commands.commit()
        commands.waitUntilCompleted()
        let buffer = try XCTUnwrap(stage.lastRecord).lightBuffer
        let drawn = try TextureUploadTests.read(buffer, device: device)

        let volume = SceneVolumetricLight(light: light, world: world, camera: camera)
        let viewProjection = SceneVolumetrics.viewProjection(camera)
        let mesh = SceneVolumeMesh.make(volume.shape)
        let transform = viewProjection * volume.volume
        // The sphere's centre texel, well inside its silhouette.
        let column = buffer.width / 2, row = buffer.height / 2
        let x = 2 * (Float(column) + 0.5) / Float(buffer.width) - 1
        let y = 2 * (Float(row) + 0.5) / Float(buffer.height) - 1
        let depths = try XCTUnwrap(VolumetricsReference.depths(of: mesh, transform: transform, x: x, y: y))
        let expected = VolumetricsReference.march(volume, point: true, viewProjection: viewProjection, x: x, y: y,
                                                  near: depths.max, far: depths.min, quality: 3, fog: fog, eye: camera.eye)
        let unfogged = VolumetricsReference.march(volume, point: true, viewProjection: viewProjection, x: x, y: y,
                                                  near: depths.max, far: depths.min, quality: 3)
        XCTAssertLessThan(expected.z, unfogged.z * 0.9, "the fog dims the march")
        let i = (row * buffer.width + column) * 4
        for channel in 0..<3 {
            let want = Float(simd_clamp(expected[channel], 0, 1) * 255)
            XCTAssertEqual(Float(drawn[i + channel]), want, accuracy: 2, "channel \(channel)")
        }
    }
}
