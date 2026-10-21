import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OpenWallpaperEngine

/// Texture variants (`TEXVariants`): the option records of a `TEXB0004` `.tex`, the patches after
/// each mipmap, and their composition as WE's loader does it (`TEXVariantResolver`), chosen by the
/// scene's user properties (`UserPropertyBindingTable.resolvedData`).
final class TEXVariantsTests: XCTestCase {
    struct Option {
        var group: UInt32
        var id: UInt32
        var blend: UInt32
        var condition: String
    }

    struct Patch {
        var option: UInt32
        var x: UInt32, y: UInt32, width: UInt32, height: UInt32
        var bytes: [UInt8]
    }

    /// A one-image, one-mipmap `.tex` of `format` (raw unless `freeImage`), with `options` and
    /// `patches` after the mipmap in one group.
    static func tex(format: UInt32 = 0, width: UInt32 = 4, height: UInt32 = 4, freeImage: Int32 = -1,
                    base: [UInt8], options: [Option], patches: [Patch], trailing: [UInt8] = []) -> Data {
        var data = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        for value in [format, 0, width, height, width, height, 0xFF00_0000] { word(value) }
        data.append(contentsOf: Data("TEXB0004\u{0}".utf8))
        word(1)
        word(UInt32(bitPattern: freeImage))
        word(UInt32(options.count))
        for option in options {
            word(option.group); word(option.id); word(option.blend)
            data.append(contentsOf: Data((option.condition + "\u{0}").utf8))
        }
        word(1)
        word(width); word(height); word(0); word(UInt32(base.count)); word(UInt32(base.count))
        data.append(contentsOf: base)
        if !options.isEmpty {
            word(1)
            word(UInt32(patches.count))
            for patch in patches {
                word(1); word(patch.option); word(patch.x); word(patch.y); word(patch.width); word(patch.height)
                word(UInt32(bitPattern: freeImage)); word(UInt32(patch.bytes.count))
                data.append(contentsOf: patch.bytes)
            }
        }
        data.append(contentsOf: trailing)
        return data
    }

