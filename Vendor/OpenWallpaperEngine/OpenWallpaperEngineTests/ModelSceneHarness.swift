import XCTest
import MetalKit
import OSLog
import simd
@testable import OpenWallpaperEngine

/// One wallpaper drawn headlessly by the real loader and renderer for the model tests
/// (`ModelLibraryRenderTests`, `ModelAdversarialTests`): the view model builds its content with
/// the given render settings, the renderer draws it on one offscreen display, and the scene clock
/// is stepped by hand (`SceneMetalRenderer.wallTime`), so frames are reproducible. Every frame's
/// command buffer is checked for a GPU error, and a frame's wall time is bounded, so a hang shows
/// as a failure instead of a stuck run.
final class ModelSceneHarness {
    let directory: URL
    let model: SceneContentLoader
    let renderer: SceneMetalRenderer
    let view: MTKView
    let device: MTLDevice
    let size: SIMD2<Int>
    let content: SceneMetalContent
    /// The clock the renderer reads (seconds); `frame(step:)` advances it.
    private(set) var now: CFTimeInterval = 1000
    /// Frames whose command buffer ended with an error, and the errors.
    private(set) var gpuErrors: [String] = []
    /// The longest a frame took on the render thread, scripts included (seconds).
    private(set) var slowestFrame: Double = 0

    struct Timing {
        var gpu: [Double] = []
        var cpu: [Double] = []

        var gpuMedian: Double { Self.median(gpu) }
        var cpuMedian: Double { Self.median(cpu) }
        var gpuMax: Double { gpu.max() ?? 0 }

        static func median(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.sorted()[values.count / 2] }
    }

