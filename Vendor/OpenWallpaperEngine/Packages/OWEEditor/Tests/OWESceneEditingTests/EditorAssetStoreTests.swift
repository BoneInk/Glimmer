import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OWESceneEditing

/// Files imported in the editor: kept in the overlay's own folder under the scene's paths, named
/// by their content, converted where the renderer can't read them, and copied into a saved copy.
final class EditorAssetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Fixtures.temporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func write(_ image: CGImage, as type: UTType, name: String) throws -> URL {
        let url = directory.appending(path: name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testImportingAPNGWritesItsTextureMaterialAndModel() throws {
        let source = try write(try image(width: 64, height: 32), as: .png, name: "My Logo.png")
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try store.importImage(from: source)
        XCTAssertEqual(imported.size, SIMD2(64, 32))
        XCTAssertEqual(imported.title, "My Logo")
        XCTAssertTrue(imported.model.hasPrefix("models/editor/my_logo-"))
        XCTAssertTrue(imported.texture.hasPrefix("editor/my_logo-"))
        let png = try XCTUnwrap(store.url(for: "materials/\(imported.texture).png"))
        XCTAssertEqual(try Data(contentsOf: png), try Data(contentsOf: source), "a PNG is kept as it is")
        let model = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: imported.model)))) as? [String: Any]
        XCTAssertEqual(model?["material"] as? String, imported.material)
        let material = try JSONSerialization.jsonObject(with: Data(contentsOf: try XCTUnwrap(store.url(for: imported.material)))) as? [String: Any]
        let pass = (material?["passes"] as? [[String: Any]])?.first
        XCTAssertEqual(pass?["shader"] as? String, "genericimage2")
        XCTAssertEqual(pass?["textures"] as? [String], [imported.texture])
        XCTAssertEqual(try store.importImage(from: source), imported, "the same file imports to the same asset")
        XCTAssertEqual(store.assets().map(\.path).filter { $0.hasSuffix(".png") }.count, 1)
    }

    func testOtherImagesAreConvertedToPNG() throws {
        let source = try write(try image(width: 8, height: 8), as: .tiff, name: "scan.tiff")
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try store.importImage(from: source)
        let png = try XCTUnwrap(store.url(for: "materials/\(imported.texture).png"))
        let read = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(read) as String?, UTType.png.identifier)
    }

    func testNotAnImageIsRefused() throws {
        let url = directory.appending(path: "notes.png")
        try Data("not an image".utf8).write(to: url)
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        XCTAssertThrowsError(try store.importImage(from: url)) { error in
            XCTAssertEqual(error as? EditorAssetStore.ImportError, .unsupported("notes.png"))
        }
    }

    func testMasksSoundsAndFonts() throws {
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let mask = try store.saveMask(try XCTUnwrap(EditorAssetStore.pngData(try image(width: 4, height: 4))), title: "Water Ripple")
        XCTAssertTrue(mask.hasPrefix("masks/editor_water_ripple-"))
        XCTAssertNotNil(store.url(for: "materials/\(mask).png"), "where the loader looks for a mask texture")
        let sound = directory.appending(path: "rain.mp3")
        try Data([0xFF, 0xFB, 0x90, 0x00]).write(to: sound)
        XCTAssertTrue(try store.importSound(from: sound).hasPrefix("sounds/editor/rain-"))
        let text = directory.appending(path: "rain.txt")
        try Data("x".utf8).write(to: text)
        XCTAssertThrowsError(try store.importSound(from: text))
        let font = directory.appending(path: "Clock Face.ttf")
        try Data([0, 1, 0, 0]).write(to: font)
        XCTAssertTrue(try store.importFont(from: font).hasPrefix("fonts/editor/clock_face-"))
        XCTAssertNil(store.url(for: "../outside"), "paths stay in the folder")
    }

    func testASavedCopyCarriesTheImportedFiles() throws {
        let wallpaper = directory.appending(path: "wallpaper", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wallpaper.appending(path: "materials"), withIntermediateDirectories: true)
        try Data(#"{"title": "W", "file": "scene.json", "type": "scene", "workshopid": "1"}"#.utf8)
            .write(to: wallpaper.appending(path: "project.json"))
        try Data("own".utf8).write(to: wallpaper.appending(path: "materials/own.png"))
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try store.importImage(from: try write(try image(width: 2, height: 2), as: .png, name: "add.png"))
        let library = directory.appending(path: "library", directoryHint: .isDirectory)
        let folder = try LocalWallpaperWriter().save(
            LocalWallpaperWriter.Source(directory: wallpaper, sceneFile: "scene.json", assetsDirectory: store.directory),
            scene: Data("{}".utf8), title: "Copy", into: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "materials/own.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "materials/\(imported.texture).png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: imported.model).path))
    }
}
