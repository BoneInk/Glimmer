import XCTest
import AppKit
import MetalKit
@testable import OpenWallpaperEngine

/// "Optimise textures" (`TexturePreparation`, `TextureCompressor`) and the mipmap upload of
/// block-compressed `.tex` files (`SceneTextureUpload.blockCompressedTexture`).
final class TexturePreparationTests: XCTestCase {
    private var device: MTLDevice!
    private var root: URL!
    private var savedRoot: URL!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        savedRoot = TexturePreparation.root
        root = FileManager.default.temporaryDirectory.appending(path: "owe-texture-prep-\(UUID().uuidString)")
        TexturePreparation.root = root
    }

    override func tearDownWithError() throws {
        TexturePreparation.root = savedRoot
        try? FileManager.default.removeItem(at: root)
    }

    /// A smooth RGBA image with a soft alpha edge, like a painted layer.
    private func paintedImage(width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
                bytes[o] = UInt8(clamping: Int(255 * fx))
                bytes[o + 1] = UInt8(clamping: Int(255 * fy))
                bytes[o + 2] = UInt8(clamping: Int(128 + 100 * sin(fx * 9) * cos(fy * 7)))
                let edge = (0.45 - hypot(fx - 0.5, fy - 0.5)) * 12
                bytes[o + 3] = UInt8(clamping: Int(255 * min(1, max(0, edge + 0.5))))
            }
        }
        return bytes
    }

    // MARK: Encoder

    func testASolidBlockRoundTripsWithinOneStep() {
        let texels = [Int32](repeating: 0, count: 64).enumerated().map { index, _ in Int32([200, 17, 99, 255][index % 4]) }
        let block = TextureCompressor.encodeMode6(texels)
        var raw = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: block.0.littleEndian) { raw.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: block.1.littleEndian) { raw.replaceSubrange(8..<16, with: $0) }
        let decoded = raw.withUnsafeBytes { TextureCompressor.decodeBC7($0, width: 4, height: 4) }
        for (index, value) in decoded.enumerated() {
            let expected: Int = [200, 17, 99, 255][index % 4]
            let difference: Int = abs(Int(value) - expected)
            XCTAssertLessThanOrEqual(difference, 1, "texel \(index / 4) channel \(index % 4)")
        }
    }

    /// The bit layout is the GPU's: Metal's BC7 sampler reads what the CPU decoder reads.
    func testTheGPUDecodesTheBlocksAsTheCheckDoes() throws {
        try XCTSkipUnless(device.supportsBCTextureCompression)
        let width = 37, height = 21
        let bytes = paintedImage(width: width, height: height)
        let blocks = bytes.withUnsafeBytes { TextureCompressor.encodeBC7($0, width: width, height: height, rowBytes: width * 4) }
        let cpu = blocks.withUnsafeBytes { TextureCompressor.decodeBC7($0, width: width, height: height) }
        var source = TEXCompressedTexture(format: TEXCompressedTexture.bc7Format, width: width, height: height, data: blocks,
                                          contentWidth: width, contentHeight: height)
        source.sourceKey = nil
        let texture = try XCTUnwrap(SceneTextureUpload.blockCompressedTexture(source, device: device))
        let gpu = try readBack(texture, level: 0)
        var worst = 0
        for index in cpu.indices { worst = max(worst, abs(Int(cpu[index]) - Int(gpu[index]))) }
        XCTAssertLessThanOrEqual(worst, 1)
    }

    /// Opaque line art (every partition shape across the blocks) takes mode 1; the GPU agrees.
    func testTheGPUDecodesTwoSubsetBlocksAsTheCheckDoes() throws {
        try XCTSkipUnless(device.supportsBCTextureCompression)
        let width = 64, height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var generator = SystemRandomNumberGenerator()
        let palette: [[UInt8]] = [[250, 240, 220], [20, 30, 40], [200, 40, 60], [30, 160, 90]]
        for block in 0..<256 {
            let mask = TextureCompressor.partitions[block % 64]
            let first = palette[block % 4], second = palette[(block / 4 + 1) % 4 == block % 4 ? (block + 2) % 4 : (block / 4 + 1) % 4]
            for texel in 0..<16 {
                let x = (block % 16) * 4 + texel % 4, y = (block / 16) * 4 + texel / 4
                let colour = mask >> UInt16(texel) & 1 == 1 ? second : first
                let o = (y * width + x) * 4
                for channel in 0..<3 { bytes[o + channel] = UInt8(clamping: Int(colour[channel]) + Int.random(in: -3...3, using: &generator)) }
            }
        }
        let blocks = bytes.withUnsafeBytes { TextureCompressor.encodeBC7($0, width: width, height: height, rowBytes: width * 4) }
        let modeOne = stride(from: 0, to: blocks.count, by: 16).filter { blocks[$0] & 0x3 == 0b10 }.count
        XCTAssertGreaterThan(modeOne, 128, "two-colour blocks take mode 1")
        let cpu = blocks.withUnsafeBytes { TextureCompressor.decodeBC7($0, width: width, height: height) }
        let source = TEXCompressedTexture(format: TEXCompressedTexture.bc7Format, width: width, height: height, data: blocks,
                                          contentWidth: width, contentHeight: height)
        let texture = try XCTUnwrap(SceneTextureUpload.blockCompressedTexture(source, device: device))
        let gpu = try readBack(texture, level: 0)
        var worst = 0
        for index in cpu.indices { worst = max(worst, abs(Int(cpu[index]) - Int(gpu[index]))) }
        XCTAssertLessThanOrEqual(worst, 1)
    }

    func testAPaintedImagePassesTheLossyBar() {
        let width = 256, height = 256
        let bytes = paintedImage(width: width, height: height)
        let blocks = bytes.withUnsafeBytes { TextureCompressor.encodeBC7($0, width: width, height: height, rowBytes: width * 4) }
        XCTAssertEqual(blocks.count, 64 * 64 * 16)
        let decoded = blocks.withUnsafeBytes { TextureCompressor.decodeBC7($0, width: width, height: height) }
        let quality = TextureCompressor.quality(reference: bytes, candidate: decoded, width: width, height: height)
        XCTAssertGreaterThanOrEqual(quality.lumaSSIM, 0.995)
        XCTAssertGreaterThanOrEqual(quality.alphaSSIM, 0.995)
        XCTAssertLessThanOrEqual(quality.deltaE99, 2.0)
    }

    func testTheBarIsStricterForLineArt() {
        let photoOnly = TextureCompressor.Quality(lumaSSIM: 0.99, alphaSSIM: 1, deltaE99: 1)
        XCTAssertTrue(TexturePreparation.accepts(photoOnly, contentClass: .photo))
        XCTAssertFalse(TexturePreparation.accepts(photoOnly, contentClass: .lineArt))
        XCTAssertFalse(TexturePreparation.accepts(photoOnly, contentClass: .text))
        let colourShift = TextureCompressor.Quality(lumaSSIM: 0.999, alphaSSIM: 1, deltaE99: 2.5)
        XCTAssertFalse(TexturePreparation.accepts(colourShift, contentClass: .photo))
        let softOutlines = TextureCompressor.Quality(lumaSSIM: 0.999, alphaSSIM: 1, deltaE99: 1, edgeSSIM: 0.985)
        XCTAssertFalse(TexturePreparation.accepts(softOutlines, contentClass: .photo))
    }

    func testMipmapsHalveAndKeepTransparentColourOut() {
        // Opaque red beside transparent green: the half-size mipmap stays red where it is visible.
        var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for index in 0..<64 {
            let left = index % 8 < 4
            bytes.replaceSubrange((index * 4)..<(index * 4 + 4), with: left ? [255, 0, 0, 255] : [0, 255, 0, 0])
        }
        let half = TextureCompressor.halfSize(bytes, width: 8, height: 8)
        XCTAssertEqual([half.width, half.height], [4, 4])
        let edge = Array(half.texels[(1 * 4 + 1) * 4..<((1 * 4 + 1) * 4 + 4)])
        XCTAssertGreaterThan(Int(edge[0]), 250, "visible colour isn't mixed with the transparent texels' green")
        XCTAssertLessThan(Int(edge[1]), 5)
    }

    // MARK: Blobs

    func testABlobIsPageAlignedAndLoadsItsLevelsMapped() throws {
        let width = 300, height = 260
        let bytes = paintedImage(width: width, height: height)
        let header = try offMain { try TexturePreparation.prepare(bytes, width: width, height: height, mipmaps: 4, key: "painted") }
        XCTAssertEqual(header.status, .compressed)
        XCTAssertEqual(header.levels.count, 4)
        for level in header.levels {
            let remainder: Int = level.offset % TexturePreparation.pageSize
            XCTAssertEqual(remainder, 0)
        }
        let texture = try XCTUnwrap(TexturePreparation.cachedTexture(key: "painted"))
        XCTAssertEqual([texture.width, texture.height, texture.contentWidth, texture.contentHeight], [300, 260, 300, 260])
        XCTAssertEqual(texture.levels.count, 4)
        XCTAssertEqual(texture.levels[1].count, TextureCompressor.blockCount(width: 150, height: 130) * 16)
        XCTAssertEqual(texture.opaque, false)
        XCTAssertNotNil(texture.contentClass)

        // The layer's size and `g_Texture0Resolution` are the image's, as for the decoded image.
        let source = SceneMetalTextureSource.dxt(texture)
        XCTAssertEqual(source.pixelSize, SIMD2(300, 260))
        XCTAssertEqual(source.contentSize, SIMD2(300, 260))
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(texture), SIMD2(1, 1))

        try XCTSkipUnless(device.supportsBCTextureCompression)
        let uploaded = try XCTUnwrap(SceneTextureUpload.blockCompressedTexture(texture, device: device))
        XCTAssertEqual(uploaded.mipmapLevelCount, 4)
        XCTAssertEqual(uploaded.pixelFormat, .bc7_rgbaUnorm)
        let again = try XCTUnwrap(SceneTextureUpload.blockCompressedTexture(texture, device: device))
        XCTAssertTrue(uploaded === again, "textures sharing a blob upload once")
    }

    func testAForeignOrTruncatedBlobIsDropped() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 100).write(to: TexturePreparation.url(key: "junk"))
        XCTAssertNil(TexturePreparation.cachedTexture(key: "junk"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TexturePreparation.url(key: "junk").path(percentEncoded: false)))
    }

    func testTheKeyFollowsTheFileAndTheLoadedLevel() {
        let a = TexturePreparation.key(texData: Data([1, 2, 3]), level: 0)
        XCTAssertEqual(a, TexturePreparation.key(texData: Data([1, 2, 3]), level: 0))
        XCTAssertNotEqual(a, TexturePreparation.key(texData: Data([1, 2, 4]), level: 0))
        XCTAssertNotEqual(a, TexturePreparation.key(texData: Data([1, 2, 3]), level: 1))
    }

    /// Masks, flow maps and other one- or two-channel data never become BC7.
    func testOneAndTwoChannelImagesAreNeverCompressed() throws {
        for format: UInt32 in [8, 9] {
            let data = TextureRG88Tests.tex(format: format, width: 4, height: 4,
                                            pixels: [UInt8](repeating: 9, count: 16 * (format == 8 ? 2 : 1)))
            let image = try XCTUnwrap(TEXParser(data: data).extractImage())
            XCTAssertNil(TexturePreparation.straightTexels(image), "format \(format)")
        }
    }

    // MARK: Stored mipmaps

    func testABlockTextureCarriesEveryStoredMipmap() throws {
        let data = TextureReductionTests.tex(format: 7, image: SIMD2(8, 8), mipmaps: [
            (SIMD2(8, 8), [UInt8](repeating: 1, count: 4 * 8)),
            (SIMD2(4, 4), [UInt8](repeating: 2, count: 8)),
            (SIMD2(2, 2), [UInt8](repeating: 3, count: 8)),
            (SIMD2(1, 1), [UInt8](repeating: 4, count: 8)),
        ])
        let full = try XCTUnwrap(TEXParser(data: data).extractCompressedTexture())
        XCTAssertEqual(full.levels.count, 4)
        XCTAssertEqual(full.levels.map { $0.first ?? 0 }, [1, 2, 3, 4])
        let reduced = try XCTUnwrap(TEXParser(data: data).extractCompressedTexture(reduction: 2))
        XCTAssertEqual(reduced.levels.count, 3, "a reduced load starts at the second")
        try XCTSkipUnless(device.supportsBCTextureCompression)
        let texture = try XCTUnwrap(SceneTextureUpload.blockCompressedTexture(full, device: device))
        XCTAssertEqual(texture.mipmapLevelCount, 4)
    }

    func testAChainThatSkipsALevelStopsThere() throws {
        let data = TextureReductionTests.tex(format: 7, image: SIMD2(8, 8), mipmaps: [
            (SIMD2(8, 8), [UInt8](repeating: 1, count: 4 * 8)),
            (SIMD2(2, 2), [UInt8](repeating: 3, count: 8)),
        ])
        let texture = try XCTUnwrap(TEXParser(data: data).extractCompressedTexture())
        XCTAssertEqual(texture.levels.count, 1)
    }

    // MARK: Setting

    func testTheSettingIsOnByDefaultAndReachesTheRenderer() throws {
        XCTAssertTrue(GlobalSettings().optimiseTextures)
        let stored = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(stored.optimiseTextures, "a settings file from before keeps the default")
        var settings = GlobalSettings()
        settings.optimiseTextures = false
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.optimiseTextures)
        XCTAssertFalse(SceneRenderSettings().optimiseTextures, "a settings-less renderer draws images as they are")
        XCTAssertTrue(SceneRenderSettings(GlobalSettings()).optimiseTextures)
        XCTAssertNotEqual(SceneRenderSettings(settings).contentKey, SceneRenderSettings(GlobalSettings()).contentKey,
                          "toggling it reloads the content")
    }

    // MARK: Helpers

    /// Runs `work` on a background queue (preparation asserts it is off the main thread).
    private func offMain<T>(_ work: @escaping () throws -> T) throws -> T {
        var result: Result<T, Error>!
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = Result { try work() }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    /// RGBA8 texels of `texture`'s `level`, sampled by a compute kernel (a compressed texture
    /// can't be blitted to a buffer).
    private func readBack(_ texture: MTLTexture, level: Int) throws -> [UInt8] {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void copyTexels(texture2d<float, access::read> input [[texture(0)]],
                               texture2d<float, access::write> output [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
            output.write(input.read(gid), gid);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "copyTexels")))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        output.getBytes(&bytes, bytesPerRow: texture.width * 4,
                        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return bytes
    }
}

