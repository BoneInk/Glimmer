import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// The library sweep for image layers: every image object's own material in every scene wallpaper
/// of a local library is planned, translated, compiled and drawn through `ImageMaterialRenderer`.
/// Materials that need an engine feature that doesn't exist yet are counted, not failed: those
/// layers draw natively. Lit (`LIGHTING`) materials draw with no light budget, as in a scene
/// without `lightconfig`. Skipped without the library (CI); `OWE_LIBRARY` overrides it.
final class ImageMaterialSweepTests: XCTestCase {
    func testEveryLibraryImageMaterialPlansCompilesAndDraws() throws {
        let assets = ShaderVariantTests.weAssets
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.path), "WE assets not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let renderer = try XCTUnwrap(ImageMaterialRenderer(device: device, archive: nil))
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-image-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let image = try LibrarySweepTests.checkerboard(device: device)
        let snapshot = try LibrarySweepTests.checkerboard(device: device)
        let loader = MTKTextureLoader(device: device)

        var wallpapers = 0, layers = 0, drawn = 0, withoutImage = 0
        var unsupported: [String: Int] = [:]
        var failures: [String] = []

        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let wallpaper = library.appending(path: id, directoryHint: .isDirectory)
            guard let sceneData = FileManager.default.contents(atPath: wallpaper.appending(path: "scene.json").path) else { continue }
            wallpapers += 1
            let scene: WEScene
            do {
                scene = try JSONDecoder().decode(WEScene.self, from: sceneData)
            } catch {
                failures.append("\(id) scene.json: \(error)")
                continue
            }
            let roots = [wallpaper, assets]
            let read = { (path: String) -> Data? in
                for root in roots {
                    if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                }
                return nil
            }
            let builder = ImageMaterialPlanBuilder(translator: translator, readFile: read, loadTexture: { name, _ in
                for path in ["materials/\(name).tex", "\(name).tex"] {
                    if let data = read(path), let image = TEXParser(data: data).extractImage() { return .image(image) }
                }
                return nil
            })
            for object in scene.objects {
                guard let modelPath = object.image, let modelData = read(modelPath),
                      let model = try? decodeTolerant(WEModel.self, from: modelData), // an undecodable model has no layer to draw; skip it
                      let materialPath = model.material else { continue }
                layers += 1
                let label = "\(id) \(object.name ?? "#\(object.id ?? -1)") \(materialPath)"
                let plan: ImageMaterialPlan
                do {
                    guard let built = try builder.build(materialPath: materialPath, colorBlendMode: object.colorBlendMode,
                                                         clampUVs: object.clampuvs) else {
                        withoutImage += 1
                        continue
                    }
                    plan = built
                } catch ImageMaterialPlanError.unsupported(let reason) {
                    unsupported[reason, default: 0] += 1
                    continue
                } catch {
                    failures.append("\(label): \(error)")
                    continue
                }
                guard renderer.waitUntilReady(plan, pixelFormat: .bgra8Unorm) else {
                    let detail = plan.pass.variant.map { variant -> String in
                        do {
                            _ = try device.makeLibrary(source: variant.vertexMSL, options: nil)
                            _ = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
                            return "pipeline"
                        } catch { return "\(error)".prefix(400).description }
                    } ?? "no variant"
                    failures.append("\(label): \(detail)")
                    continue
                }
                let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                let target = try Self.target(device: device)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                let encoder = try XCTUnwrap(buffer.makeRenderCommandEncoder(descriptor: pass))
                let ok = renderer.draw(plan, ImageMaterialRenderer.Draw(
                    layerID: label, quad: SceneQuadGeometry(center: SIMD2(128, 128), axisX: SIMD2(200, 0), axisY: SIMD2(0, 120)),
                    sceneSize: SIMD2(256, 256), color: SIMD3(1, 1, 1), alpha: 1, brightness: 1, texture: image,
                    contentSize: nil, uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1), sceneSnapshot: snapshot,
                    mipMappedFrameBuffer: snapshot, frame: BuiltinFrameContext(time: 1.5), values: EffectGraphTests.FixedValues(),
                    assetTexture: { _, source in
                        guard case .image(let image) = source,
                              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                        return try? loader.newTexture(cgImage: cg, options: [.SRGB: false]) // test texture; nil fails the draw below
                    }), pixelFormat: .bgra8Unorm, encoder: encoder, commandBuffer: buffer)
                encoder.endEncoding()
                buffer.commit()
                buffer.waitUntilCompleted()
                if !ok { failures.append("\(label): draw refused") } else { drawn += 1 }
                if let error = buffer.error { failures.append("\(label): command buffer \(error)") }
            }
        }

        var report = "Image material sweep: \(wallpapers) wallpapers, \(layers) image layers, \(drawn) drawn through their material, "
            + "\(withoutImage) without an image, \(unsupported.values.reduce(0, +)) unsupported, \(failures.count) failures"
        for (reason, count) in unsupported.sorted(by: { $0.value > $1.value }) { report += "\n  unsupported [\(count)] \(reason)" }
        for failure in failures { report += "\n  \(failure)" }
        print(report)
        XCTContext.runActivity(named: "Image material sweep summary") { $0.add(XCTAttachment(string: report)) }
        XCTAssertEqual(failures.count, 0, report)
    }

    private static func target(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }
}
