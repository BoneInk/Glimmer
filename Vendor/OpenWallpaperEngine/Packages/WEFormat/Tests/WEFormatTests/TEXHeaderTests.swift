import XCTest
@testable import WEFormat

/// The one `.tex` header reader and writer.
final class TEXHeaderTests: XCTestCase {
    func testWritesWhatItReads() throws {
        let header = TEXHeader(format: 7, flags: 2, textureWidth: 64, textureHeight: 32, imageWidth: 60, imageHeight: 30,
                               colorWord: 0xFF00_0000, containerVersion: 4, imageCount: 1, freeImageFormat: -1, variantCount: 2)
        let data = header.data
        XCTAssertEqual(data.count, header.end)
        XCTAssertEqual(header.containerOffset, 18 + 7 * 4)
        XCTAssertEqual(data[header.containerOffset..<header.containerOffset + 9], Data("TEXB0004\0".utf8))
        XCTAssertEqual(TEXHeader(data + Data([1, 2, 3])), header)
        XCTAssertEqual(TEXHeader.texiWord(1, in: data), 2)
    }

    func testEveryContainerVersionAndAVolume() throws {
        for version in 1...4 {
            let header = TEXHeader(format: 0, flags: 0, textureWidth: 4, textureHeight: 4, imageWidth: 4, imageHeight: 4,
                                   colorWord: 0, containerVersion: version)
            XCTAssertEqual(TEXHeader(header.data), header)
            XCTAssertEqual(header.mipmapsHaveCompression, version >= 2)
        }
        let volume = TEXHeader(format: 0, flags: TEXHeader.volumeFlag, textureWidth: 32, textureHeight: 32, imageWidth: 32,
                               imageHeight: 32, depth: 32, colorWord: 0, containerVersion: 3, freeImageFormat: 13)
        XCTAssertTrue(volume.isVolume)
        XCTAssertEqual(volume.containerOffset, 18 + 8 * 4)
        XCTAssertEqual(TEXHeader(volume.data), volume)
    }

    func testRejectsWhatIsNotAHeader() {
        XCTAssertNil(TEXHeader(Data("PNG".utf8)))
        var data = TEXHeader(format: 0, flags: 0, textureWidth: 1, textureHeight: 1, imageWidth: 1, imageHeight: 1,
                             colorWord: 0).data
        XCTAssertNil(TEXHeader(data.dropLast()), "the variant count is missing")
        data.replaceSubrange((18 + 28 + 7)..<(18 + 28 + 8), with: [UInt8(ascii: "5")])
        XCTAssertNil(TEXHeader(data), "TEXB0005")
    }

    func testReadsAndWritesMipmapRecords() throws {
        let header = TEXHeader(format: 0, flags: 0, textureWidth: 2, textureHeight: 1, imageWidth: 2, imageHeight: 1,
                               colorWord: 0, containerVersion: 3)
        var writer = TEXContainerWriter(header: header)
        writer.word(2)
        writer.mipmap(width: 2, height: 1, compression: 0, uncompressedSize: 8, stored: [UInt8](repeating: 7, count: 8))
        writer.mipmap(width: 1, height: 1, compression: 1, uncompressedSize: 4, stored: [UInt8]([1, 2]))
        var reader = try XCTUnwrap(TEXReader(writer.data))
        XCTAssertEqual(reader.header, header)
        XCTAssertEqual(reader.word(), 2)
        let first = try XCTUnwrap(reader.mipmap())
        XCTAssertEqual([first.width, first.height, first.uncompressedSize, first.stored.count], [2, 1, 8, 8])
        XCTAssertNil(reader.mipmap { width, _ in width > 1 }, "a size the caller refuses")
        XCTAssertNil(reader.mipmap(), "past the end")
    }
}