/// "Optimise textures" on library wallpapers against the efficiency plan's bars (§4, §5): the
/// frames with it off and on at 1920×1080 and 3840×2160 over frames 0, 30 and 120 (lossy: SSIM ≥
/// 0.98, ΔE2000 p99 ≤ 2, text and line art SSIM ≥ 0.995), and the costs: load time (off, first
/// load with it on, cached), GPU memory and GPU ms. Only runs when asked: `OWE_TEXTURE_GATE`
/// (`TEST_RUNNER_OWE_TEXTURE_GATE` through xcodebuild) lists workshop ids from `OWE_LIBRARY`.
/// Scripts are left out; particles are random, so the frames with it off are drawn twice and a
/// frame fails only when the change misses a bar that the repeat of itself passes.
final class TexturePreparationLibraryTests: XCTestCase {
    func testLibraryWallpapersPassTheLossyBar() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_TEXTURE_GATE"], !request.isEmpty else {
            throw XCTSkip("set OWE_TEXTURE_GATE to run the texture gate")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.supportsBCTextureCompression)
        let savedRoot = TexturePreparation.root
        let root = URL(fileURLWithPath: environment["OWE_TEXTURE_GATE_CACHE"]
                       ?? FileManager.default.temporaryDirectory.appending(path: "owe-texture-gate").path)
        try? FileManager.default.removeItem(at: root)
        TexturePreparation.root = root
        defer {
            TexturePreparation.root = savedRoot
        }
        var report: [String] = []
        var failures: [String] = []
        for id in request.split(separator: ",").map(String.init) {
            let directory = LibrarySweepTests.libraryRoot.appending(path: id, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data) else {
                report.append("\(id): missing; skipped")
                continue
            }
            defer { Fixtures.removeStoredSettings(for: directory) }
            let wallpaper = WEWallpaper(using: project, where: directory)
            let off = try load(wallpaper, optimise: false)
            let cold = try load(wallpaper, optimise: true)
            let prepareStart = CACurrentMediaTime()
            let idle = DispatchSemaphore(value: 0)
            PreparationPool.shared.whenIdle { idle.signal() }
            idle.wait()
            let prepareSeconds: Double = CACurrentMediaTime() - prepareStart
            let on = try load(wallpaper, optimise: true)
            let blobs = try blobSummary(root)
            report.append(String(format: "%@ “%@”: load off %.3f s, first on %.3f s, cached on %.3f s; background compression %.2f s; %@",
                                 id, project.title, off.seconds, cold.seconds, on.seconds, prepareSeconds, blobs))
            for size in [SIMD2(1920, 1080), SIMD2(3840, 2160)] {
                let reference = try draw(off.content, size: size, device: device)
                let repeatRun = try draw(off.content, size: size, device: device)
                let candidate = try draw(on.content, size: size, device: device)
                var verdicts: [String] = []
                for (index, frame) in [0, 30, 120].enumerated() {
                    let a = reference.frames[index], b = candidate.frames[index]
                    let mask = PerceptualMask.edges(of: a)
                    let verdict = PerceptualCompare.evaluate(reference: a, candidate: b, kind: .lossy, textMask: mask)
                    let floor = PerceptualCompare.evaluate(reference: a, candidate: repeatRun.frames[index], kind: .lossy, textMask: mask)
                    verdicts.append(String(format: "f%d SSIM %.4f ΔE99 %.2f text %.4f (repeat %.4f/%.2f/%.4f)", frame, verdict.ssim,
                                           verdict.deltaE99, verdict.textSSIM ?? 1, floor.ssim, floor.deltaE99, floor.textSSIM ?? 1))
                    if !verdict.passed, floor.passed {
                        failures.append("\(id) \(size.x)x\(size.y) frame \(frame): \(verdict.failures)")
                    }
                }
                report.append(String(format: "  %dx%d: GPU %.2f → %.2f ms (mean), %.2f → %.2f ms (p99); GPU memory %.1f → %.1f MB; %@",
                                     size.x, size.y, reference.gpuMean, candidate.gpuMean, reference.gpuP99, candidate.gpuP99,
                                     reference.allocatedMB, candidate.allocatedMB, verdicts.joined(separator: "; ")))
            }
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let path = environment["OWE_TEXTURE_GATE_OUT"] { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func load(_ wallpaper: WEWallpaper, optimise: Bool) throws -> (content: SceneMetalContent, seconds: Double) {
        SceneContentLoader.dropSharedParses()
        var settings = SceneRenderSettings()
        settings.particleBudget = .unlimited
        settings.optimiseTextures = optimise
        let model = SceneContentLoader(wallpaper: wallpaper)
        model.setRenderSettings(settings)
        let start = CACurrentMediaTime()
        let content = try XCTUnwrap(model.metalContent(), "\(wallpaper.project.title): no content")
        let seconds: Double = CACurrentMediaTime() - start
        return (content, seconds)
    }

    private func blobSummary(_ root: URL) throws -> String {
        var compressed = 0, kept = 0, bytes = 0, source = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where url.pathExtension == TexturePreparation.fileExtension {
            let header = try TexturePreparation.decodeHeader(Data(contentsOf: url, options: .alwaysMapped))
            if header.status == .compressed {
                compressed += 1
                bytes += header.levels.reduce(0) { $0 + $1.length }
                source += header.width * header.height * 4
            } else {
                kept += 1
            }
        }
        return String(format: "%d textures compressed (%.1f MB RGBA8 → %.1f MB BC7 with mipmaps), %d kept original",
                      compressed, Double(source) / 1e6, Double(bytes) / 1e6, kept)
    }

    private struct Drawn {
        var frames: [PerceptualImage] = []
        var gpuMean = 0.0
        var gpuP99 = 0.0
        var allocatedMB = 0.0
    }

    /// Frames 0, 30 and 120 of `content` (a fixed 1/30 s clock, no scripts) and the
    /// GPU time of frames 60…120, with the GPU memory the renderer holds.
    private func draw(_ source: SceneMetalContent, size: SIMD2<Int>, device: MTLDevice) throws -> Drawn {
        let content = source
        let points = SIMD2<Float>(Float(size.x / 2), Float(size.y / 2))
        let drawable = SIMD2<Float>(Float(size.x), Float(size.y))
        let before = device.currentAllocatedSize
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: CGFloat(points.x), height: CGFloat(points.y)), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "texture-gate"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.fill)
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(120)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let viewport = SceneViewport(drawableSize: drawable, pointSize: points, cursor: nil, frameRateLimit: 30)
        // Let every pipeline compile with the clock held, so frame 0 is the same in both runs.
        var settled = 0
        while settled < 3, Date() < deadline {
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            settled = renderer.hasPendingEffectPipelines ? 0 : settled + 1
        }
        var drawn = Drawn()
        var gpu: [Double] = []
        var peak = 0
        for frame in 0...120 {
            renderer.renderShared([viewport])
            let commands = renderer.lastCommandBuffer
            commands?.waitUntilCompleted()
            peak = max(peak, device.currentAllocatedSize)
            if frame >= 60, let commands { gpu.append((commands.gpuEndTime - commands.gpuStartTime) * 1000) }
            if [0, 30, 120].contains(frame), let texture = renderer.sharedFrame {
                drawn.frames.append(PerceptualImage(width: texture.width, height: texture.height,
                                                    rgba: try TextureUploadTests.read(texture, device: device)))
            }
            now += 1.0 / 30
        }
        XCTAssertEqual(drawn.frames.count, 3)
        gpu.sort()
        drawn.gpuMean = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count)
        drawn.gpuP99 = gpu.isEmpty ? 0 : gpu[min(gpu.count - 1, Int(Double(gpu.count) * 0.99))]
        drawn.allocatedMB = Double(peak - before) / 1e6
        return drawn
    }
}
