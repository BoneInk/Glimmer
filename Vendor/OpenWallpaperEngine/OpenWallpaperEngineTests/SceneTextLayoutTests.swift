import XCTest
@testable import OpenWallpaperEngine

/// D1, D2, D4, D6: WE text layout — 300/72 sizing, lines placed around the origin by
/// `horizontalalign`/`verticalalign` as `wallpaper64.exe` places them, wrapping only under
/// `limitwidth`, row limits with ellipsis, and no shrink-to-fit or clipping.
final class SceneTextLayoutTests: XCTestCase {
    private func font(pointSize: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: SceneTextLayout.pixelSize(pointSize: pointSize))
    }

    private func fixtureObject(_ id: Int) throws -> WESceneObject {
        let objects = try JSONDecoder().decode([WESceneObject].self,
                                               from: Fixtures.data("Scenes/text-transforms/objects.json"))
        return try XCTUnwrap(objects.first { $0.id == id })
    }

    private func layout(_ text: String, pointSize: CGFloat = 32, font: NSFont? = nil,
                        padding: SIMD2<Float> = SIMD2(32, 32), horizontal: String? = "center",
                        vertical: String? = "center", maxWidth: Float? = nil, maxRows: Int? = nil,
                        ellipsis: Bool = false) -> SceneTextLayout {
        SceneTextLayout(text: text, font: font ?? self.font(pointSize: pointSize), padding: padding,
                        horizontalAlignment: horizontal, verticalAlignment: vertical,
                        maxWidth: maxWidth, maxRows: maxRows, useEllipsis: ellipsis)
    }

    /// A font that can't be found is set in Arial, as WE falls back to `arial.ttf` (0x1401ad549).
    func testMissingFontFallsBackToArial() {
        let font = SceneTextFallbackFont.font(size: 40)
        XCTAssertEqual(font.fontName, "ArialMT")
        XCTAssertEqual(font.pointSize, 40)
        XCTAssertNil(NSFont(name: "", size: 40), "an absent font name resolves to nothing, so the fallback applies")
    }

    /// WE sets its FreeType face at 300 dpi (`FT_Set_Char_Size(…, pointsize × 64, 300, 300)`) and
    /// lays glyphs out one atlas pixel per scene unit. R1: 3270035750's "Nami" and "Robin"
    /// (Deutschlands, `pointsize` 25, scale 1) best match WE's capture at an em of 104 units.
    func testPixelSizeIsPointSizeAt300DPI() {
        XCTAssertEqual(SceneTextLayout.pixelSize(pointSize: 32), 133.3333, accuracy: 0.001)
        XCTAssertEqual(SceneTextLayout.pixelSize(pointSize: 25), 104.1667, accuracy: 0.001)
        XCTAssertEqual(SceneTextLayout.pixelSize(pointSize: 72), 300)
    }

    /// WE 2.8's capture of "WE Text 123" (NotoSans-Regular, `pointsize` 64, centred, origin y 540,
    /// effect gallery EXTRAS.md item 8) has its baseline at y 681…683, 143 below the origin: the
    /// block from the ascender (286, rounded up) to the baseline is centred, not the whole line
    /// (363); its ink is centred on the origin.
    func testCentredLineSitsAsInWEsCapture() throws {
        _ = try Fixtures.assets()
        let url = ShaderVariantTests.weAssets.appending(path: "fonts/NotoSans-Regular.ttf")
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let noto = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first),
                                                  SceneTextLayout.pixelSize(pointSize: 64), nil) as NSFont
        let text = layout("WE Text 123", font: noto)
        XCTAssertEqual(text.ascent, 286)
        XCTAssertEqual(text.lineHeight, 363)
        let origin = try XCTUnwrap(text.baselineOrigins().first)
        XCTAssertEqual(origin.y, -143)
        XCTAssertEqual(origin.x + text.lines[0].minX, -text.lines[0].width / 2, accuracy: 0.001, "ink centred")
    }

    /// `verticalalign`: `top` hangs the first line's ascender on the origin, `bottom` stands the
    /// last line's descender on it, `center` centres the first ascender to the last baseline.
    func testVerticalAlignmentsPlaceTheLinesAsWEDoes() {
        func baselines(_ vertical: String) -> (SceneTextLayout, [CGFloat]) {
            let text = layout("One\nTwo\nThree", vertical: vertical)
            return (text, text.baselineOrigins().map(\.y))
        }
        let (top, topLines) = baselines("top")
        XCTAssertEqual(topLines[0], -top.ascent)
        XCTAssertEqual(topLines[1], topLines[0] - top.lineHeight)
        let (bottom, bottomLines) = baselines("bottom")
        XCTAssertEqual(bottomLines[2] + bottom.descent, 0, accuracy: 0.001)
        let (centre, centreLines) = baselines("center")
        XCTAssertEqual(centreLines[0] + centre.ascent, -centreLines[2], accuracy: 0.001)
    }

    /// `horizontalalign`: lines align within the widest, whose ink starts (`left`), ends (`right`)
    /// or is centred on the origin.
    func testHorizontalAlignmentsPlaceTheInkAsWEDoes() {
        let left = layout("Hi\nthere", horizontal: "left")
        for (line, origin) in zip(left.lines, left.baselineOrigins()) {
            XCTAssertEqual(origin.x + line.minX, 0, accuracy: 0.001, line.text)
        }
        let right = layout("there", horizontal: "right")
        let end = try! XCTUnwrap(right.baselineOrigins().first).x + right.lines[0].minX + right.lines[0].width
        XCTAssertEqual(end, 0, accuracy: 0.001)
        let centre = layout("Hi\nthere")
        let spans = zip(centre.lines, centre.baselineOrigins()).map { ($1.x + $0.minX, $1.x + $0.minX + $0.width) }
        XCTAssertEqual(spans[1].0, -spans[1].1, accuracy: 0.001, "the widest line is centred")
        XCTAssertEqual(spans[0].0 + spans[0].1, 0, accuracy: 0.001, "a shorter line is centred within it")
    }

    /// EX2: the block (WE's buffer, where effects run) is the lines' bounds plus `padding` on each
    /// side, centred on those bounds (0x140258900, 0x140257d70, 0x140258050): across, the ink
    /// spans; up and down, the first ascender and the last line's bottom.
    func testTheBlockIsTheLinesBoundsWithPadding() {
        for (h, v) in [("left", "top"), ("right", "bottom"), ("center", "center"), ("left", "center")] {
            let text = layout("Hello\nworld", padding: SIMD2(10, 20), horizontal: h, vertical: v)
            let origins = text.baselineOrigins()
            let left = zip(text.lines, origins).map { $1.x + $0.minX }.min()!
            let right = zip(text.lines, origins).map { $1.x + $0.minX + $0.width }.max()!
            let top = origins[0].y + text.ascent
            let last = origins[origins.count - 1].y
            let bottom = min(last + text.descent, last + text.ascent - text.lineHeight)
            let low = text.boxCenter - text.boxSize / 2, high = text.boxCenter + text.boxSize / 2
            XCTAssertEqual(low.x, Float(left) - 10, accuracy: 0.001, "\(h) \(v)")
            XCTAssertEqual(high.x, Float(right) + 10, accuracy: 0.001, "\(h) \(v)")
            XCTAssertEqual(high.y, Float(top) + 20, accuracy: 0.001, "\(h) \(v)")
            XCTAssertEqual(low.y, Float(bottom) - 20, accuracy: 0.001, "\(h) \(v)")
        }
        XCTAssertEqual(layout("x", padding: SIMD2(600, 0)).padding.x, 512, "WE keeps at most 512 (0x140258986)")
    }

    /// GP2: 3378346807's clock (left, center, `padding` 22, 8 pt) is sampled 1:1 from the screen's
    /// top left (`TRANSFORMUV`). WE's capture has the first glyph's pen at x 22 and the first
    /// baseline at y 54 (Cambria's 32-unit ascender under 22 of padding): the buffer starts at the
    /// ink less the padding, not at the origin less half a centred box, which put the clock
    /// about 200 units right.
    func testALeftAlignedClockStartsAtItsPadding() throws {
        let serif = try XCTUnwrap(NSFont(name: "Times New Roman", size: SceneTextLayout.pixelSize(pointSize: 8)))
        let clock = layout("PM 03:23:55\nSep. 26, 2026\nSaturday", font: serif, padding: SIMD2(22, 22), horizontal: "left")
        let origins = clock.baselineOrigins()
        let corner = SIMD2(clock.boxCenter.x - clock.boxSize.x / 2, clock.boxCenter.y + clock.boxSize.y / 2)
        for (line, origin) in zip(clock.lines, origins) {
            XCTAssertEqual(Float(origin.x + line.minX) - corner.x, 22, accuracy: 0.001, line.text)
        }
        XCTAssertEqual(corner.y - Float(origins[0].y), 22 + Float(clock.ascent), accuracy: 0.001)
    }

    /// EX1: WE floors each glyph's advance to a whole unit (0x1401b1166: `x_advance >> 6`). In WE's
    /// capture of "WE Text 123" (NotoSans-Regular 64 pt, centred on x 960; effect gallery extras,
    /// `text_plain_nomsdf.png`, `zoom_text.png`) the glyphs W E x t 1 2 3 span these columns
    /// (W 221…459, E 490…595, x 962…1089, t 1101…1185, 1 1287…1355, 2 1427…1550, 3 1578…1701; T and
    /// e touch). Their centres are compared, which a threshold's bias on the edges leaves alone.
    /// CoreText's fractional advances drift right along the line, to 2.5 units at the 3; the
    /// floored ones stay within about a unit.
    func testGlyphsAdvanceByWholeUnitsAsInWEsCapture() throws {
        _ = try Fixtures.assets()
        let url = ShaderVariantTests.weAssets.appending(path: "fonts/NotoSans-Regular.ttf")
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let noto = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first),
                                                  SceneTextLayout.pixelSize(pointSize: 64), nil) as NSFont
        let text = layout("WE Text 123", font: noto)
        let line = try XCTUnwrap(text.lines.first)
        let origin = try XCTUnwrap(text.baselineOrigins().first)
        XCTAssertTrue(line.glyphs.allSatisfy { $0.position.x == $0.position.x.rounded() }, "whole-unit pen positions")
        let centres = line.glyphs.map { glyph -> CGFloat in
            var box = CGRect.zero
            var index = glyph.glyph
            CTFontGetBoundingRectsForGlyphs(glyph.font, .horizontal, &index, &box, 1)
            return 960 + origin.x + glyph.position.x + box.midX
        }
        XCTAssertEqual(centres.count, 11)
        let we: [Int: CGFloat] = [0: 340, 1: 542.5, 5: 1025.5, 6: 1143, 8: 1321, 9: 1488.5, 10: 1639.5]
        let errors = we.map { abs(centres[$0.key] - $0.value) }
        XCTAssertLessThanOrEqual(errors.max() ?? .infinity, 1.25, "\(centres)")
        XCTAssertLessThanOrEqual(errors.reduce(0, +) / CGFloat(errors.count), 0.8, "\(centres)")
    }

    /// EX3: `blockalign` spreads what a line the wrap broke lacks of `maxwidth` over its spaces,
    /// tabs and carriage returns, and its width becomes `maxwidth` (0x1401b21ee…0x1401b22d1); the
    /// paragraph's last line keeps its own.
    func testBlockAlignJustifiesWrappedLines() throws {
        let words = "Justified text spreads the gap over its spaces"
        let plain = layout(words, maxWidth: 900)
        let justified = SceneTextLayout(text: words, font: font(pointSize: 32), padding: SIMD2(0, 0),
                                        horizontalAlignment: "left", verticalAlignment: "top",
                                        maxWidth: 900, maxRows: nil, useEllipsis: false, blockAlign: true)
        XCTAssertGreaterThan(justified.lines.count, 1)
        XCTAssertEqual(justified.lines.map(\.text), plain.lines.map(\.text))
        for (index, line) in justified.lines.enumerated() {
            let natural = plain.lines[index]
            if index < justified.lines.count - 1 {
                XCTAssertEqual(line.width, 900, accuracy: 0.001, line.text)
                let gaps = CGFloat(line.text.filter { $0 == " " }.count)
                let extra = (900 - natural.width) / gaps
                let last = try XCTUnwrap(line.glyphs.last), plainLast = try XCTUnwrap(natural.glyphs.last)
                XCTAssertEqual(last.position.x - plainLast.position.x, extra * gaps, accuracy: 0.01, line.text)
            } else {
                XCTAssertEqual(line.width, natural.width, "the last line isn't justified")
            }
        }
    }

    func testNoWrapWithoutLimitWidth() {
        let text = "a fairly long line of text that would wrap if allowed"
        let result = layout(text, padding: SIMD2(4, 4))
        XCTAssertEqual(result.lines.map(\.text), [text])
        XCTAssertGreaterThan(result.lines[0].width, 100, "no shrink-to-fit: the line keeps its natural width")
        XCTAssertGreaterThanOrEqual(result.boxSize.x, Float(result.lines[0].width) + 8)
    }

    /// 3546971487 'Song Title': limitwidth 471, limitrows 2.
    func testWrapsAtMaxWidthAndLimitsRows() throws {
        let object = try fixtureObject(50)
        let maxWidth = Float(try XCTUnwrap(object.maxwidth))
        let text = String(repeating: "Song title words ", count: 12)
        let wrapped = layout(text, pointSize: 20, maxWidth: maxWidth)
        XCTAssertGreaterThan(wrapped.lines.count, 2)
        XCTAssertTrue(wrapped.lines.allSatisfy { $0.width <= CGFloat(maxWidth) + 0.5 })

        let limited = layout(text, pointSize: 20, maxWidth: maxWidth, maxRows: object.maxrows)
        XCTAssertEqual(limited.lines.count, 2)
        XCTAssertFalse(limited.lines.last!.text.hasSuffix("\u{2026}"))

        let ellipsis = layout(text, pointSize: 20, maxWidth: maxWidth, maxRows: 1, ellipsis: true)
        XCTAssertEqual(ellipsis.lines.count, 1)
        XCTAssertTrue(ellipsis.lines[0].text.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(ellipsis.lines[0].width, CGFloat(maxWidth) + 0.5)
    }

    func testExplicitNewlinesMakeRows() {
        XCTAssertEqual(layout("OUR JOURNEY IS\nTO THE STARS").lines.map(\.text), ["OUR JOURNEY IS", "TO THE STARS"])
    }

    /// 3245833232's clock (scale 0.28 in a 4K scene on a 1080p display) blurs in WE's buffer of
    /// its size; blurred at its on-screen 0.14 px a unit, the blur spread over the whole date.
    func testTextWithEffectsRasterisesAtItsOwnSize() {
        XCTAssertEqual(SceneTextRasterScale.layer(onScreen: 0.14, hasEffects: true), 1)
        XCTAssertEqual(SceneTextRasterScale.layer(onScreen: 0.14, hasEffects: false), 0.14)
        XCTAssertEqual(SceneTextRasterScale.layer(onScreen: 2, hasEffects: true), 1)
    }

    func testRasterisesAtRequestedPixelScale() throws {
        let result = layout("12:34")
        let image = try XCTUnwrap(result.rasterize(font: font(pointSize: 32), color: .white, pixelsPerUnit: 2))
        XCTAssertEqual(image.width, Int(ceil(result.boxSize.x * 2)))
        XCTAssertEqual(image.height, Int(ceil(result.boxSize.y * 2)))
        XCTAssertEqual(SceneTextRasterScale.quantized(1.3), exp2(Float(0.5)), accuracy: 0.0001)
        XCTAssertEqual(SceneTextRasterScale.clamped(100, boxSize: SIMD2(1000, 10)), 4.096, accuracy: 0.0001)
    }
}
