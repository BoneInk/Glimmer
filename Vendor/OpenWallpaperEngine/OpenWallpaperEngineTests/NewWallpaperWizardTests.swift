import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// New Wallpaper's app side: WE's templates are found in the assets cache's copy or beside an
/// install's assets, the cache keeps them, and a scene New Wallpaper makes from a picture loads
/// and draws its picture in the app's renderer.
final class NewWallpaperWizardTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-new-wallpaper-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: scratch)
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testTemplatesComeFromAnInstallOrTheCache() throws {
        let install = scratch.appending(path: "wallpaper_engine")
        try write("{}", to: "assets/shaders/common.h", in: install)
        try write("{}", to: "assets/effects/tint/effect.json", in: install)
        try write(#"{"name": "Animated GIF", "type": "scene2d"}"#, to: "projects/templates/gif/template.json", in: install)
        try write(#"{"file": "gifscene.json"}"#, to: "projects/templates/gif/project.json", in: install)
        try write(#"{"objects": []}"#, to: "projects/templates/gif/gifscene.json", in: install)
        XCTAssertEqual(NewWallpaperTemplates.templates(assets: install.appending(path: "assets")).map(\.name), ["Animated GIF"])

        let cache = WallpaperEngineAssets.cacheDirectory(in: scratch.appending(path: "storage"))
        let info = WallpaperEngineAssetsCache.Info(origin: .folder, installedAt: .now, steamBuildID: nil)
        try WallpaperEngineAssetsCache.fill(cache, from: install, info: info)
        XCTAssertEqual(NewWallpaperTemplates.templates(assets: cache).map(\.name), ["Animated GIF"])
        XCTAssertEqual(NewWallpaperTemplates.templates(assets: nil), [])
    }

    /// WE's own templates (`projects/templates`, beside the assets of `OWE_ASSETS`, or the cache's
    /// copy): New Wallpaper lists Flag and Animated GIF, and builds a scene from Flag and a picture.
    func testWEsTemplatesComeWithTheAssets() throws {
        let assets = try Fixtures.assets()
        let templates = NewWallpaperTemplates.templates(assets: assets)
        XCTAssertEqual(Set(templates.map(\.name)), ["Flag", "Animated GIF"], "WE's templates for \(assets.path)")
        let flag = try XCTUnwrap(templates.first { $0.name == "Flag" })
        XCTAssertEqual(flag.options.map(\.destination), ["materials/flag.png"])
        XCTAssertEqual(templates.first { $0.name == "Animated GIF" }?.options.map(\.animatedOnly), [true])

        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let url = scratch.appending(path: "mine.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let library = scratch.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let folder = try NewWallpaperBuilder().scene(from: flag, title: "My Flag",
                                                     pictures: ["materials/flag.png": try NewWallpaperBuilder.Picture(url: url)],
                                                     in: library)
        let project = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "project.json")))
            as? [String: Any])
        XCTAssertEqual(project["type"] as? String, "scene")
        XCTAssertEqual(project["title"] as? String, "My Flag")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "scene.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appending(path: "materials/flag.png").path))
    }

    func testASceneFromAPictureDraws() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let url = scratch.appending(path: "sky.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let library = scratch.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let folder = try NewWallpaperBuilder().scene(from: try NewWallpaperBuilder.Picture(url: url), title: "Sky", in: library)
        _ = try Fixtures.assets()
        var renderer = FixtureSceneRenderer(directory: folder)
        renderer.points = SIMD2(64, 32)
        let frame = try renderer.render()
        let centre = frame.pixel(frame.width / 2, frame.height / 2)
        XCTAssertLessThan(centre.x, 40, "the picture's colour fills the scene: \(centre)")
        XCTAssertGreaterThan(centre.z, 200)
        XCTAssertGreaterThan(centre.y, 90)
    }
}