    /// Loads `directory`'s wallpaper; nil content fails the calling test.
    init(directory: URL, settings: SceneRenderSettings, size: SIMD2<Int>, storage: URL,
         media: SceneScriptReplayMediaSource = SceneScriptReplayMediaSource(),
         file: StaticString = #filePath, line: UInt = #line) throws {
        self.directory = directory
        self.size = size
        let project = try Self.project(in: directory)
        Fixtures.removeStoredSettings(for: directory)
        model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        model.setRenderSettings(settings)
        content = try XCTUnwrap(model.metalContent(), "\(directory.lastPathComponent): no content", file: file, line: line)
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let points = CGSize(width: size.x, height: size.y)
        view = MTKView(frame: CGRect(origin: .zero, size: points), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = points
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: media, spectrum: { .silent })
        renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "model-harness"))
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.renderSettings = settings
        renderer.scripts.frameWait = 5
        renderer.wallTime = { [unowned self] in self.now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent, "\(directory.lastPathComponent) never got its content", file: file, line: line)
    }

    /// The folder's project. WE's default projects name no `type` (WE opens their `.json` file as a
    /// scene), which `WEProject` requires, so a missing one reads as "scene" here.
    static func project(in directory: URL) throws -> WEProject {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.json5Allowed]) as? [String: Any],
                                 "\(directory.lastPathComponent): project.json isn't an object")
        if json["type"] == nil, (json["file"] as? String)?.lowercased().hasSuffix(".json") == true { json["type"] = "scene" }
        return try decodeTolerant(WEProject.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func close() {
        renderer.releaseContent()
        Fixtures.removeStoredSettings(for: directory)
    }

    /// The model renderer (the app's `SceneModelRenderer`).
    var models: SceneModelRenderer? { renderer.modelDrawing as? SceneModelRenderer }

    /// Draws one frame after advancing the clock by `step`; returns its render-thread time and its
    /// GPU time (ms).
    @discardableResult
    func frame(step: Double = 1.0 / 30) -> (cpu: Double, gpu: Double) {
        now += step
        let drawable = SIMD2<Float>(Float(size.x), Float(size.y))
        let start = CACurrentMediaTime()
        renderer.renderShared([SceneViewport(drawableSize: drawable, pointSize: drawable, cursor: drawable / 2,
                                             frameRateLimit: 30)])
        let cpu = CACurrentMediaTime() - start
        var gpu = 0.0
        if let buffer = renderer.lastCommandBuffer {
            buffer.waitUntilCompleted()
            if let error = buffer.error { gpuErrors.append("\(error)") }
            gpu = max(0, buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        }
        renderer.scripts.wallpaper?.waitUntilIdle()
        RunLoop.main.run(until: Date())
        slowestFrame = max(slowestFrame, CACurrentMediaTime() - start)
        return (cpu * 1000, gpu)
    }

    /// Draws with the clock held until the pipelines have compiled and the frame stops changing
    /// (at most `seconds` of wall time); returns whether it settled. The scene clock can't stand
    /// quite still: like WE's, it advances at least 0.1 ms a frame (`SceneClock`), so "stopped
    /// changing" is a mean difference below a fifth of a level between frames 8 apart, twice.
    @discardableResult
    func settle(seconds: Double = 20) throws -> Bool {
        var previous: [UInt8]?
        var still = 0
        let deadline = Date().addingTimeInterval(seconds)
        var count = 0
        while Date() < deadline {
            frame(step: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            count += 1
            guard count % 8 == 0, let texture = renderer.sharedFrame else { continue }
            let bytes = try TextureUploadTests.read(texture, device: device)
            // A frame drawn while a pipeline compiles lacks what it draws: at alpha 0 (or off screen) it
            // looks the same as the finished one, so stillness alone doesn't say the scene is drawn.
            if let previous, count >= 24, !renderer.pipelinesCompiling, Self.meanDifference(bytes, previous) < 0.2 {
                still += 1
                if still == 2 { return true }
            } else {
                still = 0
            }
            previous = bytes
        }
        return false
    }

    /// Draws with the clock held until no pipeline has compiled for three frames in a row (at most
    /// `seconds` of wall time), as WE has every shader of a scene compiled before its first frame;
    /// returns whether they did.
    @discardableResult
    func waitForPipelines(seconds: Double = 60) -> Bool {
        var idle = 0
        let deadline = Date().addingTimeInterval(seconds)
        while idle < 3, Date() < deadline {
            frame(step: 0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            idle = renderer.pipelinesCompiling ? 0 : idle + 1
        }
        return idle >= 3
    }

    /// The mean absolute difference of two frames' bytes (levels of 255).
    static func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0
        a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                for index in 0..<x.count { total += abs(Int(x[index]) - Int(y[index])) }
            }
        }
        return Double(total) / Double(a.count)
    }

    /// `frames` frames at 1/30 s each, timed.
    func run(frames: Int) -> Timing {
        var timing = Timing()
        for _ in 0..<frames {
            let measured = frame()
            timing.cpu.append(measured.cpu)
            timing.gpu.append(measured.gpu)
        }
        return timing
    }

    // MARK: - Checks

    /// Values in a float target (scene target, reflection, shadow atlas) that aren't finite; nil
    /// for a format without floats (an 8-bit target can't hold a NaN).
    static func nonFiniteCount(_ texture: MTLTexture, device: MTLDevice) throws -> Int? {
        let (bytesPerPixel, components): (Int, Int)
        switch texture.pixelFormat {
        case .rgba16Float: (bytesPerPixel, components) = (8, 4)
        case .rgba32Float: (bytesPerPixel, components) = (16, 4)
        case .r32Float, .depth32Float: (bytesPerPixel, components) = (4, 1)
        case .rg16Float: (bytesPerPixel, components) = (4, 2)
        case .r16Float: (bytesPerPixel, components) = (2, 1)
        default: return nil
        }
        guard texture.sampleCount == 1, texture.textureType == .type2D else { return nil }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let rowBytes = texture.width * bytesPerPixel
        let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let count = texture.width * texture.height * components
        if bytesPerPixel / components == 2 {
            let values = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self), count: count)
            // A half is NaN or infinite when its exponent bits are all set.
            return values.reduce(0) { $0 + ($1 & 0x7C00 == 0x7C00 ? 1 : 0) }
        }
        let values = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: count)
        return values.reduce(0) { $0 + ($1.isFinite ? 0 : 1) }
    }

    /// Whether every posed bone of every model and puppet is finite.
    func posesAreFinite() -> [String] {
        var bad: [String] = []
        func finite(_ matrix: simd_float4x4) -> Bool {
            [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].allSatisfy { column in
                column.x.isFinite && column.y.isFinite && column.z.isFinite && column.w.isFinite
            }
        }
        for object in content.spatial.models {
            guard let animator = models?.animator(for: object.id) else { continue }
            if !animator.pose.bones.allSatisfy(finite) { bad.append("model \(object.id) \(object.name)") }
        }
        for layer in content.layers where layer.puppet != nil {
            guard let pose = renderer.puppetPose(ofLayer: layer.id) else { continue }
            if !pose.bones.allSatisfy(finite) { bad.append("puppet \(layer.id) \(layer.name)") }
        }
        return bad
    }
}

/// Error lines this process logged through `OWELog` since a moment (the unified log's
/// current-process store), so a test can check that a bad input was logged.
struct ModelLogWindow {
    let start = Date()

    func lines(containing text: String) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let position = store.position(date: start.addingTimeInterval(-1))
            return try store.getEntries(at: position)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "app.openwallpaperengine" && $0.date >= start.addingTimeInterval(-1) }
                .map(\.composedMessage)
                .filter { $0.contains(text) }
        } catch {
            XCTFail("the process log can't be read: \(error)")
            return []
        }
    }
}
