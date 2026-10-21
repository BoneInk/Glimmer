import Accelerate
import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// "Match Display" (`GSSceneDetail.matchDisplay`, `SceneEffectDetail`) against WE's full detail,
/// on chosen library wallpapers: both renderers draw the same frames (the clock stepped 1/60 s a
/// draw), the full frame is scaled down to the matched frame's size (Lanczos), and the two are
/// compared pixel by pixel. What a display shows then differs only by that.
///
/// Only runs when asked: `OWE_SCENE_DETAIL` (`TEST_RUNNER_OWE_SCENE_DETAIL`) lists workshop ids;
/// `OWE_SCENE_DETAIL_SIZE` is the drawable (default 3840x2160, a 4K display at 2×) and
/// `OWE_SCENE_DETAIL_MODES` the matched settings (`match`: Effect Detail Match Display;
/// `your-display`: the target at the drawable's pixels, not floored at the authored size, as the
/// app draws Your Display; `half`; joined with `+`, e.g. `match+your-display`). Particle systems are left out: two renderers' GPU simulations
/// don't draw the same particles. Frames, and an amplified difference, are written under
/// `OWE_SCENE_DETAIL_OUT` when set.
final class SceneDetailEquivalenceTests: XCTestCase {
    private static let warmFrames = 240
    private static let comparedFrames = [0, 45]
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-detail-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    struct Difference {
        var mean: Double
        var p99: Int
        var maximum: Int
        /// Pixels whose largest channel difference is over 8/255, as a fraction.
        var over8: Double
    }

    func testMatchedDetailLooksLikeFullDetail() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_SCENE_DETAIL"], !request.isEmpty else {
            throw XCTSkip("set OWE_SCENE_DETAIL to compare scene detail modes")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let sizes = (environment["OWE_SCENE_DETAIL_SIZE"] ?? "3840x2160").split(separator: ",").map { entry -> SIMD2<Int> in
            let parts = entry.split(separator: "x").compactMap { Int($0) }
            return SIMD2(parts.first ?? 3840, parts.last ?? 2160)
        }
        let modes = (environment["OWE_SCENE_DETAIL_MODES"] ?? "match").split(separator: ",").map(String.init)
        let output = environment["OWE_SCENE_DETAIL_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var report = ["Scene detail against full: compared at the matched frame's size; mean and 99th percentile "
                      + "of each pixel's largest channel difference (/255), max, pixels over 8/255"]
        for drawable in sizes {
            report.append("drawable \(drawable.x)x\(drawable.y):")
            for id in request.split(separator: ",").map(String.init) {
                let directory = library.appending(path: id, directoryHint: .isDirectory)
                let data = try XCTUnwrap(FileManager.default.contents(atPath: directory.appending(path: "project.json").path))
                let project = try JSONDecoder().decode(WEProject.self, from: data)
                defer { Fixtures.removeStoredSettings(for: directory) }
                for mode in modes {
                    let settings = Self.settings(mode)
                    let full = try frames(project, directory: directory, drawable: drawable, settings: SceneRenderSettings())
                    let matched = try frames(project, directory: directory, drawable: drawable, settings: settings)
                    for (index, frame) in Self.comparedFrames.enumerated() {
                        let reference = try Self.scaled(full[index], to: SIMD2(matched[index].width, matched[index].height))
                        let difference = Self.difference(reference, matched[index])
                        report.append(String(format: "  %@ %@ frame %d: full %dx%d, %@ %dx%d: mean %.2f, p99 %d, max %d, over 8: %.3f%%",
                                             id, project.title, frame, full[index].width, full[index].height, mode,
                                             matched[index].width, matched[index].height, difference.mean, difference.p99,
                                             difference.maximum, difference.over8 * 100))
                        print(report.last!)
                        // Matched detail shows what full detail shows at the display's size, but for how
                        // each resamples (an area average against bilinear minification, then Lanczos
                        // here) at edges. Drawing at fewer pixels (desktop, WE's half) is meant to differ,
                        // and is reported.
                        if mode == "match" {
                            XCTAssertLessThan(difference.mean, 3, "\(id) \(mode) frame \(frame): mean difference")
                            XCTAssertLessThan(difference.over8, 0.1, "\(id) \(mode) frame \(frame): pixels over 8/255")
                        }
                        if let output {
                            let folder = output.appending(path: "\(id)-\(drawable.x)x\(drawable.y)", directoryHint: .isDirectory)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            try Self.png(full[index], to: folder.appending(path: "full-\(frame).png"))
                            try Self.png(matched[index], to: folder.appending(path: "\(mode)-\(frame).png"))
                            try Self.png(Self.amplifiedDifference(reference, matched[index]),
                                         to: folder.appending(path: "\(mode)-\(frame)-diff×8.png"))
                        }
                    }
                }
            }
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let output { try text.write(to: output.appending(path: "detail-report.txt"), atomically: true, encoding: .utf8) }
    }

