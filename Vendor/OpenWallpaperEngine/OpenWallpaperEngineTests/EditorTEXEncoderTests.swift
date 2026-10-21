import CoreGraphics
import OWESceneEditing
import XCTest
@testable import OpenWallpaperEngine

/// The Wallpaper Editor importer's `.tex` writer, read back by the app's own reader: every
/// format of WE's import dialog, its flags and mipmaps, sprite sheets with their frame table,
/// and MP4 video textures. (Async, so the reader runs off the main thread as the loader runs it.)
final class EditorTEXEncoderTests: XCTestCase {
    /// A gradient with an alpha ramp: red across, green down, blue fixed.
    private func gradient(width: Int, height: Int, alpha: Bool = false) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(x * 255 / max(width - 1, 1))
                pixels[index + 1] = UInt8(y * 255 / max(height - 1, 1))
                pixels[index + 2] = 96
                pixels[index + 3] = alpha ? (x < width / 2 ? 0 : 255) : 255
            }
        }
        return pixels
    }

    private func cgImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                     decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// The texture's first image as the app decodes it, as straight RGBA.
    private func decoded(_ data: Data) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let image = try XCTUnwrap(TEXParser(data: data).extractImage())
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return (try EditorTEXEncoder.rgba(cg), cg.width, cg.height)
    }

    private func meanError(_ a: [UInt8], _ b: [UInt8], channels: [Int] = [0, 1, 2, 3]) -> Double {
        var total = 0, count = 0
        for index in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for channel in channels { total += abs(Int(a[index + channel]) - Int(b[index + channel])); count += 1 }
        }
        return Double(total) / Double(max(count, 1))
    }

    func testRGBA8888RoundTripsWithItsFlagsAndMipmaps() async throws {
        let pixels = gradient(width: 256, height: 128)
        var options = TextureImportOptions()
        options.pixelArt = true
        let data = try EditorTEXEncoder().texture(try cgImage(pixels, width: 256, height: 128), options: options)
        let header = try XCTUnwrap(TEXFileHeader(data))
        XCTAssertEqual(header.format, 0)
        XCTAssertEqual(header.flags, TEXFlags.noInterpolation.rawValue | TEXFlags.clampUVs.rawValue)
        XCTAssertEqual(header.containerVersion, 4)
        XCTAssertEqual(header.freeImageFormat, -1)
        XCTAssertEqual([header.textureWidth, header.textureHeight, header.imageWidth, header.imageHeight], [256, 128, 256, 128])
        XCTAssertEqual(header.mipmaps.map(\.width), [256, 128], "halved while the smaller side stays at 64 or more")
        let image = try decoded(data)
        XCTAssertEqual([image.width, image.height], [256, 128])
        XCTAssertEqual(image.pixels, pixels, "uncompressed")
        options.noMipmaps = true
        XCTAssertEqual(TEXFileHeader(try EditorTEXEncoder().texture(try cgImage(pixels, width: 256, height: 128), options: options))?
            .mipmaps.count, 1)
    }

    func testR8AndRG88KeepTheirChannels() async throws {
        let pixels = gradient(width: 40, height: 30)
        for (format, word) in [(TextureImportOptions.Format.r8, UInt32(9)), (.rg88, 8)] {
            var options = TextureImportOptions()
            options.format = format
            let data = try EditorTEXEncoder().texture(try cgImage(pixels, width: 40, height: 30), options: options)
            let header = try XCTUnwrap(TEXFileHeader(data))
            XCTAssertEqual(header.format, word)
            XCTAssertEqual(header.mipmaps.first?.uncompressedSize, 40 * 30 * (format == .r8 ? 1 : 2))
            let image = try decoded(data)
            XCTAssertEqual(meanError(image.pixels, pixels, channels: format == .r8 ? [0] : [0, 1]), 0, "\(format)")
        }
    }

    func testDXT5AndDXT1ArePaddedToWEsTilesAndDecodeClose() async throws {
        let pixels = gradient(width: 100, height: 70, alpha: true)
        for format in [TextureImportOptions.Format.dxt5, .dxt1] {
            var options = TextureImportOptions()
            options.format = format
            let data = try EditorTEXEncoder().texture(try cgImage(pixels, width: 100, height: 70), options: options)
            let header = try XCTUnwrap(TEXFileHeader(data))
            XCTAssertEqual(header.format, format.texFormat)
            XCTAssertEqual([header.textureWidth, header.textureHeight, header.imageWidth, header.imageHeight], [128, 96, 100, 70],
                           "padded to 32-pixel tiles, as WE's 788 × 813 → 800 × 832")
            XCTAssertEqual(header.mipmaps.first?.uncompressedSize, (128 / 4) * (96 / 4) * (format == .dxt5 ? 16 : 8))
            let image = try decoded(data)
            XCTAssertEqual([image.width, image.height], [100, 70], "the reader shows the image's part")
            // Opaque pixels' colours; the transparent half's colour is free.
            let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] == 255 }
            let error = opaque.map { i in (0..<3).map { abs(Int(image.pixels[i + $0]) - Int(pixels[i + $0])) }.reduce(0, +) }
                .reduce(0, +)
            XCTAssertLessThan(Double(error) / Double(opaque.count * 3), 6, "\(format) colours")
            XCTAssertEqual(meanError(image.pixels, pixels, channels: [3]), 0, "\(format): the alpha's two values are exact")
        }
    }

    func testBlockEncoderKeepsAFlatColourExactly() {
        let red: [UInt8] = [255, 0, 0, 255]
        let block: [UInt8] = (0..<64).map { red[$0 % 4] }
        let encoded = BCBlockEncoder.encode(block, width: 4, height: 4, dxt5: false)
        XCTAssertEqual(encoded.count, 8)
        let color0 = UInt16(encoded[0]) | UInt16(encoded[1]) << 8
        XCTAssertEqual(BCBlockEncoder.rgb(color0), SIMD3(255, 0, 0))
    }

    func testASpriteSheetHasItsFramesTable() async throws {
        let frames = try (0..<5).map { index -> TextureImportFrame in
            var pixels = gradient(width: 20, height: 10)
            for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i + 2] = UInt8(index * 50) }
            return TextureImportFrame(image: try cgImage(pixels, width: 20, height: 10), duration: Double(index + 1) / 10)
        }
        let (data, size) = try EditorTEXEncoder().spriteSheet(frames, options: TextureImportOptions())
        let header = try XCTUnwrap(TEXFileHeader(data))
        XCTAssertEqual(header.flags & TEXFlags.sprite.rawValue, TEXFlags.sprite.rawValue)
        XCTAssertEqual(header.flags & TEXFlags.clampUVs.rawValue, TEXFlags.clampUVs.rawValue)
        XCTAssertEqual(header.containerVersion, 3)
        // ⌈√(5 · 10 / 20)⌉ = 2 columns, 3 rows.
        XCTAssertEqual(size, SIMD2(40, 30))
        let table = try XCTUnwrap(TEXSpriteFrames.frames([UInt8](data)))
        XCTAssertEqual(table.count, 5)
        XCTAssertEqual(table.map(\.duration), [Float(0.1), Float(0.2), Float(0.3), Float(0.4), Float(0.5)])
        XCTAssertEqual(table.map(\.x), [0, 20, 0, 20, 0])
        XCTAssertEqual(table.map(\.y), [0, 0, 10, 10, 20])
        XCTAssertEqual(Set(table.map(\.width)), [20])
        XCTAssertEqual(Set(table.map(\.height)), [10])
        let animation = try XCTUnwrap(TEXParser(data: data).extractAnimatedImages())
        XCTAssertEqual(animation.frames.count, 5)
    }

    func testAnMP4IsAVideoTextureOfItsSize() async throws {
        let movie = try SceneScriptVideoTextureTests.movie()
        XCTAssertEqual(MP4TrackSize.pictureSize(of: movie)?.width, 16)
        let url = FileManager.default.temporaryDirectory.appending(path: "EditorTEXEncoderTests-\(UUID().uuidString).mp4")
        try movie.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (data, size) = try EditorTEXEncoder().video(url)
        XCTAssertEqual(size, SIMD2(16, 16))
        XCTAssertEqual(TEXParser(data: data).extractVideoData(), movie, "the reader finds the movie")
        // Library video textures' layout (3802509485's `bg_2560x1600_nobars.tex`): format 0,
        // flags Clamp UVs and video, FreeImage format -1, no variants.
        let header = try XCTUnwrap(TEXFileHeader(data))
        XCTAssertTrue(header.isVideo)
        XCTAssertEqual(header.format, 0)
        XCTAssertEqual(header.flags, TEXFlags.clampUVs.rawValue | TEXFlags.video.rawValue)
        XCTAssertEqual(header.containerVersion, 4)
        XCTAssertEqual(header.freeImageFormat, -1)
        XCTAssertEqual(header.variantCount, 0)
        let text = FileManager.default.temporaryDirectory.appending(path: "EditorTEXEncoderTests-\(UUID().uuidString).mp4")
        try Data("not a movie".utf8).write(to: text)
        defer { try? FileManager.default.removeItem(at: text) }
        XCTAssertThrowsError(try EditorTEXEncoder().video(text))
    }
}
