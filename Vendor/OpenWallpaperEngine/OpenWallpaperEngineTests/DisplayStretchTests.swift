import XCTest
@testable import OpenWallpaperEngine

/// WE's stretch (span): one canvas, the bounding box of the displays' desktop rects with the gaps
/// in it, each display showing its own rect; one running instance and one video player; the
/// cursor mapped onto the canvas.
@MainActor
final class DisplayStretchTests: XCTestCase {
    /// A Retina 1512×982 main display, a 2560×1440 display to its right whose top is 200 points
    /// higher, and a 1920×1080 display to the left with a negative origin and a 100-point gap.
    private let displays = [
        DisplayIdentity(screenId: "1", identity: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
        DisplayIdentity(screenId: "2", identity: "UUID-B", frame: CGRect(x: 1512, y: -258, width: 2560, height: 1440)),
        DisplayIdentity(screenId: "3", identity: "UUID-C", frame: CGRect(x: -2020, y: 0, width: 1920, height: 1080))
    ]

    private func wallpaper(_ folder: String, type: String = "scene", file: String = "scene.json") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: file, preview: "preview.jpg", title: folder, type: type),
                    where: URL(filePath: "/tmp/owe-stretch-tests/\(folder)"))
    }

    private func model() -> WallpaperViewModel {
        let model = WallpaperViewModel(persistsWallpapers: false)
        model.connectedDisplays = { [displays] in displays }
        model.audioOutputEnabled = false
        model.wallpapers = ["1": wallpaper("a"), "2": wallpaper("b"), "3": wallpaper("c")]
        return model
    }

    // MARK: Canvas maths

    func testTheCanvasIsTheBoundingBoxWithItsGaps() {
        let frames = displays.map(\.frame)
        let canvas = DisplayCanvas.bounds(of: frames)
        XCTAssertEqual(canvas, CGRect(x: -2020, y: -258, width: 6092, height: 1440),
                       "negative origins and the 100-point gap are part of the canvas")
        XCTAssertEqual(DisplayCanvas.bounds(of: []), .null)
        XCTAssertEqual(DisplayCanvas.bounds(of: [frames[0]]), frames[0])
    }

    func testEachDisplayShowsItsOwnRectFromTheCanvasTopLeft() {
        let canvas = DisplayCanvas.bounds(of: displays.map(\.frame))
        // The right display is the canvas's whole height.
        XCTAssertEqual(DisplayCanvas.rect(of: displays[1].frame, in: canvas), CGRect(x: 3532, y: 0, width: 2560, height: 1440))
        // The left display: 102 points below the canvas's top.
        XCTAssertEqual(DisplayCanvas.rect(of: displays[2].frame, in: canvas), CGRect(x: 0, y: 102, width: 1920, height: 1080))
        // The main display starts after the left one and the gap.
        XCTAssertEqual(DisplayCanvas.rect(of: displays[0].frame, in: canvas), CGRect(x: 2020, y: 200, width: 1512, height: 982))
        let unit = DisplayCanvas.unitRect(of: displays[1].frame, in: canvas)
        XCTAssertEqual(unit.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(unit.maxY, 1, accuracy: 1e-9, "it ends at the canvas's bottom")
        XCTAssertEqual(unit.width, 2560 / 6092, accuracy: 1e-9)
    }

    func testTheCanvasFitsTheGPUsLargestTextureOnly() {
        let size = CGSize(width: 6092, height: 1440)
        XCTAssertEqual(DisplayCanvas.pixelSize(of: size, scale: 2, maximumDimension: 16384), CGSize(width: 12184, height: 2880))
        let fitted = DisplayCanvas.pixelSize(of: size, scale: 3, maximumDimension: 16384)
        XCTAssertEqual(fitted.width, 16384)
        XCTAssertEqual(fitted.width / fitted.height, size.width / size.height, accuracy: 0.01, "scaled, aspect kept")
    }

    // MARK: Sub-rect and cursor

    private func snapshot(of display: DisplayIdentity, canvas: CGRect) -> SceneViewSnapshot {
        var snapshot = SceneViewSnapshot()
        snapshot.pointSize = SIMD2(Float(display.frame.width), Float(display.frame.height))
        snapshot.viewInScreen = display.frame
        snapshot.screenFrame = display.frame
        snapshot.canvas = canvas
        return snapshot
    }

    func testAStretchedDisplayPresentsItsRectOfTheFramePlacedOnTheCanvas() throws {
        let canvas = DisplayCanvas.bounds(of: displays.map(\.frame))
        // The Retina display: 2 pixels per point.
        let span = try XCTUnwrap(SceneCanvasSpan(snapshot: snapshot(of: displays[0], canvas: canvas), pixelsPerPoint: 2))
        XCTAssertEqual(span.canvasPixels, SIMD2(12184, 2880))
        XCTAssertEqual(span.origin, SIMD2(4040, 516), "its bottom-left on the canvas, y up, in its pixels")
        // A quad covering the canvas lands so that the display sees its own part.
        var uniform = LayerUniform(position: span.canvasPixels / 2, size: span.canvasPixels, sceneSize: span.canvasPixels,
                                   opacity: 1, particleShape: 0, rotation: 0, color: SIMD4(repeating: 1),
                                   uvOrigin: .zero, uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1),
                                   effects: SIMD4(1, 1, 1, 0), blur: 0, colorEffects: SIMD4(0, 1, 0, 0.7),
                                   transform: SIMD4(0, 0, 0, 1), transformScaleY: 1)
        let drawable = SIMD2<Float>(3024, 1964)
        span.apply(to: &uniform, drawableSize: drawable)
        XCTAssertEqual(uniform.sceneSize, drawable)
        // The canvas's left edge is 4040 pixels left of the display, its bottom 516 below.
        XCTAssertEqual(uniform.position - uniform.size / 2, SIMD2(-4040, -516))
        XCTAssertNil(SceneCanvasSpan(snapshot: SceneViewSnapshot(), pixelsPerPoint: 2), "not stretched")
    }

    func testTheCursorMapsIntoTheCanvasFromTheDisplayItIsOn() {
        let canvas = DisplayCanvas.bounds(of: displays.map(\.frame))
        let left = snapshot(of: displays[2], canvas: canvas)
        let main = snapshot(of: displays[0], canvas: canvas)
        let onMain = CGPoint(x: 100, y: 50)
        XCTAssertEqual(main.canvasCursor(at: onMain), SIMD2(2120, 308), "origin bottom-left of the canvas")
        XCTAssertNil(left.canvasCursor(at: onMain), "only the display under the cursor reports it")
        XCTAssertNil(main.canvasCursor(at: CGPoint(x: -50, y: 500)), "the gap shows nothing and has no cursor")
        XCTAssertEqual(left.canvasCursor(at: CGPoint(x: -2020, y: 0)), SIMD2(0, 258))
    }

    // MARK: Layout

    func testTheStretchLayoutSpansEveryDisplayFromTheMainOne() {
        let model = model()
        model.setLayout(.stretch)
        let resolution = model.layoutResolution
        XCTAssertEqual(resolution.stretches.count, 1)
        XCTAssertEqual(resolution.stretches[0].source, "1", "the main display's wallpaper")
        XCTAssertEqual(resolution.canvases["3"], DisplayCanvas.bounds(of: displays.map(\.frame)))
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "a", "a"])
        XCTAssertEqual(Set(["1", "2", "3"].map { model.instanceKey(for: $0) }).count, 1, "one instance renders the canvas")
        model.setLayout(.perDisplay)
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["a", "b", "c"],
                       "each display's own pick is back")
        XCTAssertTrue(model.layoutResolution.canvases.isEmpty)
    }

    func testAStretchGroupSpansItsMembersOnly() {
        let model = model()
        model.addStretchGroup(["2", "1"])
        XCTAssertTrue(model.isStretched("1") && model.isStretched("2"))
        XCTAssertFalse(model.isStretched("3"))
        XCTAssertEqual(model.layoutResolution.canvases["1"], displays[0].frame.union(displays[1].frame))
        XCTAssertNil(model.layoutResolution.canvases["3"])
        model.setWallpaper(wallpaper("d"), for: "2")
        XCTAssertEqual(["1", "2", "3"].map { model.wallpaper(for: $0).project.title }, ["d", "d", "c"])
        model.removeGroup(containing: "2")
        XCTAssertFalse(model.isStretched("1"))
        XCTAssertEqual(model.wallpaper(for: "2").project.title, "b")
    }

    func testAVideoStretchUsesOnePlayer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-stretch-video-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: best-effort cleanup.
        let clip = try VideoClipFixture.make(frames: 10, in: directory)
        let video = WEWallpaper(using: WEProject(file: clip.lastPathComponent, preview: "p.jpg", title: "clip", type: "video"),
                                where: clip.deletingLastPathComponent())
        let model = model()
        model.wallpapers["1"] = video
        model.addStretchGroup(["1", "2"])

        // As `AudioReactiveVideoWallpaperView` takes each display's player.
        var made = 0
        let leases = ["1", "2"].map { screen in
            let wallpaper = model.wallpaper(for: screen)
            return WallpaperInstanceLease(model.videoInstances, key: WallpaperInstanceKey(wallpaper)) {
                made += 1
                return VideoWallpaperViewModel(wallpaper: wallpaper, wallpaperViewModel: model)
            }
        }
        defer { leases.forEach { $0.instance.stop(); $0.release() } }
        XCTAssertEqual(made, 1, "one decode for the whole canvas")
        XCTAssertTrue(leases[0].instance.player === leases[1].instance.player)
    }
}
