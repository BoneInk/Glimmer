import CoreGraphics
import XCTest
@testable import OWESceneEditing

/// WE's Foreground Separation: the min cut, GrabCut from strokes, the polygon tool, Fine-tuning,
/// the two pictures it makes and how OK changes the scene.
final class ForegroundSeparationTests: XCTestCase {
    func testMaxFlowCutsTheCheapestEdges() {
        // source → 0 → 1 → sink, with a weak middle edge.
        var graph = MaxFlowGraph(vertices: 2)
        graph.addTerminalWeights(0, source: 10, sink: 0)
        graph.addTerminalWeights(1, source: 0, sink: 10)
        graph.addEdges(0, 1, weight: 3, reverse: 3)
        XCTAssertEqual(graph.maxFlow(), 3)
        XCTAssertTrue(graph.isOnSourceSide(0))
        XCTAssertFalse(graph.isOnSourceSide(1))
    }

    func testMaxFlowOnAChainFindsTheBottleneck() {
        var graph = MaxFlowGraph(vertices: 4)
        graph.addTerminalWeights(0, source: 5, sink: 0)
        graph.addTerminalWeights(3, source: 0, sink: 5)
        graph.addEdges(0, 1, weight: 4, reverse: 0)
        graph.addEdges(1, 2, weight: 2, reverse: 0)
        graph.addEdges(2, 3, weight: 4, reverse: 0)
        graph.addEdges(0, 2, weight: 1, reverse: 0)
        XCTAssertEqual(graph.maxFlow(), 3)
        XCTAssertTrue(graph.isOnSourceSide(1))
        XCTAssertFalse(graph.isOnSourceSide(2))
    }

    /// A red square on a blue field, with noise.
    private func square(size: Int = 40) -> RGBAImage {
        var image = RGBAImage(width: size, height: size)
        var generator = SplitMix64(seed: 7)
        for y in 0..<size {
            for x in 0..<size {
                let inside = x >= size / 4 && x < 3 * size / 4 && y >= size / 4 && y < 3 * size / 4
                let noise = Int(generator.next() % 30)
                let index = (y * size + x) * 4
                image.pixels[index] = UInt8(inside ? 200 + noise : 20 + noise)
                image.pixels[index + 1] = UInt8(30 + noise)
                image.pixels[index + 2] = UInt8(inside ? 20 + noise : 200 + noise)
                image.pixels[index + 3] = 255
            }
        }
        return image
    }

    func testGrabCutGrowsAStrokeToTheObject() {
        let image = square()
        var marks = SeparationMarks(width: 40, height: 40)
        marks.mode = .brush
        marks.paint(from: SIMD2(18, 20), to: SIMD2(22, 20), diameter: 3, mark: .foreground)
        marks.paint(from: SIMD2(2, 2), to: SIMD2(38, 2), diameter: 3, mark: .background)
        var settings = ForegroundSeparator.Settings()
        settings.smoothing = 0
        settings.maskTolerance = 0
        let mask = try! XCTUnwrap(ForegroundSeparator.mask(image, marks: marks, prior: nil, settings: settings))
        XCTAssertGreaterThan(mask[12, 12], 0.9, "the square's corner is found from a stroke in its middle")
        XCTAssertGreaterThan(mask[27, 27], 0.9)
        XCTAssertLessThan(mask[5, 30], 0.1, "the field stays background")
        XCTAssertLessThan(mask[35, 35], 0.1)
    }

    func testThePriorAloneSeparates() {
        let image = square()
        var prior = ImagePlane(width: 40, height: 40)
        for y in 12..<28 { for x in 12..<28 { prior[x, y] = 1 } }
        var marks = SeparationMarks(width: 40, height: 40)
        marks.mode = .brush
        let mask = try! XCTUnwrap(ForegroundSeparator.mask(image, marks: marks, prior: prior, settings: ForegroundSeparator.Settings()))
        XCTAssertGreaterThan(mask[20, 20], 0.9)
        XCTAssertLessThan(mask[3, 3], 0.1)
        // Nothing to go on: no mask.
        XCTAssertNil(ForegroundSeparator.mask(image, marks: marks, prior: nil, settings: ForegroundSeparator.Settings()))
    }

