import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// WE's volumetrics on the library's scenes (docs/lighting-plan.md §1.5, §2.8):
///
/// - Hinata (3352730400), the library's 2D volumetric scene, loaded by the real loader and drawn
///   headlessly by the real renderer: its cookie spot draws a volume where its frustum projects,
///   follows the light when it moves, and goes with the setting.
/// - The 3D test set (3455121165, 3657770939, 3233200129, 3159348391, 3378346807) and Moon
///   (3453730450). Their models and depth come with area 6, so this checks what doesn't need
///   them: which lights WE draws a volume for, with which passes, and, for the lights at the
///   scene's root, the volume drawn through the scene's own camera.
///
/// Skipped when the library is absent (CI).
final class VolumetricsLibraryTests: XCTestCase {
    private static let storage = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage")
    private static let drawable = SIMD2(480, 270)
    private var scripts: URL!

    override func setUpWithError() throws {
        scripts = FileManager.default.temporaryDirectory.appending(path: "owe-volumetrics-library-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let scripts, FileManager.default.fileExists(atPath: scripts.path) { try FileManager.default.removeItem(at: scripts) }
    }

    private func wallpaper(_ id: String) throws -> (directory: URL, project: WEProject) {
        let directory = Self.storage.appending(path: id, directoryHint: .isDirectory)
        guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path) else {
            throw XCTSkip("\(id) not in the library")
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        return (directory, try decodeTolerant(WEProject.self, from: Data(text.utf8)))
    }

    // MARK: - Hinata

    func testHinatasCookieSpotDrawsItsVolume() throws {
        _ = try Fixtures.assets()
        let (directory, project) = try wallpaper("3352730400")
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        defer { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(model.metalContent())
        let plan = try XCTUnwrap(content.volumetrics, "Hinata's volumetrics weren't planned")
        XCTAssertEqual(plan.lights.map(\.id), ["516"])
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertEqual(plan.quality, GSLightingQuality.medium.level, "the app's default")
        let light = plan.lights[0]
        XCTAssertEqual(light.light.cookie, "cookie/flashlight1", "no `cookie`: WE's default (0x14025d1b7)")
        XCTAssertNotNil(light.cookie)
        XCTAssertEqual(light.front.variant.combos["COOKIE"], 1)
        XCTAssertEqual(SceneVolumetricLight.shape(of: light.light), .box)
        XCTAssertFalse(content.spatial.camera.projection.isPerspective)

        let scene = try Scene(content: content, scripts: scripts)
        defer { scene.close() }
        let stage = try XCTUnwrap(scene.renderer.volumetrics)
        let deadline = Date().addingTimeInterval(60)
        repeat { scene.draw() } while stage.lastRecord == nil && Date() < deadline
        let record = try XCTUnwrap(stage.lastRecord, "the volumetrics never drew")
        XCTAssertEqual(record.lights.map(\.id), ["516"])
        XCTAssertEqual(record.lights.map(\.fullscreen), [false], "the 2D eye is outside the spot's frustum")
        let authored = try check(record, content: content, light: light.light, id: "516", label: "authored")

        // Moved down and right, the volume follows.
        var moved = content
        let origin = content.transforms.nodes["516"]!.local
        let shift = SIMD2<Float>(500, -300)
        let object = try decodeTolerant(WESceneObject.self, from: Data(#"""
            {"id": 516, "origin": "\#(origin.origin.x + shift.x) \#(origin.origin.y + shift.y) -421.09644",
             "angles": "-0.14119 0.58229 -0.78032"}
            """#.utf8))
        moved.motions["516"] = SceneObjectMotion(object: object, bindings: SceneLayerBindings())
        moved.transforms.makeRoot("516", local: SceneLocalTransform(object: object))
        let movedScene = try Scene(content: moved, scripts: scripts)
        defer { movedScene.close() }
        let movedStage = try XCTUnwrap(movedScene.renderer.volumetrics)
        repeat { movedScene.draw() } while movedStage.lastRecord == nil && Date() < deadline
        let movedRecord = try XCTUnwrap(movedStage.lastRecord)
        let after = try check(movedRecord, content: moved, light: light.light, id: "516", label: "moved")
        XCTAssertGreaterThan(after.x - authored.x, 0.5 * shift.x * Float(record.lightBuffer.width) / content.size.x * 0.5,
                             "the volume moved right with the light")
        XCTAssertGreaterThan(after.y - authored.y, 0, "and down: the scene's top is the buffer's first row")

        // The setting turns it off.
        scene.renderer.renderSettings.volumetrics = .disabled
        scene.draw()
        XCTAssertNil(stage.lastRecord, "disabled volumetrics draw nothing")
    }

    /// LF6: with camera shake on, the shafts move with the scene. The renderer moves every object
    /// by the negative shake (WE moves the camera by it), so the light's world position and its
    /// volume in the light buffer move frame to frame by the same amount, and `g_EyePosition` is
    /// WE's orthographic eye.
    func testHinatasVolumeFollowsTheCameraShake() throws {
        _ = try Fixtures.assets()
        let (directory, project) = try wallpaper("3352730400")
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        defer { Fixtures.removeStoredSettings(for: directory) }
        var content = try XCTUnwrap(model.metalContent())
        content.camera.shake = true
        content.camera.shakeAmplitude = 2
        content.camera.shakeSpeed = 2
        let authored = try XCTUnwrap(content.transforms.nodes["516"]).local.origin
        let scene = try Scene(content: content, scripts: scripts)
        defer { scene.close() }
        let probe = SceneDrawProbe()
        scene.renderer.drawProbe = probe
        let stage = try XCTUnwrap(scene.renderer.volumetrics)
        var samples: [(offset: SIMD2<Float>, centroid: SIMD2<Float>)] = []
        for _ in 0..<60 {
            scene.draw()
            guard let record = stage.lastRecord, let light = probe.lighting?.objects.first(where: { $0.id == "516" })
            else { continue }
            let offset = SIMD2(light.world.columns.3.x, light.world.columns.3.y) - authored
            samples.append((offset, try centroid(record.lightBuffer)))
        }
        XCTAssertGreaterThan(samples.count, 30)
        let spread = samples.map { simd_length($0.offset - samples[0].offset) }.max() ?? 0
        XCTAssertGreaterThan(spread, 20, "the shake moves the light")
        // The buffer's first row is the scene's top: +y in the scene is −y in the buffer.
        let buffer = try XCTUnwrap(stage.lastRecord).lightBuffer
        let perUnit = SIMD2(Float(buffer.width), -Float(buffer.height)) / content.size
        for sample in samples.dropFirst() {
            let expected = (sample.offset - samples[0].offset) * perUnit
            let moved = sample.centroid - samples[0].centroid
            // The volume runs off the top of the frame, so its centroid follows y only partly.
            XCTAssertEqual(moved.x, expected.x, accuracy: 1, "the volume follows the light: \(moved) vs \(expected)")
            if abs(expected.y) > 1 { XCTAssertEqual(moved.y.sign, expected.y.sign, "\(moved) vs \(expected)") }
        }
    }

    /// The light buffer's brightness-weighted centroid, in texels.
    private func centroid(_ buffer: MTLTexture) throws -> SIMD2<Float> {
        let drawn = try TextureUploadTests.read(buffer, device: buffer.device)
        var sum: Float = 0, weighted = SIMD2<Float>.zero
        for row in 0..<buffer.height {
            for column in 0..<buffer.width {
                let i = (row * buffer.width + column) * 4
                let value = Float(drawn[i]) + Float(drawn[i + 1]) + Float(drawn[i + 2])
                sum += value
                weighted += value * SIMD2(Float(column) + 0.5, Float(row) + 0.5)
            }
        }
        return weighted / max(sum, 1)
    }

    /// Against WE itself (2.8.0.42 on Windows, 1920×1080, post-processing enabled): the mean of
    /// the frame over x 300–700, y 0–400, where Hinata's spot throws its wedge from the top left,
    /// is 15.4 with volumetrics disabled and 40.2, 40.4 and 40.3 at low, medium and high. The tiers
    /// change blur and resolution, not brightness. This settles the light's rotation order
    /// (test-risks LR4): the other order, `Rx·Ry·Rz`, gives about 50.
    ///
    /// Measured once the renderer has drawn a complete frame (every pipeline, the volumetrics'
    /// too, landed) and the volume with it: a frame drawn while the volumes' pipelines compile
    /// has no wedge, about 15.4 at every tier.
    func testHinatasWedgeMatchesWE() throws {
        _ = try Fixtures.assets()
        let (directory, project) = try wallpaper("3352730400")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let expected: [(GSLightingQuality, Double)] = [(.disabled, 15.4), (.low, 40.2), (.medium, 40.4), (.high, 40.3)]
        for (quality, mean) in expected {
            let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
            var settings = SceneRenderSettings()
            settings.volumetrics = quality
            settings.postProcessing = .enabled
            model.setRenderSettings(settings)
            let scene = try Scene(content: try XCTUnwrap(model.metalContent()), scripts: scripts)
            defer { scene.close() }
            scene.renderer.renderSettings = settings
            let stage = try XCTUnwrap(scene.renderer.volumetrics)
            let deadline = Date().addingTimeInterval(60)
            repeat { scene.draw() } while !(scene.renderer.hasCompleteFrame && (quality == .disabled || stage.lastRecord != nil))
                && Date() < deadline
            XCTAssertTrue(scene.renderer.hasCompleteFrame, "\(quality): never a complete frame")
            for _ in 0..<40 { scene.draw() }
            XCTAssertEqual(stage.lastRecord != nil, quality != .disabled, "\(quality): the volume drew")
            let size = Self.drawable
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            let texture = try XCTUnwrap(scene.view.currentDrawable?.texture)
            texture.getBytes(&bytes, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            var sum = 0.0, count = 0.0
            for y in 0..<size.y {
                for x in 0..<size.x {
                    let scene = SIMD2((Double(x) + 0.5) / Double(size.x) * 1920, (Double(y) + 0.5) / Double(size.y) * 1080)
                    guard scene.x >= 300, scene.x < 700, scene.y < 400 else { continue }
                    let i = (y * size.x + x) * 4
                    sum += (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
                    count += 1
                }
            }
            XCTAssertEqual(sum / count, mean, accuracy: 1.5, "\(quality): the wedge's mean against WE's")
        }
    }

    /// 3378346807's distance fog (`general.fogdistance`, 1…48, its colour the background colour
    /// property) reaches its volumetric passes as WE's engine gives it (`FOG_DIST`,
    /// 0x1401a64ae…0x1401a6602): each sample of the march is squared and faded by it. Without it
    /// the scene's glow was about twice WE's (docs/lighting-plan.md §2.9).
    func testSnowflakesVolumesCompileWithTheScenesFog() throws {
        _ = try Fixtures.assets()
        let (directory, project) = try wallpaper("3378346807")
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        defer { Fixtures.removeStoredSettings(for: directory) }
        var settings = SceneRenderSettings()
        settings.volumetrics = .high
        model.setRenderSettings(settings)
        let content = try XCTUnwrap(model.metalContent())
        let fog = content.lighting.settings.fog
        XCTAssertTrue(fog.distance)
        XCTAssertFalse(fog.height)
        XCTAssertEqual(fog.distanceParams, SIMD4<Float>(1, 47, 0, 1))
        XCTAssertEqual(fog.distanceColor.x, 0.2549, accuracy: 1e-3)
        XCTAssertTrue(content.engineCombos.fogDistance)
        let plan = try XCTUnwrap(content.volumetrics)
        XCTAssertEqual(plan.lights.map(\.id), ["58", "322"])
        for light in plan.lights {
            XCTAssertEqual(light.front.variant.combos["FOG_DIST"], 1, light.id)
            XCTAssertEqual(light.fullscreen.variant.combos["FOG_DIST"], 1, light.id)
        }
    }

    /// Every lit texel of the light buffer lies where the light's frustum projects (the blur
    /// spreads it by a texel each way); returns the lit texels' centroid.
    @discardableResult
    private func check(_ record: SceneVolumetrics.Record, content: SceneMetalContent, light: SceneLight, id: String,
                       label: String) throws -> SIMD2<Float> {
        let buffer = record.lightBuffer
        let drawn = try TextureUploadTests.read(buffer, device: buffer.device)
        let node = try XCTUnwrap(content.transforms.nodes[id])
        let object = try XCTUnwrap(content.lighting.lights.first { $0.id == id })
        let world = SceneFrameLighting.world(parent: SceneAffineTransform(linear: matrix_identity_float2x2, translation: .zero),
                                             local: content.motions[id].map {
                                                 SceneLocalTransform(origin: $0.origin, scale: $0.scale, angle: $0.angle)
                                             } ?? node.local, depth: object.depth)
        let camera = Self.frameCamera(content)
        let volume = SceneVolumetricLight(light: light, world: world, camera: camera)
        let transform = SceneVolumetrics.viewProjection(camera) * volume.volume
        let mesh = SceneVolumeMesh.make(volume.shape)
        var lit = 0, outside = 0, centroid = SIMD2<Float>.zero
        let spread = SceneVolumetricsPlan.blurs(quality: record.quality) ? 1 : 0
        for row in 0..<buffer.height {
            for column in 0..<buffer.width {
                let i = (row * buffer.width + column) * 4
                guard drawn[i] > 1 || drawn[i + 1] > 1 || drawn[i + 2] > 1 else { continue }
                lit += 1
                centroid += SIMD2(Float(column) + 0.5, Float(row) + 0.5)
                let covered = (-spread...spread).contains { dy in
                    (-spread...spread).contains { dx in
                        let x = 2 * (Float(column + dx) + 0.5) / Float(buffer.width) - 1
                        let y = 2 * (Float(row + dy) + 0.5) / Float(buffer.height) - 1
                        return VolumetricsReference.depths(of: mesh, transform: transform, x: x, y: y,
                                                           scale: SIMD3(0.99, 0.99, 1)) != nil
                    }
                }
                if !covered { outside += 1 }
            }
        }
        XCTAssertGreaterThan(lit, buffer.width * buffer.height / 50, "\(label): the spot's volume shows")
        XCTAssertEqual(outside, 0, "\(label): \(outside) lit texels outside the light's frustum")
        print("Hinata (\(label)): \(lit) of \(buffer.width)×\(buffer.height) texels lit, centroid \(centroid / Float(max(lit, 1)))")
        return centroid / Float(max(lit, 1))
    }

    // MARK: - The 3D test set

    private struct Expected {
        var planned: [String]
        var skipped: [String] = []
        var withoutShadows: [String]
    }

    /// Which lights WE draws a volume for, with shadows on (medium) and off.
    private static let testSet: [String: Expected] = [
        // The sun's point light; its visibility is a user property.
        "3455121165": Expected(planned: ["85"], withoutShadows: ["85"]),
        // Three shadow-casting points: they read the shadow atlas (SHADOW) while shadows are on.
        "3657770939": Expected(planned: ["115", "608", "603"], withoutShadows: ["115", "608", "603"]),
        // A shadow-casting cookie spot.
        "3233200129": Expected(planned: ["24"], withoutShadows: ["24"]),
        // Lights, none with volumetrics.
        "3159348391": Expected(planned: [], withoutShadows: []),
        "3378346807": Expected(planned: ["58", "322"], withoutShadows: ["58", "322"]),
        // Moon: three points, two of them hidden.
        "3453730450": Expected(planned: ["39", "285", "339"], withoutShadows: ["39", "285", "339"]),
    ]

    func testTheTestSetPlansWEsVolumes() throws {
        _ = try Fixtures.assets()
        let builder = try makeBuilder()
        var report = "scene\tshadows\tplanned\tskipped\n"
        for (id, expected) in Self.testSet.sorted(by: { $0.key < $1.key }) {
            let (scene, directory) = try decodedScene(id)
            let lights = SceneContentLoader.lights(in: scene.objects, context: StaticContext())
            XCTAssertTrue(scene.general.projection.isPerspective, "\(id) is 3D")
            for (shadows, want) in [(GSLightingQuality.medium, expected.planned), (.disabled, expected.withoutShadows)] {
                var settings = SceneRenderSettings()
                settings.shadows = shadows
                let plan = try SceneVolumetricsPlan.build(lights: lights, settings: settings,
                                                          builder: builder.scoped(to: directory))
                XCTAssertEqual(plan?.lights.map(\.id) ?? [], want, "\(id), shadows \(shadows)")
                if shadows == .medium { XCTAssertEqual(plan?.skipped.map(\.id) ?? [], expected.skipped, id) }
                for light in plan?.lights ?? [] {
                    XCTAssertEqual(light.front.variant.combos["SHADOW"] ?? 0,
                                   light.light.castShadow && shadows != .disabled ? 1 : 0, "\(id) \(light.id)")
                    XCTAssertEqual(light.front.variant.combos["POINTLIGHT"] ?? 0, light.light.kind == .point ? 1 : 0)
                    XCTAssertEqual(light.front.variant.combos["COOKIE"] ?? 0, light.light.useCookie ? 1 : 0)
                }
                report += "\(id)\t\(shadows)\t\(plan?.lights.map(\.id) ?? [])\t\(plan?.skipped.map { "\($0.id): \($0.reason)" } ?? [])\n"
            }
        }
        print("Volumetric lights of the test set:\n\(report)")
    }

    /// The lights at a 3D scene's root, drawn through WE's camera for the scene (its active camera
    /// layer, `ScenePerspectiveCameraRig`) onto an empty frame (no models, so no depth): the
    /// volume shows only where its mesh projects.
    func testTheTestSetsRootLightsDrawThroughTheSceneCamera() throws {
        _ = try Fixtures.assets()
        let builder = try makeBuilder()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var report = "scene\tlight\tshape\tcamera inside\tlit texels\n"
        for (id, lightID) in [("3233200129", "24"), ("3453730450", "39")] {
            let (scene, directory) = try decodedScene(id)
            let lights = SceneContentLoader.lights(in: scene.objects, context: StaticContext())
            let spatial = SceneSpatialContentBuilder(
                readFile: { FileManager.default.contents(atPath: directory.appending(path: $0).path) },
                wallpaperName: id).build(scene, context: StaticContext())
            let camera = ScenePerspectiveCameraRig(spatial, values: StaticContext()).frameCamera(
                SceneCameraRigInput(sceneSize: SIMD2(1920, 1080), aspect: 16.0 / 9, time: 0, deltaTime: 0))
            XCTAssertTrue(camera.isPerspective, id)
            var settings = SceneRenderSettings()
            settings.shadows = .disabled
            settings.volumetrics = .ultra
            let plan = try XCTUnwrap(try SceneVolumetricsPlan.build(lights: lights, settings: settings,
                                                                    builder: builder.scoped(to: directory)))
            let object = try XCTUnwrap(scene.objects.first { $0.id.map(String.init) == lightID })
            XCTAssertNil(object.parent, "\(id) \(lightID) is at the root")
            let lightObject = try XCTUnwrap(lights.first { $0.id == lightID })
            let world = SceneFrameLighting.world(
                parent: SceneAffineTransform(linear: matrix_identity_float2x2, translation: .zero),
                local: SceneLocalTransform(object: object), depth: lightObject.depth)
            let stage = SceneVolumetrics(device: device)
            stage.setPlan(plan)
            XCTAssertTrue(try XCTUnwrap(stage.pipelines).waitUntilReady(plan, sceneFormat: .rgba8Unorm))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1080,
                                                                      mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            var frame = BuiltinFrameContext()
            frame.camera = camera
            frame.lighting.objects = [SceneFrameLightObject(id: lightID, world: world, visible: true)]
            var context = SceneFrameStageContext(scene: target, commandBuffer: commands, sceneSize: SIMD2(1920, 1080),
                                                 frame: frame, settings: settings)
            let upload = MTKTextureLoader(device: device)
            context.assetTexture = { _, source in
                guard case .image(let image) = source,
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    XCTFail("\(id): WE's cookies are uncompressed images")
                    return nil
                }
                do {
                    return try SceneTextureUpload.texture(from: cgImage, loader: upload, device: device)
                } catch {
                    XCTFail("\(id): the cookie can't be uploaded: \(error)")
                    return nil
                }
            }
            stage.encode(context)
            commands.commit()
            commands.waitUntilCompleted()
            let record = try XCTUnwrap(stage.lastRecord, "\(id) \(lightID)")
            let buffer = record.lightBuffer
            let drawn = try TextureUploadTests.read(buffer, device: device)
            let volume = SceneVolumetricLight(light: lightObject.light, world: world, camera: camera)
            let transform = SceneVolumetrics.viewProjection(camera) * volume.volume
            let mesh = SceneVolumeMesh.make(volume.shape)
            let scale = lightObject.light.kind == .point ? SIMD3<Float>(repeating: 1) : SIMD3(0.99, 0.99, 1)
            var lit = 0, outside = 0
            for row in 0..<buffer.height {
                for column in 0..<buffer.width {
                    let i = (row * buffer.width + column) * 4
                    guard drawn[i] > 1 || drawn[i + 1] > 1 || drawn[i + 2] > 1 else { continue }
                    lit += 1
                    let x = 2 * (Float(column) + 0.5) / Float(buffer.width) - 1
                    let y = 2 * (Float(row) + 0.5) / Float(buffer.height) - 1
                    let covered = volume.cameraInside
                        || VolumetricsReference.depths(of: mesh, transform: transform, x: x, y: y, scale: scale) != nil
                    if !covered { outside += 1 }
                }
            }
            XCTAssertGreaterThan(lit, 0, "\(id) \(lightID): the volume shows")
            XCTAssertEqual(outside, 0, "\(id) \(lightID): lit outside its volume")
            report += "\(id)\t\(lightID)\t\(volume.shape)\t\(volume.cameraInside)\t\(lit)\n"
        }
        print("Root volumetric lights through the scene camera (1920×1080, ultra):\n\(report)")
    }

    // MARK: - Helpers

    /// The camera the renderer draws `content` with, at its first frame.
    private static func frameCamera(_ content: SceneMetalContent) -> SceneFrameCamera {
        SceneCameraRigs.make(for: content).frameCamera(SceneCameraRigInput(
            sceneSize: content.size, aspect: content.size.x / content.size.y, time: 0, deltaTime: 0))
    }

    private struct StaticContext: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    private func decodedScene(_ id: String) throws -> (WEScene, URL) {
        let (directory, _) = try wallpaper(id)
        let data = try XCTUnwrap(FileManager.default.contents(atPath: directory.appending(path: "scene.json").path),
                                 "\(id): no loose scene.json")
        return (try decodeTolerant(WEScene.self, from: data), directory)
    }

    /// WE's assets and a wallpaper's own files, as the loader reads them.
    private struct Builder {
        let translator: ShaderVariantTranslator

        func scoped(to directory: URL) -> SceneEffectPlanBuilder {
            let roots = [directory, ShaderVariantTests.weAssets]
            let read = { (path: String) in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first }
            return SceneEffectPlanBuilder(translator: translator, readFile: read, loadTexture: { name, _ in
                guard let data = read("materials/\(name).tex") else { return nil }
                let parser = TEXParser(data: data)
                if let texture = parser.extractCompressedTexture() { return .dxt(texture) }
                return parser.extractImage().map { .image($0) }
            })
        }
    }

    private func makeBuilder() throws -> Builder {
        Builder(translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(),
                                                    cacheDirectory: scripts.appending(path: "variants")))
    }

    /// A content on one offscreen view, its clock stepped 1/60 s per draw.
    private final class Scene {
        let renderer: SceneMetalRenderer
        let view: MTKView
        private var now: CFTimeInterval = 1000

        init(content: SceneMetalContent, scripts: URL) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let size = VolumetricsLibraryTests.drawable
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            let services = SceneScriptServices(prelude: SceneScriptPrelude.load(),
                                               storage: SceneScriptStorage(directory: scripts),
                                               media: SceneScriptReplayMediaSource(), spectrum: { .silent })
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "volumetrics"))
            view.isPaused = true
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(content)
            waitForContent()
        }

        private func waitForContent() {
            waitUntil("the scene's content", timeout: 60) { renderer.hasContent }
        }

        func draw() {
            now += 1.0 / 60
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            RunLoop.main.run(until: Date())
        }

        func close() {
            renderer.releaseContent()
        }
    }
}
