import XCTest
import Metal
import MetalKit
@testable import OpenWallpaperEngine

/// M8 coverage sweep: every effect on every object of every scene wallpaper in a local library is
/// planned, translated and run through the effect graph. Skipped when the library or the WE
/// install is absent (CI). `OWE_LIBRARY` overrides the library root.
final class LibrarySweepTests: XCTestCase {
    static var libraryRoot: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage")
    }

    private struct Failure {
        let wallpaper: String
        let effect: String
        let cause: String
        let detail: String
    }

    func testEveryLibraryEffectPlansTranslatesAndRuns() throws {
        let assets = ShaderVariantTests.weAssets
        let library = Self.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: assets.path), "WE install not present")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cache = FileManager.default.temporaryDirectory.appending(path: "owe-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) } // scratch cleanup
        // Not the user's pipeline archive: tests must not write to the app's caches.
        let renderer = try XCTUnwrap(EffectGraphRenderer(device: device, pipelineArchiveDirectory: cache.appending(path: "archives")))
        defer { renderer.pipelineArchive?.flush() } // runs before the cleanup above deletes its directory
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: cache)
        let input = try Self.checkerboard(device: device)
        let loader = MTKTextureLoader(device: device)

        var wallpapers = 0, instances = 0, passes = 0
        var files = Set<String>(), variants = Set<String>()
        var failures: [Failure] = []

        let directories = try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
        for id in directories {
            let wallpaper = library.appending(path: id, directoryHint: .isDirectory)
            let sceneURL = wallpaper.appending(path: "scene.json")
            guard let sceneData = FileManager.default.contents(atPath: sceneURL.path) else { continue }
            wallpapers += 1
            let scene: WEScene
            do {
                scene = try JSONDecoder().decode(WEScene.self, from: sceneData)
            } catch {
                failures.append(Failure(wallpaper: id, effect: "scene.json", cause: "scene decode", detail: "\(error)"))
                continue
            }
            let roots = [wallpaper, assets]
            let builder = SceneEffectPlanBuilder(
                translator: translator,
                readFile: { path in
                    for root in roots {
                        if let data = FileManager.default.contents(atPath: root.appending(path: path).path) { return data }
                    }
                    return nil
                },
                loadTexture: { name, materialPath in
                    let effectDirectory = materialPath.split(separator: "/").prefix(2).joined(separator: "/")
                    for root in roots {
                        for path in ["materials/\(name).tex", "\(name).tex", "\(effectDirectory)/materials/\(name).tex"] {
                            if let data = FileManager.default.contents(atPath: root.appending(path: path).path),
                               let image = TEXParser(data: data).extractImage() { return .image(image) }
                        }
                    }
                    return nil
                })

            for (objectIndex, object) in scene.objects.enumerated() {
                for effect in object.effects ?? [] {
                    instances += 1
                    files.insert(effect.file)
                    let label = "\(object.name ?? "#\(objectIndex)") / \(effect.file)"
                    let plan: SceneEffectPlan
                    do {
                        plan = try builder.build(effect)
                    } catch {
                        let detail = String(describing: error)
                        failures.append(Failure(wallpaper: id, effect: label, cause: Self.cause(detail), detail: detail))
                        continue
                    }
                    let renderPasses = plan.passes.filter { if case .render = $0.command { return true } else { return false } }
                    passes += renderPasses.count
                    for pass in renderPasses {
                        if pass.variant == nil {
                            failures.append(Failure(wallpaper: id, effect: label, cause: "pass without variant", detail: ""))
                        } else {
                            variants.insert(pass.variantKey)
                        }
                    }
                    guard !renderPasses.isEmpty else { continue }

                    let failedBefore = renderer.failedPipelineCount
                    let buffer = try XCTUnwrap(queue.makeCommandBuffer())
                    let context = EffectGraphRenderer.Context(
                        frame: BuiltinFrameContext(time: 1.5), values: EffectGraphTests.FixedValues(),
                        assetTexture: { _, source in
                            guard case .image(let image) = source,
                                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                            return try? loader.newTexture(cgImage: cg, options: [.SRGB: false]) // test texture; nil is reported below
                        },
                        sceneSnapshot: input, layerColor: SIMD3(1, 1, 1), layerAlpha: 1)
                    if !renderer.waitUntilReady([plan], width: input.width, height: input.height) {
                        failures.append(Failure(wallpaper: id, effect: label, cause: "pipelines still compiling after 60 s", detail: ""))
                    }
                    let output = renderer.apply([plan], to: input, layerID: "\(id)|\(objectIndex)|\(effect.file)",
                                                context: context, commandBuffer: buffer)
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    if renderer.failedPipelineCount > failedBefore {
                        let detail = renderPasses.compactMap { pass -> String? in
                            guard let variant = pass.variant else { return nil }
                            do {
                                _ = try device.makeLibrary(source: variant.vertexMSL, options: nil)
                                _ = try device.makeLibrary(source: variant.fragmentMSL, options: nil)
                                return nil
                            } catch { return "\(error)" }
                        }.joined(separator: "\n")
                        failures.append(Failure(wallpaper: id, effect: label, cause: "pipeline: " + Self.cause(detail), detail: detail))
                    } else if output == nil, plan.passes.contains(where: { $0.target == nil && $0.variant != nil }) {
                        failures.append(Failure(wallpaper: id, effect: label, cause: "apply returned nil", detail: ""))
                    }
                    if let error = buffer.error {
                        failures.append(Failure(wallpaper: id, effect: label, cause: "command buffer", detail: "\(error)"))
                    }
                    renderer.releaseTargets()
                }
            }
        }

        var byCause: [String: [Failure]] = [:]
        for failure in failures { byCause[failure.cause, default: []].append(failure) }
        var report = """
        Library sweep: \(wallpapers) wallpapers, \(instances) effect instances, \(files.count) distinct effect files, \
        \(passes) render passes, \(variants.count) distinct variants, \(failures.count) failures
        """
        for (cause, group) in byCause.sorted(by: { $0.value.count > $1.value.count }) {
            report += "\n[\(group.count)] \(cause)"
            for failure in group {
                report += "\n    \(failure.wallpaper) \(failure.effect)"
                if !failure.detail.isEmpty { report += "\n        " + failure.detail.prefix(400).replacingOccurrences(of: "\n", with: "\n        ") }
            }
        }
        print(report)
        XCTContext.runActivity(named: "Library sweep summary") { activity in
            activity.add(XCTAttachment(string: report))
        }
        XCTAssertEqual(failures.count, 0, report)
    }

    /// A failure's cause without paths and line numbers, so identical problems group together.
    static func cause(_ detail: String) -> String {
        let line = detail.split(separator: "\n").first { $0.contains("ERROR") || $0.contains("error:") }
            .map(String.init) ?? String(detail.split(separator: "\n").first ?? "")
        var result = line
        for pattern in [#"ERROR: [^:]*:\d+: "#, #"program_source:\d+:\d+: "#, #"[\w./-]+\.(frag|vert|json|tex)\b"#] {
            result = result.replacingOccurrences(of: pattern, with: "…", options: .regularExpression)
        }
        return String(result.prefix(160))
    }

    static func checkerboard(device: MTLDevice, size: Int = 256) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size where (x / 32 + y / 32) % 2 == 0 {
            let i = (y * size + x) * 4
            pixels[i] = 20; pixels[i + 1] = 40; pixels[i + 2] = 200
        } }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: pixels, bytesPerRow: size * 4)
        return texture
    }
}
