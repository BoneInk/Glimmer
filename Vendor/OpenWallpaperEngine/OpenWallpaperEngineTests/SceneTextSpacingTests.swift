import XCTest
@testable import OpenWallpaperEngine

/// WE 2.8's letter spacing (`spacing`, "x y" in scene units): x is added to every glyph's advance
/// (wallpaper64.exe 0x1401b1194), y to the line height (0x1401b0c04); a line's width is still its
/// glyphs' boxes (0x1401b2190…0x1401b21e3).
final class SceneTextSpacingTests: XCTestCase {
    private let font = NSFont(name: "ArialMT", size: SceneTextLayout.pixelSize(pointSize: 32))
        ?? SceneTextFallbackFont.font(size: SceneTextLayout.pixelSize(pointSize: 32))

    private func layout(_ text: String, spacing: SIMD2<Float>, maxWidth: Float? = nil) -> SceneTextLayout {
        SceneTextLayout(text: text, font: font, padding: .zero, horizontalAlignment: "left", verticalAlignment: "top",
                        maxWidth: maxWidth, maxRows: nil, useEllipsis: false, spacing: spacing)
    }

    func testSpacingXAddsToEveryAdvance() throws {
        let plain = layout("ABCD", spacing: .zero)
        let spaced = layout("ABCD", spacing: SIMD2(10.48, 0))
        let plainX = plain.lines[0].glyphs.map(\.position.x)
        let spacedX = spaced.lines[0].glyphs.map(\.position.x)
        XCTAssertEqual(spacedX.count, 4)
        for index in 0..<4 {
            XCTAssertEqual(spacedX[index] - plainX[index], CGFloat(index) * 10.48, accuracy: 0.001)
        }
        // Three gaps wider; the last glyph's spacing adds nothing to the width.
        XCTAssertEqual(spaced.lines[0].width - plain.lines[0].width, 3 * 10.48, accuracy: 0.01)
    }

    func testSpacingYAddsToTheLineHeight() {
        let plain = layout("A\nB", spacing: .zero)
        let spaced = layout("A\nB", spacing: SIMD2(0, 12))
        XCTAssertEqual(spaced.lineHeight - plain.lineHeight, 12)
        let plainOrigins = plain.baselineOrigins(), spacedOrigins = spaced.baselineOrigins()
        XCTAssertEqual((spacedOrigins[0].y - spacedOrigins[1].y) - (plainOrigins[0].y - plainOrigins[1].y), 12)
        // One gap, and the last line's bottom (its ascender less the line height, 0x9c/0x94 of WE's layout).
        XCTAssertEqual(spaced.boxSize.y - plain.boxSize.y, 24, accuracy: 0.001)
    }

    func testWrappingCountsTheSpacing() throws {
        let text = String(repeating: "aaaa ", count: 12)
        let plain = layout(text, spacing: .zero, maxWidth: 800).lines.count
        XCTAssertGreaterThan(plain, 1)
        XCTAssertGreaterThan(layout(text, spacing: SIMD2(20, 0), maxWidth: 800).lines.count, plain)
    }

    /// 3802509485 (Everyone) authors `"spacing": "10.48000 10.48000"`; a single number is both axes.
    func testSpacingDecodes() throws {
        let object = try JSONDecoder().decode(WESceneObject.self,
                                              from: Data(#"{"id": 1, "text": "a", "spacing": "10.48000 10.48000"}"#.utf8))
        XCTAssertEqual(object.spacing, "10.48000 10.48000")
        let scalar = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id": 1, "text": "a", "spacing": 3}"#.utf8))
        XCTAssertEqual(scalar.spacing, "3")
        var text = SceneMetalText(value: "a", font: nil, pointSize: 32, horizontalAlignment: nil, verticalAlignment: nil,
                                  padding: .zero, maxWidth: nil, maxRows: nil, useEllipsis: false, anchor: nil, blockAlign: false)
        let before = text.layoutKey
        text.spacing = SIMD2(1, 0)
        XCTAssertNotEqual(text.layoutKey, before)
    }
}
