import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The library's lit image layers (docs/lighting-plan.md §1.5: every image object whose material
/// sets `LIGHTING` or `REFLECTION`), loaded by the real loader and drawn headlessly by the real
/// renderer, post-processing off:
///
/// - none falls back to the native draw: each has its material plan, and a layer with effects
///   has WE's prelighting pass (A4);
/// - the renderer draws them through their material every frame once the pipelines are ready,
///   and runs the prelighting passes;
/// - One piece girls' `f1`, lit by 4 tubes, is brighter at the tubes than between them, measured
///   against the same frame without its lights (only the ambient colour), which divides the image out;
/// - the frame's GPU time is reported.
///
/// Skipped when the library is absent (CI); roots as `LightingLibraryDecodeTests`.
final class LitLayerLibraryTests: XCTestCase {
    private static let frames = 30
    private static let drawable = SIMD2(480, 270)
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-lit-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testEveryLitLayerDrawsThroughItsMaterial() throws {
        _ = try Fixtures.assets()
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        let scenes = try Self.litScenes(in: roots)
        let ids = Set(scenes.map(\.id))
        for expected in ["3270035750", "3803167460", "2515150033", "2370927443"] {
            XCTAssertTrue(ids.contains(expected), "\(expected)'s lit layers weren't found")
        }
        var report = "scene\tlit layers\tprelit\tmaterial draws/frame\tprelit draws/frame\tGPU p50 ms\n"
        for scene in scenes { report += try sweep(scene) + "\n" }
        print("Lit image layers (\(Self.frames) frames, drawable \(Self.drawable.x)×\(Self.drawable.y)):\n\(report)")
    }

    /// `f1`'s 4 vertical tubes (x ≈ 0, 641, 1282, 1917, at z = 250 with radius 500): the lit
    /// frame over the ambient-only one is highest at the tubes and lowest halfway between them.
    func testOnePieceGirlsIsLitByItsTubes() throws {
        _ = try Fixtures.assets()
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        let item = try XCTUnwrap(try Self.litScenes(in: roots).first { $0.id == "3270035750" })
        let lit = try frame(of: item, lights: true)
        let unlit = try frame(of: item, lights: false)
        let width = Self.drawable.x, height = Self.drawable.y
        // The mean ratio of a 3-pixel column band over the middle half of the height.
        func ratio(atScene x: Float) -> Float {
            let column = min(max(Int(x / 1920 * Float(width)), 1), width - 2)
            var sum: Float = 0, count: Float = 0
            for y in (height / 4)..<(3 * height / 4) {
                for c in (column - 1)...(column + 1) {
                    let i = (y * width + c) * 4
                    let before = (0..<3).map { Float(unlit[i + $0]) }.reduce(0, +)
                    guard before > 30 else { continue }
                    sum += (0..<3).map { Float(lit[i + $0]) }.reduce(0, +) / before
                    count += 1
                }
            }
            return count > 0 ? sum / count : 0
        }
        let atTubes = [641, 1282].map { ratio(atScene: $0) }
        let between = [320, 961, 1600].map { ratio(atScene: $0) }
        print("One piece girls lit/unlit: at the tubes \(atTubes), between them \(between)")
        XCTAssertGreaterThan(atTubes.min()!, between.max()! * 1.5, "the tubes' bands")
    }

    /// The Knight 2515150033 (test-risks LF2): its legacy light 29 has scripts on `intensity`
    /// (`1 + 0.3 sin 7.3t + 0.2 sin 9.8t`) and on `origin` (y = 500 + 200 sin 0.78t, z = 500 +
    /// 200 sin t). Every frame's `g_LightsColorRadius[0]` and `g_LightsPosition[0].z` follow them.
    func testKnightsScriptedLegacyLightFlickersAndMovesInDepth() throws {
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        let item = try XCTUnwrap(try Self.litScenes(in: roots).first { $0.id == "2515150033" })
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        let content = try XCTUnwrap(model.metalContent())
        defer { Fixtures.removeStoredSettings(for: item.directory) }
        let scene = try Scene(content: content, services: services(), settings: SceneRenderSettings.headless)
        defer { scene.close() }
        let probe = SceneDrawProbe()
        scene.renderer.drawProbe = probe
        var intensities = Set<Float>(), depths: [Float] = []
        for _ in 0..<40 {
            scene.draw(step: 0.1)
            let arrays = try XCTUnwrap(probe.lighting?.arrays)
            let colorRadius = try XCTUnwrap(arrays["g_LightsColorRadius"]), position = try XCTUnwrap(arrays["g_LightsPosition"])
            // Colour 0.72157 0.35294 0.14902 × intensity, radius 2048.
            let intensity = colorRadius[0] / 0.72157
            XCTAssertEqual(colorRadius[3], 2048)
            XCTAssertEqual(colorRadius[1] / 0.35294, intensity, accuracy: 1e-3)
            XCTAssertTrue((0.5...1.5).contains(intensity), "intensity \(intensity) outside the script's range")
            XCTAssertTrue((299...701).contains(position[2]), "z \(position[2]) outside 500 ± 200")
            intensities.insert((intensity * 1000).rounded())
            depths.append(position[2])
        }
        XCTAssertGreaterThan(intensities.count, 10, "the intensity script flickers the light")
        XCTAssertGreaterThan((depths.max() ?? 0) - (depths.min() ?? 0), 100, "origin.z follows the script: \(depths)")
    }

