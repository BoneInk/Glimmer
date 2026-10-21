import CoreGraphics
import ImageIO
import OWESceneEditing
import XCTest
@testable import OpenWallpaperEngine

/// Texture variants against Wallpaper Engine's own output (capture 540, WE 2.8.0.42,
/// `Tests/Fixtures/TextureVariants/540`): `variant_a.tex` as WE's resource compiler wrote it from
/// `variant_a.png` and its `.tex-json` (one group "shapes": `variant_b.png` Replace on
/// `shapesel` = 1, `variant_c.png` Alpha blended on `shapesel` = 2). The player reads WE's file,
/// and the editor's writer lays the same inputs out as WE does.
final class TEXVariantCaptureTests: XCTestCase {
    private static let folder = "TextureVariants/540"

    private func fixture(_ name: String) throws -> Data { try Fixtures.data("\(Self.folder)/\(name)") }

    /// A PNG's straight RGBA as stored, the colour of transparent pixels kept (WE bleeds colours
    /// into them, which an alpha-blended option over them shows).
    private func decodedPNG(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        guard image.alphaInfo == .last, image.bitsPerPixel == 32, image.bitsPerComponent == 8 else { return try EditorTEXEncoder.rgba(image) }
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        var pixels: [UInt8] = []
        for row in 0..<image.height {
            let start = bytes.startIndex + row * image.bytesPerRow
            pixels += bytes[start..<(start + image.width * 4)]
        }
        return pixels
    }

    /// The first mipmap of a variant-free `.tex` as straight RGBA.
    private func picture(_ data: Data) throws -> [UInt8] {
        let layout = try TEXVariantWriter.Layout(data)
        let level = try XCTUnwrap(layout.images.first?.first)
        return layout.isPicture ? try decodedPNG(Data(level.stored)) : try XCTUnwrap(TEXVariantWriter.texels(level))
    }

    /// The largest channel difference over the pixels `b` doesn't leave fully transparent (WE
    /// bleeds colours into those, `bleedtransparentcolors`).
    private func worstDifference(_ a: [UInt8], _ b: [UInt8], where include: ((Int) -> Bool)? = nil) -> Int {
        guard a.count == b.count else { return .max }
        var worst = 0
        for index in stride(from: 0, to: a.count, by: 4) where (b[index + 3] != 0 || a[index + 3] != 0) && include?(index / 4) ?? true {
            for channel in 0..<4 { worst = max(worst, abs(Int(a[index + channel]) - Int(b[index + channel]))) }
        }
        return worst
    }

