import XCTest
import Metal
@testable import OpenWallpaperEngine

/// A raw .tex image (RGBA8888, RG88, R8) inside a larger allocation is uploaded padded, the image
/// in its top-left texels, as WE uploads every .tex and as a block-compressed one is uploaded here.
/// A material samples all its textures at the same coordinates: Deep Space's `flowimage` names a
/// raw 480 × 270 flow mask (512 × 512 allocation) first and DXT galaxies (1920 × 1080 in 2048 ×
/// 2048) after it; with the mask cropped the layer's coordinates ran over the whole of each galaxy
/// texture, padding and all, and the galaxies drew in its top-left quarter.
final class PaddedRawTextureTests: XCTestCase {
    /// 6 × 3 opaque red inside an 8 × 4 allocation whose padding is transparent.
    private static func paddedTex() -> Data {
        var bytes = [UInt8](repeating: 0, count: 8 * 4 * 4)
        for y in 0..<3 {
            for x in 0..<6 { bytes.replaceSubrange(((y * 8 + x) * 4)..<((y * 8 + x) * 4 + 4), with: [255, 0, 0, 255]) }
        }
        return TextureReductionTests.tex(format: 0, image: SIMD2(6, 3), mipmaps: [(SIMD2(8, 4), bytes)])
    }

    func testAPaddedRawImageKeepsItsAllocation() throws {
        let parser = TEXParser(data: Self.paddedTex())
        XCTAssertTrue(parser.isPaddedRawImage())
        let image = try XCTUnwrap(parser.extractImage())
        let raw = try XCTUnwrap(TEXRawImageRep.of(image))
        XCTAssertTrue(raw.isPadded)
        XCTAssertEqual(raw.allocationRows, 4)
        XCTAssertEqual(raw.contentUVExtent, SIMD2(0.75, 0.75))
        let source = SceneMetalTextureSource.image(image)
        XCTAssertEqual(source.pixelSize, SIMD2(6, 3), "an unsized layer is the image's size")
        XCTAssertEqual(source.contentSize, SIMD2(6, 3))
        XCTAssertEqual(source.sheetPixelSize, SIMD2(8, 4))
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(raw.makeAllocationTexture(device: device))
        XCTAssertEqual(SIMD2(texture.width, texture.height), SIMD2(8, 4))
    }

    func testAnUnpaddedRawImageIsUnchanged() throws {
        let bytes = [UInt8](repeating: 255, count: 8 * 4 * 4)
        let parser = TEXParser(data: TextureReductionTests.tex(format: 0, image: SIMD2(8, 4), mipmaps: [(SIMD2(8, 4), bytes)]))
        XCTAssertFalse(parser.isPaddedRawImage())
        let image = try XCTUnwrap(parser.extractImage())
        XCTAssertNil(SceneMetalTextureSource.image(image).contentSize)
    }

    /// Drawn, the layer shows the image over its whole quad, never the padding.
    func testALayerDrawsOnlyTheImage() throws {
        _ = try Fixtures.assets()
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-padded-raw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) } // Optional: a temporary folder.
        for folder in ["materials", "models"] {
            try FileManager.default.createDirectory(at: directory.appending(path: folder), withIntermediateDirectories: true)
        }
        try Self.paddedTex().write(to: directory.appending(path: "materials/red.tex"))
        let files = [
            "materials/red.json": #"{"passes":[{"blending":"translucent","shader":"genericimage2","textures":["red"]}]}"#,
            "models/red.json": #"{"autosize":true,"material":"materials/red.json"}"#,
            "scene.json": #"{"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"version":1,"general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":64,"height":32}},"objects":[{"id":1,"name":"red","image":"models/red.json","origin":"32 16 0","size":"64 32"}]}"#,
            "project.json": #"{"file":"scene.json","title":"Fixture: a padded raw image","type":"scene"}"#,
        ]
        for (path, text) in files { try Data(text.utf8).write(to: directory.appending(path: path)) }
        var renderer = FixtureSceneRenderer(directory: directory)
        renderer.points = SIMD2(64, 32)
        let frame = try renderer.render()
        // Every corner of the quad is red: the padding (transparent, black over the clear colour)
        // would fill its right and bottom quarters.
        for (x, y) in [(2, 2), (61, 2), (2, 29), (61, 29), (32, 16)] {
            let pixel = frame.pixel(x, y)
            XCTAssertGreaterThan(pixel.x, 100, "(\(x), \(y)) is \(pixel)")
            XCTAssertLessThan(pixel.y, 40, "(\(x), \(y)) is \(pixel)")
        }
    }
}
