import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// An image in a padded `.tex` (the picture in the top-left of a power-of-two texture, as WE's
/// editor stores most imported pictures) with an effect and a mask, placed on a 1920×1080 display.
/// The picture is a test pattern: red counts its columns, green its rows, blue marks its bottom
/// band, and the padding is magenta. The frame must show the scene's rows and columns that the
/// placement keeps, whatever the texture's allocation.
final class EffectPaddedImagePlacementTests: XCTestCase {
    static let image = SIMD2(1000, 601)
    static let display = SIMD2(1920, 1080)
    /// Rows from here down are the bottom band (blue).
    static let bandRow = 571

    struct Variant {
        var padded: Bool
        var effect: Bool
    }

    /// What a display pixel shows: the source column and row its colour encodes, and whether it is
    /// the bottom band or the padding.
    struct Sample: CustomStringConvertible {
        var column: Float
        var row: Float
        var band: Bool
        var padding: Bool
        var description: String { "col \(column) row \(row)\(band ? " band" : "")\(padding ? " padding" : "")" }
    }

    /// Fill scales the 1000×601 scene by 1.92 to 1920×1154 and trims 37 px (19 rows) off its top
    /// and bottom; Fit scales it by 1.797 to 1797×1080 with 61 px bars left and right.
    private func assertPlacement(_ variant: Variant, _ placement: WallpaperPlacement,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try render(variant, placement: placement)
        let name = "\(placement) padded \(variant.padded) effect \(variant.effect)"
        let tolerance: Float = 3
        let fill = placement == .fill
        // Columns and rows the placement keeps, sampled a few pixels in from the picture's edges.
        let (left, right) = fill ? (4, 1915) : (66, 1853)
        let (firstColumn, lastColumn): (Float, Float) = fill ? (2, 997) : (2.5, 996)
        let (top, bottom) = (4, 1075)
        let (firstRow, lastRow): (Float, Float) = fill ? (21.3, 579.5) : (2.4, 598.4)
        func check(_ sample: Sample, column: Float? = nil, row: Float? = nil, band: Bool? = nil, _ what: String) {
            if let column { XCTAssertEqual(sample.column, column, accuracy: tolerance, "\(name) \(what): \(sample)", file: file, line: line) }
            if let row { XCTAssertEqual(sample.row, row, accuracy: tolerance, "\(name) \(what): \(sample)", file: file, line: line) }
            if let band { XCTAssertEqual(sample.band, band, "\(name) \(what): \(sample)", file: file, line: line) }
            XCTAssertFalse(sample.padding, "\(name) \(what) shows the texture's padding: \(sample)", file: file, line: line)
        }
        check(frame(960, 540), column: 500, row: 300, band: false, "centre")
        check(frame(960, top), column: 500, row: firstRow, band: false, "top")
        check(frame(960, bottom), column: 500, row: lastRow, band: true, "bottom")
        check(frame(left, 540), column: firstColumn, row: 300, "left")
        check(frame(right, 540), column: lastColumn, row: 300, "right")
    }

