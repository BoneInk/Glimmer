import XCTest
import simd
@testable import OpenWallpaperEngine

/// A text object's font effects (`outline`, `blur`, `dropshadow`): the fields, the values WE's
/// engine gives its `font` shader (`wallpaper64.exe` 0x1401b3b60…0x1401b3f5f), the distance field
/// the effects are drawn from, and the shader's math on it.
final class SceneTextEffectsTests: XCTestCase {
    private func fields(_ json: String) throws -> WETextEffectFields {
        try JSONDecoder().decode(WETextEffectFields.self, from: Data(json.utf8))
    }

    /// The switches turn each effect on; absent values are WE's (`WETextDefaults`).
    func testTheFieldsAndWEsDefaults() throws {
        XCTAssertNil(try fields(#"{"msdf": true, "outlinethickness": 3}"#).effects, "switched off: plain text")
        let library = try XCTUnwrap(try fields(#"""
            {"msdf": true, "outline": true, "outlinecolor": "0.00000 0.00000 0.00000", "outlinethickness": 1.33,
             "dropshadow": true, "dropshadowcolor": "0.00000 0.00000 0.00000", "dropshadowoffset": "4.00000 4.00000",
             "dropshadowopacity": 1.0, "dropshadowsize": 6.0}
            """#).effects, "3803044683's clock")
        XCTAssertEqual(library.outline, .init(thickness: 1.33, color: .zero))
        XCTAssertNil(library.blur)
        XCTAssertEqual(library.dropShadow, .init(size: 6, opacity: 1, offset: SIMD2(4, 4), color: .zero))
        let bare = try XCTUnwrap(try fields(#"{"outline": true, "blur": true, "dropshadow": true}"#).effects)
        XCTAssertEqual(bare.outline, .init(thickness: 4, color: .zero))
        XCTAssertEqual(bare.blur, 6)
        XCTAssertEqual(bare.dropShadow, .init(size: 6, opacity: 1, offset: SIMD2(4, 4), color: .zero))
    }

    /// The loader keeps a text object's effects, and such text draws its coloured raster natively
    /// instead of through the `font` material, which reads coverage.
    func testTheLoaderKeepsTheEffects() throws {
        let directory = Fixtures.url("Scenes/text-defaults")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/text-defaults/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layers = Dictionary(uniqueKeysWithValues: content.layers.map { ($0.id, $0) })
        let effects = try XCTUnwrap(layers["3"]?.text?.effects)
        XCTAssertEqual(effects.outline?.thickness, 1.33)
        XCTAssertEqual(effects.dropShadow, .init(size: 6, opacity: 1, offset: SIMD2(4, 4), color: .zero))
        XCTAssertNil(layers["3"]?.imageMaterial)
        XCTAssertNil(layers["1"]?.text?.effects)
        if Fixtures.hasWEShaderSources { XCTAssertNotNil(layers["1"]?.imageMaterial, "plain text keeps the font material") }
    }

    /// Sizes in scene units become atlas pixels at 32 / pointsize · 0.24, clamped as WE clamps them.
    func testTheShaderValuesAreWEs() {
        XCTAssertEqual(SceneTextEffects.atlasPixelsPerUnit(pointSize: 32), 0.24, accuracy: 1e-6)
        XCTAssertEqual(SceneTextEffects.atlasPixelsPerUnit(pointSize: 1000), 0.03, accuracy: 1e-6, "size capped at 256")
        var effects = SceneTextEffects(outline: .init(thickness: 4, color: .zero), blur: nil,
                                       dropShadow: .init(size: 6, opacity: 1, offset: SIMD2(4, -4), color: .zero))
        var values = effects.shaderValues(pointSize: 32)
        XCTAssertTrue(values.outlineEnabled)
        XCTAssertFalse(values.blurEnabled)
        XCTAssertTrue(values.dropShadowEnabled)
        XCTAssertEqual(values.outlineWidth, 0.96, accuracy: 1e-5)
        XCTAssertEqual(values.dropShadowRadius, 1.44, accuracy: 1e-5)
        XCTAssertEqual(values.dropShadowOffset.x, 0.96, accuracy: 1e-5)
        XCTAssertEqual(values.dropShadowOffset.y, -0.96, accuracy: 1e-5)
        // Small text: outline ≤ 5.1, the rest ≤ 6 (a negative offset isn't clamped).
        effects.dropShadow?.offset = SIMD2(100, -100)
        effects.dropShadow?.size = 100
        effects.outline?.thickness = 100
        values = effects.shaderValues(pointSize: 8)
        XCTAssertEqual(values.outlineWidth, 5.1, accuracy: 1e-5)
        XCTAssertEqual(values.dropShadowRadius, 6)
        XCTAssertEqual(values.dropShadowOffset, SIMD2(6, -96))
        // Outline and blur share 5.1.
        effects.blur = 100
        values = effects.shaderValues(pointSize: 8)
        XCTAssertTrue(values.blurEnabled)
        XCTAssertEqual(values.blurRadius, 6)
        XCTAssertEqual(values.outlineWidth, 0)
        // An outline thinner than 1 unit isn't drawn; a shadow without size or offset isn't either.
        let thin = SceneTextEffects(outline: .init(thickness: 0.9, color: .zero), blur: nil,
                                    dropShadow: .init(size: 0, opacity: 1, offset: .zero, color: .zero))
        XCTAssertFalse(thin.shaderValues(pointSize: 32).outlineEnabled)
        XCTAssertFalse(thin.shaderValues(pointSize: 32).dropShadowEnabled)
    }

    /// Distances in pixels from a square's edge: positive inside, negative outside, edge pixels by
    /// their coverage.
    func testTheDistanceField() {
        let size = 40
        var coverage = [UInt8](repeating: 0, count: size * size)
        for y in 10..<30 { for x in 10..<30 { coverage[y * size + x] = 255 } }
        let distances = SceneDistanceField.signedDistances(coverage: coverage, width: size, height: size)
        XCTAssertEqual(distances[20 * size + 20], 9.5, accuracy: 1e-4, "centre: 10 pixels in")
        XCTAssertEqual(distances[20 * size + 10], 0.5, accuracy: 1e-4)
        XCTAssertEqual(distances[20 * size + 9], -0.5, accuracy: 1e-4)
        XCTAssertEqual(distances[20 * size + 4], -5.5, accuracy: 1e-4)
        XCTAssertEqual(distances[4 * size + 4], -(sqrt(Float(6 * 6 + 6 * 6)) - 0.5), accuracy: 1e-4, "diagonal")
        coverage[20 * size + 9] = 64
        XCTAssertEqual(SceneDistanceField.signedDistances(coverage: coverage, width: size, height: size)[20 * size + 9],
                       64.0 / 255 - 0.5, accuracy: 1e-4)
    }

    /// A white square at pointsize 7.68 (one atlas pixel per unit) drawn at one pixel per unit.
    private func square(_ effects: SceneTextEffects, fill: SIMD3<Float> = SIMD3(1, 1, 1)) -> (Int, [UInt8]) {
        let size = 64
        var coverage = [UInt8](repeating: 0, count: size * size)
        for y in 24..<40 { for x in 24..<40 { coverage[y * size + x] = 255 } }
        return (size, effects.render(coverage: coverage, width: size, height: size, pixelsPerUnit: 1,
                                     pointSize: 7.68, fill: fill))
    }

    private func pixel(_ image: (Int, [UInt8]), _ x: Int, _ y: Int) -> SIMD4<UInt8> {
        let i = (y * image.0 + x) * 4
        return SIMD4(image.1[i], image.1[i + 1], image.1[i + 2], image.1[i + 3])
    }

    /// The outline surrounds the glyph by its thickness in the outline's colour; the glyph keeps its fill.
    func testTheOutlineSurroundsTheGlyph() {
        let image = square(SceneTextEffects(outline: .init(thickness: 3, color: SIMD3(1, 0, 0)), blur: nil, dropShadow: nil),
                           fill: SIMD3(0, 0, 1))
        XCTAssertEqual(pixel(image, 32, 32), SIMD4(0, 0, 255, 255), "inside: the fill")
        XCTAssertEqual(pixel(image, 22, 32), SIMD4(255, 0, 0, 255), "2 units out: the outline")
        XCTAssertEqual(pixel(image, 18, 32).w, 0, "past it: nothing")
        let plain = square(SceneTextEffects(outline: .init(thickness: 3, color: .zero), blur: nil, dropShadow: nil))
        XCTAssertEqual(pixel(plain, 32, 32), SIMD4(255, 255, 255, 255))
    }

    /// The drop shadow lies under the glyph moved by its offset, in its colour and opacity.
    func testTheDropShadowFollowsItsOffset() {
        let image = square(SceneTextEffects(outline: nil, blur: nil,
                                            dropShadow: .init(size: 0.5, opacity: 0.5, offset: SIMD2(6, 6), color: SIMD3(0, 1, 0))))
        XCTAssertEqual(pixel(image, 32, 32), SIMD4(255, 255, 255, 255), "the glyph over its shadow")
        let shadow = pixel(image, 43, 43)
        XCTAssertEqual(SIMD3(shadow.x, shadow.y, shadow.z), SIMD3(0, 255, 0), "down and right: the shadow")
        XCTAssertEqual(Int(shadow.w), 128, accuracy: 1)
        XCTAssertEqual(pixel(image, 20, 20).w, 0, "up and left: nothing")
    }

    /// Blur widens the glyph's edge into a ramp as wide as its radius.
    func testBlurSoftensTheEdge() {
        let sharp = square(SceneTextEffects(outline: nil, blur: nil, dropShadow: nil))
        let blurred = square(SceneTextEffects(outline: nil, blur: 4, dropShadow: nil))
        XCTAssertEqual(pixel(sharp, 22, 32).w, 0)
        XCTAssertGreaterThan(pixel(blurred, 22, 32).w, 0, "outside, within the ramp")
        XCTAssertLessThan(pixel(blurred, 25, 32).w, 255, "inside, within the ramp")
        XCTAssertEqual(pixel(blurred, 32, 32).w, 255)
    }
}
