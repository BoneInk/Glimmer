import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Camera parallax on a library wallpaper against what WE 2.8 does on Windows.
///
/// 3802047741 ("Sakura Haruno by NaughtyfeetAI") is an orthographic 1920×1080 scene with
/// `cameraparallax` on, amount 0.5 and mouse influence 0.17; its layers have no `parallaxDepth`
/// (WE's 1 1). Measured in WE 2.8.0.42 at 1920×1080: moving the cursor from the left edge to the
/// centre shifts the image by −82 px, and to the right edge by −164 px, linearly, the image moving
/// opposite to the cursor, with about 2 px of vertical drift. Skipped without the library.
final class CameraParallaxLibraryTests: XCTestCase {
    private static let wallpaper = "3802047741"
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-parallax-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    /// At 1920×1080, one frame pixel per scene unit, as WE was measured.
    func testCursorSweepMovesTheImageAsWEDoes() throws {
        try assertSweep(drawable: SIMD2(1920, 1080), points: SIMD2(1920, 1080), authoredDelay: false)
    }

    /// A 4K display at 2×: the cursor is in points, the frame twice as dense, so twice the pixels.
    func testCursorSweepOnARetinaDisplay() throws {
        try assertSweep(drawable: SIMD2(3840, 2160), points: SIMD2(1920, 1080), authoredDelay: false)
    }

    /// With the scene's own delay (0.1) and the clock running at 60 fps, the image settles on the
    /// same place within two seconds.
    func testCursorSweepSettlesWithTheAuthoredDelay() throws {
        try assertSweep(drawable: SIMD2(1920, 1080), points: SIMD2(1920, 1080), authoredDelay: true)
    }

    private func assertSweep(drawable: SIMD2<Int>, points: SIMD2<Float>, authoredDelay: Bool) throws {
        let directory = LibrarySweepTests.libraryRoot.appending(path: Self.wallpaper, directoryHint: .isDirectory)
        let projectURL = directory.appending(path: "project.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: projectURL.path), "\(Self.wallpaper) not in the library")
        let project = try JSONDecoder().decode(WEProject.self, from: try Data(contentsOf: projectURL))
        let frames = try frames(project, directory: directory, drawable: drawable, points: points,
                                cursorX: [0, points.x / 2, points.x], authoredDelay: authoredDelay)
        let scale = Double(drawable.x) / 1920
        let centre = try XCTUnwrap(Self.shift(from: frames[0], to: frames[1], width: drawable.x, scale: scale))
        let right = try XCTUnwrap(Self.shift(from: frames[0], to: frames[2], width: drawable.x, scale: scale))
        // WE: −82 and −164 at 1920 (our model: −0.5 · 0.17 · 1920 = −163.2 for the whole sweep).
        XCTAssertEqual(Double(centre.x) / scale, -82, accuracy: 3, "left edge → centre, frame pixels \(centre)")
        XCTAssertEqual(Double(right.x) / scale, -164, accuracy: 3, "left edge → right edge, frame pixels \(right)")
        XCTAssertLessThanOrEqual(Double(abs(right.y)) / scale, 3, "vertical drift")
    }

    /// The scene's finished frames (`drawable`, before placement) with the cursor at each `cursorX`
    /// (points) on the middle row. Without `authoredDelay` the delay is left out, so one frame
    /// settles the parallax, and the clock stands still so the layers' animated effects draw the
    /// same in every frame; with it, 2 s of 60 fps frames run before each capture.
    private func frames(_ project: WEProject, directory: URL, drawable: SIMD2<Int>, points: SIMD2<Float>,
                        cursorX: [Float], authoredDelay: Bool) throws -> [[UInt8]] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var content = try XCTUnwrap(model.metalContent())
        XCTAssertEqual(content.size, SIMD2(1920, 1080))
        XCTAssertTrue(content.camera.parallax)
        XCTAssertEqual(content.camera.parallaxAmount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(content.camera.parallaxMouseInfluence, 0.17, accuracy: 1e-6)
        XCTAssertEqual(content.camera.parallaxDelay, 0.1, accuracy: 1e-6)
        if !authoredDelay { content.camera.parallaxDelay = 0 }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: CGFloat(points.x), height: CGFloat(points.y)), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: drawable.x, height: drawable.y)
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "parallax"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.fill)
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        var result: [[UInt8]] = []
        for x in cursorX {
            let viewport = SceneViewport(drawableSize: SIMD2(Float(drawable.x), Float(drawable.y)), pointSize: points,
                                         cursor: SIMD2(x, points.y / 2), frameRateLimit: 60)
            // Pipelines compile off the render thread; the last of these frames is complete.
            for _ in 0..<120 {
                if authoredDelay { now += 1.0 / 60 }
                renderer.renderShared([viewport])
                renderer.lastCommandBuffer?.waitUntilCompleted()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            let texture = try XCTUnwrap(renderer.sharedFrame)
            XCTAssertEqual(SIMD2(texture.width, texture.height), drawable)
            result.append(try TextureUploadTests.read(texture, device: device))
        }
        return result
    }

    /// The whole-pixel shift that best maps the middle of `a` onto `b` (least mean absolute
    /// difference of the green channel): searched over ±300 px (at 1920 wide, `scale` times that
    /// in a larger frame) horizontally, then ±8 px vertically around the best column shift.
    private static func shift(from a: [UInt8], to b: [UInt8], width: Int, scale: Double) -> SIMD2<Int>? {
        let range = Int(300 * scale)
        let rows = Array(stride(from: Int(300 * scale), to: Int(780 * scale), by: Int(8 * scale)))
        let columns = Array(stride(from: Int(400 * scale), to: Int(1520 * scale), by: Int(2 * scale)))
        func best(_ candidates: [SIMD2<Int>]) -> SIMD2<Int>? {
            candidates.map { (shift: $0, error: difference(a, b, width: width, rows: rows, columns: columns, shift: $0)) }
                .min { $0.error < $1.error }?.shift
        }
        guard let column = best((-range...range).map { SIMD2($0, 0) }) else { return nil }
        return best((-8...8).flatMap { dy in (-2...2).map { SIMD2(column.x + $0, dy) } })
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8], width: Int, rows: [Int], columns: [Int],
                                   shift: SIMD2<Int>) -> Double {
        var total = 0
        for row in rows {
            // Texture rows run top-down; a layer moving up by dy scene units is dy rows higher.
            let rowA = row * width
            let rowB = (row - shift.y) * width
            for column in columns {
                total += abs(Int(a[(rowA + column) * 4 + 1]) - Int(b[(rowB + column + shift.x) * 4 + 1]))
            }
        }
        return Double(total) / Double(rows.count * columns.count)
    }
}