    /// The same image as DXT1 in a 1024×1024 allocation, blue with a red bottom band, tinted green by
    /// WE's tint effect where its padded mask (500×300 in 512×512) is white: rows 75…224 of the
    /// mask, the picture's rows 150…449. A DXT texture can't be blitted texel by texel, so its
    /// effects ran over the whole allocation and the mask's band landed on rows 256…767.
    func testPaddedDXTImageMaskLinesUpWithThePicture() throws {
        _ = try Fixtures.assets()
        for placement in [WallpaperPlacement.fit, .fill] {
            let frame = try render(Self.writeDXTFixture(), effect: true, placement: placement)
            // The colour at the display's centre column of a picture row.
            func colour(_ row: Float) -> SIMD3<UInt8> {
                let (scale, top): (Float, Float) = placement == .fill ? (1.92, 36.96) : (1080 / 601, 0)
                let y = Int((row + 0.5) * scale - top)
                let i = (y * Self.display.x + 960) * 4
                return SIMD3(frame[i + 2], frame[i + 1], frame[i])
            }
            let blue = SIMD3<UInt8>(0, 0, 255), green = SIMD3<UInt8>(0, 255, 0), red = SIMD3<UInt8>(255, 0, 0)
            for (row, expected) in [(30, blue), (140, blue), (160, green), (300, green), (440, green), (460, blue),
                                    (560, blue), (578, red)] as [(Float, SIMD3<UInt8>)] {
                let got = colour(row)
                let difference = simd_reduce_max(simd_abs(SIMD3<Int32>(truncatingIfNeeded: got) &- SIMD3<Int32>(truncatingIfNeeded: expected)))
                XCTAssertLessThanOrEqual(difference, 8, "\(placement) row \(row): \(got), expected \(expected)")
            }
        }
    }

    // MARK: - Rendering

    /// Renders the fixture once it has settled and returns a reader of its display pixels.
    func render(_ variant: Variant, placement: WallpaperPlacement) throws -> (Int, Int) -> Sample {
        let frame = try render(Self.writeFixture(variant), effect: variant.effect, placement: placement)
        return { x, y in
            let i = (y * Self.display.x + x) * 4
            let (b, g, r) = (Float(frame[i]), Float(frame[i + 1]), Float(frame[i + 2]))
            return Sample(column: r / 255 * Float(Self.image.x - 1), row: g / 255 * Float(Self.image.y - 1),
                          band: b > 200 && g > 100, padding: r > 200 && b > 200 && g < 50)
        }
    }

