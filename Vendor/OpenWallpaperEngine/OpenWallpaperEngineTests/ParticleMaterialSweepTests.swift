import XCTest
import Metal
import AppKit
@testable import OpenWallpaperEngine

/// Every particle system of every scene wallpaper in a local library is planned for WE's
/// particle shaders and its pipelines built, with and without a sprite sheet, refraction
/// included. A system none of whose stages builds would fall back to the built-in draw. Skipped
/// when the library is absent (CI). `OWE_LIBRARY` overrides the library root.
final class ParticleMaterialSweepTests: XCTestCase {
    func testEveryLibraryParticleMaterialBuilds() throws {
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(ParticleMaterialRenderer(device: device))
        let translator = ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil)
        let sheet = SpriteSheet(columns: 4, rows: 4, frames: 16, duration: 1)

        var systems = 0, pipelines = 0, refracting = 0
        var failures: [String] = []
        var fallbacks: [String] = []
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let wallpaper = library.appending(path: id, directoryHint: .isDirectory)
            guard let sceneData = FileManager.default.contents(atPath: wallpaper.appending(path: "scene.json").path),
                  let scene = try? JSONDecoder().decode(WEScene.self, from: sceneData) else { continue } // decoding is covered elsewhere
            let roots = [wallpaper, ShaderVariantTests.weAssets]
            let read: (String) -> Data? = { path in
                roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first
            }
            // Every texture the material names counts as found, so combos such as NORMALMAP are
            // the ones the wallpaper runs with.
            let builder = ParticleMaterialPlanBuilder(translator: translator, readFile: read,
                                                      loadTexture: { _, _ in .image(NSImage()) })
            for object in scene.objects {
                guard let particlePath = object.particle, let data = read(particlePath),
                      let system = try? JSONDecoder().decode(WEParticleSystem.self, from: data), // decoding is covered elsewhere
                      let material = system.material else { continue }
                systems += 1
                for spriteSheet in [nil, sheet] {
                    let label = "\(id) \(particlePath) \(system.renderer?.first?.name ?? "sprite")\(spriteSheet == nil ? "" : " sheet")"
                    do {
                        let plan = try builder.build(materialPath: material, renderer: system.renderer?.first,
                                                     flags: system.flags ?? 0, baseTexture: .image(NSImage()),
                                                     spriteSheet: spriteSheet)
                        XCTAssertTrue(renderer.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm), label)
                        var built = 0
                        for stage in plan.stages {
                            pipelines += 1
                            if stage.readsSceneSnapshot { refracting += 1 }
                            if let failure = renderer.pipelineFailure(stage, plan: plan, pixelFormat: .bgra8Unorm) {
                                failures.append("\(label) \(stage.geometry): \(failure)")
                            } else {
                                built += 1
                            }
                        }
                        if built == 0 { fallbacks.append(label) }
                    } catch {
                        failures.append("\(label): \(error)")
                    }
                }
            }
        }
        print("Particle material sweep: \(systems) systems, \(pipelines) pipelines (\(refracting) refracting), "
              + "\(failures.count) failures, \(fallbacks.count) fallbacks")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertTrue(fallbacks.isEmpty, "built-in draw: " + fallbacks.joined(separator: "\n"))
    }
}
