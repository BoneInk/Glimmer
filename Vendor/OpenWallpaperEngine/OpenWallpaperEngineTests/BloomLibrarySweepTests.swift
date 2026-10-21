import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The library's bloom scenes (the survey's 24, docs/lighting-plan.md §1.5, and any added since)
/// loaded by the real loader and drawn headlessly by the real renderer, post-processing "enabled",
/// the clock stepped 1/60 s a frame.
/// For every scene whose `bloom` is on:
///
/// - WE's chain runs (no fallback) once its pipelines have compiled, every frame after that;
/// - its constants are finite, and bloom only adds (a NaN would have written black);
/// - the bloomed frame equals the CPU model of the four passes (`BloomReference`) run on that
///   frame's own scene target, within 2/255, so bright regions brighten exactly per WE's threshold;
/// - the frame's GPU time is reported.
///
/// Skipped when the library is absent (CI); roots as `LightingLibraryDecodeTests`.
final class BloomLibrarySweepTests: XCTestCase {
    private static let frames = 45
    private static let checkedFrames: Set<Int> = [20, 44]
    private static let step = 1.0 / 60
    private static let drawable = SIMD2(384, 216)
    /// The 24 of the survey (§1.5); scenes added to the library since are swept too.
    private static let surveyed: Set<String> = [
        "1556245028", "1877013475", "2071964019", "2134765860", "2370927443", "2734461061", "3000562427", "3030025146",
        "3074485715", "3109042108", "3270035750", "3352730400", "3453730450", "3546971487", "3606529469", "3639372043",
        "arsenal", "demon_core", "dna_fragment", "fantasticcar", "neon_sunset", "razer_bedroom", "ricepod",
        "shimmering_particles",
    ]
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-bloom-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testEveryBloomSceneBloomsLikeWE() throws {
        _ = try Fixtures.assets()
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        let scenes = try Self.bloomScenes(in: roots)
        let missing = Self.surveyed.subtracting(scenes.map(\.id))
        XCTAssertTrue(missing.isEmpty, "bloom scenes of the survey not found: \(missing.sorted())")
        var report = "scene\tbloom\tstrength\tthreshold\ttarget\tbloomed px\tworst\tGPU p50 ms\tCPU p50 ms\n"
        for scene in scenes {
            report += try sweep(scene) + "\n"
        }
        print("Bloom library sweep (\(Self.frames) frames at 60 Hz, drawable \(Self.drawable.x)×\(Self.drawable.y)):\n\(report)")
    }

    // MARK: - One scene

