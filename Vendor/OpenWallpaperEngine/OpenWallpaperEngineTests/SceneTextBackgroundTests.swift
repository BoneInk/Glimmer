import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A text layer's `opaquebackground` / `backgroundcolor` (WE 2.x): the block, the lines' bounds
/// plus `padding`, filled with the colour under the glyphs (wallpaper64.exe 0x140257c30,
/// 0x140258966), authored or scripted.
final class SceneTextBackgroundTests: XCTestCase {
    private func text(opaque: Bool, color: SIMD3<Float> = SIMD3(0, 0, 1), padding: Float = 10) -> SceneMetalText {
        var text = SceneMetalText(value: "Hi", font: nil, pointSize: 32, horizontalAlignment: "center",
                                  verticalAlignment: "center", padding: SIMD2(repeating: padding), maxWidth: nil,
                                  maxRows: nil, useEllipsis: false, anchor: nil, blockAlign: false)
        text.opaqueBackground = opaque
        text.backgroundColor = color
        return text
    }

    func testBackgroundDecodes() throws {
        let json = #"{"id": 1, "text": "a", "opaquebackground": true, "backgroundcolor": "0.20000 0.40000 0.60000"}"#
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
        XCTAssertEqual(object.opaquebackground, true)
        XCTAssertEqual(object.backgroundcolor, "0.20000 0.40000 0.60000")
        let bound = #"{"id": 1, "text": "a", "opaquebackground": {"user": "box", "value": true}}"#
        XCTAssertEqual(try JSONDecoder().decode(WESceneObject.self, from: Data(bound.utf8)).opaquebackground, true)
    }

    func testScriptsTurnTheBoxOnAndColourIt() {
        var state = SceneScriptObjectState(values: [Float](repeating: 0, count: SceneScriptObjectTable.Layout.stride))
        state.owned.insert(.opaquebackground)
        state.values[SceneScriptObjectField.opaquebackground.offset] = 1
        state.owned.insert(.backgroundcolor)
        for (index, value) in [Float(1), 0.5, 0].enumerated() { state.values[SceneScriptObjectField.backgroundcolor.offset + index] = value }
        let scripted = text(opaque: false).scripted(by: state)
        XCTAssertEqual(scripted.background, SIMD3<Float>(1, 0.5, 0))
        XCTAssertTrue(scripted.rastersInColor)
        XCTAssertNotEqual(scripted.layoutKey, text(opaque: false).layoutKey)
        XCTAssertNil(text(opaque: false).background)
        XCTAssertFalse(text(opaque: false).rastersInColor)
    }

    /// The whole block, padding included, is the colour, opaque; the glyphs draw over it in theirs.
    func testTheRasterFillsTheBlockUnderTheGlyphs() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let request = SceneTextRasterRequest(text: text(opaque: true), value: "Hi", fontName: "", pointSize: 32, bold: false,
                                             italic: false, rasterScale: 1, fill: SIMD3(1, 1, 1))
        let result = try XCTUnwrap(SceneTextRaster.render(request, device: device, loader: MTKTextureLoader(device: device)))
        XCTAssertNil(result.frame.coverage, "drawn in its colours, not as coverage")
        let texture = result.frame.texture
        var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        let corner = Array(pixels[0..<4])
        XCTAssertEqual(corner[3], 255, "opaque in the padding")
        let isBGRA = texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb
        XCTAssertEqual(isBGRA ? corner[0] : corner[2], 255, "blue")
        XCTAssertEqual(corner[1], 0)
        XCTAssertTrue(pixels.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 }, "no transparent texel")
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] > 200 && pixels[$0 + 1] > 200 },
                      "white glyphs over the box")
    }

    func testFontEffectsCompositeOverTheBox() {
        var rgba: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 128]
        SceneTextRaster.composite(&rgba, over: SIMD3(0, 0, 1))
        XCTAssertEqual(rgba, [0, 0, 255, 255, 255, 0, 0, 255, 128, 0, 127, 255])
    }
}
