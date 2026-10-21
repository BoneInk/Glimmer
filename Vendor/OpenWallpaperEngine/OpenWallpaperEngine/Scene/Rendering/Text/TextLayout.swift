import AppKit
import CoreText
import simd

/// Lays out a WE text object the way Wallpaper Engine does, in scene units:
/// - the glyph size (em) is `pointsize × 300/72` scene units: WE sets its FreeType face to
///   `pointsize` points at 300 dpi and lays the glyphs out one atlas pixel per scene unit;
/// - each glyph's advance is floored to a whole unit and its box is the glyph's pixel box (the
///   layout loop 0x1401b10f2…0x1401b12b9: HarfBuzz's 26.6 `x_advance >> 6`, and
///   `FT_Glyph_Get_CBox(…, FT_GLYPH_BBOX_PIXELS)` at 0x1401addb0);
/// - `spacing` (WE 2.8's letter spacing, scene units) adds its x to every glyph's advance
///   (0x1401b1194: `addss` of the layout's spacing.x to the floored advance) and its y to the
///   line height (0x1401b0c04: `size->metrics.height >> 6` plus spacing.y); a line's width is
///   still its glyphs' boxes, so the last glyph's spacing adds nothing (0x1401b2190…0x1401b21e3);
/// - text wraps only when `limitwidth` is set (at `maxwidth`), and `limitrows` keeps the first
///   `maxrows` lines, ending in an ellipsis when `limituseellipsis` is set; with `blockalign`, a
///   line the wrap broke is justified to `maxwidth` (0x1401b21ee);
/// - nothing is ever shrunk to fit, and nothing is clipped;
/// - the lines sit around the object's origin by `horizontalalign` and `verticalalign` alone
///   (`baselineOrigins`); scene.json's `size` plays no part, and `padding` is room around the
///   glyphs (`wallpaper64.exe`'s layout 0x1401b0410 and its placement 0x140257690…0x1402577c4);
/// - the block (WE's buffer, where effects run) is the lines' bounds plus `padding`, centred on
///   those bounds, not on the origin (0x140258900 sizes it, 0x140257d70 draws the glyphs into it,
///   0x140258050 places it): `boxCenter` is where its centre lies from the origin.
struct SceneTextLayout {
    /// A glyph as WE places it: its font (CoreText's cascade may pick another for a character the
    /// face lacks), its pen position from the line's start (whole units) and its character.
    struct Glyph: Equatable {
        let font: CTFont
        let glyph: CGGlyph
        let position: CGPoint
        let isWhitespace: Bool
    }

    struct Line: Equatable {
        let text: String
        /// WE's line width: the glyphs' boxes joined with the pen's start, `min(0, xMin)` to
        /// `max(0, xMax)` (0x1401b215d); `maxwidth` for a justified line.
        let width: CGFloat
        /// That span's left end from the pen's start (≤ 0).
        let minX: CGFloat
        let glyphs: [Glyph]
    }

    /// The text block (the quad), in unscaled scene units: the lines' bounds plus `padding` on
    /// each side.
    let boxSize: SIMD2<Float>
    /// The block's centre from the object's origin (y-up), unscaled: the lines' bounds' centre.
    let boxCenter: SIMD2<Float>
    let lines: [Line]
    /// `size->metrics.height`, `ascender` and `descender` (0x1401b0bf0, 0x14025769a), whole pixels
    /// as FreeType rounds them: the height to nearest, the ascender up, the descender down.
    let lineHeight: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let padding: SIMD2<Float>
    /// `spacing`: added to each glyph's advance (x) and to the line height (y), in scene units.
    let spacing: SIMD2<Float>
    let horizontalAlignment: String?
    let verticalAlignment: String?

    /// WE's `FT_Set_Char_Size(face, 0, pointsize × 64, 300, 300)`: the em in scene units.
    static func pixelSize(pointSize: CGFloat) -> CGFloat { pointSize * 300 / 72 }
    /// The largest padding WE keeps on each side (0x140258986: `minss` with 512).
    static let maxPadding: Float = 512

    init(text: String, font: NSFont, padding: SIMD2<Float>, horizontalAlignment: String?, verticalAlignment: String?,
         maxWidth: Float?, maxRows: Int?, useEllipsis: Bool, blockAlign: Bool = false, spacing: SIMD2<Float> = .zero) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // Lines are measured for wrapping with the letter spacing in their advances.
        var measuring = attributes
        if spacing.x != 0 { measuring[.kern] = CGFloat(spacing.x) }
        let letterSpacing = CGFloat(spacing.x)
        ascent = ceil(font.ascender)
        descent = floor(font.descender)
        lineHeight = (font.ascender - font.descender + font.leading).rounded() + CGFloat(spacing.y)
        self.spacing = spacing
        self.padding = simd_min(padding, SIMD2(repeating: Self.maxPadding))
        self.horizontalAlignment = horizontalAlignment
        self.verticalAlignment = verticalAlignment