    static let hat = Option(group: 1, id: 1, blend: 0, condition: #"{"condition":"hat"}"#)
    static let red = Option(group: 2, id: 2, blend: 1, condition: #"{"condition":{"name":"tint","condition":"red"}}"#)
    static let blue = Option(group: 2, id: 3, blend: 0, condition: #"{"condition":{"name":"tint","condition":"blue"}}"#)

    static func solid(_ pixel: [UInt8], count: Int) -> [UInt8] { Array([[UInt8]](repeating: pixel, count: count).joined()) }

    /// The first mipmap's bytes of a resolved `.tex` (a variant-free `TEXB0004`).
    private func mipmap(_ data: Data) throws -> [UInt8] {
        let header = try XCTUnwrap(TEXFileHeader(data))
        XCTAssertEqual(header.variantCount, 0)
        let first = try XCTUnwrap(header.mipmaps.first)
        return [UInt8](data.subdata(in: first.stored))
    }

    func testOptionsAndConditionsDecode() throws {
        let data = Self.tex(base: Self.solid([0, 0, 0, 255], count: 16), options: [Self.hat, Self.red, Self.blue], patches: [])
        XCTAssertTrue(TEXVariants.declares(in: data))
        let variants = try XCTUnwrap(TEXVariants(texData: data))
        XCTAssertEqual(variants.options.map(\.condition), [.flag(property: "hat"), .equals(property: "tint", value: "red"),
                                                           .equals(property: "tint", value: "blue")])
        XCTAssertEqual(variants.options.map(\.blend), [[], .alphaBlend, []])
        // The first option of a group that is on wins.
        XCTAssertEqual(variants.enabled { _ in true }, [1: [], 2: .alphaBlend])
        XCTAssertEqual(variants.enabled { $0 == .equals(property: "tint", value: "blue") }, [3: []])
        XCTAssertFalse(TEXVariants.declares(in: Self.tex(base: [0, 0, 0, 0], options: [], patches: [])))
    }

    func testRegionReplaceAndAlphaBlendComposeAsWEDoes() throws {
        let base = Self.solid([100, 50, 200, 255], count: 16)
        let data = Self.tex(base: base, options: [Self.hat, Self.red], patches: [
            Patch(option: 1, x: 1, y: 2, width: 2, height: 1, bytes: Self.solid([9, 8, 7, 6], count: 2)),
            Patch(option: 2, x: 0, y: 0, width: 1, height: 1, bytes: [200, 100, 0, 128]),
        ])
        // Nothing on: the base, the patches gone.
        XCTAssertEqual(try mipmap(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [:]))), base)
        let composed = try mipmap(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [1: [], 2: .alphaBlend])))
        var expected = base
        for pixel in [9, 10] { expected.replaceSubrange(pixel * 4..<(pixel * 4 + 4), with: [9, 8, 7, 6]) }
        // base + (patch − base) × 128 / 256 per channel, alpha the larger.
        expected.replaceSubrange(0..<4, with: [150, 75, 100, 255])
        XCTAssertEqual(composed, expected)
    }

    func testWholeMipmapReplacesTheStoredBytes() throws {
        let replacement: [UInt8] = Array(0..<64)
        let data = Self.tex(base: Self.solid([1, 1, 1, 1], count: 16),
                            options: [Option(group: 1, id: 1, blend: 2, condition: #"{"condition":"alt"}"#)],
                            patches: [Patch(option: 1, x: 0, y: 0, width: 4, height: 4, bytes: replacement)],
                            trailing: Array("TEXS0003".utf8))
        let resolved = try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [1: .wholeMipmap]))
        XCTAssertEqual(try mipmap(resolved), replacement)
        XCTAssertEqual(try XCTUnwrap(TEXFileHeader(resolved)).trailingByteCount, 8, "bytes after the images stay")
    }

    func testRegionCopyOfOneChannelAndBlockFormats() throws {
        let r8 = Self.tex(format: 9, base: [UInt8](repeating: 0, count: 16), options: [Self.hat],
                          patches: [Patch(option: 1, x: 2, y: 1, width: 2, height: 2, bytes: [1, 2, 3, 4])])
        XCTAssertEqual(try mipmap(try XCTUnwrap(TEXVariantResolver.resolve(r8, enabled: [1: []]))),
                       [0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0, 0, 0, 0])
        // DXT5 8×8: 2×2 blocks of 16 bytes; the 4×4 patch is the second block of the second row.
        let dxt = Self.tex(format: 4, width: 8, height: 8, base: [UInt8](repeating: 0, count: 64), options: [Self.hat],
                           patches: [Patch(option: 1, x: 4, y: 4, width: 4, height: 4, bytes: [UInt8](repeating: 7, count: 16))])
        let blocks = try mipmap(try XCTUnwrap(TEXVariantResolver.resolve(dxt, enabled: [1: []])))
        XCTAssertEqual(blocks, [UInt8](repeating: 0, count: 48) + [UInt8](repeating: 7, count: 16))
    }

    func testPictureContainerDecodesToRawRGBAWhenPatched() throws {
        let png = try Self.png(width: 4, height: 4, rgba: [10, 20, 30, 255])
        let patch = try Self.png(width: 2, height: 2, rgba: [250, 0, 0, 255])
        let data = Self.tex(freeImage: 13, base: png, options: [Self.hat],
                            patches: [Patch(option: 1, x: 0, y: 0, width: 2, height: 2, bytes: patch)])
        // Off: the picture stays a picture.
        let plain = try XCTUnwrap(TEXFileHeader(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [:]))))
        XCTAssertEqual(plain.freeImageFormat, 13)
        let resolved = try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [1: []]))
        let header = try XCTUnwrap(TEXFileHeader(resolved))
        XCTAssertEqual(header.freeImageFormat, -1)
        XCTAssertEqual(header.format, 0)
        let pixels = try mipmap(resolved)
        XCTAssertEqual(Array(pixels[0..<4]), [250, 0, 0, 255])
        XCTAssertEqual(Array(pixels[8..<12]), [10, 20, 30, 255])
        // Every reader sees the base of a texture with variants.
        XCTAssertNotNil(TEXParser(data: data).extractImage())
    }

    func testUserPropertiesChooseTheVariantAndRebuildItsReaders() throws {
        let base = Self.solid([0, 0, 0, 255], count: 16)
        let data = Self.tex(base: base, options: [Self.hat, Self.blue], patches: [
            Patch(option: 1, x: 0, y: 0, width: 1, height: 1, bytes: [1, 1, 1, 1]),
            Patch(option: 3, x: 3, y: 3, width: 1, height: 1, bytes: [3, 3, 3, 3]),
        ])
        let table = UserPropertyBindingTable()
        var values = ["hat": "false", "tint": "red"]
        let off = table.building(.object(7)) {
            table.resolvedData(data, path: "materials/a.tex", properties: { values[$0] })
        }
        XCTAssertEqual(try mipmap(off), base)
        values = ["hat": "true", "tint": "Blue"]
        let on = try mipmap(table.resolvedData(data, path: "materials/a.tex", properties: { values[$0] }))
        XCTAssertEqual(Array(on[0..<4]), [1, 1, 1, 1])
        XCTAssertEqual(Array(on[60..<64]), [3, 3, 3, 3])
        XCTAssertEqual(Set(table.all.map(\.name)), ["hat", "tint"])
        XCTAssertEqual(table.changes(for: ["tint"])[.object(7)], .structural)
        // A texture without variants passes through and binds nothing.
        let plain = Self.tex(base: base, options: [], patches: [])
        XCTAssertEqual(table.resolvedData(plain, path: "materials/b.tex", properties: { values[$0] }), plain)
        XCTAssertFalse(table.hasBindings(in: .asset("materials/b.tex")))
    }

    private static func png(width: Int, height: Int, rgba: [UInt8]) throws -> [UInt8] {
        let pixels = solid(rgba, count: width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return [UInt8](output as Data)
    }
}