    private func sweep(_ item: Item) throws -> String {
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: item.project, where: item.directory))
        guard let content = model.metalContent() else {
            XCTFail("\(item.id): no content")
            return "\(item.id)\tno content"
        }
        defer { Fixtures.removeStoredSettings(for: item.directory) }
        let bloomOn = content.bloom.enabled
        guard content.timelines != nil else {
            // A scene the loader can't draw yet (a 3D one) shows its preview, which has no bloom.
            return "\(item.id)\tpreview only"
        }
        XCTAssertNotNil(content.bloomChain, "\(item.id): WE's bloom wasn't planned")
        let scene = try Scene(content: content, services: services())
        defer { scene.close() }
        let renderer = scene.renderer
        let post = renderer.postProcess

        // Until the chain's pipelines compile the frame draws without it; then it must run every frame.
        let deadline = Date().addingTimeInterval(60)
        repeat { scene.draw() } while bloomOn && post.lastBloom == nil && Date() < deadline

        var gpuTimes: [Double] = [], cpuTimes: [Double] = []
        var worst = 0, bloomed = 0
        var constants = (strength: Float(0), threshold: Float(0))
        for frame in 0..<Self.frames {
            let start = CACurrentMediaTime()
            scene.draw()
            cpuTimes.append((CACurrentMediaTime() - start) * 1000)
            if let buffer = renderer.lastCommandBuffer { gpuTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
            guard bloomOn else {
                XCTAssertNil(post.lastBloom, "\(item.id) frame \(frame): the scene's bloom is off")
                continue
            }
            let record = try XCTUnwrap(post.lastBloom, "\(item.id) frame \(frame): WE's bloom didn't run")
            XCTAssertTrue(record.strength.isFinite && record.threshold.isFinite && all(record.tint, \.isFinite),
                          "\(item.id) frame \(frame): constants \(record)")
            constants = (record.strength, record.threshold)
            // WE's camera fade draws over the bloomed frame while a camera path starts or ends
            // (a scene of models with paths: the default projects arsenal, fantasticcar…).
            guard Self.checkedFrames.contains(frame), content.cameraFade?.lastFade == nil else { continue }
            let result = try check(record, item: item, frame: frame)
            worst = max(worst, result.worst)
            bloomed = result.bloomed
        }
        let size = post.lastBloom.map { "\($0.frame.width)×\($0.frame.height)" } ?? "-"
        return [item.id, bloomOn ? "on" : "off", String(constants.strength), String(constants.threshold), size,
                String(bloomed), String(worst), Self.median(gpuTimes), Self.median(cpuTimes)].joined(separator: "\t")
    }

    /// The bloomed frame against the CPU model run on its own input; returns the worst difference
    /// and how many compared pixels bloom brightened.
    private func check(_ record: ScenePostProcess.BloomRecord, item: Item, frame: Int) throws -> (worst: Int, bloomed: Int) {
        let device = record.frame.device
        let input = try TextureUploadTests.read(record.frame, device: device)
        let output = try TextureUploadTests.read(record.bloomed, device: device)
        let width = record.frame.width, height = record.frame.height
        XCTAssertEqual(record.bloomed.width, width)
        XCTAssertEqual(record.bloomed.height, height)
        let image = BloomReference.Image(bytes: input, width: width, height: height)
        let bloom = BloomReference.bloom(image, strength: record.strength, threshold: record.threshold, tint: record.tint)
        var worst = 0, bloomed = 0, regressions = 0
        // The combine on a grid of the frame (the 1/4 and 1/8 passes are modelled in full).
        let stride = max(1, min(width, height) / 97)
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 1, to: width, by: stride) {
                let expected = BloomReference.combined(image, bloom: bloom, x: x, y: y) * 255
                let i = (y * width + x) * 4
                for channel in 0..<3 {
                    let drawn = Int(output[i + channel]), before = Int(input[i + channel])
                    worst = max(worst, abs(drawn - Int(expected[channel].rounded())))
                    if drawn < before { regressions += 1 }
                }
                if (0..<3).contains(where: { output[i + $0] > input[i + $0] }) { bloomed += 1 }
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "\(item.id) frame \(frame): off the CPU model by \(worst)/255")
        XCTAssertEqual(regressions, 0, "\(item.id) frame \(frame): bloom darkened \(regressions) channels")
        if record.strength == 0 { XCTAssertEqual(bloomed, 0, "\(item.id): strength 0 adds nothing") }
        return (worst, bloomed)
    }

    private func all(_ vector: SIMD3<Float>, _ predicate: (Float) -> Bool) -> Bool {
        predicate(vector.x) && predicate(vector.y) && predicate(vector.z)
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        return String(format: "%.2f", values.sorted()[values.count / 2])
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
    }

    /// Scenes whose `general.bloom` is on as authored, or by its fallback when user-bound
    /// (de-duplicated by Workshop id, the first root first, like the survey).
    private static func bloomScenes(in roots: [URL]) throws -> [Item] {
        var seen = Set<String>(), items: [Item] = []
        for root in roots {
            for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
                let directory = root.appending(path: name, directoryHint: .isDirectory)
                // `try?`: a folder without a readable project.json isn't a wallpaper.
                guard let data = try? Data(contentsOf: directory.appending(path: "project.json")),
                      let json = try? JSONSerialization.jsonObject(with: Data(String(decoding: data, as: UTF8.self)
                          .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8), options: [.json5Allowed])
                          as? [String: Any] else { continue }
                let workshopID = json["workshopid"].map { "\($0)" } ?? ""
                let key = workshopID.isEmpty || workshopID == "0" ? name : workshopID
                guard !seen.contains(key), !seen.contains(name) else { continue }
                seen.formUnion([key, name])
                guard (json["type"] as? String)?.lowercased() == "scene",
                      let file = sceneData(json["file"] as? String ?? "scene.json", in: directory) else { continue }
                let scene = try decodeTolerant(WEScene.self, from: file)
                guard isOn(scene.general.values[.bloom]) else { continue }
                let project = try decodeTolerant(WEProject.self, from: Data(String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8))
                items.append(Item(id: name, directory: directory, project: project))
            }
        }
        return items
    }

    private static func isOn(_ raw: SceneRawValue?) -> Bool {
        switch raw {
        case .bool(let flag)?: return flag
        case .number(let number)?: return number != 0
        case .object(let object)?: return isOn(object.value)
        default: return false
        }
    }

    /// A loose file wins over the same path inside a `.pkg`, as WE reads a wallpaper.
    private static func sceneData(_ file: String, in directory: URL) -> Data? {
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

        init(content: SceneMetalContent, services: SceneScriptServices) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let size = BloomLibrarySweepTests.drawable
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "bloom-sweep"))
            view.isPaused = true
            renderer.renderSettings.postProcessing = .enabled
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(renderer.hasContent)
        }

        func draw() {
            now += BloomLibrarySweepTests.step
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
