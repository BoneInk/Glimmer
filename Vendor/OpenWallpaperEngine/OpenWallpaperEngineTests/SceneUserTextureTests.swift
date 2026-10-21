import XCTest
@testable import OpenWallpaperEngine

/// WE's texture user property (`scenetexture`, `SceneUserTexture`): a plain-string `usertextures`
/// entry names the property whose picked picture or video replaces the image slot
/// (`Scenes/user-texture`); with nothing picked the layer keeps its image.
@MainActor
final class SceneUserTextureTests: XCTestCase {
    func testPlainStringEntriesNameTheProperty() {
        let entries = SceneJSON.array([.null, .string("photo"),
                                       .object(["name": .string("$mediaThumbnail"), "type": .string("system")])])
        XCTAssertNil(SceneUserTexture.property(in: entries, slot: 0))
        XCTAssertEqual(SceneUserTexture.property(in: entries, slot: 1), "photo")
        XCTAssertNil(SceneUserTexture.property(in: entries, slot: 2), "a system texture")
        XCTAssertNil(SceneUserTexture.property(in: entries, slot: 3))
        XCTAssertEqual(SceneUserTexture.property(in: [nil, .array([.string("fallback")])], slot: 0), "fallback")
        XCTAssertEqual(SceneSystemTexture.name(in: entries, slot: 1), nil)
        XCTAssertEqual(SceneUserTexture.kind(of: "/a/b.JPG"), .image)
        XCTAssertEqual(SceneUserTexture.kind(of: "/a/b.mp4"), .video)
        XCTAssertNil(SceneUserTexture.kind(of: "/a/b.txt"))
    }

    func testPickedPictureReplacesTheLayerImageAndRebuildsItAlone() throws {
        let directory = Fixtures.url("Scenes/user-texture")
        Fixtures.removeStoredSettings(for: directory)
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/user-texture/project.json"))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let authored = try XCTUnwrap(content.layers.first { $0.id == "1" })
        XCTAssertEqual(authored.source.pixelSize, SIMD2<Float>(2, 2), "nothing picked: the authored image")

        let picked = FileManager.default.temporaryDirectory.appendingPathComponent("owe-user-texture-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: picked) }  // Optional cleanup of a temporary file.
        try Data(Self.png(width: 4, height: 3)).write(to: picked)
        WallpaperServices.shared.setUserProperties(["photo": picked.path], wallpaper: model.propertyStoreKey, replacing: false)
        let update = model.bindingUpdate(for: ["photo"])
        XCTAssertEqual(update.rebuild, [1])
        let replacement = try XCTUnwrap(model.rebuildObjects(update.rebuild))
        let layer = try XCTUnwrap(replacement.content.layers.first { $0.id == "1" })
        XCTAssertEqual(layer.source.pixelSize, SIMD2<Float>(4, 3), "the picked picture")
        XCTAssertEqual(layer.size, authored.size, "drawn at the authored image's size")
    }

    /// A one-colour RGBA PNG.
    private static func png(width: Int, height: Int) throws -> [UInt8] {
        let pixels = [UInt8](repeating: 200, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        return [UInt8](data)
    }
}
