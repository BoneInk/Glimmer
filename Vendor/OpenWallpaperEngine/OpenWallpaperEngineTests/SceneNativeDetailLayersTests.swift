import XCTest
import simd
@testable import OpenWallpaperEngine

/// Under Render Resolution Full on a 2× display the fixtures' scenes (authored at the display's
/// points) are drawn at their authored size and scaled up to the backing pixels, as the earlier
/// points-based "Display" drew them; text and the media artwork whose pixels nothing after them
/// reads or covers are drawn over the output after that instead (`SceneNativeDetailLayers`), at
/// its backing pixels. Your Display draws everything at the backing pixels ("Retina" below).
final class SceneNativeDetailLayersTests: XCTestCase {
    private typealias Rect = SceneSnapshotTracker.Rect
    private typealias Item = SceneNativeDetailLayers.Item

    private func layer(_ index: Int, _ rect: Rect?, readsScene: Bool = false, candidate: Bool = false) -> Item {
        .layer(index: index, bounds: rect, readsScene: readsScene, candidate: candidate)
    }

    // MARK: - Eligibility

    func testATopmostCandidateIsPromoted() {
        let items = [layer(0, Rect(x: 0, y: 0, width: 100, height: 100)),
                     layer(1, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true)]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [1])
    }

    func testALaterLayerOverItKeepsItInTheScenePass() {
        let items = [layer(0, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true),
                     layer(1, Rect(x: 25, y: 15, width: 20, height: 20))]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [])
    }

    func testALaterLayerTouchingItsUpscaleFilterKeepsIt() {
        // One scene-target pixel apart: the upscale's filter mixes them.
        let items = [layer(0, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true),
                     layer(1, Rect(x: 31, y: 10, width: 5, height: 5))]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [])
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items, padding: 0), [0])
    }

    func testALaterLayerElsewhereDoesNotBlockIt() {
        let items = [layer(0, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true),
                     layer(1, Rect(x: 200, y: 200, width: 20, height: 20))]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [0])
    }

    func testALaterPromotedLayerKeepsTheOrder() {
        // Both draw after the composite, in this order: overlapping is fine.
        let items = [layer(0, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true),
                     layer(1, Rect(x: 15, y: 12, width: 20, height: 10), candidate: true)]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [0, 1])
    }

    func testALaterReaderOfTheSceneKeepsEverythingBeforeIt() {
        let items = [layer(0, Rect(x: 10, y: 10, width: 20, height: 10), candidate: true),
                     layer(1, Rect(x: 300, y: 300, width: 5, height: 5), readsScene: true),
                     layer(2, Rect(x: 50, y: 50, width: 5, height: 5), candidate: true)]
        XCTAssertEqual(SceneNativeDetailLayers.promoted(items), [2])
    }

    func testLaterModelsParticlesAndPlacedLayersCoverEverything() {
        let rect = Rect(x: 10, y: 10, width: 20, height: 10)
        XCTAssertEqual(SceneNativeDetailLayers.promoted([layer(0, rect, candidate: true), .unbounded]), [])
        XCTAssertEqual(SceneNativeDetailLayers.promoted([layer(0, rect, candidate: true), layer(1, nil)]), [])
        XCTAssertEqual(SceneNativeDetailLayers.promoted([.unbounded, layer(0, rect, candidate: true)]), [0])
    }

    func testOnlyDetailLayersFreeOfTheSceneAreCandidates() {
        func candidate(text: Bool = true, media: Bool = false, visible: Bool = true, source: Bool = false,
                       effects: Bool = false, reads: Bool = false, puppet: Bool = false, placed: Bool = false) -> Bool {
            SceneNativeDetailLayers.isCandidate(isText: text, isMediaImage: media, visible: visible, compositeSource: source,
                                                hasLayerEffects: effects, readsScene: reads, isPuppet: puppet, placed3D: placed)
        }
        XCTAssertTrue(candidate())
        XCTAssertTrue(candidate(text: false, media: true), "the album art")
        XCTAssertFalse(candidate(text: false), "a plain image")
        XCTAssertFalse(candidate(visible: false), "hidden (the lock picture's clock)")
        XCTAssertFalse(candidate(source: true), "sampled by a model or another layer")
        XCTAssertFalse(candidate(effects: true))
        XCTAssertFalse(candidate(reads: true))
        XCTAssertFalse(candidate(puppet: true))
        XCTAssertFalse(candidate(placed: true))
    }

    func testOnlyAnOutputWithMorePixelsGains() {
        XCTAssertTrue(SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: 1, outputPixelsPerUnit: 2), "Display at 2×")
        XCTAssertTrue(SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: 1.5, outputPixelsPerUnit: 2), "a render scale")
        XCTAssertFalse(SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: 2, outputPixelsPerUnit: 2), "Retina")
        XCTAssertFalse(SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: 2.125, outputPixelsPerUnit: 2))
    }

    func testThePlacedViewportIsTheCompositesRect() {
        let fit = SceneNativeDetailLayers.placedViewport(center: SIMD2(1000, 500), size: SIMD2(1600, 900),
                                                         outputSize: SIMD2(2000, 1000))
        XCTAssertEqual(fit.origin, SIMD2(200, 50))
        XCTAssertEqual(fit.size, SIMD2(1600, 900))
        let fill = SceneNativeDetailLayers.placedViewport(center: SIMD2(500, 500), size: SIMD2(1200, 1000),
                                                          outputSize: SIMD2(1000, 1000))
        XCTAssertEqual(fill.origin, SIMD2(-100, 0))
    }


    // MARK: - The detail patch

    func testThePatchCoversTheUnionOfTheLayers() {
        let rects = [Rect.empty, Rect(x: 10, y: 10, width: 5, height: 5), Rect(x: 20, y: 0, width: 5, height: 5)]
        XCTAssertEqual(SceneNativeDetailLayers.union(rects), Rect(x: 10, y: 0, width: 15, height: 15))
        XCTAssertNil(SceneNativeDetailLayers.union([.empty]))
    }

    func testThePatchIsTheTexelsOnTheOutputRoundedOut() {
        let stretch = (origin: SIMD2<Float>(0, 0), size: SIMD2<Float>(960, 544))
        let texels = Rect(x: 10, y: 20, width: 30, height: 10)
        let patch = SceneNativeDetailLayers.outputRect(ofTexels: texels, sceneTexels: SIMD2(480, 272), placed: stretch,
                                                       outputSize: SIMD2(960, 544))
        XCTAssertEqual(patch, Rect(x: 19, y: 39, width: 62, height: 22), "2× and a pixel more on each side")
        // Kept on the placed scene: a letterboxed output's bars stay the composite's.
        let fit = (origin: SIMD2<Float>(100, 0), size: SIMD2<Float>(960, 544))
        let corner = SceneNativeDetailLayers.outputRect(ofTexels: Rect(x: 0, y: 0, width: 5, height: 5),
                                                        sceneTexels: SIMD2(480, 272), placed: fit, outputSize: SIMD2(1160, 544))
        XCTAssertEqual(corner, Rect(x: 100, y: 0, width: 11, height: 11))
        // Off the output (a cropping placement): nothing.
        let crop = (origin: SIMD2<Float>(-500, 0), size: SIMD2<Float>(1920, 1088))
        XCTAssertNil(SceneNativeDetailLayers.outputRect(ofTexels: Rect(x: 0, y: 0, width: 10, height: 10),
                                                        sceneTexels: SIMD2(480, 272), placed: crop, outputSize: SIMD2(960, 1088)))
    }

    func testThePatchsBaseCopiesTheTexelsItsFilterReads() {
        let stretch = (origin: SIMD2<Float>(0, 0), size: SIMD2<Float>(960, 544))
        let patch = Rect(x: 19, y: 39, width: 62, height: 22)
        let base = SceneNativeDetailLayers.texels(under: patch, sceneTexels: SIMD2(480, 272), placed: stretch)
        XCTAssertEqual(base, Rect(x: 8, y: 18, width: 34, height: 14))
        XCTAssertTrue(base.contains(Rect(x: 10, y: 20, width: 30, height: 10)))
        // Clamped to the target at its edges, where the filter clamps alike.
        let edge = SceneNativeDetailLayers.texels(under: Rect(x: 0, y: 0, width: 4, height: 4), sceneTexels: SIMD2(480, 272),
                                                  placed: stretch)
        XCTAssertEqual(edge, Rect(x: 0, y: 0, width: 3, height: 3))
    }

    func testTheCopysCoordinatesReadTheTargetsTexels() {
        let region = Rect(x: 8, y: 18, width: 43, height: 14)
        let uv = SceneNativeDetailLayers.copyUV(of: region, sceneTexels: SIMD2(480, 272))
        // The centre of the target's texel (10, 20) is the centre of the copy's texel (2, 2).
        let corner = SIMD2<Float>(10.5 / 480, 20.5 / 272)
        let read = uv.origin + corner.x * uv.axisX + corner.y * uv.axisY
        XCTAssertEqual(read.x * 43, 2.5, accuracy: 1e-3)
        XCTAssertEqual(read.y * 14, 2.5, accuracy: 1e-3)
    }

    func testAQuadMovesIntoThePatch() {
        // The scene's centre on a 960 × 544 output, drawn into the patch at (19, 39) of 62 × 22.
        let position = SceneNativeDetailLayers.patchPosition(SIMD2(480, 272), rect: Rect(x: 19, y: 39, width: 62, height: 22),
                                                             outputHeight: 544)
        // y up: the patch's bottom row is the output's 483rd from the bottom.
        XCTAssertEqual(position, SIMD2<Float>(461, 272 - 483))
    }

    // MARK: - Frames

    /// Rows and columns in 1× pixels of the 480 × 272 fixtures, row 0 at the top.
    private let textBox = (x: 110..<480, y: 40..<150)
    /// The album art's square, (360, 80) ± 32 with y up.
    private let artBox = (x: 328..<392, y: 160..<224)
    /// Inside the bar under the text in `layered.json`, a pixel clear of its edges.
    private let barInside = (x: 151..<449, y: 73..<131)
    /// Around the clock in `text-native-post/bloom.json`, centred at (300, 102) with y down.
    private let glowBox = (x: 250..<350, y: 80..<125)
    private typealias Box = (x: Range<Int>, y: Range<Int>)
    private typealias Frame = FixtureSceneRenderer.Frame

    private func render(_ file: String, _ resolution: GSRenderResolution, promotes: Bool = true,
                        in folder: String = "Scenes/text-retina",
                        postProcessing: GSPostProcessingQuality = .enabled) throws -> Frame {
        var settings = SceneRenderSettings()
        settings.renderResolution = resolution
        settings.postProcessing = postProcessing
        var renderer = FixtureSceneRenderer(directory: Fixtures.url(folder), sceneFile: file, pixelsPerPoint: 2,
                                            settings: settings)
        renderer.configure = { $0.promotesDetailLayers = promotes }
        return try renderer.render()
    }

    private func inBox(_ box: Box, _ x: Int, _ y: Int, scale: Int, margin: Int = 0) -> Bool {
        (box.x.lowerBound * scale - margin..<box.x.upperBound * scale + margin).contains(x)
            && (box.y.lowerBound * scale - margin..<box.y.upperBound * scale + margin).contains(y)
    }

    private static func differ(_ a: SIMD4<Int>, _ b: SIMD4<Int>, by tolerance: Int) -> Bool {
        let delta = a &- b
        return max(abs(delta.x), abs(delta.y), abs(delta.z)) > tolerance
    }

    /// The 2×2 pixels of a 2× frame over the 1× pixel (x, y), averaged.
    private static func block(_ frame: Frame, _ x: Int, _ y: Int) -> SIMD4<Int> {
        var sum = SIMD4<Int>(repeating: 0)
        for dy in 0..<2 { for dx in 0..<2 { sum &+= frame.pixel(x * 2 + dx, y * 2 + dy) } }
        return sum / 4
    }

    private static func luminance(_ pixel: SIMD4<Int>) -> Int { (pixel.x + pixel.y + pixel.z) / 3 }

    /// Compares the 2× `display` frame with `plain`, the 1× Display frame drawn without promotion,
    /// away from `box`: wherever `plain` is flat over its 3×3 neighbours (to `flatness`), the 2×2
    /// pixels of `display` over it average to it within `tolerance`, since the composite's linear
    /// upscale of a flat neighbourhood is its colour. Next to an edge, a diagonal one included, the
    /// upscale mixes in the neighbour, so `plain` itself is no reference there.
    private func compareWithPlain(_ display: Frame, _ plain: Frame, awayFrom box: Box, flatness: Int = 0,
                                  tolerance: Int = 2) -> (compared: Int, differing: Int) {
        var compared = 0, differing = 0
        for y in 1..<(plain.height - 1) {
            for x in 1..<(plain.width - 1) where !inBox(box, x, y, scale: 1, margin: 2) {
                let centre = plain.pixel(x, y)
                var flat = true
                for dy in -1...1 { for dx in -1...1 where Self.differ(plain.pixel(x + dx, y + dy), centre, by: flatness) {
                    flat = false
                } }
                guard flat else { continue }
                if Self.differ(Self.block(display, x, y), centre, by: tolerance) { differing += 1 }
                compared += 1
            }
        }
        return (compared, differing)
    }

    /// Pixels of `box` (1× units, within `display`) that differ from `retina` by more than 6, and
    /// how many were compared.
    private func compareWithRetina(_ display: Frame, _ retina: Frame, in box: Box) -> (compared: Int, differing: Int) {
        var compared = 0, differing = 0
        for y in box.y.lowerBound * 2..<min(box.y.upperBound * 2, display.height) {
            for x in box.x.lowerBound * 2..<min(box.x.upperBound * 2, display.width) {
                if Self.differ(display.pixel(x, y), retina.pixel(x, y), by: 6) { differing += 1 }
                compared += 1
            }
        }
        return (compared, differing)
    }

    func testTextOnTopAtDisplayIsAsSharpAsRetinaAndTheRestIsDisplay() throws {
        _ = try Fixtures.assets()
        let display = try render("layered.json", .full)
        let retina = try render("layered.json", .yourDisplay)
        let plain = try render("layered.json", .full, promotes: false)
        try SceneRegionTransformTests.write(display, name: "native-detail-display")
        XCTAssertEqual(display.promoted, 1, "the text is drawn at the backing pixels")
        XCTAssertEqual(plain.promoted, 0)
        XCTAssertEqual(display.width, retina.width)
        XCTAssertEqual(display.height, retina.height)
        XCTAssertEqual(plain.width * 2, display.width, "the plain Display frame is the scene's points")

        // Within the text's bounds: Retina's pixels, its blend over the square beneath included. The
        // square's sides there come from the upscaled scene, a column or two of filtered edge.
        var ink = 0
        for y in textBox.y.lowerBound * 2..<textBox.y.upperBound * 2 {
            for x in textBox.x.lowerBound * 2..<min(textBox.x.upperBound * 2, display.width) {
                let a = display.pixel(x, y)
                if a.x > 150, a.y > 150, a.z < 120 { ink += 1 }
            }
        }
        let text = compareWithRetina(display, retina, in: textBox)
        XCTAssertGreaterThan(ink, 400, "the yellow text is drawn over the square")
        XCTAssertLessThan(Float(text.differing) / Float(text.compared), 0.02, "\(text.differing) of \(text.compared) differ from Retina")

        // Elsewhere: the plain Display frame, scaled up.
        let elsewhere = compareWithPlain(display, plain, awayFrom: textBox)
        XCTAssertGreaterThan(elsewhere.compared, 50_000)
        XCTAssertEqual(elsewhere.differing, 0, "outside the text the frame is the plain Display frame")
    }

    func testTextWithALayerAboveItStaysInTheScenePass() throws {
        _ = try Fixtures.assets()
        let display = try render("covered.json", .full)
        XCTAssertEqual(display.promoted, 0)
        let plain = try render("covered.json", .full, promotes: false)
        XCTAssertEqual(display.width, plain.width, "nothing promoted: the frame is the plain Display one")
        XCTAssertEqual(display.pixels, plain.pixels)
    }

    func testTheAlbumArtIsPromoted() throws {
        _ = try Fixtures.assets()
        let display = try render("album-art.json", .full)
        XCTAssertEqual(display.promoted, 1)
        // Without a media session it shows its own (white) image, where Retina draws it.
        let retina = try render("album-art.json", .yourDisplay)
        XCTAssertEqual(display.width, retina.width)
        let art = compareWithRetina(display, retina, in: artBox)
        XCTAssertLessThan(art.differing, art.compared / 100, "\(art.differing) of \(art.compared) differ from Retina")
        // The rest (the turned square's edges among it) is the upscaled scene, as without promotion.
        let plain = try render("album-art.json", .full, promotes: false)
        let elsewhere = compareWithPlain(display, plain, awayFrom: artBox)
        XCTAssertGreaterThan(elsewhere.compared, 50_000)
        XCTAssertEqual(elsewhere.differing, 0)
    }

    func testRetinaPromotesNothing() throws {
        _ = try Fixtures.assets()
        XCTAssertEqual(try render("layered.json", .yourDisplay).promoted, 0)
    }

    // MARK: - Frames through the post-process

    /// White text over a dark scene with WE's bloom (`text-native-post/bloom.json`): the text is
    /// promoted, still feeds the bloom (it glows as in the plain Display frame), its glyphs are
    /// Retina's, and away from it the frame is the plain Display one.
    func testTextUnderBloomIsSharpAndStillGlows() throws {
        _ = try Fixtures.assets()
        let folder = "Scenes/text-native-post"
        let display = try render("bloom.json", .full, in: folder)
        let plain = try render("bloom.json", .full, promotes: false, in: folder)
        let retina = try render("bloom.json", .yourDisplay, in: folder)
        let unbloomed = try render("bloom.json", .full, promotes: false, in: folder, postProcessing: .disabled)
        try SceneRegionTransformTests.write(display, name: "native-detail-bloom")
        XCTAssertEqual(display.promoted, 1, "bloom keeps the text out of the scene pass's upscale")
        XCTAssertEqual(display.width, retina.width)
        XCTAssertEqual(plain.width * 2, display.width)
        XCTAssertEqual(unbloomed.width, plain.width)

        // The glow beside the glyphs (dark in the unbloomed frame, with no glyph next to it): the
        // text feeds the bloom as before, so it glows as much as in the plain Display frame.
        var glow = 0, plainGlow = 0, background = 0, count = 0
        for y in glowBox.y {
            for x in glowBox.x {
                var dark = true
                for dy in -1...1 { for dx in -1...1 where Self.luminance(unbloomed.pixel(x + dx, y + dy)) >= 60 { dark = false } }
                guard dark else { continue }
                glow += Self.luminance(Self.block(display, x, y))
                plainGlow += Self.luminance(plain.pixel(x, y))
                background += Self.luminance(unbloomed.pixel(x, y))
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 500)
        let mean = { (sum: Int) in Float(sum) / Float(max(count, 1)) }
        XCTAssertGreaterThan(mean(glow) - mean(background), 3, "the text glows")
        XCTAssertEqual(mean(glow), mean(plainGlow), accuracy: 3, "as much as in the plain Display frame")

        // At the text: Retina's glyphs. The glow there differs (the bloom runs at the scene target's
        // texels), so compare the ink, against the plain frame's upscaled glyphs as well.
        func isInk(_ pixel: SIMD4<Int>) -> Bool { min(pixel.x, pixel.y, pixel.z) >= 200 }
        var retinaInk = 0, displayMisses = 0, plainMisses = 0
        for y in textBox.y.lowerBound * 2..<textBox.y.upperBound * 2 {
            for x in textBox.x.lowerBound * 2..<min(textBox.x.upperBound * 2, display.width) {
                let ink = isInk(retina.pixel(x, y))
                if ink { retinaInk += 1 }
                if isInk(display.pixel(x, y)) != ink { displayMisses += 1 }
                if isInk(plain.pixel(x / 2, y / 2)) != ink { plainMisses += 1 }
            }
        }
        XCTAssertGreaterThan(retinaInk, 200, "the text is drawn")
        XCTAssertLessThan(Float(displayMisses), Float(retinaInk) * 0.25, "\(displayMisses) of \(retinaInk) ink pixels differ")
        XCTAssertLessThan(displayMisses * 3, plainMisses, "sharper than the upscaled text")

        // Away from the text: the plain Display frame, glow included.
        let elsewhere = compareWithPlain(display, plain, awayFrom: textBox, flatness: 3, tolerance: 4)
        XCTAssertGreaterThan(elsewhere.compared, 30_000)
        XCTAssertLessThanOrEqual(Float(elsewhere.differing), Float(elsewhere.compared) * 0.001,
                                 "\(elsewhere.differing) of \(elsewhere.compared) differ from the plain Display frame")
    }

    /// `layered.json` through WE's colour correction (`text-native-cc`, the colour options on): the
    /// text is promoted and corrected as Retina corrects it, and the rest is the plain Display frame.
    func testTextThroughColourCorrectionIsAsSharpAsRetina() throws {
        _ = try Fixtures.assets()
        let folder = "Scenes/text-native-cc"
        let display = try render("scene.json", .full, in: folder)
        let retina = try render("scene.json", .yourDisplay, in: folder)
        let plain = try render("scene.json", .full, promotes: false, in: folder)
        try SceneRegionTransformTests.write(display, name: "native-detail-cc")
        XCTAssertEqual(display.promoted, 1, "colour correction keeps the text out of the scene pass's upscale")
        XCTAssertEqual(display.width, retina.width)
        XCTAssertEqual(plain.width * 2, display.width)

        // The correction ran: the bar beside the text isn't its authored green, in either byte order.
        let bar = plain.pixel(160, 102)
        XCTAssertTrue(Self.differ(bar, SIMD4(26, 128, 51, 0), by: 6) && Self.differ(bar, SIMD4(51, 128, 26, 0), by: 6),
                      "the frame is colour corrected: \(bar)")

        // On the bar, where the text is: Retina's pixels, corrected alike.
        let text = compareWithRetina(display, retina, in: barInside)
        XCTAssertLessThan(Float(text.differing) / Float(text.compared), 0.02, "\(text.differing) of \(text.compared) differ from Retina")

        // Elsewhere: the plain Display frame, scaled up.
        let elsewhere = compareWithPlain(display, plain, awayFrom: textBox)
        XCTAssertGreaterThan(elsewhere.compared, 50_000)
        XCTAssertEqual(elsewhere.differing, 0, "outside the text the frame is the plain Display frame")
    }
}
