import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// The library sweep for models (docs/models-plan.md §4.3 M5, M8): every mesh of every model object
/// in every scene of the local library and of WE's default projects is planned through its
/// material (`ModelMaterialPlanBuilder`, the scene's own light budget) with the user's shadows off,
/// low, medium and high, its pipeline compiled for a pass with depth, and drawn through
/// `SceneModelRenderer` with the cleared shadow atlas; with shadows on, every opaque mesh under a
/// shadowed budget has a shadow variant, which draws into a shadow map. A material that needs an
/// engine feature that doesn't exist yet is counted by reason, not failed. Skipped without the
/// library (CI); `OWE_LIBRARY` overrides it and `OWE_WE_INSTALL` WE's install.
final class ModelMaterialSweepTests: XCTestCase {
    private struct Tally {
        var scenes = 0, objects = 0, meshes = 0, planned = 0, drawn = 0, casters = 0, casterDraws = 0
        var unsupported: [String: Int] = [:]
        var failures: [String] = []
    }

    func testEveryLibraryModelMeshBuildsAPipelineAndDraws() throws {
        let assets = ShaderVariantTests.weAssets
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.path), "WE assets not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let steam = "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps"
        let install = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_WE_INSTALL"] ?? "\(steam)/common/wallpaper_engine")
        let defaults = install.appending(path: "projects/defaultprojects", directoryHint: .isDirectory)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        let shadowPass = try XCTUnwrap(SceneShadowPass(device: device, archive: nil))
        let depthStates = try XCTUnwrap(SceneDepthStates(device: device))
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-model-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let checkerboard = try LibrarySweepTests.checkerboard(device: device)
        let loader = MTKTextureLoader(device: device)

        var directories = try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
            .map { library.appending(path: $0, directoryHint: .isDirectory) }
        if FileManager.default.fileExists(atPath: defaults.path) {
            directories += try FileManager.default.contentsOfDirectory(atPath: defaults.path).sorted()
                .map { defaults.appending(path: $0, directoryHint: .isDirectory) }
        }
        var tallies: [(GSLightingQuality, Tally)] = []
        for shadows in [GSLightingQuality.disabled, .low, .medium, .high] {
            var tally = Tally()
            for directory in directories {
                try autoreleasepool {
                    try sweep(directory, shadows: shadows.level, assets: assets, translator: translator, renderer: renderer,
                              shadowPass: shadowPass, depthStates: depthStates, device: device, queue: queue,
                              checkerboard: checkerboard, loader: loader, tally: &tally)
                }
            }
            tallies.append((shadows, tally))
        }

