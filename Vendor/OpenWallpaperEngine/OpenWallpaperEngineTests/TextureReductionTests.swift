import XCTest
import AppKit
@testable import OpenWallpaperEngine

/// WE's "Texture Resolution" setting (`TextureReduction`, `wallpaper64.exe` 0x14017e6f0,
/// 0x14015d3fd): when it reduces, and that a reduced `.tex` loads its second mipmap.
final class TextureReductionTests: XCTestCase {
    func testTheSettingGivesWEsReduction() {
        let uhd = SIMD2<Float>(3840, 2160), fullHD = SIMD2<Float>(1920, 1080), small = SIMD2<Float>(1600, 900)
        XCTAssertEqual(TextureReduction.factor(.highQuality, outputPixels: small), 1, "full never reduces")
        XCTAssertEqual(TextureReduction.factor(.highPerformance, outputPixels: uhd), 2, "half always reduces")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: uhd), 1)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: fullHD), 1, "1080p is over 0.95 × 1080p")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: small), 2, "auto reduces below 1 969 920 pixels")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: SIMD2(1919, 1026)), 2)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: .zero), 1, "no display yet")
    }

    func testAutoWeighsASizedSceneAgainstTheWindow() {
        // 0x14017e6f0 under engine flag 0x400: the scene's pixels over 3.9 × the window's.
        let uhd = SIMD2<Float>(3840, 2160), fullHD = SIMD2<Float>(1920, 1080), small = SIMD2<Float>(1280, 800)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: fullHD, sceneSize: uhd), 2,
                       "8 294 400 > 3.9 × 2 073 600")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: fullHD, sceneSize: fullHD), 1)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: small, sceneSize: fullHD), 1,
                       "a small window alone doesn't reduce a sized scene")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: SIMD2(1458, 1458), sceneSize: uhd), 2)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: SIMD2(1459, 1459), sceneSize: uhd), 1)
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: .zero, sceneSize: uhd), 1, "no display yet")
        XCTAssertEqual(TextureReduction.factor(.highQuality, outputPixels: SIMD2(640, 480), sceneSize: uhd), 1)
        XCTAssertEqual(TextureReduction.factor(.highPerformance, outputPixels: uhd, sceneSize: fullHD), 2)
    }

    func testTheSceneSizeFollowsWEsOrthographicFlag() throws {
        func scene(_ projection: String) throws -> WEScene {
            try JSONDecoder().decode(WEScene.self, from: Data(#"{"camera": {}, "general": {"orthogonalprojection": \#(projection)}, "objects": []}"#.utf8))
        }
        XCTAssertEqual(TextureReduction.orthographicSize(of: try scene(#"{"width": 3840, "height": 2160}"#)), SIMD2(3840, 2160))
        XCTAssertNil(TextureReduction.orthographicSize(of: try scene("null")), "a perspective scene")
        XCTAssertNil(TextureReduction.orthographicSize(of: try scene(#"{"width": 1920, "height": 0}"#)),
                     "flag 0x400 needs both sides")
        let auto = try XCTUnwrap(TextureReduction.orthographicSize(of: try scene(#"{"auto": true}"#)))
        XCTAssertEqual(auto, .zero, "auto sets the flag with no size")
        XCTAssertEqual(TextureReduction.factor(.automatic, outputPixels: SIMD2(640, 480), sceneSize: auto), 1,
                       "so Automatic never reduces it")
    }

    func testWEsConfigValuesAreFullHalfOrAuto() {
        // 0x1401155f6…0x14011562f compares with "full" and "half" only.
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: "full"), .highQuality)
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: "half"), .highPerformance)
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: "auto"), .automatic)
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: "quarter"), .automatic, "WE has no quarter")
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: nil), .automatic)
        XCTAssertEqual(GSTextureResolutionQuality(weConfigValue: "Half"), .automatic, "compared exactly")
    }

    func testOnlyAnImageWithSeveralMipmapsSkipsItsFirst() {
        XCTAssertEqual(TextureReduction.loadedMipmap(reduction: 2, mipmapCount: 5), 1)
        XCTAssertEqual(TextureReduction.loadedMipmap(reduction: 2, mipmapCount: 1), 0, "a single mipmap loads whole")
        XCTAssertEqual(TextureReduction.loadedMipmap(reduction: 1, mipmapCount: 5), 0)
        XCTAssertEqual(TextureReduction.mipmapSide(4466, level: 1), 2233)
        XCTAssertEqual(TextureReduction.mipmapSide(2233, level: 1), 1116, "as the library's .tex files store it")
        XCTAssertEqual(TextureReduction.mipmapSide(1, level: 3), 1)
    }

    func testAReducedImageLoadsItsSecondMipmap() throws {
        // 4 × 2 red, then 2 × 1 green.
        let data = Self.tex(format: 1, image: SIMD2(4, 2), mipmaps: [
            (SIMD2(4, 2), [UInt8](repeating: 0, count: 8).flatMap { _ in [255, 0, 0] as [UInt8] }),
            (SIMD2(2, 1), [0, 255, 0, 0, 255, 0]),
        ])
        let parser = TEXParser(data: data)
        XCTAssertEqual(parser.firstImageMipmapCount(), 2)
        let full = try XCTUnwrap(parser.extractImage())
        XCTAssertEqual(SceneMetalTextureSource.image(full).pixelSize, SIMD2(4, 2))
        let reduced = try XCTUnwrap(parser.extractImage(reduction: 2))
        XCTAssertEqual(SceneMetalTextureSource.image(reduced).pixelSize, SIMD2(2, 1))
        let pixel = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(reduced.tiffRepresentation))?.colorAt(x: 0, y: 0))
        XCTAssertEqual(pixel.greenComponent, 1, accuracy: 0.01, "the second mipmap's texels")
        XCTAssertEqual(pixel.redComponent, 0, accuracy: 0.01)
    }

    func testASingleMipmapImageLoadsWholeUnderAReduction() throws {
        let data = Self.tex(format: 1, image: SIMD2(2, 1), mipmaps: [(SIMD2(2, 1), [255, 0, 0, 255, 0, 0])])
        let image = try XCTUnwrap(TEXParser(data: data).extractImage(reduction: 2))
        XCTAssertEqual(SceneMetalTextureSource.image(image).pixelSize, SIMD2(2, 1))
    }

    func testAReducedBlockTextureKeepsItsImageCropAtTheMipmapsScale() throws {
        // DXT1 (format 7): an 8 × 8 allocation holding a 6 × 5 image, then its 4 × 4 mipmap.
        let data = Self.tex(format: 7, image: SIMD2(6, 5), mipmaps: [
            (SIMD2(8, 8), [UInt8](repeating: 0, count: 4 * 8)),
            (SIMD2(4, 4), [UInt8](repeating: 0, count: 8)),
        ])
        let full = try XCTUnwrap(TEXParser(data: data).extractCompressedTexture())
        XCTAssertEqual([full.width, full.height, full.contentWidth, full.contentHeight], [8, 8, 6, 5])
        let reduced = try XCTUnwrap(TEXParser(data: data).extractCompressedTexture(reduction: 2))
        XCTAssertEqual([reduced.width, reduced.height, reduced.contentWidth, reduced.contentHeight], [4, 4, 3, 2])
    }

    func testAReducedSpriteSheetScalesItsFrameRects() throws {
        var data = Self.tex(format: 1, image: SIMD2(4, 2), mipmaps: [
            (SIMD2(4, 2), [UInt8](repeating: 255, count: 24)), (SIMD2(2, 1), [UInt8](repeating: 255, count: 6)),
        ])
        // TEXS0003: one frame, 0.1 s, the atlas's right half (x 2, width 2, height 2).
        data.append(contentsOf: Array("TEXS0003\u{0}".utf8))
        for value: UInt32 in [1, 4, 2, 0, Float(0.1).bitPattern] { Self.word(value, into: &data) }
        for value: Float in [2, 0, 2, 0, 0, 2] { Self.word(value.bitPattern, into: &data) }
        let full = try XCTUnwrap(TEXParser(data: data).extractAnimatedImages())
        XCTAssertEqual([full.frames[0].x, full.frames[0].width, full.frames[0].height], [2, 2, 2])
        let reduced = try XCTUnwrap(TEXParser(data: data).extractAnimatedImages(reduction: 2))
        XCTAssertEqual(SceneMetalTextureSource.animated(reduced).pixelSize, SIMD2(2, 1))
        XCTAssertEqual([reduced.frames[0].x, reduced.frames[0].width, reduced.frames[0].height], [1, 1, 1],
                       "the frame covers the same part of the halved atlas")
    }

    func testTheShaderSeesTheReduction() {
        var frame = BuiltinFrameContext()
        frame.textureReductionScale = 2
        XCTAssertEqual(BuiltinUniforms.value(named: "g_TextureReductionScale", frame: frame,
                                             pass: BuiltinPassContext(targetSize: SIMD2(1, 1))), [2])
    }

    func testTheSettingResolvesForTheDisplays() {
        var settings = GlobalSettings()
        settings.textureResolution = .automatic
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: SIMD2(3840, 2160)).textureReduction, 1)
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: SIMD2(1280, 800)).textureReduction, 2)
        settings.textureResolution = .highPerformance
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: SIMD2(3840, 2160)).textureReduction, 2)
        XCTAssertEqual(SceneRenderSettings().textureReduction, 1, "a settings-less renderer draws as WE's full")
        settings.textureResolution = .automatic
        let fullHD = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: fullHD, sceneSize: SIMD2(3840, 2160)).textureReduction, 2)
        XCTAssertEqual(SceneRenderSettings(settings, outputPixels: SIMD2(1280, 800), sceneSize: fullHD).textureReduction, 1)
    }

    // MARK: - Fixtures

    static func word(_ value: UInt32, into data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// A `TEXB0003` texture of one image with `mipmaps` (size, uncompressed bytes).
    static func tex(format: UInt32, image: SIMD2<UInt32>, mipmaps: [(SIMD2<UInt32>, [UInt8])]) -> Data {
        var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        let first = mipmaps[0].0
        for value in [format, 0, first.x, first.y, image.x, image.y, 0] { word(value, into: &data) }
        data.append(contentsOf: Data("TEXB0003\u{0}".utf8))
        for value in [1, UInt32.max, UInt32(mipmaps.count)] { word(value, into: &data) }
        for (size, bytes) in mipmaps {
            for value in [size.x, size.y, 0, 0, UInt32(bytes.count)] { word(value, into: &data) }
            data.append(contentsOf: bytes)
        }
        return data
    }
}
