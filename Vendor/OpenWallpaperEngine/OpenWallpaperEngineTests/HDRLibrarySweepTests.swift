import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The library's HDR scenes (the survey's 5, docs/lighting-plan.md §1.5, and the 4 of the HDR test
/// set) loaded by the real loader and drawn headlessly by the real renderer, the clock stepped
/// 1/60 s a frame. With post-processing "ultra", for every scene:
///
/// - the content draws in HDR: `HDR=1`, an RGBA16F scene target, WE's HDR chain (no fallback)
///   every frame once its pipelines have compiled;
/// - the float frame is finite (a NaN would bloom into black), and its constants are;
/// - the combined frame equals the CPU model of the chain (`HDRReference`) run on that frame's own
///   scene target, within 2/255;
/// - the frame's GPU time is reported, with how much of the frame is overbright.
///
/// With "enabled" the same scenes draw in LDR with WE's LDR bloom. Skipped when the library is
/// absent (CI); roots as `LightingLibraryDecodeTests`.
final class HDRLibrarySweepTests: XCTestCase {
    private static let frames = 45
    private static let checkedFrames: Set<Int> = [20, 44]
    private static let step = 1.0 / 60
    private static let drawable = SIMD2(384, 216)
    static let scenes = ["3074485715", "3352730400", "3606529469", "razer_bedroom", "shimmering_particles",
                         "2321732083", "3657770939", "3734636606", "2350874185"]
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-hdr-sweep-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testEveryHDRSceneRunsWEsHDRChain() throws {
        _ = try Fixtures.assets()
        let roots = LightingLibraryDecodeTests.roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        try XCTSkipIf(roots.count < LightingLibraryDecodeTests.roots.count, "wallpaper library not present")
        var report = "scene\tHDR\tlevels\tstrength\tthreshold\ttarget\toverbright %\tworst\tGPU p50 ms\tLDR p50 ms\n"
        for id in Self.scenes {
            guard let directory = roots.lazy.map({ $0.appending(path: id, directoryHint: .isDirectory) })
                .first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path) }) else {
                XCTFail("\(id): not in the library")
                continue
            }
            report += try sweep(id, directory: directory) + "\n"
        }
        print("HDR library sweep (\(Self.frames) frames at 60 Hz, drawable \(Self.drawable.x)×\(Self.drawable.y), ultra):\n\(report)")
    }

    // MARK: - One scene

    private func sweep(_ id: String, directory: URL) throws -> String {
        defer { Fixtures.removeStoredSettings(for: directory) }
        let ultra = try content(directory, .ultra)
        guard ultra.timelines != nil else {
            // A scene the loader can't draw yet (a 3D one) shows its preview.
            return "\(id)\tpreview only"
        }
        XCTAssertTrue(ultra.engineCombos.hdr, "\(id): not drawn in HDR with ultra")
        XCTAssertNotNil(ultra.hdrChain, "\(id): WE's HDR chain wasn't planned")
        let scene = try Scene(content: ultra, postProcessing: .ultra, services: services())
        let renderer = scene.renderer
        let post = renderer.postProcess
        let deadline = Date().addingTimeInterval(60)
        repeat { scene.draw() } while post.lastHDR == nil && Date() < deadline

        var gpuTimes: [Double] = []
        var worst = 0, overbright = 0.0
        var levels: Int?, constants: SceneHDRChain.Constants?
        for frame in 0..<Self.frames {
            scene.draw()
            if let buffer = renderer.lastCommandBuffer { gpuTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
            let record = try XCTUnwrap(post.lastHDR, "\(id) frame \(frame): WE's HDR chain didn't run")
            XCTAssertNil(post.lastBloom, "\(id): no LDR bloom in HDR")
            XCTAssertEqual(record.frame.pixelFormat, .rgba16Float)
            let values = [record.constants.strength, record.constants.scatter, record.constants.blend.x, record.constants.blend.y,
                          record.constants.blend.z, record.constants.blend.w, record.constants.tint.x]
            XCTAssertTrue(values.allSatisfy(\.isFinite), "\(id) frame \(frame): constants \(record.constants)")
            levels = record.levels
            constants = record.constants
            guard Self.checkedFrames.contains(frame) else { continue }
            let result = try check(record, id: id, frame: frame)
            worst = max(worst, result.worst)
            overbright = result.overbright
        }
        scene.close()

        // "enabled": LDR, WE's LDR bloom where the scene's bloom is on.
        let enabled = try content(directory, .enabled)
        XCTAssertFalse(enabled.engineCombos.hdr, "\(id): HDR with post-processing enabled")
        XCTAssertNil(enabled.hdrChain)
        let ldr = try Scene(content: enabled, postProcessing: .enabled, services: services())
        let ldrDeadline = Date().addingTimeInterval(60)
        repeat { ldr.draw() } while enabled.bloom.enabled && ldr.renderer.postProcess.lastBloom == nil && Date() < ldrDeadline
        var ldrTimes: [Double] = []
        for _ in 0..<10 {
            ldr.draw()
            XCTAssertNil(ldr.renderer.postProcess.lastHDR)
            if enabled.bloom.enabled { XCTAssertNotNil(ldr.renderer.postProcess.lastBloom, "\(id): no LDR bloom with enabled") }
            if let buffer = ldr.renderer.lastCommandBuffer { ldrTimes.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000) }
        }
        ldr.close()

        let size = post.lastHDR.map { "\($0.frame.width)×\($0.frame.height)" } ?? "-"
        return [id, "on", levels.map(String.init) ?? "srgb", constants.map { String($0.strength) } ?? "-",
                constants.map { String($0.blend.x) } ?? "-", size, String(format: "%.2f", overbright * 100),
                String(worst), Self.median(gpuTimes), Self.median(ldrTimes)].joined(separator: "\t")
    }

    /// The combined frame against the CPU model run on its own input; returns the worst difference
    /// and the share of the frame above 1.
    private func check(_ record: ScenePostProcess.HDRRecord, id: String, frame: Int) throws -> (worst: Int, overbright: Double) {
        let device = record.frame.device
        let image = try HDRReference.read(record.frame, device: device)
        let finite = image.pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        XCTAssertTrue(finite, "\(id) frame \(frame): the float frame isn't finite")
        let overbright = Double(image.pixels.filter { max($0.x, max($0.y, $0.z)) > 1 }.count) / Double(image.pixels.count)
        let output = try TextureUploadTests.read(record.combined, device: device)
        let bloom = record.levels.map { HDRReference.levels(image, levels: $0, constants: record.constants)[0] }
        var worst = 0
        let stride = max(1, min(image.width, image.height) / 97)
        for y in Swift.stride(from: 0, to: image.height, by: stride) {
            for x in Swift.stride(from: 1, to: image.width, by: stride) {
                let expected = bloom.map { HDRReference.combined(image, bloom: $0, x: x, y: y) }
                    ?? HDRReference.srgbOnly(image, x: x, y: y)
                let i = (y * image.width + x) * 4
                for channel in 0..<3 {
                    worst = max(worst, abs(Int(output[i + channel]) - Int(expected[channel])))
                }
            }
        }
        XCTAssertLessThanOrEqual(worst, 2, "\(id) frame \(frame): off the CPU model by \(worst)/255")
        return (worst, overbright)
    }

    private func content(_ directory: URL, _ quality: GSPostProcessingQuality) throws -> SceneMetalContent {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let project = try decodeTolerant(WEProject.self, from: Data(String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).utf8))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = quality
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent(), "\(directory.lastPathComponent): no content")
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        return String(format: "%.2f", values.sorted()[values.count / 2])
    }

    private func services() -> SceneScriptServices {
        SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                            media: SceneScriptReplayMediaSource(), spectrum: { .silent })
    }

    /// A content on one offscreen view, its clock stepped 1/60 s per draw.
    private final class Scene {
        let renderer: SceneMetalRenderer
        let view: MTKView
        private var now: CFTimeInterval = 1000

        init(content: SceneMetalContent, postProcessing: GSPostProcessingQuality, services: SceneScriptServices) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let size = HDRLibrarySweepTests.drawable
            view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = false
            view.autoResizeDrawable = false
            view.drawableSize = CGSize(width: size.x, height: size.y)
            renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "hdr-sweep"))
            view.isPaused = true
            renderer.renderSettings.postProcessing = postProcessing
            renderer.setPlacement(.stretch)
            renderer.scripts.frameWait = 5
            renderer.wallTime = { [unowned self] in self.now }
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(60)
            while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(renderer.hasContent)
        }

        func draw() {
            now += HDRLibrarySweepTests.step
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
