import XCTest
import MetalKit
import AppKit
@testable import OpenWallpaperEngine

/// Blend-mode layers copy only the part of the scene they read, and share a copy that still holds.
final class SceneSnapshotTrackerTests: XCTestCase {
    private typealias Rect = SceneSnapshotTracker.Rect

    // MARK: - Rects

    func testPixelRectIsTheQuadsPaddedBoxInTheYDownTarget() throws {
        // A 20×10 unit quad whose top-left is at (10, 90) in a 100×100 scene drawn at 2 px per unit.
        let quad = SceneQuadGeometry(center: SIMD2(20, 85), axisX: SIMD2(20, 0), axisY: SIMD2(0, 10))
        let rect = try XCTUnwrap(SceneSnapshotTracker.pixelRect(of: quad, sceneSize: SIMD2(100, 100), targetSize: SIMD2(200, 200)))
        let pad = SceneSnapshotTracker.padding
        XCTAssertEqual(rect, Rect(x: 20 - pad, y: 20 - pad, width: 40 + 2 * pad, height: 20 + 2 * pad))
    }

    func testRotatedQuadsUseTheirBoundingBox() throws {
        let quad = SceneQuadGeometry(center: SIMD2(50, 50), axisX: SIMD2(10, 10), axisY: SIMD2(-10, 10))
        let rect = try XCTUnwrap(SceneSnapshotTracker.pixelRect(of: quad, sceneSize: SIMD2(100, 100), targetSize: SIMD2(100, 100)))
        let pad = SceneSnapshotTracker.padding
        XCTAssertEqual(rect, Rect(x: 40 - pad, y: 40 - pad, width: 20 + 2 * pad, height: 20 + 2 * pad))
    }

    func testOffscreenAndDegenerateQuadsCoverNothing() {
        let size = SIMD2<Float>(100, 100), target = SIMD2(100, 100)
        XCTAssertNil(SceneSnapshotTracker.pixelRect(of: SceneQuadGeometry(center: SIMD2(500, 50), axisX: SIMD2(10, 0),
                                                                          axisY: SIMD2(0, 10)), sceneSize: size, targetSize: target))
        XCTAssertNil(SceneSnapshotTracker.pixelRect(of: SceneQuadGeometry(center: SIMD2(.nan, 50), axisX: SIMD2(10, 0),
                                                                          axisY: SIMD2(0, 10)), sceneSize: size, targetSize: target))
        let huge = SceneQuadGeometry(center: SIMD2(50, 50), axisX: SIMD2(1e30, 0), axisY: SIMD2(0, 1e30))
        XCTAssertEqual(SceneSnapshotTracker.pixelRect(of: huge, sceneSize: size, targetSize: target),
                       Rect(x: 0, y: 0, width: 100, height: 100), "clamped, not overflowing")
    }

    // MARK: - Sharing

    func testACopyIsSharedUntilSomethingIsDrawnOverIt() {
        var tracker = SceneSnapshotTracker()
        let whole = Rect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(tracker.copy(for: whole), whole)
        XCTAssertNil(tracker.copy(for: Rect(x: 10, y: 10, width: 20, height: 20)), "nothing drawn since: shared")
        tracker.sceneDrawn(in: Rect(x: 0, y: 0, width: 100, height: 30))
        XCTAssertNil(tracker.copy(for: Rect(x: 10, y: 40, width: 20, height: 20)), "the draw didn't touch this part")
        XCTAssertEqual(tracker.copy(for: Rect(x: 10, y: 20, width: 20, height: 20)), Rect(x: 10, y: 20, width: 20, height: 20),
                       "overlaps the draw: copied again, just this rect")
        tracker.sceneDrawn(in: nil)
        XCTAssertNotNil(tracker.copy(for: Rect(x: 10, y: 20, width: 20, height: 20)), "drawn anywhere (particles)")
        XCTAssertNil(tracker.copy(for: .empty), "covers no pixel: nothing to copy")
        tracker.reset()
        XCTAssertNotNil(tracker.copy(for: Rect(x: 10, y: 20, width: 20, height: 20)), "a new frame copies again")
    }

    func testDrawsKeepTheLargestUntouchedBand() {
        var tracker = SceneSnapshotTracker()
        _ = tracker.copy(for: Rect(x: 0, y: 0, width: 100, height: 100))
        tracker.sceneDrawn(in: Rect(x: 70, y: 0, width: 30, height: 100))
        XCTAssertEqual(tracker.valid, Rect(x: 0, y: 0, width: 70, height: 100))
        tracker.sceneDrawn(in: Rect(x: 200, y: 200, width: 5, height: 5))
        XCTAssertEqual(tracker.valid, Rect(x: 0, y: 0, width: 70, height: 100), "a draw elsewhere changes nothing")
    }