        var report = ""
        for (shadows, tally) in tallies {
            report += "Model material sweep, shadows \(shadows): \(tally.scenes) scenes with models, \(tally.objects) model objects, "
                + "\(tally.meshes) meshes, \(tally.planned) planned, \(tally.drawn) drawn, \(tally.casters) casting "
                + "(\(tally.casterDraws) shadow draws), \(tally.unsupported.values.reduce(0, +)) unsupported, "
                + "\(tally.failures.count) failures\n"
            for (reason, count) in tally.unsupported.sorted(by: { $0.value > $1.value }) { report += "  unsupported [\(count)] \(reason)\n" }
            for failure in tally.failures { report += "  \(failure)\n" }
        }
        print(report)
        XCTContext.runActivity(named: "Model material sweep summary") { $0.add(XCTAttachment(string: report)) }
        for (shadows, tally) in tallies {
            XCTAssertGreaterThan(tally.meshes, 0, "no library model was found")
            XCTAssertEqual(tally.failures.count, 0, "shadows \(shadows): \(report)")
            XCTAssertEqual(tally.planned, tallies[0].1.planned, "shadows \(shadows) plan as many meshes as without")
            XCTAssertEqual(tally.drawn, tally.planned, "shadows \(shadows)")
            if shadows != .disabled { XCTAssertGreaterThan(tally.casterDraws, 0, "shadows \(shadows) draw casters") }
        }
    }

    private func sweep(_ directory: URL, shadows: Int, assets: URL, translator: ShaderVariantTranslator,
                       renderer: SceneModelRenderer, shadowPass: SceneShadowPass, depthStates: SceneDepthStates, device: MTLDevice,
                       queue: MTLCommandQueue, checkerboard: MTLTexture, loader: MTKTextureLoader, tally: inout Tally) throws {
        let packageURL = directory.appending(path: "scene.pkg")
        let package = FileManager.default.fileExists(atPath: packageURL.path) ? try PKGParser(url: packageURL) : nil
        let read = { (path: String) -> Data? in
            if let data = package?.extractFile(named: path) { return data }
            for root in [directory, assets] {
                if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
            }
            return nil
        }
        guard let sceneData = read("scene.json"), let scene = try? decodeTolerant(WEScene.self, from: sceneData), // not a scene
              scene.objects.contains(where: { $0.model?.path != nil }) else { return }
        tally.scenes += 1
        let name = directory.lastPathComponent
        let lighting = SceneLightingSettings(scene.general, in: EffectGraphTests.FixedValues())
        let materials = ModelMaterialPlanBuilder(
            translator: translator, readFile: read,
            loadTexture: { texture, _ in
                for path in ["materials/\(texture).tex", "\(texture).tex"] {
                    if let data = read(path), let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            },
            sceneEngineCombos: SceneEngineCombos(sceneOrtho: !scene.general.projection.isPerspective,
                                                 lightBudget: shadows == 0 ? lighting.lightConfig?.withShadowsDisabled
                                                     : lighting.lightConfig,
                                                 shadowQuality: shadows))
        var loaded: [String: MDLModel] = [:]
        for object in scene.objects {
            guard let model = object.model, let path = model.path else { continue }
            tally.objects += 1
            let mdl: MDLModel
            if let cached = loaded[path] {
                mdl = cached
            } else {
                do {
                    mdl = try MDLModel.load(path: path, package: package, directory: directory)
                    loaded[path] = mdl
                } catch {
                    tally.failures.append("\(name) \(path): \(error)")
                    continue
                }
            }
            var meshes: [SceneModelPlan.Mesh] = []
            let bones = mdl.skeleton?.bones.count ?? 0
            for (index, mesh) in mdl.meshes.enumerated() where mesh.vertexCount > 0 && mesh.indexCount > 0 {
                tally.meshes += 1
                let materialPath = mesh.materials[min(max(model.skin, 0), mesh.materials.count - 1)]
                do {
                    let plan = try materials.build(materialPath: materialPath,
                                                   mesh: ModelMeshCombos(mesh: mesh, bones: bones, morphTargets: false))
                    meshes.append(SceneModelPlan.Mesh(index: index, material: plan, format: mesh.format, vertexData: mesh.vertexData,
                                                      indexData: mesh.indexData, usesUInt32Indices: mesh.usesUInt32Indices,
                                                      indexCount: mesh.indexCount))
                    tally.planned += 1
                } catch ModelMaterialPlanError.unsupported(let reason) {
                    tally.unsupported[reason.replacingOccurrences(of: #"_\d+_a$"#, with: "_<id>_a", options: .regularExpression),
                                      default: 0] += 1
                } catch {
                    tally.failures.append("\(name) \(path) mesh \(index) \(materialPath): \(error)")
                }
            }
            guard !meshes.isEmpty else { continue }
            let plan = SceneModelPlan(path: path, meshes: meshes, bounds: mdl.bounds, skeleton: mdl.skeleton,
                                      clips: mdl.animations ?? [], attachments: mdl.attachments ?? [])
            guard renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm), shadowPass.waitUntilReady(plan) else {
                tally.failures.append("\(name) \(path): a pipeline failed")
                continue
            }
            let casting = meshes.filter { $0.material.isOpaque && $0.material.shadowCaster != nil }.count
            if shadows > 0, materials.sceneEngineCombos.castsShadows,
               casting != meshes.filter(\.material.isOpaque).count {
                tally.failures.append("\(name) \(path): \(casting) of the opaque meshes have a shadow variant")
            }
            tally.casters += casting
            let before = shadowPass.casterDraws
            let drawn = try draw(plan, id: "\(name)|\(object.id ?? -1)", renderer: renderer, shadowPass: shadowPass,
                                 depthStates: depthStates, device: device, queue: queue, checkerboard: checkerboard, loader: loader)
            tally.casterDraws += shadowPass.casterDraws - before
            if casting > 0, !plan.isTranslucent, shadowPass.casterDraws == before {
                tally.failures.append("\(name) \(path): its shadow variants drew nothing")
            }
            if drawn == meshes.count { tally.drawn += drawn } else {
                tally.failures.append("\(name) \(path): drew \(drawn) of \(meshes.count) meshes")
            }
        }
    }

    /// Draws `plan` through a camera looking at its box, after drawing it into a shadow map seen
    /// from that camera; returns the meshes encoded.
    private func draw(_ plan: SceneModelPlan, id: String, renderer: SceneModelRenderer, shadowPass: SceneShadowPass,
                      depthStates: SceneDepthStates, device: MTLDevice, queue: MTLCommandQueue, checkerboard: MTLTexture,
                      loader: MTKTextureLoader) throws -> Int {
        let object = SceneModelObject(id: id, name: id, order: 0, authored: WESceneModel(source: .path(plan.path)), plan: plan)
        renderer.setContent([object], content: SceneMetalContent(size: SIMD2(256, 256), layers: [], particleSystems: [],
                                                                 bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                                                           tint: SIMD3(repeating: 1))))
        let bounded = plan.bounds != .unbounded
        let centre = bounded ? (plan.bounds.min + plan.bounds.max) / 2 : .zero
        let radius = bounded ? max(simd_length(plan.bounds.max - plan.bounds.min) / 2, 0.01) : 1
        let eye = centre + SIMD3(0, 0, radius * 3)
        let camera = SceneFrameCamera(view: SceneCamera.lookAt(eye: eye, center: centre, up: SIMD3(0, 1, 0)),
                                      projection: SceneCamera.perspective(fovDegrees: 50, aspect: 1, near: radius * 0.1, far: radius * 10),
                                      eye: eye, forward: simd_normalize(centre - eye), up: SIMD3(0, 1, 0), fieldOfView: 50)
        var frame = BuiltinFrameContext(time: 1)
        frame.camera = camera
        frame.eyePosition = eye
        let assetTexture = { (_: String, source: SceneMetalTextureSource) -> MTLTexture? in
            guard case .image(let image) = source,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return checkerboard }
            return (try? loader.newTexture(cgImage: cg, options: [.SRGB: false])) ?? checkerboard // test texture
        }
        var shadows = SceneShadowFrame(maps: [SceneShadowMap(kind: .spot, lightID: "sweep", size: 256,
                                                             renderViews: [camera.viewProjection], transformIndex: 0)])
        shadows.layOut(minimumExtent: .zero)
        let target = try ModelRenderTests.target(device: device, size: 256)
        let depth = SceneDepthBuffer(device: device)
        XCTAssertTrue(depth.prepare(width: 256, height: 256, sampleCount: 1))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        depth.attach(to: pass, clear: true)
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        shadowPass.setContent()
        let atlas = shadowPass.encode(shadows, casters: [SceneShadowPass.Caster(model: object, world: matrix_identity_float4x4)],
                                      models: renderer, frame: frame, values: EffectGraphTests.FixedValues(),
                                      assetTexture: assetTexture, commandBuffer: buffer)
        let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
        renderer.draw(object, SceneModelDraw(
            world: matrix_identity_float4x4, camera: camera, frame: frame, values: EffectGraphTests.FixedValues(),
            pixelFormat: .bgra8Unorm, sampleCount: 1, depth: depthStates, mipMappedFrameBuffer: checkerboard,
            assetTexture: assetTexture, layerComposite: { _ in checkerboard }, shadowAtlas: atlas, planarReflection: checkerboard),
            encoder: encoder, commandBuffer: buffer)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error, id)
        return renderer.meshDraws[id] ?? 0
    }
}