    /// The mean channel difference over the pixels either leaves visible.
    private func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0, count = 0
        for index in stride(from: 0, to: min(a.count, b.count), by: 4) where b[index + 3] != 0 || a[index + 3] != 0 {
            for channel in 0..<4 { total += abs(Int(a[index + channel]) - Int(b[index + channel])) }
            count += 4
        }
        return Double(total) / Double(max(count, 1))
    }

    private func resolved(_ data: Data, shapesel: String) -> Data {
        UserPropertyBindingTable().resolvedData(data, path: "materials/variant_a.tex", properties: { $0 == "shapesel" ? shapesel : nil })
    }

    /// WE's blend of `over` on `under`, every pixel.
    private func blended(_ over: [UInt8], under: [UInt8], width: Int, height: Int) -> [UInt8] {
        var result = under
        TEXVariantResolver.blend(over, into: &result,
                                 patch: TEXVariantResolver.Patch(option: 0, x: 0, y: 0, width: width, height: height, stored: 0..<0),
                                 rowPixels: width)
        return result
    }

    /// The `.tex`'s layout without the stored bytes: the header words (not the colour word), the
    /// container, the option records, and per mipmap its words, group and patch counts and each
    /// patch's words but its size.
    private func structure(_ data: Data) throws -> [String] {
        var reader = try XCTUnwrap(TEXReader(data))
        let header = reader.header
        var lines = ["format \(header.format) flags \(header.flags) TEXB000\(header.containerVersion) images \(header.imageCount)"
                     + " freeimage \(header.freeImageFormat) options \(header.variantCount)"]
        for option in try XCTUnwrap(reader.options(count: header.variantCount)) {
            let condition: String
            switch option.condition {
            case .flag(let property)?: condition = property
            case .equals(let property, let value)?: condition = "\(property)=\(value)"
            case nil: condition = "-"
            }
            lines.append("option \(option.group) \(option.id) \(option.blend.rawValue) \(condition)")
        }
        for _ in 0..<header.imageCount {
            let count = try XCTUnwrap(reader.word())
            for _ in 0..<count {
                let words = try (0..<4).map { _ in try XCTUnwrap(reader.word()) }
                _ = try XCTUnwrap(reader.range(Int(try XCTUnwrap(reader.word()))))
                lines.append("mipmap \(words)")
                let groups = try XCTUnwrap(reader.word())
                for _ in 0..<groups {
                    let patches = try XCTUnwrap(reader.word())
                    lines.append(" patches \(patches)")
                    for _ in 0..<patches {
                        let patch = try (0..<7).map { _ in Int32(bitPattern: try XCTUnwrap(reader.word())) }
                        _ = try XCTUnwrap(reader.range(Int(try XCTUnwrap(reader.word()))))
                        lines.append("  patch \(patch)")
                    }
                }
            }
        }
        XCTAssertEqual(reader.cursor, reader.bytes.count, "nothing after the image")
        return lines
    }

    // MARK: The player reads WE's file

    func testWEsTextureReadsAsCaptured() throws {
        let data = try fixture("variant_a.tex")
        let variants = try XCTUnwrap(TEXVariants(texData: data))
        XCTAssertEqual(variants.options, [
            TEXVariants.Option(group: 1, id: 1, blend: [], condition: .equals(property: "shapesel", value: "1")),
            TEXVariants.Option(group: 1, id: 2, blend: .alphaBlend, condition: .equals(property: "shapesel", value: "2")),
        ])
        XCTAssertEqual(try structure(data), [
            "format 0 flags 2 TEXB0004 images 1 freeimage 13 options 2",
            "option 1 1 0 shapesel=1",
            "option 1 2 1 shapesel=2",
            "mipmap [512, 256, 0, 0]", " patches 2", "  patch [1, 1, 0, 0, 512, 256, 13]", "  patch [1, 2, 0, 0, 512, 256, 13]",
            "mipmap [256, 128, 0, 0]", " patches 2", "  patch [1, 1, 0, 0, 256, 128, 13]", "  patch [1, 2, 0, 0, 256, 128, 13]",
            "mipmap [128, 64, 0, 0]", " patches 2", "  patch [1, 1, 0, 0, 128, 64, 13]", "  patch [1, 2, 0, 0, 128, 64, 13]",
        ])

        let base = try picture(resolved(data, shapesel: "0"))
        XCTAssertEqual(base.count, 512 * 256 * 4)
        // Replace: only variant_b shows (capture: the bars are gone).
        let replaced = try picture(resolved(data, shapesel: "1"))
        XCTAssertLessThanOrEqual(worstDifference(replaced, try decodedPNG(try fixture("variant_b.png"))), 2)
        // Alpha blended: variant_c over the base by its alpha (capture: the bars still show).
        let composed = try picture(resolved(data, shapesel: "2"))
        let expected = blended(try decodedPNG(try fixture("variant_c.png")), under: base, width: 512, height: 256)
        XCTAssertLessThanOrEqual(worstDifference(composed, expected), 2)
        XCTAssertNotEqual(composed, base)
    }

    // MARK: The editor writes what WE writes

    /// WE's `.tex-json` as the editor reads it, and the options it compiles from it.
    private func weDocument() throws -> TextureVariantDocument {
        try XCTUnwrap(TextureVariantDocument(json: try fixture("variant_a.tex-json"), texture: "variant_a"))
    }

    func testTheTexJSONIsWEsShape() throws {
        let document = try weDocument()
        XCTAssertEqual(document.source, "variant_a")
        XCTAssertEqual(document.groups.map(\.name), ["shapes"])
        XCTAssertEqual(document.groups[0].options.map(\.blend), [.replace, .alphaBlend])
        // Written again, `variants` is WE's own.
        func variants(_ data: Data) throws -> NSArray {
            let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(root["variants"] as? NSArray)
        }
        XCTAssertEqual(try variants(document.json), try variants(try fixture("variant_a.tex-json")))
    }

    func testTheWriterLaysWEsInputsOutAsWEDoes() throws {
        let document = try weDocument()
        let inputs = try document.compiledOptions.map { group, id, option in
            TextureVariantInput(group: group, id: id, alphaBlend: option.blend == .alphaBlend,
                                condition: option.condition?.compiledJSON ?? "{}",
                                file: try fixture((option.file as NSString).lastPathComponent))
        }
        let ours = try EditorTEXEncoder().texture(try fixture("variant_a.png"), withVariants: inputs)
        let theirs = try fixture("variant_a.tex")
        XCTAssertEqual(try structure(ours), try structure(theirs))
        // From the container's tag through the option records, byte for byte.
        func records(_ data: Data) throws -> Data {
            var reader = try XCTUnwrap(TEXReader(data))
            let header = reader.header
            _ = try XCTUnwrap(reader.options(count: header.variantCount))
            return data.subdata(in: header.containerOffset..<reader.cursor)
        }
        XCTAssertEqual(try records(ours), try records(theirs))
        // And it shows the same pictures for every value: exactly where the base is visible; where
        // an alpha-blended option covers the base's transparent pixels, through the bled colours,
        // which come close to WE's.
        let base = try picture(resolved(theirs, shapesel: "0"))
        for value in ["0", "1", "2"] {
            let mine = try picture(resolved(ours, shapesel: value)), wes = try picture(resolved(theirs, shapesel: value))
            XCTAssertLessThanOrEqual(worstDifference(mine, wes, where: { base[$0 * 4 + 3] != 0 || value == "1" }), 3, "shapesel \(value)")
            XCTAssertLessThan(meanDifference(mine, wes), 6, "shapesel \(value)")
        }
        // The bleed of the base's transparent pixels, against WE's.
        let mine = try picture(resolved(ours, shapesel: "0"))
        var total = 0, count = 0
        for index in stride(from: 0, to: base.count, by: 4) where base[index + 3] == 0 {
            for channel in 0..<3 { total += abs(Int(mine[index + channel]) - Int(base[index + channel])) }
            count += 3
        }
        XCTAssertLessThan(Double(total) / Double(count), 14, "bleedtransparentcolors")
    }
}