    // MARK: - Whole frames

    /// A: grey under everything. B (left) and C (centre, over B) add colour through `BLENDMODE`
    /// 9 (add), each reading the scene under it; D (right) does too, alone. Every result needs the
    /// scene as drawn just before that layer, and far less than whole-scene copies are made.
    func testBlendLayersReadTheSceneBeneathFromPartialCopies() throws {
        _ = try Fixtures.assets()
        let size = 128
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size, height: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size, height: size)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)

        let scene = Float(size)
        let blend = try addMaterial()
        let a = layer("A", color: [0.25, 0.25, 0.25, 1], center: SIMD2(scene / 2, scene / 2), size: SIMD2(scene, scene), order: 0)
        var b = layer("B", color: [0, 0.25, 0, 1], center: SIMD2(32, 64), size: SIMD2(64, 32), order: 1)
        var c = layer("C", color: [0, 0, 0.5, 1], center: SIMD2(64, 64), size: SIMD2(64, 32), order: 2)
        var d = layer("D", color: [0.5, 0, 0, 1], center: SIMD2(116, 20), size: SIMD2(24, 24), order: 3)
        b.imageMaterial = blend
        c.imageMaterial = blend
        d.imageMaterial = blend
        renderer.setContent(SceneMetalContent(
            size: SIMD2(scene, scene), layers: [a, b, c, d], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))))

        // Pixel rows are y down; scene y is up. BGRA bytes.
        let expectations: [(x: Int, y: Int, bgra: [Double], what: String)] = [
            (16, 64, [0.25, 0.5, 0.25], "B over A"),
            (48, 64, [0.75, 0.5, 0.25], "C over B over A"),
            (88, 64, [0.75, 0.25, 0.25], "C over A"),
            (116, 108, [0.25, 0.25, 0.75], "D over A"),
            (116, 64, [0.25, 0.25, 0.25], "A alone"),
        ]
        func matches(_ pixels: [UInt8]) -> [String] {
            expectations.compactMap { entry in
                let index = (entry.y * size + entry.x) * 4
                guard pixels.count > index + 3 else { return entry.what }
                let actual = (0..<3).map { Double(pixels[index + $0]) / 255 }
                let close = zip(actual, entry.bgra).allSatisfy { abs($0 - $1) < 3.0 / 255 }
                return close ? nil : "\(entry.what): \(actual)"
            }
        }
        var pixels: [UInt8] = []
        var copied = 0
        let deadline = Date().addingTimeInterval(20)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let before = renderer.snapshotTracker.pixelsCopied
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            copied = renderer.snapshotTracker.pixelsCopied - before
            guard let texture = view.currentDrawable?.texture else { continue }
            pixels = [UInt8](repeating: 0, count: size * size * 4)
            texture.getBytes(&pixels, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        } while Date() < deadline && !matches(pixels).isEmpty
        XCTAssertEqual(matches(pixels), [])
        XCTAssertGreaterThan(copied, 0)
        XCTAssertLessThan(copied, size * size / 2, "three small layers copy their own rects, not three whole scenes")
    }

    private func addMaterial() throws -> ImageMaterialPlan {
        let roots = [Fixtures.url("ImageMaterials"), ShaderVariantTests.weAssets]
        let builder = ImageMaterialPlanBuilder(
            translator: ShaderVariantTranslator(compiler: InProcessShaderCompiler(), cacheDirectory: nil),
            readFile: { path in roots.lazy.compactMap { FileManager.default.contents(atPath: $0.appending(path: path).path) }.first },
            loadTexture: { _, _ in nil })
        return try XCTUnwrap(try builder.build(materialPath: "materials/image4.json", colorBlendMode: 9))
    }

    private func layer(_ id: String, color: [Double], center: SIMD2<Float>, size: SIMD2<Float>, order: Int) -> SceneMetalLayer {
        var layer = SceneMetalLayer(
            id: id, name: id, source: .image(SceneContentLoader.pixelImage(color)), position: center, size: size,
            scale: SIMD2(1, 1), opacity: 1,
            brightness: 1, color: SIMD4(repeating: 1), text: nil,
            parallaxDepth: .zero, perspective: false, rotation: 0)
        layer.order = order
        return layer
    }
}