        // Each line with whether the wrap broke it (WE's line flag +0x20, set at 0x1401b1cc6).
        var lines: [(text: String, wrapped: Bool)] = []
        for paragraph in text.components(separatedBy: .newlines) {
            if let maxWidth, maxWidth > 0 {
                let wrapped = Self.wrap(paragraph, attributes: measuring, width: CGFloat(maxWidth))
                lines += wrapped.enumerated().map { ($1, $0 < wrapped.count - 1) }
            } else {
                lines.append((paragraph, false))
            }
        }
        if let maxRows, maxRows > 0, lines.count > maxRows {
            lines = Array(lines.prefix(maxRows))
            if useEllipsis, let last = lines.popLast() {
                lines.append((Self.withEllipsis(last.text, attributes: measuring, width: maxWidth.map { CGFloat($0) }),
                              false))
            }
        }
        let justifyWidth = blockAlign ? maxWidth.flatMap { $0 > 0 ? CGFloat($0) : nil } : nil
        let laidOut = lines.map {
            Self.line($0.text, attributes: attributes, letterSpacing: letterSpacing, justifiedTo: $0.wrapped ? justifyWidth : nil)
        }
        self.lines = laidOut
        let origins = Self.origins(laidOut, ascent: ascent, descent: descent, lineHeight: lineHeight,
                                   horizontal: horizontalAlignment, vertical: verticalAlignment)
        let bounds = Self.bounds(around: origins, lines: laidOut, ascent: ascent, descent: descent, lineHeight: lineHeight)
        boxSize = SIMD2(Float(bounds.width), Float(bounds.height)) + self.padding * 2
        boxCenter = SIMD2(Float(bounds.midX), Float(bounds.midY))
    }

    /// Where each line's baseline starts, from the object's origin (y-up), as WE places them:
    /// - vertically (0x140257690…0x1402577c4): `center` puts the block from the first line's ascender to the
    ///   last line's baseline around the origin, `top` the first line's ascender on it, `bottom` the
    ///   last line's descender; lines follow each other by the line height;
    /// - horizontally (0x1401b2990, 0x140257690): lines are aligned within the widest, and the
    ///   block's span is centred on the origin, or starts (`left`) or ends (`right`) on it.
    func baselineOrigins() -> [CGPoint] {
        Self.origins(lines, ascent: ascent, descent: descent, lineHeight: lineHeight,
                     horizontal: horizontalAlignment, vertical: verticalAlignment)
    }

    private static func origins(_ lines: [Line], ascent: CGFloat, descent: CGFloat, lineHeight: CGFloat,
                                horizontal horizontalAlignment: String?, vertical verticalAlignment: String?) -> [CGPoint] {
        let count = CGFloat(lines.count)
        let first: CGFloat
        switch verticalAlignment?.lowercased() {
        case "top": first = -ascent
        case "bottom": first = -descent + (count - 1) * lineHeight
        default: first = -(ascent - (count - 1) * lineHeight) / 2
        }
        let blockMin = lines.map(\.minX).min() ?? 0
        let blockMax = lines.map { $0.minX + $0.width }.max() ?? 0
        let blockWidth = blockMax - blockMin
        let widest = lines.map(\.width).max() ?? 0
        let horizontal = horizontalAlignment?.lowercased()
        let shift: CGFloat = horizontal == "left" ? blockWidth / 2 : horizontal == "right" ? -blockWidth / 2 : 0
        return lines.enumerated().map { index, line in
            let offset: CGFloat
            switch horizontal {
            case "left": offset = 0
            case "right": offset = widest - line.width
            default: offset = (widest - line.width) / 2
            }
            return CGPoint(x: shift - blockWidth / 2 - line.minX + offset, y: first - CGFloat(index) * lineHeight)
        }
    }

    /// Draws the block into a new bitmap at `pixelsPerUnit` device pixels per scene unit, so
    /// the glyphs are rasterised at the size they are shown at instead of being upscaled. Each
    /// glyph is drawn at its whole-unit pen position, as WE's glyph quads are.
    /// `background` fills the whole block (padding included) under the glyphs, opaque.
    func rasterize(font: NSFont, color: NSColor, pixelsPerUnit: CGFloat, background: SIMD3<Float>? = nil) -> CGImage? {
        let width = Int(saturating: ceil(CGFloat(boxSize.x) * pixelsPerUnit), in: 1...Int.max)
        let height = Int(saturating: ceil(CGFloat(boxSize.y) * pixelsPerUnit), in: 1...Int.max)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(false)
        if let background {
            context.setFillColor(CGColor(srgbRed: CGFloat(background.x), green: CGFloat(background.y),
                                         blue: CGFloat(background.z), alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.scaleBy(x: CGFloat(width) / CGFloat(max(boxSize.x, 0.0001)),
                        y: CGFloat(height) / CGFloat(max(boxSize.y, 0.0001)))
        // The origin sits where the block's centre is offset from it (WE's 0x140257e43…0x140257f3f
        // translates the glyphs by the padding less the bounds' low corner).
        context.translateBy(x: CGFloat(boxSize.x / 2 - boxCenter.x), y: CGFloat(boxSize.y / 2 - boxCenter.y))
        context.setFillColor(color.cgColor)
        for (line, origin) in zip(lines, baselineOrigins()) {
            var index = 0
            while index < line.glyphs.count {
                // Glyphs of one font draw together.
                let runFont = line.glyphs[index].font
                var end = index
                while end < line.glyphs.count, CFEqual(line.glyphs[end].font, runFont) { end += 1 }
                let run = line.glyphs[index..<end]
                let glyphs = run.map(\.glyph)
                let positions = run.map { CGPoint(x: origin.x + $0.position.x, y: origin.y + $0.position.y) }
                CTFontDrawGlyphs(runFont, glyphs, positions, glyphs.count, context)
                index = end
            }
        }
        return context.makeImage()
    }

    /// A line's glyphs placed as WE places them, with WE's width: pen positions advance by each
    /// glyph's advance floored to a whole unit (HarfBuzz's offsets floored the same way), and the
    /// width is the glyphs' pixel boxes (left edge floored, right edge rounded up) joined with the
    /// pen's start. `letterSpacing` is added to every glyph's advance. `justifiedTo` (`blockalign`
    /// on a line the wrap broke) spreads what the line lacks of that width over its spaces, tabs
    /// and carriage returns, and the width becomes it.
    private static func line(_ text: String, attributes: [NSAttributedString.Key: Any], letterSpacing: CGFloat = 0,
                             justifiedTo justifyWidth: CGFloat?) -> Line {
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let utf16 = Array(text.utf16)
        var placed: [(font: CTFont, glyph: CGGlyph, offset: CGPoint, advance: CGFloat, box: CGRect, isWhitespace: Bool)] = []
        let requested = attributes[.font] as? NSFont ?? SceneTextFallbackFont.font(size: 12)
        for run in CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            // CoreText names the font each run is set in (the cascade's for characters the
            // requested face lacks).
            let runFont = (CTRunGetAttributes(run) as? [NSAttributedString.Key: Any])?[.font] as? NSFont
            let font = (runFont ?? requested) as CTFont
            let range = CFRange(location: 0, length: count)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var boxes = [CGRect](repeating: .zero, count: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)
            CTRunGetAdvances(run, range, &advances)
            CTRunGetStringIndices(run, range, &indices)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, glyphs, &boxes, count)
            var pen = positions[0].x
            for index in 0..<count {
                let character = indices[index] < utf16.count ? utf16[indices[index]] : 0
                // HarfBuzz's offset is where the glyph sits from its pen position.
                let offset = CGPoint(x: positions[index].x - pen, y: positions[index].y)
                placed.append((font, glyphs[index], offset, advances[index].width, boxes[index],
                               [9, 13, 32].contains(character)))
                pen += advances[index].width
            }
        }
        var pen: CGFloat = 0
        var minX: CGFloat = 0, maxX: CGFloat = 0
        for glyph in placed {
            let x = pen + floor(glyph.offset.x)
            // FreeType's pixel box of an empty outline is (0, 0, 0, 0), at the pen.
            let box = glyph.box.isNull || glyph.box.isEmpty ? CGRect.zero : glyph.box
            minX = min(minX, x + floor(box.minX))
            maxX = max(maxX, x + ceil(box.maxX))
            pen += floor(glyph.advance) + letterSpacing
        }
        var extra: CGFloat = 0
        var width = maxX - minX
        if let justifyWidth {
            let gaps = utf16.filter { [9, 13, 32].contains($0) }.count
            if gaps > 0 {
                extra = (justifyWidth - width) / CGFloat(gaps)
                width = justifyWidth
            }
        }
        pen = 0
        var glyphs: [Glyph] = []
        for glyph in placed {
            glyphs.append(Glyph(font: glyph.font, glyph: glyph.glyph,
                                position: CGPoint(x: pen + floor(glyph.offset.x), y: floor(glyph.offset.y)),
                                isWhitespace: glyph.isWhitespace))
            pen += floor(glyph.advance) + letterSpacing + (glyph.isWhitespace ? extra : 0)
        }
        return Line(text: text, width: width, minX: minX, glyphs: glyphs)
    }

    /// The lines' bounds from the object's origin (y-up): the ink spans across, and from the first
    /// line's ascender down to the last line's descender, or to where the next line's ascender
    /// would start if that is lower (0x9c/0x94 of the layout).
    private static func bounds(around origins: [CGPoint], lines: [Line], ascent: CGFloat, descent: CGFloat,
                               lineHeight: CGFloat) -> CGRect {
        guard !lines.isEmpty else { return .zero }
        var low = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        var high = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity)
        for (origin, line) in zip(origins, lines) {
            low.x = min(low.x, origin.x + line.minX)
            high.x = max(high.x, origin.x + line.minX + line.width)
            low.y = min(low.y, origin.y + descent, origin.y + ascent - lineHeight)
            high.y = max(high.y, origin.y + ascent)
        }
        return CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
    }

    // MARK: - Line breaking

    private static func width(of text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func wrap(_ paragraph: String, attributes: [NSAttributedString.Key: Any], width: CGFloat) -> [String] {
        guard !paragraph.isEmpty else { return [""] }
        let attributed = NSAttributedString(string: paragraph, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let utf16 = paragraph.utf16
        var lines: [String] = []
        var start = 0
        while start < utf16.count {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            let from = utf16.index(utf16.startIndex, offsetBy: start)
            let to = utf16.index(from, offsetBy: count)
            let line = String(paragraph[from..<to])
            lines.append(line.trimmingCharacters(in: .whitespaces))
            start += count
        }
        return lines
    }

    private static func withEllipsis(_ line: String, attributes: [NSAttributedString.Key: Any], width: CGFloat?) -> String {
        let ellipsis = "\u{2026}"
        var trimmed = line
        while !trimmed.isEmpty,
              let width, Self.width(of: trimmed + ellipsis, attributes: attributes) > width {
            trimmed.removeLast()
        }
        return trimmed.trimmingCharacters(in: .whitespaces) + ellipsis
    }
}

/// How finely text is rasterised: device pixels per scene unit, in quarter-octave steps so an
/// animated scale doesn't re-rasterise every frame, and capped so a block stays a sane texture.
enum SceneTextRasterScale {
    static let maxTextureDimension: Float = 4096

    /// Where a text layer is rasterised: WE draws plain text's glyphs at the display's density
    /// (`onScreen`), but runs a text object's effects in buffers of its size, one pixel a scene
    /// unit (its `font` material has no texture: `wallpaper64.exe` 0x140209206…0x14020923c).
    static func layer(onScreen: Float, hasEffects: Bool) -> Float {
        hasEffects ? 1 : onScreen
    }

    static func quantized(_ pixelsPerUnit: Float) -> Float {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return 1 }
        return exp2((log2(pixelsPerUnit) * 4).rounded(.up) / 4)
    }

    /// Text keeps the finest scale it has been rasterised at, so an animated scale re-rasterises
    /// only while it grows past what it has already reached, not at every step up and down.
    static func retained(_ pixelsPerUnit: Float, previous: Float?) -> Float {
        max(pixelsPerUnit, previous ?? 0)
    }

    /// Frames a layer's density must hold still before it gets an exact raster.
    static let settleFrames = 30

    /// A text layer's raster scale over time: while its density animates, the retained quantised
    /// step (`quantized`, `retained`), so a scaling clock reuses a few rasters drawn scaled on the
    /// GPU; once it has held still for `settleFrames`, the exact density, so text at rest is sharp.
    struct Tracker {
        private(set) var retained: Float?
        private var last: Float?
        private var stillFrames = 0

        mutating func scale(for pixelsPerUnit: Float) -> Float {
            if let last, abs(pixelsPerUnit - last) <= max(abs(last), 1e-6) * 1e-4 {
                stillFrames += 1
            } else {
                stillFrames = 0
            }
            last = pixelsPerUnit
            if stillFrames >= SceneTextRasterScale.settleFrames, pixelsPerUnit.isFinite, pixelsPerUnit > 0 {
                // The next animation starts over from where this one rests.
                retained = SceneTextRasterScale.quantized(pixelsPerUnit)
                return pixelsPerUnit
            }
            let scale = SceneTextRasterScale.retained(SceneTextRasterScale.quantized(pixelsPerUnit), previous: retained)
            retained = scale
            return scale
        }
    }

    static func clamped(_ pixelsPerUnit: Float, boxSize: SIMD2<Float>) -> Float {
        let largest = max(boxSize.x, boxSize.y, 1)
        return max(min(pixelsPerUnit, maxTextureDimension / largest), 1 / largest)
    }
}