    // MARK: - One scene

    private func sweep(_ item: Item) throws -> String {
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        guard let content = model.metalContent() else {
            XCTFail("\(item.id): no content")
            return "\(item.id)\tno content"
        }
        defer { Fixtures.removeStoredSettings(for: item.directory) }
        var prelit = 0
        for (id, hasEffects) in item.litLayers {
            guard let layer = content.layers.first(where: { $0.id == id }) else {
                XCTFail("\(item.id) layer \(id): not in the content")
                continue
            }
            guard let plan = layer.imageMaterial else {
                XCTFail("\(item.id) layer \(id) (\(layer.name)): draws natively")
                continue
            }
            XCTAssertEqual(plan.prelighting != nil, hasEffects && !layer.weEffects.isEmpty,
                           "\(item.id) layer \(id): prelit only with effects")
            if plan.prelighting != nil { prelit += 1 }
        }
        let scene = try Scene(content: content, services: services(), settings: SceneRenderSettings.headless)
        defer { scene.close() }
        let renderer = scene.renderer
        let litIDs = item.litLayers.map(\.id)
        scene.settle(litLayers: litIDs, prelitDraws: prelit)
        let drawsBefore = renderer.imageMaterialDraws
        let prelitBefore = renderer.imageMaterialPrelitDraws
        let fallbacksBefore = scene.fallbacks(of: litIDs)
        var gpuTimes: [Double] = []
        for _ in 0..<Self.frames {
            scene.draw()
            if let buffer = renderer.lastCommandBuffer { gpuTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
        }
        let draws = Double(renderer.imageMaterialDraws - drawsBefore) / Double(Self.frames)
        let prelitDraws = Double(renderer.imageMaterialPrelitDraws - prelitBefore) / Double(Self.frames)
        // Scripts may hide or clone layers; every lit layer shown must draw through its material,
        // each one in every frame.
        XCTAssertGreaterThanOrEqual(draws, Double(item.litLayers.count), "\(item.id): lit layers drew natively")
        let fallbacks = scene.fallbacks(of: litIDs).filter { $0.value > (fallbacksBefore[$0.key] ?? 0) }
        XCTAssertTrue(fallbacks.isEmpty, "\(item.id): lit layers \(fallbacks.keys.sorted()) drew natively")
        XCTAssertGreaterThanOrEqual(prelitDraws, Double(prelit), "\(item.id): a prelighting pass didn't run")
        let median = gpuTimes.isEmpty ? "-" : String(format: "%.2f", gpuTimes.sorted()[gpuTimes.count / 2])
        return [item.id, String(item.litLayers.count), String(prelit), String(draws), String(prelitDraws), median]
            .joined(separator: "\t")
    }

    /// One frame of `item` once its lit layers draw through their material; with `lights` off the
    /// content has no `lightconfig`, so only the ambient colour lights them.
    private func frame(of item: Item, lights: Bool) throws -> [UInt8] {
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        var content = try XCTUnwrap(model.metalContent())
        defer { Fixtures.removeStoredSettings(for: item.directory) }
        if !lights { content.lighting.settings.lightConfig = nil }
        let scene = try Scene(content: content, services: services(), settings: SceneRenderSettings.headless)
        defer { scene.close() }
        scene.settle(litLayers: item.litLayers.map(\.id), prelitDraws: 0)
        scene.draw()
        return try scene.pixels()
    }

    private func services() -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent })
    }

    // MARK: - The library

    private struct Item {
        var id: String
        var directory: URL
        var project: WEProject
        /// Each lit image object's id, and whether it has effects.
        var litLayers: [(id: String, effects: Bool)]
    }

    /// Scenes with image objects whose material sets `LIGHTING` or `REFLECTION` (de-duplicated by
    /// Workshop id, the first root first).
    private static func litScenes(in roots: [URL]) throws -> [Item] {
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
                guard (json["type"] as? String)?.lowercased() == "scene",
                      let file = read(json["file"] as? String ?? "scene.json", in: directory) else { continue }
                let scene = try decodeTolerant(WEScene.self, from: file)
                var lit: [(id: String, effects: Bool)] = []
                for object in scene.objects {
                    // Optional: an object whose model or material can't be read has no lit material to check.
                    guard let image = object.image, let modelData = read(image, in: directory) ?? asset(image),
                          let model = try? decodeTolerant(WEModel.self, from: modelData), let path = model.material,
                          let materialData = read(path, in: directory) ?? asset(path),
                          let material = try? decodeTolerant(MaterialDocument.self, from: materialData),
                          let combos = material.passes.first?.combos else { continue }
                    if (combos["LIGHTING"] ?? 0) != 0 || (combos["REFLECTION"] ?? 0) != 0 {
                        lit.append((String(object.id ?? -1), !(object.effects ?? []).isEmpty))
                    }
                }
                guard !lit.isEmpty else { continue }
                let project = try decodeTolerant(WEProject.self, from: text)
                items.append(Item(id: name, directory: directory, project: project, litLayers: lit))
            }
        }
        return items
    }

    private static func asset(_ path: String) -> Data? {
        FileManager.default.contents(atPath: ShaderVariantTests.weAssets.appending(path: path).path)
    }

    /// A loose file wins over the same path inside a `.pkg`, as WE reads a wallpaper.
    private static func read(_ file: String, in directory: URL) -> Data? {
        if let loose = FileManager.default.contents(atPath: directory.appending(path: file).path) { return loose }
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "pkg" else { continue }
            do {
                if let data = try PKGParser(url: url).extractFile(named: file) { return data }
            } catch {
                XCTFail("\(url.path): \(error)")
            }
        }
        return nil
    }

    /// A content on one offscreen view, its clock stepped 1/60 s per draw.
    private final class Scene {
        let renderer: SceneMetalRenderer
        let view: MTKView
        private var now: CFTimeInterval = 1000

        init(content: SceneMetalContent, services: SceneScriptServices, settings: SceneRenderSettings) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let size = LitLayerLibraryTests.drawable
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "lit-sweep"))
            view.isPaused = true
            renderer.renderSettings = settings
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(renderer.hasContent)
        }

        /// Draws until the frames are settled: `settledFrames` in a row in which none of `litLayers`
        /// fell back to the native draw, at least as many layers as `litLayers` drew through their
        /// material and `prelitDraws` prelighting passes ran, and no pipeline was compiling. While
        /// a pipeline compiles the native draw stands in, and one landing can make the next frame
        /// need another. A frame whose total of material draws is right isn't enough either: in The
        /// Knight (2515150033) the unlit layer draws through its material while its effects compile,
        /// so the total can read right while the lit layer still draws natively, and once those
        /// effects land the unlit layer's base pass compiles in turn.
        func settle(litLayers: [String], prelitDraws: Int, timeout: TimeInterval = 120) {
            let deadline = Date().addingTimeInterval(timeout)
            var settled = 0
            while settled < Self.settledFrames, Date() < deadline {
                let draws = renderer.imageMaterialDraws, prelit = renderer.imageMaterialPrelitDraws
                let fallbacks = self.fallbacks(of: litLayers)
                draw()
                let drewAll = renderer.imageMaterialDraws - draws >= litLayers.count
                    && renderer.imageMaterialPrelitDraws - prelit >= prelitDraws
                    && self.fallbacks(of: litLayers) == fallbacks
                settled = drewAll && !renderer.pipelinesCompiling ? settled + 1 : 0
            }
        }

        /// How often each of `layers` fell back to the native draw so far.
        func fallbacks(of layers: [String]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: layers.map { ($0, renderer.imageMaterialFallbacks[$0] ?? 0) })
        }

        static let settledFrames = 3

        func draw(step: CFTimeInterval = 1.0 / 60) {
            now += step
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        /// The drawable, RGBA.
        func pixels() throws -> [UInt8] {
            let size = LitLayerLibraryTests.drawable
            var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
            let texture = try XCTUnwrap(view.currentDrawable?.texture)
            texture.getBytes(&bytes, bytesPerRow: size.x * 4, from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            return SceneMipMappedFrameBufferTests.swappingRedAndBlue(bytes)
        }

        func close() {
            renderer.releaseContent()
        }
    }
}

private extension SceneRenderSettings {
    /// Post-processing off (no bloom over the layers being measured); everything else the default.
    static var headless: SceneRenderSettings {
        var settings = SceneRenderSettings()
        settings.postProcessing = .disabled
        return settings
    }
}
