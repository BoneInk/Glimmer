import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Every 3D scene (perspective, or with model objects) and every scene with a Puppet Warp layer in
/// the library, drawn whole by the real loader and renderer (docs/models-plan.md §4.3 T) with the
/// user's shadows off, low, medium and high and the reflection setting on, and with shadows high
/// and the reflection off:
///
/// - no model or puppet falls back: every model object with a `.mdl` path has a plan with every
///   mesh of its `.mdl` that has triangles and a material, and every puppet layer has its mesh
///   plan (not its unwarped image);
/// - no frame has a NaN or an infinity: the scene target when it is a float target, the planar
///   reflection and the shadow atlas, and every posed bone of every model and puppet;
/// - no frame fails on the GPU or takes longer than 5 s;
/// - it reports the frame time (render thread and GPU, median of 30 frames at 1920×1080 after the
///   pipelines settle) and the counts of meshes, bones and draws (model meshes, shadow caster
///   draws, puppet meshes and reflected models a frame).
///
/// Roots: the Workshop folder, OpenWallpaperStorage and WE's default projects, or `OWE_LIBRARY`
/// (paths separated by ':'); skipped when none is present (CI). `OWE_MODEL_LIBRARY_ONLY` lists
/// folder names or Workshop ids; `OWE_MODEL_LIBRARY_OUT` names a file for the table;
/// `OWE_MODEL_LIBRARY_FRAMES` a folder for each variant's last frame and shadow atlas, raw.
final class ModelLibraryRenderTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-model-library-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    struct Variant {
        var name: String
        var shadows: GSLightingQuality
        var reflection: Bool
    }

    static let variants = [
        Variant(name: "shadows off", shadows: .disabled, reflection: true),
        Variant(name: "shadows low", shadows: .low, reflection: true),
        Variant(name: "shadows medium", shadows: .medium, reflection: true),
        Variant(name: "shadows high", shadows: .high, reflection: true),
        Variant(name: "high, reflection off", shadows: .high, reflection: false),
    ]

    struct Item {
        var name: String
        var directory: URL
        var perspective: Bool
        /// Model objects with a `.mdl` path.
        var models: Int
        /// Puppet Warp layers, by object id.
        var puppets: [String]
    }

    func testEveryLibrary3DSceneAndPuppetRendersWithoutFallbackOrNaN() throws {
        let roots = SceneTransform3DLibraryTests.roots
        try XCTSkipIf(roots.isEmpty, "wallpaper library not present")
        let only = Set((ProcessInfo.processInfo.environment["OWE_MODEL_LIBRARY_ONLY"] ?? "").split(separator: ",").map(String.init))
        let items = try Self.items(in: roots).filter { only.isEmpty || only.contains($0.name) }
        try XCTSkipIf(items.isEmpty, "no 3D scene or puppet in the library")
        var lines = ["scene\tvariant\tprojection\tmodels\tmeshes\tbones\tpuppets\tmodel draws/frame\tculled\tcaster draws/frame\t"
                     + "shadow maps\treflected\tpuppet draws/frame\tcpu ms (median)\tgpu ms (median / max)\ttarget\tsettled"]
        for item in items {
            for variant in Self.variants {
                try autoreleasepool {
                    lines.append(try render(item, variant))
                    print(lines.last!)
                }
            }
        }
        let report = lines.joined(separator: "\n")
        print("Model library render:\n\(report)")
        XCTContext.runActivity(named: "Model library render") { $0.add(XCTAttachment(string: report)) }
        if let path = ProcessInfo.processInfo.environment["OWE_MODEL_LIBRARY_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func render(_ item: Item, _ variant: Variant) throws -> String {
        var settings = SceneRenderSettings()
        settings.shadows = variant.shadows
        settings.reflection = variant.reflection
        settings.particleBudget = .unlimited
        let label = "\(item.name) [\(variant.name)]"
        let harness = try ModelSceneHarness(directory: item.directory, settings: settings, size: SIMD2(1920, 1080),
                                            storage: storage)
        defer { harness.close() }
        let content = harness.content

        // No fallback.
        let package = Self.package(in: item.directory)
        var meshes = 0, bones = 0
        var loaded: [String: MDLModel] = [:]
        for object in content.spatial.models {
            guard let path = object.authored.path else { continue }
            guard let plan = object.plan else {
                XCTFail("\(label): model \(object.id) \(object.name) (\(path)) falls back: no plan")
                continue
            }
            let mdl: MDLModel
            if let known = loaded[path] { mdl = known } else {
                mdl = try MDLModel.load(path: path, package: package, directory: item.directory)
                loaded[path] = mdl
            }
            let drawable = mdl.meshes.filter { $0.vertexCount > 0 && $0.indexCount > 0 && !$0.materials.isEmpty }.count
            XCTAssertEqual(plan.meshes.count, drawable, "\(label): model \(object.id) \(object.name) (\(path)) drops meshes")
            meshes += plan.meshes.count
            bones += plan.skeleton?.bones.count ?? 0
        }
        XCTAssertEqual(content.spatial.models.filter { $0.authored.path != nil }.count, item.models, "\(label): model objects")
        for id in item.puppets {
            guard let layer = content.layers.first(where: { $0.id == id }) else {
                XCTFail("\(label): puppet layer \(id) isn't in the content")
                continue
            }
            guard let puppet = layer.puppet else {
                XCTFail("\(label): puppet layer \(id) \(layer.name) falls back to its unwarped image")
                continue
            }
            meshes += 1
            bones += puppet.skeleton.bones.count
        }

        // Frames.
        let settled = try harness.settle()
        let models = harness.models
        let modelDraws = models?.drawsEncoded ?? 0
        let culled = models?.modelsCulled ?? 0
        let casterDraws = harness.renderer.shadowPass?.casterDraws ?? 0
        let puppetDraws = harness.renderer.puppetMeshDraws
        let frames = 30
        let timing = harness.run(frames: frames)
        let perFrame = { (delta: Int) in Double(delta) / Double(frames) }
        XCTAssertTrue(harness.gpuErrors.isEmpty, "\(label): \(harness.gpuErrors.prefix(3))")
        XCTAssertLessThan(harness.slowestFrame, 5, "\(label): a frame took \(harness.slowestFrame) s")

        // NaN and infinity.
        XCTAssertEqual(harness.posesAreFinite(), [], "\(label): posed bones that aren't finite")
        var target = "8-bit"
        if let scene = harness.renderer.lastSceneTarget, let bad = try ModelSceneHarness.nonFiniteCount(scene, device: harness.device) {
            target = "\(scene.pixelFormat == .rgba16Float ? "rgba16F" : "float")"
            XCTAssertEqual(bad, 0, "\(label): the scene target has \(bad) values that aren't finite")
        }
        if let reflection = harness.renderer.planarReflection?.texture,
           let bad = try ModelSceneHarness.nonFiniteCount(reflection, device: harness.device) {
            XCTAssertEqual(bad, 0, "\(label): the reflection has \(bad) values that aren't finite")
        }
        if let atlas = harness.renderer.shadowPass?.atlas.texture,
           let bad = try ModelSceneHarness.nonFiniteCount(atlas, device: harness.device) {
            XCTAssertEqual(bad, 0, "\(label): the shadow atlas has \(bad) values that aren't finite")
        }
        if let folder = ProcessInfo.processInfo.environment["OWE_MODEL_LIBRARY_FRAMES"] {
            try saveFrames(harness, to: URL(fileURLWithPath: folder), name: "\(item.name)-\(variant.name)")
        }
        let reflected = harness.renderer.planarReflection?.drawnModels.count ?? 0
        if !variant.reflection { XCTAssertEqual(reflected, 0, "\(label): nothing is reflected with the setting off") }
        if variant.shadows == .disabled {
            XCTAssertEqual((harness.renderer.shadowPass?.casterDraws ?? 0) - casterDraws, 0, "\(label): no casters with shadows off")
        }

        return String(format: "%@\t%@\t%@\t%d\t%d\t%d\t%d\t%.1f\t%.1f\t%.1f\t%d\t%d\t%.1f\t%.2f\t%.2f / %.2f\t%@\t%@",
                      item.name, variant.name, item.perspective ? "persp" : "ortho", item.models, meshes, bones,
                      item.puppets.count, perFrame((models?.drawsEncoded ?? 0) - modelDraws),
                      perFrame((models?.modelsCulled ?? 0) - culled),
                      perFrame((harness.renderer.shadowPass?.casterDraws ?? 0) - casterDraws),
                      harness.renderer.shadowPass?.lastMapCount ?? 0, reflected,
                      perFrame(harness.renderer.puppetMeshDraws - puppetDraws), timing.cpuMedian, timing.gpuMedian,
                      timing.gpuMax, target, settled ? "yes" : "no")
    }

    /// The last frame's bytes and the shadow atlas's (`OWE_MODEL_LIBRARY_FRAMES`), raw, so two
    /// builds' frames can be compared byte for byte (an optimisation must draw the same).
    private func saveFrames(_ harness: ModelSceneHarness, to folder: URL, name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let frame = harness.renderer.sharedFrame {
            try Data(try TextureUploadTests.read(frame, device: harness.device)).write(to: folder.appending(path: "\(name).frame"))
        }
        if let atlas = harness.renderer.shadowPass?.atlas.texture, atlas.pixelFormat == .depth32Float {
            let queue = try XCTUnwrap(harness.device.makeCommandQueue())
            let rowBytes = atlas.width * 4
            let buffer = try XCTUnwrap(harness.device.makeBuffer(length: rowBytes * atlas.height, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
            blit.copy(from: atlas, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: atlas.width, height: atlas.height, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * atlas.height)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            try Data(bytes: buffer.contents(), count: buffer.length).write(to: folder.appending(path: "\(name).atlas"))
        }
    }

    // MARK: - The library

    private static func package(in directory: URL) -> PKGParser? {
        let url = directory.appending(path: "scene.pkg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try PKGParser(url: url) } catch {
            XCTFail("\(url.path): \(error)")
            return nil
        }
    }

    /// Every scene once (by Workshop id, the first root first) that is perspective, has a model
    /// object or a puppet layer.
    static func items(in roots: [URL]) throws -> [Item] {
        var seen = Set<String>(), items: [Item] = []
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                // `try?`: a folder without a readable project.json isn't a wallpaper.
                guard let data = try? Data(contentsOf: directory.appending(path: "project.json")) else { continue }
                let text = Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8)
                guard let json = try? JSONSerialization.jsonObject(with: text, options: [.json5Allowed]) as? [String: Any] else { continue }
                let workshopID = json["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                // WE's default projects name no type: their file is a scene's `.json`. Workshop assets
                // (effects, models) name none either, and aren't wallpapers.
                let isAsset = (json["category"] as? String)?.lowercased() == "asset"
                let type = (json["type"] as? String)?.lowercased()
                    ?? (!isAsset && (json["file"] as? String)?.lowercased().hasSuffix(".json") == true ? "scene" : "")
                guard type == "scene" else { continue }
                let package = Self.package(in: directory)
                let read = { (file: String) -> Data? in
                    if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
                    return package?.extractFile(named: file)
                }
                guard let file = read(json["file"] as? String ?? "scene.json") else { continue }
                let scene: WEScene
                do { scene = try decodeTolerant(WEScene.self, from: file) } catch {
                    XCTFail("\(name): its scene doesn't decode: \(error)")
                    continue
                }
                let models = scene.objects.filter { $0.model?.path != nil }.count
                var puppets: [String] = []
                for object in scene.objects {
                    // Optional: an object whose model can't be read has no rig to check.
                    guard let image = object.image, let modelData = read(image),
                          let model = try? decodeTolerant(WEModel.self, from: modelData), model.puppet != nil else { continue }
                    puppets.append(String(object.id ?? -1))
                }
                let perspective = scene.general.projection.isPerspective
                guard perspective || models > 0 || !puppets.isEmpty else { continue }
                items.append(Item(name: name, directory: directory, perspective: perspective, models: models, puppets: puppets))
            }
        }
        return items
    }
}
