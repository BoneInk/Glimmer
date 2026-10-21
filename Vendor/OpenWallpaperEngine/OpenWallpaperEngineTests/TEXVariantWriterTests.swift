import CoreGraphics
import ImageIO
import OWESceneEditing
import UniformTypeIdentifiers
import XCTest
@testable import OpenWallpaperEngine

/// The texture-variant writer (`TEXVariantWriter`, through the editor's `EditorTEXEncoder`), read
/// back by the player's reader and composer (`TEXVariants`, `TEXVariantResolver`,
/// `UserPropertyBindingTable.resolvedData`): every format the importer writes, Replace and
/// Alpha blended, pictures and videos, the conditions, and the editor's whole flow.
final class TEXVariantWriterTests: XCTestCase {
    // MARK: Pictures

    private func solid(_ pixel: [UInt8], width: Int, height: Int) -> [UInt8] {
        Array([[UInt8]](repeating: pixel, count: width * height).joined())
    }

    /// `pixels` with `rect` painted `pixel`.
    private func painted(_ pixels: [UInt8], width: Int, x: Int, y: Int, w: Int, h: Int, _ pixel: [UInt8]) -> [UInt8] {
        var result = pixels
        for row in y..<(y + h) {
            for column in x..<(x + w) { result.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 4), with: pixel) }
        }
        return result
    }

    private func gradient(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                pixels[(y * width + x) * 4] = UInt8(x * 255 / max(width - 1, 1))
                pixels[(y * width + x) * 4 + 1] = UInt8(y * 255 / max(height - 1, 1))
                pixels[(y * width + x) * 4 + 2] = 80
            }
        }
        return pixels
    }

    private func png(_ pixels: [UInt8], width: Int, height: Int) throws -> Data {
        Data(try XCTUnwrap(TEXVariantWriter.pngData(pixels, width: width, height: height)))
    }

    /// Every mipmap's texels of a variant-free `.tex`.
    private func levels(_ data: Data) throws -> [[UInt8]] {
        let layout = try TEXVariantWriter.Layout(data)
        XCTAssertEqual(layout.header.variantCount, 0)
        return try layout.images[0].map { try XCTUnwrap(TEXVariantWriter.texels($0)) }
    }

    /// The first mipmap of a variant-free `.tex` as straight RGBA, a picture container's decoded.
    private func picture(_ data: Data) throws -> [UInt8] {
        let layout = try TEXVariantWriter.Layout(data)
        let level = try XCTUnwrap(layout.images.first?.first)
        guard layout.isPicture else { return try XCTUnwrap(TEXVariantWriter.texels(level)) }
        return try decodedPNG(Data(level.stored))
    }

    /// Equal but for colour management's rounding (a PNG drawn through Core Graphics).
    private func assertClose(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 2, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        let worst = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, tolerance, message, file: file, line: line)
    }

    private func decodedPNG(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try EditorTEXEncoder.rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func texHeader(_ data: Data) -> TEXHeader? {
        TEXHeader([UInt8](data))
    }

    private func option(_ id: UInt32, group: UInt32 = 0, alphaBlend: Bool = false, condition: TextureVariantDocument.Condition,
                        file: Data) -> TextureVariantInput {
        TextureVariantInput(group: group, id: id, alphaBlend: alphaBlend, condition: condition.compiledJSON, file: file)
    }

    // MARK: Round trips

    func testReplaceRoundTripsInEveryImportFormat() throws {
        // Two mipmaps in every format (DXT pads 136 to 160).
        let width = 160, height = 136
        let basePixels = gradient(width: width, height: height)
        let variantPixels = painted(basePixels, width: width, x: 40, y: 8, w: 20, h: 12, [255, 0, 255, 255])
        let encoder = EditorTEXEncoder()
        for format in TextureImportOptions.Format.allCases {
            let base = EditorTEXEncoder.texture(basePixels, width: width, height: height, format: format, flags: 2, mipmapped: true)
            let data = try encoder.texture(base, withVariants: [option(0, condition: .flag("hat"), file: try png(variantPixels, width: width, height: height))])
            let variants = try XCTUnwrap(TEXVariants(texData: data), "\(format)")
            XCTAssertEqual(variants.options, [TEXVariants.Option(group: 0, id: 0, blend: [], condition: .flag(property: "hat"))])
            // Off: the base, every mipmap.
            XCTAssertEqual(try levels(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [:]))), try levels(base), "\(format)")
            // On: the variant as the importer writes it.
            let expected = EditorTEXEncoder.texture(variantPixels, width: width, height: height, format: format, flags: 2, mipmapped: true)
            let composed = try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [0: []]))
            XCTAssertEqual(try levels(composed), try levels(expected), "\(format)")
        }
    }

    func testAPictureBaseIsCompiledAsWEsImportedPicture() throws {
        // Capture 540: a 512 × 256 PNG import is RGBA8888 in a PNG container, three mipmaps.
        let pixels = gradient(width: 512, height: 256)
        let data = try EditorTEXEncoder().texture(try png(pixels, width: 512, height: 256),
                                                  withVariants: [option(1, condition: .flag("same"), file: try png(pixels, width: 512, height: 256))])
        let header = try XCTUnwrap(texHeader(data))
        XCTAssertEqual(header.format, 0)
        XCTAssertEqual(header.flags, TEXFlags.clampUVs.rawValue)
        XCTAssertEqual(header.freeImageFormat, 13)
        let plain = try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [:]))
        XCTAssertEqual(try TEXVariantWriter.Layout(plain).images[0].map { [$0.width, $0.height, $0.uncompressedSize] },
                       [[512, 256, 0], [256, 128, 0], [128, 64, 0]])
        assertClose(try picture(plain), pixels)
        assertClose(try picture(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [1: []]))), pixels)
    }

    func testAlphaBlendDrawsTheOpaquePartOverTheBase() throws {
        let width = 64, height = 64
        let basePixels = solid([100, 50, 200, 255], width: width, height: height)
        let overlay = painted(solid([0, 0, 0, 0], width: width, height: height), width: width, x: 10, y: 20, w: 6, h: 4, [250, 10, 0, 255])
        let base = EditorTEXEncoder.texture(basePixels, width: width, height: height, format: .rgba8888, flags: 2, mipmapped: false)
        let data = try EditorTEXEncoder().texture(base, withVariants: [
            option(0, alphaBlend: true, condition: .equals("tint", "red"), file: try png(overlay, width: width, height: height)),
        ])
        XCTAssertEqual(TEXVariants(texData: data)?.options.first?.blend, .alphaBlend)
        let composed = try levels(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [0: .alphaBlend])))[0]
        // WE's integer blend (`TEXVariantResolver.blend`) of the patch's pixel over the base's.
        var blended: [UInt8] = [100, 50, 200, 255]
        TEXVariantResolver.blend([250, 10, 0, 255], into: &blended,
                                 patch: TEXVariantResolver.Patch(option: 0, x: 0, y: 0, width: 1, height: 1, stored: 0..<0), rowPixels: 1)
        XCTAssertNotEqual(blended, [100, 50, 200, 255])
        XCTAssertEqual(Array(composed[((21 * width + 12) * 4)..<((21 * width + 12) * 4 + 4)]), blended)
        XCTAssertEqual(Array(composed[0..<4]), [100, 50, 200, 255], "outside the opaque part the base stays")

        // Only RGBA8888 can blend.
        let dxt = EditorTEXEncoder.texture(basePixels, width: width, height: height, format: .dxt5, flags: 2, mipmapped: false)
        XCTAssertThrowsError(try EditorTEXEncoder().texture(dxt, withVariants: [
            option(0, alphaBlend: true, condition: .flag("a"), file: try png(overlay, width: width, height: height)),
        ])) { XCTAssertEqual($0 as? TextureVariantError, .alphaBlendUnsupported(optionID: 0)) }
        XCTAssertEqual(EditorTEXEncoder().variantBase(dxt)?.allowsAlphaBlend, false)
        XCTAssertEqual(EditorTEXEncoder().variantBase(base)?.allowsAlphaBlend, true)
    }

    func testAPictureContainerReplacesTheWholePictureAndBlendsIt() throws {
        let pixels = solid([10, 20, 30, 255], width: 8, height: 8)
        var base = Data("TEXV0005\u{0}TEXI0001\u{0}".utf8)
        func word(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { base.append(contentsOf: $0) } }
        for value: UInt32 in [0, 2, 8, 8, 8, 8, 0xFF00_0000] { word(value) }
        base.append(contentsOf: Data("TEXB0003\u{0}".utf8))
        let basePicture = try png(pixels, width: 8, height: 8)
        word(1); word(13); word(1); word(8); word(8); word(0); word(UInt32(basePicture.count)); word(UInt32(basePicture.count))
        base.append(basePicture)
        let red = try png(solid([255, 0, 0, 255], width: 8, height: 8), width: 8, height: 8)
        let dot = try png(painted(solid([0, 0, 0, 0], width: 8, height: 8), width: 8, x: 2, y: 2, w: 1, h: 1, [0, 255, 0, 255]),
                          width: 8, height: 8)
        let data = try EditorTEXEncoder().texture(base, withVariants: [
            option(0, condition: .flag("red"), file: red),
            option(1, group: 1, alphaBlend: true, condition: .flag("dot"), file: dot),
        ])
        let variants = try XCTUnwrap(TEXVariants(texData: data))
        // As capture 540's: Replace is a rectangle (blend 0) of the whole picture, decoded and copied in.
        XCTAssertEqual(variants.options.map(\.blend), [[], .alphaBlend])
        let replaced = try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [0: []]))
        assertClose(try picture(replaced), solid([255, 0, 0, 255], width: 8, height: 8))
        let blended = try levels(try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [1: .alphaBlend])))[0]
        XCTAssertEqual(Int(blended[(2 * 8 + 2) * 4 + 1]), 20 + (255 - 20) * 255 / 256, accuracy: 2)
        assertClose(Array(blended[0..<4]), [10, 20, 30, 255])
    }

    func testAVideoTextureSwapsItsMovie() throws {
        let movie = try SceneScriptVideoTextureTests.movie()
        let other = try SceneScriptVideoTextureTests.movie() + Data([0])
        let base = EditorTEXEncoder.videoTexture(movie, width: 16, height: 16)
        XCTAssertEqual(EditorTEXEncoder().variantBase(base)?.isVideo, true)
        let data = try EditorTEXEncoder().texture(base, withVariants: [option(0, condition: .flag("night"), file: other)])
        XCTAssertEqual(TEXVariants(texData: data)?.options.first?.blend, .wholeMipmap)
        XCTAssertEqual(TEXParser(data: try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [0: .wholeMipmap]))).extractVideoData(), other)
        XCTAssertEqual(TEXParser(data: try XCTUnwrap(TEXVariantResolver.resolve(data, enabled: [:]))).extractVideoData(), movie)
        // A picture can't be a video's option, nor a video a picture's.
        XCTAssertThrowsError(try EditorTEXEncoder().texture(base, withVariants: [
            option(0, condition: .flag("a"), file: try png(solid([0, 0, 0, 255], width: 16, height: 16), width: 16, height: 16)),
        ])) { XCTAssertEqual($0 as? TextureVariantError, .incompatible(optionID: 0)) }
        let picture = EditorTEXEncoder.texture(solid([0, 0, 0, 255], width: 16, height: 16), width: 16, height: 16, format: .rgba8888,
                                               flags: 2, mipmapped: false)
        XCTAssertThrowsError(try EditorTEXEncoder().texture(picture, withVariants: [option(3, condition: .flag("a"), file: movie)])) {
            XCTAssertEqual($0 as? TextureVariantError, .incompatible(optionID: 3))
        }
    }

    func testAnOptionOfAnotherSizeIsIncompatible() throws {
        let base = EditorTEXEncoder.texture(solid([0, 0, 0, 255], width: 64, height: 64), width: 64, height: 64, format: .rgba8888,
                                            flags: 2, mipmapped: true)
        XCTAssertThrowsError(try EditorTEXEncoder().texture(base, withVariants: [
            option(5, condition: .flag("a"), file: try png(solid([0, 0, 0, 255], width: 32, height: 64), width: 32, height: 64)),
        ])) { XCTAssertEqual($0 as? TextureVariantError, .incompatible(optionID: 5)) }
    }

    // MARK: The layout

    func testTheRecordsAndPatchesAreLaidOutAsWEsLoaderReadsThem() throws {
        // 4 × 4 RGBA, one raw mipmap; option 0 changes pixel (1, 2).
        let base = TEXWriter.data(TEXWriter.Texture(format: 0, flags: 2, textureWidth: 4, textureHeight: 4, imageWidth: 4,
                                                    imageHeight: 4, colorWord: 0xFF00_0000,
                                                    mipmaps: [TEXWriter.Mipmap(width: 4, height: 4, compression: 0, uncompressedSize: 64,
                                                                               stored: Data(solid([0, 0, 0, 255], width: 4, height: 4)))]))
        let variant = painted(solid([0, 0, 0, 255], width: 4, height: 4), width: 4, x: 1, y: 2, w: 1, h: 1, [9, 8, 7, 255])
        let condition = TextureVariantDocument.Condition.equals("tint", "red").compiledJSON
        let data = try EditorTEXEncoder().texture(base, withVariants: [
            TextureVariantInput(group: 0, id: 0, alphaBlend: false, condition: condition, file: try png(variant, width: 4, height: 4)),
            TextureVariantInput(group: 1, id: 1, alphaBlend: false, condition: "{}", file: try png(variant, width: 4, height: 4)),
        ])
        let bytes = [UInt8](data)
        var cursor = texHeader(data)!.containerOffset
        func string() -> String {
            let end = bytes[cursor...].firstIndex(of: 0)!
            defer { cursor = end + 1 }
            return String(decoding: bytes[cursor..<end], as: UTF8.self)
        }
        func word() -> UInt32 {
            defer { cursor += 4 }
            return UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8 | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24
        }
        XCTAssertEqual(string(), "TEXB0004")
        XCTAssertEqual([word(), word(), word()], [1, UInt32(bitPattern: -1), 2], "images, FreeImage format, options")
        XCTAssertEqual([word(), word(), word()], [0, 0, 0], "group, option id, blend (region replace)")
        XCTAssertEqual(string(), #"{"condition":{"condition":"red","name":"tint"}}"#)
        XCTAssertEqual([word(), word(), word()], [1, 1, 0])
        XCTAssertEqual(string(), "{}")
        XCTAssertEqual(word(), 1, "mipmaps")
        XCTAssertEqual([word(), word(), word(), word(), word()], [4, 4, 0, 64, 64])
        cursor += 64
        XCTAssertEqual(word(), 2, "a patch count per group")
        for group: UInt32 in [0, 1] {
            XCTAssertEqual(word(), 1)
            // As WE's: the whole mipmap's rectangle.
            XCTAssertEqual([word(), word(), word(), word(), word(), word()], [group, group, 0, 0, 4, 4], "group, option, x, y, w, h")
            XCTAssertEqual([word(), word()], [UInt32(bitPattern: -1), 64], "FreeImage format, size")
            XCTAssertEqual(Array(bytes[cursor..<(cursor + 64)]), variant)
            cursor += 64
        }
        XCTAssertEqual(cursor, bytes.count)
        // Writing again over a base with variants replaces them.
        let again = try EditorTEXEncoder().texture(data, withVariants: [])
        XCTAssertEqual(texHeader(again)?.variantCount, 0)
        XCTAssertEqual(EditorTEXEncoder().variantBase(data)?.hasCompiledVariants, true)
    }

    // MARK: The conditions, through the player

    func testThePlayerChoosesTheFirstOptionOnInEachGroup() throws {
        let width = 64, height = 64
        let basePixels = solid([0, 0, 0, 255], width: width, height: height)
        let base = EditorTEXEncoder.texture(basePixels, width: width, height: height, format: .rgba8888, flags: 2, mipmapped: false)
        func file(_ pixel: [UInt8], x: Int) throws -> Data {
            try png(painted(basePixels, width: width, x: x, y: 0, w: 4, h: 4, pixel), width: width, height: height)
        }
        let data = try EditorTEXEncoder().texture(base, withVariants: [
            option(0, group: 0, condition: .flag("hat"), file: try file([1, 1, 1, 255], x: 0)),
            option(1, group: 0, condition: .equals("outfit", "2"), file: try file([2, 2, 2, 255], x: 0)),
            // A Replace option is the whole picture (capture 540), so an optional part goes in a
            // group of its own, alpha blended, as WE's docs advise.
            option(2, group: 1, alphaBlend: true, condition: .equals("outfit", "2"),
                   file: try png(painted(solid([0, 0, 0, 0], width: width, height: height), width: width, x: 8, y: 0, w: 4, h: 4,
                                         [200, 200, 200, 255]), width: width, height: height)),
        ])
        func pixels(_ values: [String: String]) throws -> [UInt8] {
            let resolved = UserPropertyBindingTable().resolvedData(data, path: "materials/a.tex", properties: { values[$0] })
            return try levels(resolved)[0]
        }
        let both = try pixels(["hat": "true", "outfit": "2"])
        XCTAssertEqual(both[0], 1, "the group's first option that is on wins")
        XCTAssertEqual(Int(both[8 * 4]), 200, accuracy: 1, "another group shows its own")
        XCTAssertEqual(try pixels(["hat": "false", "outfit": "2"])[0], 2)
        let none = try pixels(["hat": "false", "outfit": "1"])
        XCTAssertEqual([none[0], none[8 * 4]], [0, 0], "nothing on: the base")
    }

    @MainActor
    func testTheEditorsVariantsPlayThroughThePlayersResolver() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TEXVariantWriterTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory, encoder: EditorTEXEncoder())
        let width = 64, height = 64
        let basePixels = solid([20, 40, 60, 255], width: width, height: height)
        let hat = painted(basePixels, width: width, x: 16, y: 16, w: 8, h: 8, [200, 0, 0, 255])
        let hatURL = directory.appending(path: "hat.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png(hat, width: width, height: height).write(to: hatURL)
        let files: [String: Data] = [
            "models/bg.json": Data(#"{"autosize": true, "material": "materials/bg.json"}"#.utf8),
            "materials/bg.json": Data(#"{"passes": [{"shader": "genericimage2", "textures": ["bg"]}]}"#.utf8),
            "materials/bg.png": try png(basePixels, width: width, height: height),
        ]
        let readFile: (String) -> Data? = { path in
            files[path] ?? store.url(for: path).flatMap { try? Data(contentsOf: $0) }
        }
        let scene = Data(#"{"general": {"orthogonalprojection": {"width": 64, "height": 64}}, "objects": [{"id": 10, "image": "models/bg.json"}]}"#.utf8)
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: undoManager)

        var document = try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: readFile)).document
        XCTAssertEqual(document.source, "bg")
        let file = try store.importVariantFile(from: hatURL)
        XCTAssertTrue(file.hasPrefix("materials/editor/variants/hat-"))
        document.groups = [.init(name: "Clothes", options: [.init(name: "Hat", file: file, condition: .flag("hat"))])]
        try session.applyTextureVariants(document, to: 10, store: store, readFile: readFile, actionName: "Add Option")

        let model = try XCTUnwrap(session.overlay.field("image", of: 10)?.stringValue)
        let texture = try XCTUnwrap(ImageLayerMaterial(modelPath: model, readFile: readFile)?.texture)
        let compiled = try XCTUnwrap(readFile("materials/\(texture).tex"))
        let table = UserPropertyBindingTable()
        let on = try picture(table.building(.object(10)) {
            table.resolvedData(compiled, path: "materials/\(texture).tex", properties: { $0 == "hat" ? "true" : nil })
        })
        assertClose(on, hat)
        let off = try picture(table.resolvedData(compiled, path: "materials/\(texture).tex", properties: { _ in "false" }))
        assertClose(off, basePixels)
        XCTAssertEqual(Set(table.all.map(\.name)), ["hat"], "the condition rebuilds the texture's readers")

        // The editor reads its variants back from the `.tex-json` beside the texture.
        let state = try XCTUnwrap(session.textureVariants(of: 10, store: store, readFile: readFile))
        XCTAssertEqual(state.document.groups.first?.options.first?.condition, .flag("hat"))
        XCTAssertEqual(state.base?.allowsAlphaBlend, true)
        session.undo()
        XCTAssertNil(session.overlay.field("image", of: 10))
    }
}
