import XCTest
@testable import OpenWallpaperEngine

/// `.tex` sizes are validated before anything is allocated from them.
final class TEXInputBoundsTests: XCTestCase {
    /// A one-mipmap `TEXB0003` `.tex` whose mipmap declares `width × height`, `compression` and
    /// `uncompressedSize`, holding `stored`.
    private func tex(format: UInt32, width: UInt32, height: UInt32, compression: UInt32 = 0,
                     uncompressedSize: UInt32 = 0, stored: [UInt8]) -> Data {
        var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value in [format, 0, width, height, width, height, 0] { word(value) }
        data.append(contentsOf: Data("TEXB0003\u{0}".utf8))
        for value in [1, UInt32.max, 1, width, height, compression, uncompressedSize, UInt32(stored.count)] { word(value) }
        data.append(contentsOf: stored)
        return data
    }

    func testHugeDimensionsAreRefused() {
        for (width, height) in [(UInt32.max, UInt32.max), (16_385, 1), (1, 16_385), (0, 4), (4, 0)] {
            for format in [UInt32(0), 1, 4, 7, 9, 14] {
                let parser = TEXParser(data: tex(format: format, width: width, height: height, stored: [1, 2, 3, 4]))
                XCTAssertNil(parser.extractImage(), "\(format) \(width)x\(height)")
                XCTAssertNil(parser.extractCompressedTexture(), "\(format) \(width)x\(height)")
                XCTAssertNil(parser.extractAnimatedImages(), "\(format) \(width)x\(height)")
            }
        }
    }

    func testSizeProductsReportOverflow() {
        XCTAssertNil(TEXParser.byteCount(width: Int.max, height: 2, bytesPerPixel: 1))
        XCTAssertNil(TEXParser.byteCount(width: 1 << 40, height: 1 << 20, bytesPerPixel: 8))
        XCTAssertEqual(TEXParser.byteCount(width: 4, height: 4, bytesPerPixel: 4), 64)
        XCTAssertEqual(TEXParser.blockByteCount(width: 5, height: 5, format: 7), 32)
    }

    func testOversizedLZ4HeaderIsRejected() {
        let parser = TEXParser(data: tex(format: 9, width: 4, height: 4, compression: 1,
                                         uncompressedSize: 0x7FFF_FFFF, stored: [0x10, 7]))
        XCTAssertNil(parser.extractImage())
        let blocks = TEXParser(data: tex(format: 7, width: 4, height: 4, compression: 1,
                                         uncompressedSize: 1 << 30, stored: [0x10, 7]))
        XCTAssertNil(blocks.extractCompressedTexture())
    }

    func testLZ4OutputLimitTakesTheSmallestBound() {
        XCTAssertEqual(TEXParser.lz4OutputLimit(compressedSize: 100, format: 9, width: 4, height: 4), 16)
        XCTAssertEqual(TEXParser.lz4OutputLimit(compressedSize: 2, format: 0, width: 4096, height: 4096), 510)
        XCTAssertEqual(TEXParser.lz4OutputLimit(compressedSize: 1 << 30, format: 0, width: 16_384, height: 16_384),
                       TEXParser.maxDecompressedSize)
    }

    func testLZ4MipmapWithinItsBoundStillDecodes() throws {
        // One LZ4 sequence of 16 literals (15 in the token, 1 more in the next byte).
        let encoded: [UInt8] = [0xF0, 0x01] + [UInt8](repeating: 7, count: 16)
        let parser = TEXParser(data: tex(format: 9, width: 4, height: 4, compression: 1,
                                         uncompressedSize: 16, stored: encoded))
        XCTAssertNotNil(parser.extractImage())
    }
}