    static func settings(_ mode: String) -> SceneRenderSettings {
        var settings = SceneRenderSettings()
        for part in mode.split(separator: "+") {
            switch part {
            case "match": settings.sceneDetail = .matchDisplay
            case "your-display":
                settings.renderResolution = .yourDisplay
                settings.floorsAtAuthoredSize = false
            case "half": settings.textureReduction = 2
            default: XCTFail("unknown mode \(part)")
            }
        }
        return settings
    }

    // MARK: - Drawing

    struct Frame {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// The scene's finished frames (`renderShared`, before placement) at `comparedFrames` after the warm-up.
    private func frames(_ project: WEProject, directory: URL, drawable: SIMD2<Int>,
                        settings: SceneRenderSettings) throws -> [Frame] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        model.setRenderSettings(settings)
        let built = try XCTUnwrap(model.metalContent())
        // Without particles: two renderers' GPU simulations don't draw the same particles.
        let content = Self.withoutParticles(built)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: drawable.x / 2, height: drawable.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: drawable.x, height: drawable.y)
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "detail"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings = settings
        renderer.setPlacement(.fill)
        renderer.scripts.frameWait = 5
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let viewport = SceneViewport(drawableSize: SIMD2(Float(drawable.x), Float(drawable.y)),
                                     pointSize: SIMD2(Float(drawable.x / 2), Float(drawable.y / 2)), cursor: nil,
                                     frameRateLimit: 60)
        var frames: [Frame] = []
        let last = Self.warmFrames + (Self.comparedFrames.max() ?? 0)
        for frame in 0...last {
            now += 1.0 / 60
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            // Pipelines compile off the render thread; give them the warm-up's time.
            RunLoop.main.run(until: Date().addingTimeInterval(frame < Self.warmFrames ? 0.01 : 0))
            guard frame >= Self.warmFrames, Self.comparedFrames.contains(frame - Self.warmFrames) else { continue }
            let texture = try XCTUnwrap(renderer.sharedFrame)
            frames.append(Frame(pixels: try TextureUploadTests.read(texture, device: device),
                                width: texture.width, height: texture.height))
        }
        return frames
    }

    /// `content` without its particle systems.
    private static func withoutParticles(_ content: SceneMetalContent) -> SceneMetalContent {
        var copy = SceneMetalContent(size: content.size, layers: content.layers, particleSystems: [], bloom: content.bloom)
        copy.transforms = content.transforms
        copy.motions = content.motions
        copy.camera = content.camera
        copy.wallpaperKey = content.wallpaperKey
        copy.visibility = content.visibility
        copy.objectIDs = content.objectIDs
        copy.scripts = content.scripts
        copy.timelines = content.timelines
        copy.sounds = content.sounds
        copy.lighting = content.lighting
        copy.volumetrics = content.volumetrics
        copy.engineCombos = content.engineCombos
        copy.bloomChain = content.bloomChain
        copy.hdrChain = content.hdrChain
        return copy
    }

    // MARK: - Comparing

    /// `frame` scaled to `size` with a Lanczos filter (what showing it at that size does).
    static func scaled(_ frame: Frame, to size: SIMD2<Int>) throws -> Frame {
        guard size != SIMD2(frame.width, frame.height) else { return frame }
        var output = [UInt8](repeating: 0, count: size.x * size.y * 4)
        var source = frame.pixels
        let error = source.withUnsafeMutableBytes { sourceBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var from = vImage_Buffer(data: sourceBytes.baseAddress, height: vImagePixelCount(frame.height),
                                         width: vImagePixelCount(frame.width), rowBytes: frame.width * 4)
                var to = vImage_Buffer(data: outputBytes.baseAddress, height: vImagePixelCount(size.y),
                                       width: vImagePixelCount(size.x), rowBytes: size.x * 4)
                return vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        XCTAssertEqual(error, kvImageNoError)
        return Frame(pixels: output, width: size.x, height: size.y)
    }

    static func difference(_ a: Frame, _ b: Frame) -> Difference {
        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        for index in stride(from: 0, to: min(a.pixels.count, b.pixels.count), by: 4) {
            var largest = 0
            for channel in 0..<3 { largest = max(largest, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel]))) }
            histogram[largest] += 1
            total += largest
        }
        let count = max(histogram.reduce(0, +), 1)
        var seen = 0, p99 = 0
        for (value, number) in histogram.enumerated() {
            seen += number
            if seen * 100 >= count * 99 { p99 = value; break }
        }
        let maximum = histogram.lastIndex { $0 > 0 } ?? 0
        let over8 = Double(histogram[9...].reduce(0, +)) / Double(count)
        return Difference(mean: Double(total) / Double(count), p99: p99, maximum: maximum, over8: over8)
    }

    static func amplifiedDifference(_ a: Frame, _ b: Frame) -> Frame {
        var pixels = [UInt8](repeating: 255, count: a.pixels.count)
        for index in stride(from: 0, to: min(a.pixels.count, b.pixels.count), by: 4) {
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) * 8))
            }
        }
        return Frame(pixels: pixels, width: a.width, height: a.height)
    }

    static func png(_ frame: Frame, to url: URL) throws {
        var opaque = frame.pixels
        for index in stride(from: 3, to: opaque.count, by: 4) { opaque[index] = 255 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(opaque) as CFData))
        let image = try XCTUnwrap(CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
