import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// WE's volumetrics (`SceneVolumetrics`, docs/lighting-plan.md §2.8): the plan of WE's util
/// materials, the light values, the meshes, and the passes against the CPU model
/// (`VolumetricsReference`).
final class SceneVolumetricsTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var cache: URL!
    private var builder: SceneEffectPlanBuilder!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        cache = FileManager.default.temporaryDirectory.appending(path: "owe-volumetrics-\(UUID().uuidString)")
        let root = ShaderVariantTests.weAssets
        builder = SceneEffectPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache),
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { name, _ in
                let url = root.appending(path: "materials/\(name).tex")
                guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
                let parser = TEXParser(data: data)
                if let texture = parser.extractCompressedTexture() { return .dxt(texture) }
                return parser.extractImage().map { .image($0) }
            })
    }

    override func tearDownWithError() throws {
        if let cache { try? FileManager.default.removeItem(at: cache) }
    }

    // MARK: - Lights

    static func spot(cookie: Bool = false, shadow: Bool = false) -> SceneLight {
        var light = SceneLight(kind: .spot)
        light.color = SIMD3(1, 0.8, 0.6)
        light.intensity = 3
        light.radius = 120
        light.exponent = 1
        light.innerCone = 20
        light.outerCone = 30
        light.density = 2
        light.volumetricsExponent = 1.5
        light.castVolumetrics = true
        light.useCookie = cookie
        light.castShadow = shadow
        if cookie { light.cookie = SceneLightDefaults.cookie }
        return light
    }

    static func point() -> SceneLight {
        var light = SceneLight(kind: .point)
        light.color = SIMD3(0.5, 0.7, 1)
        light.intensity = 4
        light.radius = 50
        light.density = 3
        light.volumetricsExponent = 2
        light.castVolumetrics = true
        return light
    }

    static func object(_ id: String, _ light: SceneLight) -> SceneLightObject {
        SceneLightObject(id: id, authored: WESceneLight(kind: light.kind), light: light)
    }

    static func settings(_ volumetrics: GSLightingQuality, shadows: GSLightingQuality = .medium) -> SceneRenderSettings {
        var settings = SceneRenderSettings()
        settings.volumetrics = volumetrics
        settings.shadows = shadows
        return settings
    }

    /// An orthographic scene's camera for a 256×144 scene (`SceneOrthographicCameraRig`).
    static let camera = orthographicCamera(SIMD2(256, 144))

    static func orthographicCamera(_ size: SIMD2<Float>) -> SceneFrameCamera {
        SceneOrthographicCameraRig().frameCamera(SceneCameraRigInput(sceneSize: size, aspect: size.x / size.y,
                                                                     time: 0, deltaTime: 0))
    }

    private func plan(_ lights: [SceneLightObject], _ volumetrics: GSLightingQuality,
                      shadows: GSLightingQuality = .medium) throws -> SceneVolumetricsPlan? {
        try SceneVolumetricsPlan.build(lights: lights, settings: Self.settings(volumetrics, shadows: shadows), builder: builder)
    }

    // MARK: - The plan

    /// Every util material translates at every quality, with WE's combos and passes.
    func testThePlanIsWEsUtilMaterials() throws {
        _ = try Fixtures.assets()
        let lights = [Self.object("1", Self.spot()), Self.object("2", Self.spot(cookie: true)), Self.object("3", Self.point())]
        for quality in [GSLightingQuality.low, .medium, .high, .ultra] {
            let plan = try XCTUnwrap(plan(lights, quality))
            XCTAssertEqual(plan.quality, quality.level)
            XCTAssertEqual(plan.lights.map(\.id), ["1", "2", "3"])
            XCTAssertEqual(plan.blurH != nil, quality.level < 3, "\(quality): WE blurs below quality 3")
            XCTAssertEqual(plan.blurV != nil, quality.level < 3)
            XCTAssertEqual(SceneVolumetricsPlan.divisor(quality: quality.level), quality.level >= 3 ? 4 : 8)
            for light in plan.lights {
                XCTAssertEqual(light.front.variant.combos["QUALITY"], quality.level)
                XCTAssertEqual(light.fullscreen.variant.combos["FULLSCREEN"], 1)
                XCTAssertEqual(light.front.variant.combos["FULLSCREEN"] ?? 0, 0)
                XCTAssertEqual(light.front.blending, "additive")
                XCTAssertEqual(light.back.cullMode, "normal")
                XCTAssertEqual(light.fullscreen.cullMode, "nocull")
            }
            XCTAssertEqual(plan.lights[1].front.variant.combos["COOKIE"], 1)
            XCTAssertEqual(plan.lights[0].front.variant.combos["COOKIE"] ?? 0, 0)
            XCTAssertEqual(plan.lights[2].front.variant.combos["POINTLIGHT"], 1)
            XCTAssertEqual(plan.lights[2].front.variant.combos["LIGHTS_SHADOW_MAPPING_QUALITY"], 2)
            XCTAssertNotNil(plan.lights[1].cookie, "the cookie spot binds its cookie")
            XCTAssertTrue(plan.lights[1].front.variant.textureSlots.contains(2))
            XCTAssertEqual(Set(plan.lights[0].front.variant.textureSlots), [1, 3])
            XCTAssertEqual(plan.combine.blending, "additive")
            XCTAssertEqual(plan.combine.material, "materials/util/volumetrics_combine.json")
        }
    }

    /// WE's trigger: nothing with the setting disabled or without a light that casts volumetrics.
    func testTheSettingGatesThePlan() throws {
        _ = try Fixtures.assets()
        XCTAssertNil(try plan([Self.object("1", Self.spot())], .disabled))
        var quiet = Self.spot()
        quiet.castVolumetrics = false
        XCTAssertNil(try plan([Self.object("1", quiet)], .ultra))
        XCTAssertNotNil(try plan([Self.object("1", quiet), Self.object("2", Self.point())], .low))
        let plan = try XCTUnwrap(plan([Self.object("1", Self.spot())], .medium))
        XCTAssertTrue(SceneVolumetrics.runs(plan, settings: Self.settings(.medium)))
        XCTAssertFalse(SceneVolumetrics.runs(plan, settings: Self.settings(.disabled)))
        XCTAssertFalse(SceneVolumetrics.runs(nil, settings: Self.settings(.ultra)))
    }

    /// A shadow caster reads its map in the shadow atlas (`SHADOW`, LR22) while shadows are on;
    /// with them off WE compiles it without `SHADOW`, as it does.
    func testShadowCastersReadTheShadowAtlas() throws {
        _ = try Fixtures.assets()
        let caster = Self.object("9", Self.spot(cookie: true, shadow: true))
        let on = try XCTUnwrap(plan([caster, Self.object("1", Self.spot())], .high))
        XCTAssertEqual(on.lights.map(\.id), ["9", "1"])
        XCTAssertEqual(on.skipped.map(\.id), [])
        XCTAssertEqual(on.lights[0].front.variant.combos["SHADOW"], 1)
        XCTAssertEqual(on.lights[0].fullscreen.variant.combos["SHADOW"], 1)
        XCTAssertEqual(on.lights[1].front.variant.combos["SHADOW"] ?? 0, 0)
        XCTAssertEqual(SceneVolumetricsPlan.combos(for: caster.light, quality: 3, shadowQuality: 2)["SHADOW"], 1)
        let off = try XCTUnwrap(plan([caster], .high, shadows: .disabled))
        XCTAssertEqual(off.lights.map(\.id), ["9"])
        XCTAssertEqual(off.lights[0].front.variant.combos["SHADOW"] ?? 0, 0)
        XCTAssertEqual(off.lights[0].front.variant.combos["COOKIE"], 1)
    }

    /// LF4: a cookie that doesn't load falls back to WE's default (0x14025d1b7), per light; one
    /// whose default is missing too is skipped alone, and the other lights still draw.
    func testAMissingCookieFallsBackPerLight() throws {
        _ = try Fixtures.assets()
        var missing = Self.spot(cookie: true)
        missing.cookie = "cookie/missing"
        let fallback = try XCTUnwrap(plan([Self.object("1", missing), Self.object("2", Self.spot())], .medium))
        XCTAssertEqual(fallback.lights.map(\.id), ["1", "2"])
        XCTAssertEqual(fallback.lights[0].cookie?.key, "\(SceneVolumetricsPlan.frontMaterial)|\(SceneLightDefaults.cookie)")

        let root = ShaderVariantTests.weAssets
        let noCookies = SceneEffectPlanBuilder(
            translator: builder.translator,
            readFile: { FileManager.default.contents(atPath: root.appending(path: $0).path) },
            loadTexture: { _, _ in nil })
        let plan = try XCTUnwrap(try SceneVolumetricsPlan.build(
            lights: [Self.object("1", missing), Self.object("2", Self.spot())],
            settings: Self.settings(.medium), builder: noCookies))
        XCTAssertEqual(plan.lights.map(\.id), ["2"], "the other light still draws")
        XCTAssertEqual(plan.skipped.map(\.id), ["1"])
    }

    /// The cookie is the light's `cookie` key, read with `usecookie`, WE's default when it names none.
    func testTheCookieIsTheLightsCookieKey() throws {
        func light(_ json: String) throws -> SceneLight {
            let object = try decodeTolerant(WESceneObject.self, from: Data(json.utf8))
            return SceneLight(try XCTUnwrap(object.light), in: LiveSceneValueContext())
        }
        XCTAssertEqual(try light(#"{"id": 1, "light": "lspot", "usecookie": true, "cookie": "cookie/flashlight3"}"#).cookie,
                       "cookie/flashlight3")
        XCTAssertEqual(try light(#"{"id": 1, "light": "lspot", "usecookie": true}"#).cookie, "cookie/flashlight1")
        XCTAssertEqual(try light(#"{"id": 1, "light": "lspot", "usecookie": true, "cookie": ""}"#).cookie, "cookie/flashlight1")
        XCTAssertNil(try light(#"{"id": 1, "light": "lspot", "cookie": "cookie/flashlight3"}"#).cookie)
    }

    // MARK: - Meshes and values

    /// WE's meshes, wound outward: the signed volume of every triangle fan from the centroid is positive.
    func testTheMeshesAreWEsAndWoundOutward() {
        XCTAssertEqual(SceneVolumeMesh.box.positions.count, 8)
        XCTAssertEqual(SceneVolumeMesh.box.indices.count, 36)
        XCTAssertEqual(SceneVolumeMesh.cone.positions.count, 2 + 4 * 32)
        XCTAssertEqual(SceneVolumeMesh.cone.indices.count, 12 * 32)
        XCTAssertEqual(SceneVolumeMesh.sphere.positions.count, 2 + 23 * 25)
        for mesh in [SceneVolumeMesh.box, .cone, .sphere] {
            let centroid = mesh.positions.reduce(SIMD3<Float>.zero, +) / Float(mesh.positions.count)
            var volume: Float = 0
            for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
                let a = mesh.positions[Int(mesh.indices[triangle])] - centroid
                let b = mesh.positions[Int(mesh.indices[triangle + 1])] - centroid
                let c = mesh.positions[Int(mesh.indices[triangle + 2])] - centroid
                let part = simd_dot(a, simd_cross(b, c))
                XCTAssertGreaterThanOrEqual(part, -1e-6)
                volume += part / 6
            }
            XCTAssertGreaterThan(volume, 0)
        }
        // The box spans WE's clip volume; the cone is the circle inside it.
        XCTAssertEqual(Set(SceneVolumeMesh.box.positions.map(\.z)), [0, 1])
        XCTAssertTrue(SceneVolumeMesh.cone.positions.dropFirst(2).allSatisfy { abs(simd_length(SIMD2($0.x, $0.y)) - 1) < 1e-5 })
    }

    /// The light's `g_RenderVar*`, projection and volume, as WE packs them.
    func testTheLightValuesAreWEs() {
        let light = Self.spot(cookie: true)
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(100, 50, -20, 1)
        let volume = SceneVolumetricLight(light: light, world: world, camera: Self.camera)
        XCTAssertEqual(volume.shape, .box)
        XCTAssertEqual(volume.renderVars[1], SIMD4(118.8, cos(20 * .pi / 180), cos(30 * .pi / 180), 3))
        XCTAssertEqual(volume.renderVars[2], SIMD4(100, 50, -20, 2))
        XCTAssertEqual(volume.renderVars[3], SIMD4(1, 0, 0, 0), "the light's local +X")
        XCTAssertEqual(volume.renderVars[4], SIMD4(1, 0.8, 0.6, 1.5), "the colour without the intensity")
        // Down the light's +X: the axis projects to the clip centre, reversed like every WE
        // projection: 1 (orthographic near) at depth 1, the radius at 0.
        func clip(_ distance: Float) -> SIMD3<Float> {
            let p = volume.lightProjection * SIMD4(100 + distance, 50, -20, 1)
            return SIMD3(p.x, p.y, p.z) / p.w
        }
        XCTAssertEqual(clip(1).z, 1, accuracy: 1e-5)
        XCTAssertEqual(clip(120).z, 0, accuracy: 1e-5)
        XCTAssertEqual(clip(60).x, 0, accuracy: 1e-5)
        // The outer cone reaches the clip square's edge.
        let edge = volume.lightProjection * SIMD4(100 + 60, 50 + 60 * tan(30 * .pi / 180), -20, 1)
        XCTAssertEqual(abs(edge.y / edge.w), 1, accuracy: 1e-4)
        // The volume is the projection's inverse: WE's far corner (clip depth 0) lands on the far plane.
        let corner = volume.volume * SIMD4(1, 1, SceneVolumeMesh.farDepth, 1)
        XCTAssertEqual(corner.x / corner.w, 100 + 120, accuracy: 1e-2)
        XCTAssertEqual(SceneVolumetricLight(light: Self.spot(), world: world, camera: Self.camera).shape, .cone)

        let point = SceneVolumetricLight(light: Self.point(), world: world, camera: Self.camera)
        XCTAssertEqual(point.shape, .sphere)
        XCTAssertEqual(point.volume * SIMD4(1, 0, 0, 1), SIMD4(150, 50, -20, 1))
        XCTAssertEqual(point.renderVars[3], .zero)
    }

    /// WE's inside tests: a sphere around the eye, a cone and a frustum the eye looks down.
    func testTheCameraInsideTests() {
        let eye = SIMD3<Float>(0, 0, 10)
        let camera = SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0)),
                                      projection: SceneCamera.perspective(fovDegrees: 50, aspect: 16.0 / 9, near: 0.01, far: 1000),
                                      eye: eye, forward: SIMD3(0, 0, -1), fieldOfView: 50)
        func at(_ position: SIMD3<Float>, forward: SIMD3<Float> = SIMD3(0, 0, -1)) -> simd_float4x4 {
            let f = simd_normalize(forward)
            let side = simd_normalize(simd_cross(SIMD3(0, 1, 0), f))
            let up = simd_cross(f, side)
            return simd_float4x4(columns: (SIMD4(f, 0), SIMD4(up, 0), SIMD4(side, 0), SIMD4(position, 1)))
        }
        XCTAssertTrue(SceneVolumetricLight(light: Self.point(), world: at(SIMD3(0, 0, 20)), camera: camera).cameraInside)
        XCTAssertFalse(SceneVolumetricLight(light: Self.point(), world: at(SIMD3(0, 0, -60)), camera: camera).cameraInside)
        // The spots shine from behind the eye, then away from it.
        for cookie in [false, true] {
            let toward = SceneVolumetricLight(light: Self.spot(cookie: cookie), world: at(SIMD3(0, 0, 40)), camera: camera)
            XCTAssertTrue(toward.cameraInside, "cookie \(cookie)")
            let away = SceneVolumetricLight(light: Self.spot(cookie: cookie), world: at(SIMD3(0, 0, 40), forward: SIMD3(0, 0, 1)),
                                            camera: camera)
            XCTAssertFalse(away.cameraInside, "cookie \(cookie)")
            let wide = SceneVolumetricLight(light: Self.spot(cookie: cookie), world: at(SIMD3(80, 0, 40)), camera: camera)
            XCTAssertFalse(wide.cameraInside, "cookie \(cookie): beside the cone")
        }
    }

    // MARK: - The passes against the CPU model

    /// `volumetrics_blur_h`, `_v` and `volumetrics_combine` on a synthetic light buffer, against
    /// `VolumetricsReference.finish`, with and without the blur.
    func testTheBlurAndCombineMatchTheCPUModel() throws {
        _ = try Fixtures.assets()
        let stage = SceneVolumetrics(device: device)
        let pipelines = try XCTUnwrap(stage.pipelines)
        let width = 40, height = 23
        let light = VolumetricsReference.Image(width: width, height: height) { x, y in
            let spot: Float = (x - 20) * (x - 20) + (y - 11) * (y - 11) < 30 ? 0.9 : 0
            return SIMD4(spot, Float(x) / Float(width - 1) * 0.5, Float(y % 5) / 8, 1)
        }.quantized
        let scene = VolumetricsReference.Image(width: width, height: height) { x, y in
            SIMD4(0.2, Float(y) / Float(height - 1) * 0.6, 0.1, 1)
        }.quantized
        for quality in [GSLightingQuality.low, .ultra] {
            let plan = try XCTUnwrap(plan([Self.object("1", Self.spot())], quality))
            XCTAssertTrue(pipelines.waitUntilReady(plan, sceneFormat: .rgba8Unorm))
            XCTAssertEqual(pipelines.failedCount, 0)
            let lightBuffer = try texture(light, usage: [.renderTarget, .shaderRead])
            let lightBufferB = try texture(light, usage: [.renderTarget, .shaderRead])
            let target = try texture(scene, usage: [.renderTarget, .shaderRead])
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            XCTAssertTrue(stage.finish(plan, lightBuffer: lightBuffer, lightBufferB: lightBufferB, into: target,
                                       frame: BuiltinFrameContext(), commandBuffer: commands))
            commands.commit()
            commands.waitUntilCompleted()
            let drawn = try TextureUploadTests.read(target, device: device)
            let expected = VolumetricsReference.finish(scene: scene, lightBuffer: light,
                                                       blurs: SceneVolumetricsPlan.blurs(quality: quality.level)).bytes
            var worst = 0
            for index in drawn.indices where index % 4 != 3 {
                worst = max(worst, abs(Int(drawn[index]) - Int(expected[index])))
            }
            XCTAssertLessThanOrEqual(worst, 1, "\(quality): off the CPU model by \(worst)/255")
        }
    }

    /// The whole stage on a synthetic frame: each light's front pass against `volumetrics_front`
    /// along each pixel's ray (`VolumetricsReference.march`), before the combine.
    func testTheRayMarchMatchesTheCPUModelAlongEachRay() throws {
        _ = try Fixtures.assets()
        let width = 256, height = 144
        var rightward = matrix_identity_float4x4
        rightward.columns.3 = SIMD4(70, 80, -10, 1)
        var sphere = matrix_identity_float4x4
        sphere.columns.3 = SIMD4(190, 60, 5, 1)
        for (quality, cases) in [(GSLightingQuality.ultra, [("cone", Self.spot(), rightward)]),
                                 (.high, [("sphere", Self.point(), sphere)])] {
            for (name, light, world) in cases {
                let plan = try XCTUnwrap(plan([Self.object(name, light)], quality))
                let stage = SceneVolumetrics(device: device)
                stage.setPlan(plan)
                XCTAssertTrue(try XCTUnwrap(stage.pipelines).waitUntilReady(plan, sceneFormat: .rgba8Unorm))
                let scene = try texture(VolumetricsReference.Image(width: width, height: height) { _, _ in SIMD4(0, 0, 0, 1) },
                                        usage: [.renderTarget, .shaderRead])
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                var frame = BuiltinFrameContext()
                frame.camera = Self.camera
                frame.lighting.objects = [SceneFrameLightObject(id: name, world: world, visible: true)]
                stage.encode(SceneFrameStageContext(scene: scene, commandBuffer: commands, sceneSize: SIMD2(256, 144),
                                                    frame: frame, settings: Self.settings(quality)))
                commands.commit()
                commands.waitUntilCompleted()
                let record = try XCTUnwrap(stage.lastRecord, name)
                XCTAssertEqual(record.lights.map(\.id), [name])
                XCTAssertEqual(record.lights.map(\.fullscreen), [false])
                let buffer = record.lightBuffer
                XCTAssertEqual(buffer.width, width / 4)
                let drawn = try TextureUploadTests.read(buffer, device: device)
                let volume = SceneVolumetricLight(light: light, world: world, camera: Self.camera)
                let viewProjection = SceneVolumetrics.viewProjection(Self.camera)
                let transform = viewProjection * volume.volume
                let mesh = SceneVolumeMesh.make(volume.shape)
                let frontScale = light.kind == .point ? SIMD3<Float>(repeating: 1) : SIMD3(0.99, 0.99, 1)
                var worst = 0, lit = 0, compared = 0
                for row in 0..<buffer.height {
                    for column in 0..<buffer.width {
                        // Pixel centres in the clip space the shaders see (the scene's top in row 0).
                        let x = 2 * (Float(column) + 0.5) / Float(buffer.width) - 1
                        let y = 2 * (Float(row) + 0.5) / Float(buffer.height) - 1
                        let front = VolumetricsReference.depths(of: mesh, transform: transform, x: x, y: y, scale: frontScale)
                        let back = VolumetricsReference.depths(of: mesh, transform: transform, x: x, y: y)
                        // Pixels on a silhouette may round either way.
                        let offsets: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
                        let near: [Bool] = offsets.map { (dx: Int, dy: Int) -> Bool in
                            VolumetricsReference.depths(of: mesh, transform: transform,
                                                        x: x + 2 * Float(dx) / Float(buffer.width),
                                                        y: y + 2 * Float(dy) / Float(buffer.height), scale: frontScale) != nil
                        }
                        guard near.allSatisfy({ $0 == (front != nil) }) else { continue }
                        var expected = SIMD3<Float>.zero
                        if let front, let back {
                            // Reversed depth: the near faces are the greatest depth, the far ones the least.
                            expected = VolumetricsReference.march(volume, point: light.kind == .point,
                                                                  viewProjection: viewProjection, x: x, y: y,
                                                                  near: front.max, far: back.min, quality: quality.level)
                        }
                        let i = (row * buffer.width + column) * 4
                        compared += 1
                        if drawn[i] > 0 || drawn[i + 2] > 0 { lit += 1 }
                        for channel in 0..<3 {
                            let want = Int((simd_clamp(expected[channel], 0, 1) * 255).rounded())
                            worst = max(worst, abs(Int(drawn[i + channel]) - want))
                        }
                    }
                }
                XCTAssertGreaterThan(lit, 20, "\(name): the volume shows")
                // Where the light is: the scene's top is the buffer's first row.
                var rows: Float = 0, count: Float = 0
                for row in 0..<buffer.height {
                    for column in 0..<buffer.width where drawn[(row * buffer.width + column) * 4 + 2] > 0 {
                        rows += Float(row) + 0.5
                        count += 1
                    }
                }
                if light.kind == .point {
                    let expected = (144 - world.columns.3.y) / 144 * Float(buffer.height)
                    XCTAssertEqual(rows / count, expected, accuracy: 1.5, "\(name): the sphere is centred on the light")
                }
                XCTAssertGreaterThan(compared, buffer.width * buffer.height / 2)
                XCTAssertLessThanOrEqual(worst, 2, "\(name): off the CPU model by \(worst)/255")
            }
        }
    }

    /// With the setting disabled the stage draws nothing, whatever the plan.
    func testTheStageIsGatedByTheSetting() throws {
        _ = try Fixtures.assets()
        let plan = try XCTUnwrap(plan([Self.object("1", Self.point())], .high))
        let stage = SceneVolumetrics(device: device)
        stage.setPlan(plan)
        XCTAssertTrue(try XCTUnwrap(stage.pipelines).waitUntilReady(plan, sceneFormat: .rgba8Unorm))
        let black = VolumetricsReference.Image(width: 64, height: 32) { _, _ in SIMD4(0, 0, 0, 1) }
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(128, 72, 0, 1)
        for (setting, visible, draws) in [(GSLightingQuality.disabled, true, false), (.high, false, false), (.high, true, true)] {
            let scene = try texture(black, usage: [.renderTarget, .shaderRead])
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            var frame = BuiltinFrameContext()
            frame.camera = Self.camera
            frame.lighting.objects = [SceneFrameLightObject(id: "1", world: world, visible: visible)]
            stage.encode(SceneFrameStageContext(scene: scene, commandBuffer: commands, sceneSize: SIMD2(256, 144),
                                                frame: frame, settings: Self.settings(setting)))
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertEqual(stage.lastRecord != nil, draws, "\(setting), visible \(visible)")
            let bytes = try TextureUploadTests.read(scene, device: device)
            let added = stride(from: 0, to: bytes.count, by: 4).contains { bytes[$0] > 0 || bytes[$0 + 2] > 0 }
            XCTAssertEqual(added, draws, "\(setting), visible \(visible)")
        }
    }

    /// What volumetrics cost on the GPU at 1920×1080, per quality: two spots and a point.
    func testTheCost() throws {
        _ = try Fixtures.assets()
        let lights = [Self.object("1", Self.spot()), Self.object("2", Self.spot(cookie: true)), Self.object("3", Self.point())]
        var report = "quality\tlights\tGPU min ms\tGPU median ms\n"
        for quality in [GSLightingQuality.low, .medium, .high, .ultra] {
            let plan = try XCTUnwrap(try SceneVolumetricsPlan.build(lights: lights, settings: Self.settings(quality),
                                                                    builder: builder))
            let stage = SceneVolumetrics(device: device)
            stage.setPlan(plan)
            XCTAssertTrue(try XCTUnwrap(stage.pipelines).waitUntilReady(plan, sceneFormat: .rgba8Unorm))
            let scene = try blank(width: 1920, height: 1080)
            var frame = BuiltinFrameContext()
            frame.camera = Self.orthographicCamera(SIMD2(1920, 1080))
            frame.lighting.objects = [(1, SIMD4<Float>(400, 500, -100, 1)), (2, SIMD4(1200, 900, -300, 1)),
                                      (3, SIMD4(960, 540, 0, 1))].map { id, position in
                var world = simd_float4x4(diagonal: SIMD4(1, 1, 1, 1))
                world.columns.3 = position
                return SceneFrameLightObject(id: String(id), world: world, visible: true)
            }
            var times: [Double] = []
            for _ in 0..<20 {
                let commands = try XCTUnwrap(queue.makeCommandBuffer())
                stage.encode(SceneFrameStageContext(scene: scene, commandBuffer: commands, sceneSize: SIMD2(1920, 1080),
                                                    frame: frame, settings: Self.settings(quality)))
                commands.commit()
                commands.waitUntilCompleted()
                XCTAssertNotNil(stage.lastRecord)
                times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            }
            times.sort()
            report += String(format: "%@\t3\t%.3f\t%.3f\n", quality.rawValue, times[0], times[times.count / 2])
            XCTAssertLessThan(times[0], 16, "\(quality): volumetrics cost a frame")
        }
        print("Volumetrics cost at 1920×1080:\n\(report)")
    }

    // MARK: - Helpers

    private func texture(_ image: VolumetricsReference.Image, usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = usage
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: image.bytes, bytesPerRow: image.width * 4)
        return texture
    }

    private func blank(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
}