    func testPolygonsFillTheirInsideAndCancelWhereTheyOverlap() {
        var marks = SeparationMarks(width: 20, height: 20)
        marks.polygons = [[SIMD2(2, 2), SIMD2(12, 2), SIMD2(12, 12), SIMD2(2, 12), SIMD2(2, 2)],
                          [SIMD2(8, 8), SIMD2(18, 8), SIMD2(18, 18), SIMD2(8, 18), SIMD2(8, 8)]]
        let mask = marks.polygonMask(smoothing: 0)
        XCTAssertEqual(mask[4, 4], 1)
        XCTAssertEqual(mask[15, 15], 1)
        XCTAssertEqual(mask[10, 10], 0, "WE fills overlapping outlines with xor")
        XCTAssertEqual(mask[0, 0], 0)
        // Smoothing curves the outline through its points, bulging its straight sides.
        let single = SeparationMarks(width: 20, height: 20, polygons: [marks.polygons[0]])
        XCTAssertEqual(single.polygonMask(smoothing: 0)[7, 1], 0)
        XCTAssertEqual(single.polygonMask(smoothing: 5)[7, 1], 1)
        XCTAssertEqual(single.polygonMask(smoothing: 5)[7, 7], 1)
    }

    func testBrushSizeIsWEs() {
        XCTAssertEqual(SeparationMarks.brushDiameter(percent: 1, width: 1920, height: 1080), 1)
        XCTAssertEqual(SeparationMarks.brushDiameter(percent: 100, width: 1920, height: 1080), 961, accuracy: 1e-9)
        XCTAssertEqual(SeparationMarks.brushDiameter(percent: 100, width: 300, height: 200), 201, accuracy: 1e-9)
        XCTAssertEqual(SeparationMarks.brushDiameter(percent: 20, width: 400, height: 400), 200 * pow(19.0 / 99, 1.5) + 1, accuracy: 1e-9)
    }

    func testMaskToleranceGrowsAndShrinks() {
        var mask = ImagePlane(width: 30, height: 30)
        for y in 10..<20 { for x in 10..<20 { mask[x, y] = 1 } }
        let grown = ForegroundSeparator.grown(mask, by: 2)
        XCTAssertEqual(grown[8, 15], 1)
        XCTAssertEqual(grown[7, 15], 0)
        let shrunk = ForegroundSeparator.grown(mask, by: -2)
        XCTAssertEqual(shrunk[11, 15], 0)
        XCTAssertEqual(shrunk[12, 15], 1)
    }

    func testTheTwoPictures() {
        let image = square()
        var mask = ImagePlane(width: 40, height: 40)
        for y in 10..<30 { for x in 10..<30 { mask[x, y] = 1 } }
        let result = ForegroundSeparator.separate(image, mask: mask, settings: ForegroundSeparator.Settings())
        // The foreground: the picture, with the mask as alpha.
        XCTAssertEqual(result.foreground.pixels[(20 * 40 + 20) * 4 + 3], 255)
        XCTAssertEqual(result.foreground.pixels[(2 * 40 + 2) * 4 + 3], 0)
        XCTAssertEqual(result.foreground.pixels[(20 * 40 + 20) * 4], image.pixels[(20 * 40 + 20) * 4])
        // The background: the square's area filled with the field's blue, opaque.
        let middle = (20 * 40 + 20) * 4
        XCTAssertGreaterThan(result.background.pixels[middle + 2], 150)
        XCTAssertLessThan(result.background.pixels[middle], 120)
        XCTAssertEqual(result.background.pixels[middle + 3], 255)
        XCTAssertEqual(result.background.pixels[(1 * 40 + 1) * 4 + 2], image.pixels[(1 * 40 + 1) * 4 + 2])
    }

    func testFillGapsKeepsTheCutOutAreaNearThePicture() {
        // A cut-out: an opaque body (left) and an opaque limb sticking out to the right, on transparency.
        var image = RGBAImage(width: 60, height: 20)
        for y in 0..<20 {
            for x in 0..<60 where (x < 30 && y >= 2 && y < 18) || (x >= 30 && y >= 8 && y < 12) {
                let index = (y * 60 + x) * 4
                image.pixels[index] = 180
                image.pixels[index + 3] = 255
            }
        }
        var mask = ImagePlane(width: 60, height: 20)
        for y in 8..<12 { for x in 22..<60 { mask[x, y] = 1 } }
        var settings = ForegroundSeparator.Settings.sheet
        settings.quality = 2
        settings.fillGaps = 2 // 5 pixels.
        let result = ForegroundSeparator.separate(image, mask: mask, settings: settings)
        XCTAssertEqual(result.background.pixels[(10 * 60 + 25) * 4 + 3], 255, "inside the body the cut is filled")
        XCTAssertEqual(result.background.pixels[(10 * 60 + 55) * 4 + 3], 0, "the limb's far end isn't")
        settings.fillGaps = 100
        let off = ForegroundSeparator.separate(image, mask: mask, settings: settings)
        XCTAssertEqual(off.background.pixels[(10 * 60 + 55) * 4 + 3], 255, "off: the picture's opacity is kept")
    }

