import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OWESceneEditing

/// WE's importer options: what keeps a PNG as it is, what goes to the `.tex` writer, cropping,
/// animated GIFs and image sequences as sprite sheets, MP4s as video textures, normal maps.
final class TextureImportTests: XCTestCase {
    private var directory: URL!

    /// Records what it is asked to write.
    final class RecordingEncoder: EditorTextureEncoding, @unchecked Sendable {
        var textures: [(width: Int, height: Int, options: TextureImportOptions)] = []
        var sheets: [[Double]] = []
        var normalMaps = 0
        var videos: [URL] = []

        func texture(_ image: CGImage, options: TextureImportOptions) throws -> Data {
            textures.append((image.width, image.height, options))
            return Data("tex \(image.width)x\(image.height) \(options.format)".utf8)
        }
        func normalMap(_ image: CGImage) throws -> Data {
            normalMaps += 1
            return Data("normal".utf8)
        }
        func spriteSheet(_ frames: [TextureImportFrame], options: TextureImportOptions) throws -> (data: Data, size: SIMD2<Double>) {
            sheets.append(frames.map(\.duration))
            return (Data("sheet \(frames.count)".utf8), SIMD2(1, 1))
        }
        func video(_ url: URL) throws -> (data: Data, size: SIMD2<Double>) {
            videos.append(url)
            return (Data("video".utf8), SIMD2(1280, 720))
        }
    }

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `width` × `height`, transparent but for an opaque rectangle `content` (top-left origin).
    private func image(width: Int, height: Int, content: CGRect? = nil) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        let rect = content ?? CGRect(x: 0, y: 0, width: width, height: height)
        context.fill(CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height))
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ images: [CGImage], as type: UTType, name: String, delay: Double? = nil) throws -> URL {
        let url = directory.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil))
        for image in images {
            let properties: [CFString: Any]? = delay.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func textures(of material: String, in store: EditorAssetStore) throws -> [String]? {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: material)))) as? [String: Any]
        return ((json?["passes"] as? [[String: Any]])?.first)?["textures"] as? [String]
    }

    func testWEsDefaultsKeepAPNGAndAnythingElseWritesATex() throws {
        XCTAssertTrue(TextureImportOptions().keepsPicture)
        XCTAssertEqual(TextureImportOptions().format, .rgba8888)
        XCTAssertTrue(TextureImportOptions().clampUVs, "WE clamps an imported image")
        let source = try write([try image(width: 40, height: 20)], as: .png, name: "logo.png")
        let encoder = RecordingEncoder()
        let store = EditorAssetStore(directory: directory.appending(path: "store"), encoder: encoder)
        let kept = try store.importImage(from: source)
        XCTAssertNotNil(store.url(for: "materials/\(kept.texture).png"))
        XCTAssertTrue(encoder.textures.isEmpty)
        var options = TextureImportOptions()
        options.format = .dxt5
        options.pixelArt = true
        let written = try store.importImage(from: source, options: options)
        XCTAssertNotNil(store.url(for: "materials/\(written.texture).tex"))
        XCTAssertEqual(encoder.textures.first?.options.format, .dxt5)
        XCTAssertEqual(written.size, SIMD2(40, 20))
        XCTAssertEqual(options.texFlags(), 3, "point filtering and clamping")
        XCTAssertEqual(options.texFlags(spriteSheet: true), 7)
        let plain = EditorAssetStore(directory: directory.appending(path: "plain"))
        XCTAssertThrowsError(try plain.importImage(from: source, options: options)) { error in
            XCTAssertEqual(error as? EditorAssetStore.ImportError, .needsEncoder("logo.png"))
        }
    }

    func testCropTransparencyCutsTheImageToItsPixels() throws {
        let picture = try image(width: 100, height: 80, content: CGRect(x: 10, y: 20, width: 30, height: 40))
        let cropped = try XCTUnwrap(EditorAssetStore.croppedToContent(picture, padding: 0))
        XCTAssertEqual(cropped.width, 30)
        XCTAssertEqual(cropped.height, 40)
        let padded = try XCTUnwrap(EditorAssetStore.croppedToContent(picture, padding: 15))
        XCTAssertEqual(padded.width, 55, "15 to the right, cut at the image's left edge")
        XCTAssertEqual(padded.height, 70, "15 above, 15 below")
        XCTAssertNil(EditorAssetStore.croppedToContent(try image(width: 8, height: 8), padding: 0), "nothing to cut")
        let source = try write([picture], as: .png, name: "sprite.png")
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        var options = TextureImportOptions()
        options.cropTransparency = true
        let imported = try store.importImage(from: source, options: options)
        XCTAssertEqual(imported.size, SIMD2(30, 40), "the layer is the cropped size")
        XCTAssertNotNil(store.url(for: "materials/\(imported.texture).png"), "still a PNG: the defaults keep the picture")
    }

    func testAGIFAndASequenceBecomeSpriteSheets() throws {
        let frames = try (0..<3).map { _ in try image(width: 16, height: 8) }
        let gif = try write(frames, as: .gif, name: "spin.gif", delay: 0.2)
        let encoder = RecordingEncoder()
        let store = EditorAssetStore(directory: directory.appending(path: "store"), encoder: encoder)
        let animated = try store.importImage(from: gif)
        XCTAssertEqual(encoder.sheets.first?.count, 3)
        XCTAssertEqual(encoder.sheets.first?.first ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(animated.size, SIMD2(16, 8), "the layer shows one frame")
        let urls = try ["b10.png", "b2.png", "b1.png"].map { try write([try image(width: 4, height: 4)], as: .png, name: $0) }
        var options = TextureImportOptions()
        options.frameDuration = 0.5
        let sequence = try store.importImageSequence(from: urls, options: options)
        XCTAssertEqual(sequence.title, "b1", "Finder's order: b1, b2, b10")
        XCTAssertEqual(encoder.sheets.last, [0.5, 0.5, 0.5])
    }

    func testAnMP4IsAVideoImageLayerAndANormalMapIsTheSecondTexture() throws {
        let movie = directory.appending(path: "clip.mp4")
        try Data("not decoded by the store".utf8).write(to: movie)
        let encoder = RecordingEncoder()
        let store = EditorAssetStore(directory: directory.appending(path: "store"), encoder: encoder)
        let video = try store.importImage(from: movie)
        XCTAssertEqual(encoder.videos, [movie])
        XCTAssertEqual(video.size, SIMD2(1280, 720))
        XCTAssertNotNil(store.url(for: "materials/\(video.texture).tex"))
        var options = TextureImportOptions()
        options.normalMap = try write([try image(width: 8, height: 8)], as: .png, name: "rock_n.png")
        let rock = try store.importImage(from: try write([try image(width: 8, height: 8)], as: .png, name: "rock.png"), options: options)
        XCTAssertEqual(encoder.normalMaps, 1)
        XCTAssertEqual(try textures(of: rock.material, in: store), [rock.texture, rock.texture + "_normal"])
        XCTAssertNotNil(store.url(for: "materials/\(rock.texture)_normal.tex"))
    }
}
