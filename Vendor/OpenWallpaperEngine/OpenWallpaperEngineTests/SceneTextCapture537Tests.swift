import XCTest
import simd
@testable import OpenWallpaperEngine

/// WE 2.8.0.42 capture 537 (RenderDoc stills at 2 s of `Tests/Fixtures/Scenes/text-537`): a
/// 1920 × 1080 scene with one MSDF text object, "Text Layer" at point size 32, centred at
/// (960, 540), under the default bloom. WE's numbers: the glyph ink (white above 200) is 609 px
/// wide and widens by 46 at spacing 5 and by 180 at spacing 20 (9 gaps), centred; the opaque
/// background is the layout box, 615 × 153 at x 652–1266, y 479–631 with padding 0, and 20 px more
/// on every side with padding 20; its (0.2, 0.4, 0.8) reads (45, 71, 122) at alpha 0.5 and glows
/// to about (55, 127, 255) inside at alpha 1; white text at alpha 0.5 over it reads
/// (156, 170, 197), the box showing through the glyphs.
final class SceneTextCapture537Tests: XCTestCase {
    private var directory: URL { Fixtures.url("Scenes/text-537") }

    private func render(_ variant: String) throws -> FixtureSceneRenderer.Frame {
        var renderer = FixtureSceneRenderer(directory: directory)
        renderer.sceneFile = variant + ".json"
        renderer.points = SIMD2(1920, 1080)
        let frame = try renderer.render()
        try SceneRegionTransformTests.write(frame, name: "text-537-" + variant)
        return frame
    }

    private struct Span {
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    private func span(_ frame: FixtureSceneRenderer.Frame, where test: (SIMD4<Int>) -> Bool) -> Span {
        var result = Span()
        for y in 0..<frame.height {
            for x in 0..<frame.width where test(frame.pixel(x, y)) {
                result.minX = min(result.minX, x); result.maxX = max(result.maxX, x)
                result.minY = min(result.minY, y); result.maxY = max(result.maxY, y)
            }
        }
        return result
    }

    private func ink(_ frame: FixtureSceneRenderer.Frame) -> Span {
        span(frame) { min($0.x, $0.y, $0.z) > 200 }
    }

    private func box(_ frame: FixtureSceneRenderer.Frame) -> Span {
        span(frame) { $0.z - $0.x > 30 }
    }

    func testSpacingWidensTheTextByNineGapsCentred() throws {
        let plain = ink(try render("sp0")), five = ink(try render("sp5")), twenty = ink(try render("sp20"))
        XCTAssertEqual(Double(plain.width), 609, accuracy: 2, "\(plain)")
        XCTAssertEqual(Double(five.width - plain.width), 46, accuracy: 1)
        XCTAssertEqual(Double(twenty.width - plain.width), 180, accuracy: 1)
        for spanned in [plain, five, twenty] {
            XCTAssertEqual(Double(spanned.minX + spanned.maxX) / 2, 960, accuracy: 1.5, "centred: \(spanned)")
        }
    }

    func testTheBackgroundIsTheLayoutBoxPlusPadding() throws {
        let unpadded = try render("bg_pad0_a05"), padded = try render("bg_pad20_a05")
        let tight = box(unpadded), wide = box(padded)
        XCTAssertEqual(tight.width, 615, "\(tight)")
        XCTAssertEqual(tight.height, 153)
        XCTAssertEqual(Double(tight.minX), 652, accuracy: 1)
        XCTAssertEqual(Double(tight.minY), 479, accuracy: 1)
        XCTAssertEqual(wide.width, tight.width + 40)
        XCTAssertEqual(wide.height, tight.height + 40)
        XCTAssertEqual(wide.minX, tight.minX - 20)
        // Alpha 0.5: the box half over the 0.15 clear colour, as WE's (45, 71, 122).
        let colour = unpadded.pixel(900, 490)
        XCTAssertEqual(Double(colour.x), 45, accuracy: 2, "\(colour)")
        XCTAssertEqual(Double(colour.y), 71, accuracy: 2)
        XCTAssertEqual(Double(colour.z), 122, accuracy: 2)
        // The glyphs fade with the box, which shows through them: WE's (156, 170, 197) deep in
        // the ink, where a box baked under them would give a flat (146, 146, 146).
        let opaque = try render("sp0")
        var sum = SIMD3<Double>(repeating: 0)
        var count = 0
        for y in 2..<(opaque.height - 2) {
            for x in 2..<(opaque.width - 2) {
                let deep = [(0, 0), (-2, 0), (2, 0), (0, -2), (0, 2)].allSatisfy { opaque.pixel(x + $0.0, y + $0.1).x > 250 }
                guard deep else { continue }
                let p = unpadded.pixel(x, y)
                sum += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 1000)
        let mean: SIMD3<Double> = sum / Double(max(count, 1))
        XCTAssertEqual(mean.x, 156, accuracy: 10, "\(mean)")
        XCTAssertEqual(mean.y, 170, accuracy: 10)
        XCTAssertEqual(mean.z, 197, accuracy: 10)
        XCTAssertGreaterThan(mean.z - mean.x, 25, "tinted by the box")
    }

    func testAtFullAlphaTheBoxGlows() throws {
        _ = try Fixtures.assets() // the glow is WE's bloom, whose shaders are WE's assets
        let frame = try render("bg_pad0_a10")
        let inside = frame.pixel(900, 490)
        XCTAssertEqual(Double(inside.x), 55, accuracy: 4, "\(inside)")
        XCTAssertEqual(Double(inside.y), 127, accuracy: 4)
        XCTAssertGreaterThan(inside.z, 250)
        XCTAssertEqual(ink(frame).width, ink(try render("sp0")).width, "the text is the same over the box")
    }

    func testBackgroundBrightnessDecodes() throws {
        let json = #"{"id": 1, "text": "a", "opaquebackground": true, "backgroundbrightness": 2.5}"#
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
        XCTAssertEqual(object.backgroundbrightness, 2.5)
        let plain = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "text": "a"}"#.utf8))
        XCTAssertNil(plain.backgroundbrightness)
    }
}