    /// The scene in `directory` drawn on the display once it has settled with its effects, as BGRA
    /// bytes from the top-left; removes `directory`.
    func render(_ directory: URL, effect: Bool, placement: WallpaperPlacement) throws -> [UInt8] {
        defer {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // scratch cleanup
        }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let content = try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
        let layer = try XCTUnwrap(content.layers.first)
        XCTAssertEqual(layer.weEffects.isEmpty, !effect, "effects built")
        let size = Self.display
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "padded-effect"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(placement)
        renderer.setContent(content)
        var bytes = [UInt8](repeating: 0, count: size.x * size.y * 4)
        var previous: [UInt8] = []
        var stable = 0
        let deadline = Date().addingTimeInterval(60)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            // Until its effect pipelines compile the layer draws plain; only its effects' frame counts.
            guard renderer.hasContent,
                  !effect || (renderer.effectPassesEncoded > 0 && !renderer.hasPendingEffectPipelines) else { continue }
            view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: size.x * 4,
                                                   from: MTLRegionMake2D(0, 0, size.x, size.y), mipmapLevel: 0)
            // The shake moves by under a hundredth of a texel: settled is within a couple of levels.
            let settled = bytes.count == previous.count && !zip(bytes, previous).contains { abs(Int($0) - Int($1)) > 2 }
            stable = settled ? stable + 1 : 0
            previous = bytes
        } while stable < 3 && Date() < deadline
        XCTAssertGreaterThanOrEqual(stable, 3, "the frame never settled with its effects drawn")
        return bytes
    }

    // MARK: - Fixture

    /// The fixture's scene: one autosized image, sized and placed as WE's editor writes it, with
    /// WE's shake effect whose direction map is a padded mask, on a scene the image's size.
    static func writeFixture(_ variant: Variant) throws -> URL {
        let assets = try Fixtures.assets()
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-padded-effect-\(UUID().uuidString)")
        let files = FileManager.default
        for folder in ["models", "materials/masks"] {
            try files.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: directory.appending(path: path)) }
        // WE's editor packs an effect's material and shaders into the wallpaper; copied from WE's assets.
        for path in ["materials/effects/shake.json", "shaders/effects/shake.frag", "shaders/effects/shake.vert"] {
            let target = directory.appending(path: path)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: assets.appending(path: "effects/shake/\(path)"), to: target)
        }
        try write(#"{"file": "scene.json", "title": "Padded image with an effect", "type": "scene"}"#, "project.json")
        try write(#"{"autosize": true, "material": "materials/picture.json"}"#, "models/picture.json")
        try write(#"""
        {"passes": [{"blending": "translucent", "combos": {"version": 2}, "cullmode": "nocull",
                     "depthtest": "disabled", "depthwrite": "disabled", "shader": "genericimage2",
                     "textures": ["picture"]}]}
        """#, "materials/picture.json")
        let effects = variant.effect ? #"""
        "effects": [{"file": "effects/shake/effect.json", "id": 18, "name": "", "visible": true,
                     "passes": [{"id": 19, "constantshadervalues": {"speed": 0.68, "strength": 0.11},
                                 "textures": [null, "masks/shake_mask_test", "util/white"]}]}],
        """# : ""
        try write("""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"clearcolor": "0.7 0.7 0.7", "clearenabled": true, "bloom": false,
                     "orthogonalprojection": {"width": \(image.x), "height": \(image.y)}},
         "objects": [{"alignment": "center", "alpha": 1, "angles": "0 0 0", "color": "1 1 1",
                      "colorBlendMode": 0, "copybackground": true, \(effects)
                      "id": 13, "image": "models/picture.json", "ledsource": false, "locktransforms": true,
                      "name": "picture", "origin": "500 300.5 0", "parallaxDepth": "1 1", "perspective": false,
                      "scale": "1 1 1", "size": "\(image.x) \(image.y)", "solid": true, "visible": true}]}
        """, "scene.json")
        let allocated = variant.padded ? SIMD2(1024, 1024) : image
        try tex(allocated: allocated, image: image) { x, y in
            let band: UInt8 = y >= bandRow ? 255 : 0
            return [UInt8((Float(x) / Float(image.x - 1) * 255).rounded()),
                    UInt8((Float(y) / Float(image.y - 1) * 255).rounded()), band, 255]
        }.write(to: directory.appending(path: "materials/picture.tex"))
        // A neutral direction map (no flow), padded like the wallpaper's: 500×300 in 512×512.
        let mask = variant.padded ? SIMD2(512, 512) : SIMD2(500, 300)
        try tex(allocated: mask, image: SIMD2(500, 300)) { _, _ in [127, 127, 0, 255] }
            .write(to: directory.appending(path: "materials/masks/shake_mask_test.tex"))
        return directory
    }

    /// The DXT fixture's scene (`testPaddedDXTImageMaskLinesUpWithThePicture`), laid out as
    /// `writeFixture`'s with WE's tint effect.
    static func writeDXTFixture() throws -> URL {
        let assets = try Fixtures.assets()
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-padded-dxt-\(UUID().uuidString)")
        let files = FileManager.default
        for folder in ["models", "materials/masks"] {
            try files.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        func write(_ text: String, _ path: String) throws { try Data(text.utf8).write(to: directory.appending(path: path)) }
        for path in ["materials/effects/tint.json", "shaders/effects/tint.frag", "shaders/effects/tint.vert"] {
            let target = directory.appending(path: path)
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.copyItem(at: assets.appending(path: "effects/tint/\(path)"), to: target)
        }
        try write(#"{"file": "scene.json", "title": "Padded DXT image with a masked effect", "type": "scene"}"#, "project.json")
        try write(#"{"autosize": true, "material": "materials/picture.json"}"#, "models/picture.json")
        try write(#"""
        {"passes": [{"blending": "translucent", "combos": {"version": 2}, "cullmode": "nocull",
                     "depthtest": "disabled", "depthwrite": "disabled", "shader": "genericimage2",
                     "textures": ["picture"]}]}
        """#, "materials/picture.json")
        try write("""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
         "general": {"clearcolor": "0.7 0.7 0.7", "clearenabled": true, "bloom": false,
                     "orthogonalprojection": {"width": \(image.x), "height": \(image.y)}},
         "objects": [{"alignment": "center", "alpha": 1, "angles": "0 0 0", "color": "1 1 1", "colorBlendMode": 0,
                      "effects": [{"file": "effects/tint/effect.json", "id": 18, "name": "", "visible": true,
                                   "passes": [{"id": 19, "combos": {"BLENDMODE": 0},
                                               "constantshadervalues": {"alpha": 1, "color": "0 1 0"},
                                               "textures": [null, "masks/tint_mask_test"]}]}],
                      "id": 13, "image": "models/picture.json", "name": "picture", "origin": "500 300.5 0",
                      "scale": "1 1 1", "size": "\(image.x) \(image.y)", "visible": true}]}
        """, "scene.json")
        try dxt1(allocated: SIMD2(1024, 1024), image: image) { _, y in y >= 572 ? (255, 0, 0) : (0, 0, 255) }
            .write(to: directory.appending(path: "materials/picture.tex"))
        try tex(allocated: SIMD2(512, 512), image: SIMD2(500, 300)) { _, y in
            let white: UInt8 = (75..<225).contains(y) ? 255 : 0
            return [white, white, white, 255]
        }.write(to: directory.appending(path: "materials/masks/tint_mask_test.tex"))
        return directory
    }

    /// An uncompressed DXT1 `.tex` whose 4×4 blocks are each one colour: `colour` of the block's
    /// first texel inside `image`, magenta in the padding.
    static func dxt1(allocated: SIMD2<Int>, image: SIMD2<Int>, colour: (Int, Int) -> (Int, Int, Int)) -> Data {
        var blocks = Data()
        func word(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { blocks.append(contentsOf: $0) } }
        for by in stride(from: 0, to: allocated.y, by: 4) {
            for bx in stride(from: 0, to: allocated.x, by: 4) {
                let (r, g, b) = bx < image.x && by < image.y ? colour(bx, by) : (255, 0, 255)
                let packed = UInt16(r >> 3) << 11 | UInt16(g >> 2) << 5 | UInt16(b >> 3)
                word(packed)
                word(packed)
                blocks.append(contentsOf: [0, 0, 0, 0])
            }
        }
        return TEXWriter.data(TEXWriter.Texture(
            format: 7, flags: 2, textureWidth: allocated.x, textureHeight: allocated.y,
            imageWidth: image.x, imageHeight: image.y, colorWord: 0,
            mipmaps: [TEXWriter.Mipmap(width: allocated.x, height: allocated.y, compression: 0,
                                       uncompressedSize: blocks.count, stored: blocks)]))
    }

    /// An LZ4-compressed RGBA8888 `.tex`: `pixel` inside `image`, magenta padding around it.
    static func tex(allocated: SIMD2<Int>, image: SIMD2<Int>, pixel: (Int, Int) -> [UInt8]) -> Data {
        var bytes = [UInt8](repeating: 0, count: allocated.x * allocated.y * 4)
        for y in 0..<allocated.y {
            for x in 0..<allocated.x {
                let value: [UInt8] = x < image.x && y < image.y ? pixel(x, y) : [255, 0, 255, 255]
                bytes.replaceSubrange((y * allocated.x + x) * 4..<(y * allocated.x + x) * 4 + 4, with: value)
            }
        }
        let stored = LZ4BlockEncoder.compress(bytes)
        return TEXWriter.data(TEXWriter.Texture(
            format: 0, flags: 2, textureWidth: allocated.x, textureHeight: allocated.y,
            imageWidth: image.x, imageHeight: image.y, colorWord: 0,
            mipmaps: [TEXWriter.Mipmap(width: allocated.x, height: allocated.y, compression: 1,
                                       uncompressedSize: bytes.count, stored: Data(stored))]))
    }
}
