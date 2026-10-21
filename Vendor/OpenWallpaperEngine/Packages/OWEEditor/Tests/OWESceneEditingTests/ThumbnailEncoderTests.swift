import CoreGraphics
import ImageIO
import XCTest
@testable import OWESceneEditing

/// The editor's thumbnails as WE's snapshot tool writes them: a square `preview.jpg`, and a
/// `preview.gif` in one of its formats with one global palette, looping, under Steam's 1 MB.
final class ThumbnailEncoderTests: XCTestCase {
    func testTheGIFFormatsAreWallpaperEnginesTable() {
        let formats = GIFRecordingFormat.all.map { [$0.side, $0.framesPerSecond, $0.seconds, $0.dithered ? 1 : 0] }
        XCTAssertEqual(formats, [[256, 25, 2, 1], [256, 12, 4, 1], [128, 25, 8, 1], [256, 25, 2, 0], [256, 12, 4, 0], [128, 25, 8, 0]])
        XCTAssertEqual(GIFRecordingFormat.all.map(\.frameCount), [50, 48, 200, 50, 48, 200])
        XCTAssertEqual(GIFRecordingFormat.all.map(\.delayCentiseconds), [4, 8, 4, 4, 8, 4], "WE's 12 FPS GIFs are written 8/100 s a frame")
    }

    func testTheSceneIsDrawnAtItsAspectWithTheSquareInside() {
        XCTAssertEqual(WallpaperThumbnail.renderSize(side: 1024, sceneSize: SIMD2(1920, 1080)), SIMD2<Int>(1820, 1024))
        XCTAssertEqual(WallpaperThumbnail.renderSize(side: 256, sceneSize: SIMD2(1080, 1920)), SIMD2<Int>(256, 455))
        XCTAssertEqual(WallpaperThumbnail.snapshotSide(sceneSize: SIMD2(3840, 2160)), 1024)
        XCTAssertEqual(WallpaperThumbnail.snapshotSide(sceneSize: SIMD2(1280, 720)), 720, "never larger than the scene")
    }

    func testASnapshotIsTheCentreSquareAsAJPEG() throws {
        // Red bands left and right of a green centre square.
        let image = try XCTUnwrap(Self.image(width: 1820, height: 1024) { x, _ in
            x < 398 || x >= 1422 ? (255, 0, 0) : (0, 200, 0)
        })
        let thumbnail = try ThumbnailEncoder.snapshot(image, side: 1024)
        XCTAssertEqual(thumbnail.kind, .image)
        XCTAssertEqual(thumbnail.fileName, "preview.jpg")
        XCTAssertLessThanOrEqual(thumbnail.data.count, WallpaperThumbnail.steamSizeLimit)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 1024)
        XCTAssertEqual(decoded.height, 1024)
        let corner = try XCTUnwrap(Self.pixel(decoded, x: 4, y: 4))
        XCTAssertLessThan(corner.0, 40, "the red bands are cropped away")
        XCTAssertGreaterThan(corner.1, 160)
    }

    func testAGIFHasOneGlobalPaletteLoopsForeverAndDecodes() throws {
        let format = GIFRecordingFormat(side: 64, framesPerSecond: 25, seconds: 1, dithered: true)
        let frames = try (0..<6).map { frame in
            try XCTUnwrap(Self.image(width: 114, height: 64) { x, y in (UInt8((x * 2 + frame * 20) % 256), UInt8(y * 4 % 256), 128) })
        }
        let thumbnail = try ThumbnailEncoder.gif(frames, format: format)
        XCTAssertEqual(thumbnail.kind, .gif)
        XCTAssertEqual(thumbnail.side, 64)
        let data = [UInt8](thumbnail.data)
        XCTAssertEqual(Array(data[0..<6]), Array("GIF89a".utf8))
        XCTAssertEqual(data[10] & 0x80, 0x80, "a global colour table")
        XCTAssertEqual(data[10] & 0x07, 7, "256 colours")
        XCTAssertNotNil(thumbnail.data.range(of: Data("NETSCAPE2.0".utf8)))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 6)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 2, nil) as? [CFString: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double), 0.04, accuracy: 0.001)
        let container = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let loop = (container[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        XCTAssertEqual(loop, 0, "loops forever")

        // The picture survives the palette: frame 0's middle is close to the source's.
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = try XCTUnwrap(Self.pixel(decoded, x: 32, y: 32))
        let expectedRed: Int = (25 + 32) * 2 % 256
        XCTAssertLessThan(abs(Int(pixel.0) - expectedRed), 40)
        XCTAssertLessThan(abs(Int(pixel.2) - 128), 40)
    }

    func testAGIFOverSteamsLimitShrinksAsWallpaperEnginesEncoderDoes() throws {
        let format = GIFRecordingFormat(side: 256, framesPerSecond: 25, seconds: 1, dithered: false)
        var generator = SystemRandomNumberGenerator()
        let frames = try (0..<format.frameCount).map { _ in
            try XCTUnwrap(Self.image(width: 256, height: 256) { _, _ in
                (UInt8.random(in: 0...255, using: &generator), UInt8.random(in: 0...255, using: &generator),
                 UInt8.random(in: 0...255, using: &generator))
            })
        }
        let thumbnail = try ThumbnailEncoder.gif(frames, format: format)
        XCTAssertLessThan(thumbnail.side, 256)
        XCTAssertEqual(thumbnail.side % 32, 0, "32 pixels smaller a step")
        XCTAssertLessThanOrEqual(thumbnail.data.count, WallpaperThumbnail.steamSizeLimit)
        XCTAssertEqual(thumbnail.data[10] & 0x07, 6, "128 colours after the first step")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), format.frameCount)
    }

    func testLZWDecodesBackToTheIndicesAcrossATableReset() throws {
        // Enough distinct runs to fill the 4096-code table and clear it.
        var indices: [UInt8] = []
        for i in 0..<40_000 { indices.append(UInt8((i * 7 + i / 13) % 256)) }
        let compressed = LZW.compress(indices, minimumCodeSize: 8)
        XCTAssertEqual(Self.decompress(compressed, minimumCodeSize: 8), indices)
    }

    // MARK: Helpers

    private static func image(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let offset = (y * width + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The RGB at (x, y), y from the top.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return true
        }
        return drawn ? (pixel[0], pixel[1], pixel[2]) : nil
    }

    /// A plain GIF LZW decoder, to check the encoder's codes.
    private static func decompress(_ bytes: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var codeSize = minimumCodeSize + 1
        var table: [[UInt8]] = []
        func reset() {
            table = (0..<clear).map { [UInt8($0)] } + [[], []]
            codeSize = minimumCodeSize + 1
        }
        reset()
        var output: [UInt8] = []
        var bitBuffer = 0, bitCount = 0, index = 0
        var previous: [UInt8]?
        while true {
            while bitCount < codeSize {
                guard index < bytes.count else { return output }
                bitBuffer |= Int(bytes[index]) << bitCount
                bitCount += 8
                index += 1
            }
            let code = bitBuffer & ((1 << codeSize) - 1)
            bitBuffer >>= codeSize
            bitCount -= codeSize
            if code == clear { reset(); previous = nil; continue }
            if code == end { return output }
            let entry: [UInt8]
            if code < table.count {
                entry = table[code]
            } else if let previous {
                entry = previous + [previous[0]]
            } else {
                return output
            }
            output += entry
            if let previous, table.count < 4096 {
                table.append(previous + [entry[0]])
                if table.count == (1 << codeSize), codeSize < 12 { codeSize += 1 }
            }
            previous = entry
        }
    }
}