    // MARK: Applying

    @MainActor
    func testOKReplacesThePictureAndAddsTheForegroundAbove() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: UndoManager())
        let files: [String: Data] = [
            "models/logo.json": Data(#"{"autosize": true, "material": "materials/logo.json"}"#.utf8),
            "materials/logo.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["logo"], "blending": "translucent"}]}"#.utf8),
        ]
        let readFile: (String) -> Data? = { path in files[path] ?? store.url(for: path).flatMap { try? Data(contentsOf: $0) } }
        let image = square(size: 8)
        var mask = ImagePlane(width: 8, height: 8)
        mask[4, 4] = 1
        let result = ForegroundSeparator.separate(image, mask: mask, settings: ForegroundSeparator.Settings())
        let before = session.outline.layers.map(\.id)

        let id = try session.applyForegroundSeparation(result, to: 13, store: store, readFile: readFile,
                                                       foregroundName: "Logo Foreground", actionName: "Foreground Separation")

        let order = session.outline.layers.map(\.id)
        XCTAssertEqual(order.firstIndex(of: id), try XCTUnwrap(order.firstIndex(of: 13)) + 1, "just above the layer")
        let foreground = try XCTUnwrap(session.outline.layer(id))
        XCTAssertEqual(foreground.name, "Logo Foreground")
        XCTAssertEqual(foreground.fields["size"]?.stringValue, "200 100")
        XCTAssertEqual(foreground.fields["origin"]?.stringValue, "1700 900 0")
        XCTAssertNotNil(foreground.fields["visible"], "the layer's visibility binding comes along")
        let foregroundMaterial = try XCTUnwrap(ImageLayerMaterial(layer: foreground, readFile: readFile))
        XCTAssertTrue(try XCTUnwrap(foregroundMaterial.texture).hasPrefix("editor/logo_foreground-"))
        XCTAssertEqual((foregroundMaterial.material["passes"] as? [[String: Any]])?.first?["blending"] as? String, "translucent")
        let backgroundLayer = try XCTUnwrap(session.outline.layer(13))
        let backgroundMaterial = try XCTUnwrap(ImageLayerMaterial(layer: backgroundLayer, readFile: readFile))
        XCTAssertTrue(try XCTUnwrap(backgroundMaterial.texture).hasPrefix("editor/logo_background-"))
        XCTAssertEqual(session.selection, id)

        session.undo()
        XCTAssertEqual(session.outline.layers.map(\.id), before)
        let undone = session.overlay
        XCTAssertNil(undone.field("image", of: 13))
    }
}

extension SeparationMarks {
    init(width: Int, height: Int, polygons: [[SIMD2<Double>]]) {
        self.init(width: width, height: height)
        self.polygons = polygons
    }
}

/// The automatic guess: Vision's objects, the ones the foreground strokes touch.
final class SeparationPriorTests: XCTestCase {
    func testStrokesChooseTheObjects() throws {
        var left = ImagePlane(width: 10, height: 1), right = ImagePlane(width: 10, height: 1)
        for x in 0..<4 { left[x, 0] = 1 }
        for x in 6..<10 { right[x, 0] = 0.9 }
        var marks = SeparationMarks(width: 10, height: 1)
        XCTAssertEqual(try XCTUnwrap(marks.prior(from: [left, right])).pixels, [1, 1, 1, 1, 0, 0, 0.9, 0.9, 0.9, 0.9])
        marks.paint(from: SIMD2(8, 0.5), to: SIMD2(8, 0.5), diameter: 1, mark: .foreground)
        XCTAssertEqual(try XCTUnwrap(marks.prior(from: [left, right])).pixels, [0, 0, 0, 0, 0, 0, 0.9, 0.9, 0.9, 0.9])
        XCTAssertNil(marks.prior(from: []))
    }
}
