import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import OpenWallpaperEngine

/// A JPEG mipmap decodes from its own stored bytes, bounded by the mipmap's size field: bytes after
/// its EOI, the mipmaps that follow it and a bad payload never reach ImageIO as one stream.
final class TEXJPEGPayloadTests: XCTestCase {
    func testJPEGMipmapsDecodeFromTheirStoredBytes() throws {
        let large = try Self.jpeg(width: 8, height: 4), small = try Self.jpeg(width: 4, height: 2)
        // Trailing bytes after EOI, as some encoders pad the stream.
        let padded = large + [0, 0, 0xFF, 0xD8, 0x12]
        for version in ["TEXB0001", "TEXB0003"] {
            let data = Self.tex(version: version, mipmaps: [(8, 4, padded), (4, 2, small)])
            let image = try XCTUnwrap(TEXParser(data: data).extractImage(), version)
            XCTAssertEqual(image.representations.first?.pixelsWide, 8, version)
            let reduced = try XCTUnwrap(TEXParser(data: data).extractImage(reduction: 2), version)
            XCTAssertEqual(reduced.representations.first?.pixelsWide, 4, "\(version): the second mipmap alone")
        }
    }

    func testBadJPEGPayloadDoesNotCrash() throws {
        let jpeg = try Self.jpeg(width: 8, height: 4)
        for payload in [Array(jpeg.prefix(jpeg.count / 2)), [0xFF, 0xD8], [0xFF, 0xD8, 0xFF, 0xD9]] {
            _ = TEXParser(data: Self.tex(version: "TEXB0001", mipmaps: [(8, 4, payload)])).extractImage()
        }
    }

    private static func jpeg(width: Int, height: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](output as Data)
    }

    /// A one-image RGBA `.tex` whose mipmaps hold `payload` bytes (TEXB0001: no compression fields).
    private static func tex(version: String, mipmaps: [(UInt32, UInt32, [UInt8])]) -> Data {
        var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let (width, height, _) = mipmaps[0]
        for value in [0, 0, width, height, width, height, 0] { word(value) }
        data.append(contentsOf: Data("\(version)\u{0}".utf8))
        word(1)
        if version == "TEXB0003" { word(2) }  // FreeImage JPEG
        word(UInt32(mipmaps.count))
        for (width, height, payload) in mipmaps {
            word(width); word(height)
            if version != "TEXB0001" { word(0); word(0) }
            word(UInt32(payload.count))
            data.append(contentsOf: payload)
        }
        return data
    }
}
