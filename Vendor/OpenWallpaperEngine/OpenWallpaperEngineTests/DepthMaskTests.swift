import Compression
import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// A layer's depth map made into an effect's mask (Create Mask from Depth Map): the `.tex` is the
/// R8 mask WE's editor writes, Save as New Wallpaper carries it and the effect's reference into
/// the copy, and the masked effect changes only the masked part of the layer; as the layer's
/// opacity (WE's Opacity effect added with the mask), the layer is transparent where it is black.
@MainActor
final class DepthMaskTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-depthmask-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch) // Scratch: a leftover is harmless.
    }

    /// As WE's editor writes an effect mask in Workshop scenes (`materials/masks/<effect>_mask_<hash>.tex`):
    /// `TEXV0005`/`TEXI0001`, format 9 (R8), flags 2 (clamp UVs), the texture its image's size,
    /// colour word `0xFF000000`, `TEXB0003` with one image, no FreeImage picture and one LZ4 mipmap.
    func testTheMaskIsWEsR8EffectMask() throws {
        let width = 37, height = 21
        let pixels = (0..<(width * height)).map { UInt8(truncatingIfNeeded: $0 * 7) }
        let data = TEXWriter.effectMask(pixels, width: width, height: height)
        let header = try XCTUnwrap(TEXFileHeader(data))
        XCTAssertEqual(header.format, 9)
        XCTAssertEqual(header.flags, 2)
        XCTAssertEqual([header.textureWidth, header.textureHeight, header.imageWidth, header.imageHeight], [width, height, width, height])
        XCTAssertEqual(header.colorWord, 0xFF00_0000)
        XCTAssertEqual(header.containerVersion, 3)
        XCTAssertEqual(header.imageCount, 1)
        XCTAssertEqual(header.freeImageFormat, -1)
        XCTAssertEqual(header.trailingByteCount, 0)
        let mipmap = try XCTUnwrap(header.mipmaps.first)
        XCTAssertEqual(header.mipmaps.count, 1)
        XCTAssertEqual([mipmap.width, mipmap.height, mipmap.uncompressedSize], [width, height, pixels.count])
        XCTAssertEqual(mipmap.compression, 1, "LZ4")
        let stored = [UInt8](data.subdata(in: mipmap.stored)) // The writer's data starts at index 0.
        var output = [UInt8](repeating: 0, count: pixels.count)
        XCTAssertEqual(compression_decode_buffer(&output, output.count, stored, stored.count, nil, COMPRESSION_LZ4_RAW), pixels.count)
        XCTAssertEqual(output, pixels)
        XCTAssertNotNil(TEXParser(data: data).extractImage(), "the app reads it back")
    }

    /// WE's Tint on the effect gallery's checkerboard layer, masked with a depth map that is near
    /// (white) on the layer's left half and far on its right, through the overlay and Save as Local
    /// Wallpaper: the copy has the mask file and names it in the effect's pass, and drawn headlessly
    /// the tint shows on the left half only.
    func testAMaskedEffectSavedAsLocalWallpaperChangesOnlyTheMaskedHalf() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shader sources aren't available")
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        let control = try WEEffectGallery.makeProject(effect: nil, name: "mask-control", assets: assets, in: scratch)
        let source = try WEEffectGallery.makeProject(effect: "tint", name: "mask-source", assets: assets, in: scratch)

        let side = 256
        let depth = (0..<(side * side)).map { $0 % side < side / 2 ? UInt8(255) : 0 }
        let mask = DepthMask.shaped(depth, invert: false, contrast: DepthMask.defaultContrast)
        let tex = TEXWriter.effectMask(mask, width: side, height: side)
        let editorFiles = scratch.appending(path: "editor-files", directoryHint: .isDirectory)
        let path = try EditorAssetStore(directory: editorFiles).saveEffectMask(tex, name: "tint")

        let sceneData = try Data(contentsOf: source.appending(path: "scene.json"))
        let session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData))
        session.setEffectTexture(path, slot: 1, effect: "0", of: 10, combo: "MASK", actionName: "Use Depth Map as Mask")
        let copy = try LocalWallpaperWriter().save(
            LocalWallpaperWriter.Source(directory: source, sceneFile: "scene.json", assetsDirectory: editorFiles),
            scene: try session.overlay.applied(to: sceneData), title: "Masked", into: scratch.appending(path: "library"))

        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "materials/\(path).tex")), tex, "the mask is a file of the copy")
        let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy.appending(path: "scene.json"))) as? [String: Any])
        let objects = try XCTUnwrap(scene["objects"] as? [[String: Any]])
        let layer = try XCTUnwrap(objects.first { ($0["id"] as? Int) == 10 })
        let effect = try XCTUnwrap((layer["effects"] as? [[String: Any]])?.first)
        let pass = try XCTUnwrap((effect["passes"] as? [[String: Any]])?.first)
        let textures = try XCTUnwrap(pass["textures"] as? [Any])
        XCTAssertTrue(textures.first is NSNull, "the layer's own image, as WE writes it")
        XCTAssertEqual(textures[1] as? String, path, "named in the pass's textures at the mask's slot, as WE does")
        XCTAssertEqual((pass["combos"] as? [String: Any])?["MASK"] as? Int, 1)

        let masked = try render(copy)
        let plain = try render(control)
        // The checkerboard layer: 1024 × 0.85 around (480, 540), x 45…915, y 105…975.
        let left = CGRect(x: 100, y: 300, width: 280, height: 480)
        let right = CGRect(x: 580, y: 300, width: 280, height: 480)
        XCTAssertGreaterThan(Self.difference(masked, plain, in: left), 10, "the tint shows where the mask is white")
        XCTAssertLessThan(Self.difference(masked, plain, in: right), 1, "and not where it is black")
    }

    /// Layer Opacity on the effect gallery's checkerboard layer, which has no Opacity effect: WE's
    /// Opacity effect added with a depth mask that is near (white) on the layer's left half and far
    /// on its right, one undo step, through Save as Local Wallpaper. The copy lists the effect with
    /// the mask in its pass's `textures` and `MASK` on, and drawn headlessly the left half is the
    /// layer as it was and the right half shows the clear colour through it.
    func testLayerOpacitySavedAsLocalWallpaperIsTransparentWhereTheMaskIsBlack() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE's effect shader sources aren't available")
        let assets = try XCTUnwrap(WallpaperEngineAssets.directory)
        let control = try WEEffectGallery.makeProject(effect: nil, name: "opacity-control", assets: assets, in: scratch)
        let source = try WEEffectGallery.makeProject(effect: nil, name: "opacity-source", assets: assets, in: scratch)
        // As adding the effect does (`EditorWallpaperResources.prepareEffect`): its files go with the project.
        try WEEffectGallery.copyEffect("opacity", assets: assets, into: source)

        let side = 256
        let depth = (0..<(side * side)).map { $0 % side < side / 2 ? UInt8(255) : 0 }
        let mask = DepthMask.shaped(depth, invert: false, contrast: DepthMask.defaultContrast)
        let tex = TEXWriter.effectMask(mask, width: side, height: side)
        let editorFiles = scratch.appending(path: "editor-files", directoryHint: .isDirectory)
        let path = try EditorAssetStore(directory: editorFiles).saveEffectMask(tex, name: "opacity")
        XCTAssertTrue(path.hasPrefix("masks/opacity_mask_"))

        let sceneData = try Data(contentsOf: source.appending(path: "scene.json"))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData), undoManager: undoManager)
        let key = try XCTUnwrap(session.addEffect(DepthMask.opacityEffect, to: 10, texture: path, slot: 1, combo: "MASK",
                                                  actionName: "Use Depth Map as Mask"))
        let edited = session.overlay
        session.undo()
        XCTAssertFalse(session.overlay.hasSceneEdits, "adding the effect and its mask is one undo step")
        session.redo()
        XCTAssertEqual(session.overlay, edited)
        XCTAssertEqual(session.effectTexture(1, effect: key, of: 10), path)

        let copy = try LocalWallpaperWriter().save(
            LocalWallpaperWriter.Source(directory: source, sceneFile: "scene.json", assetsDirectory: editorFiles),
            scene: try session.overlay.applied(to: sceneData), title: "Faded", into: scratch.appending(path: "library"))
        XCTAssertEqual(try Data(contentsOf: copy.appending(path: "materials/\(path).tex")), tex, "the mask is a file of the copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appending(path: "effects/opacity/effect.json").path))
        let scene = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: copy.appending(path: "scene.json"))) as? [String: Any])
        let objects = try XCTUnwrap(scene["objects"] as? [[String: Any]])
        let layer = try XCTUnwrap(objects.first { ($0["id"] as? Int) == 10 })
        let effect = try XCTUnwrap((layer["effects"] as? [[String: Any]])?.last)
        XCTAssertEqual(effect["file"] as? String, "effects/opacity/effect.json")
        let pass = try XCTUnwrap((effect["passes"] as? [[String: Any]])?.first)
        let textures = try XCTUnwrap(pass["textures"] as? [Any])
        XCTAssertTrue(textures.first is NSNull)
        XCTAssertEqual(textures[1] as? String, path, "named in the pass's textures at the mask's slot, as WE does")
        XCTAssertEqual((pass["combos"] as? [String: Any])?["MASK"] as? Int, 1)

        let faded = try render(copy)
        let plain = try render(control)
        // The checkerboard layer: 1024 × 0.85 around (480, 540), x 45…915, y 105…975; above it, the clear colour.
        let left = CGRect(x: 100, y: 300, width: 280, height: 480)
        let right = CGRect(x: 580, y: 300, width: 280, height: 480)
        let clear = Self.mean(faded, in: CGRect(x: 100, y: 20, width: 760, height: 60))
        XCTAssertLessThan(Self.difference(faded, plain, in: left), 1, "the layer shows where the mask is white")
        XCTAssertGreaterThan(Self.difference(faded, plain, in: right), 10, "and not where it is black")
        let rightMean = Self.mean(faded, in: right)
        for channel in 0..<3 {
            XCTAssertEqual(rightMean[channel], clear[channel], accuracy: 1.5, "the clear colour through the transparent half")
        }
    }

    private func render(_ directory: URL) throws -> WEReferenceImage {
        let project = try decodeTolerant(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        var settings = SceneRenderSettings()
        settings.postProcessing = .enabled
        settings.textureReduction = 1
        settings.sceneDetail = .full
        settings.renderResolution = .yourDisplay
        let renderer = WEReferenceRenderer(directory: directory, project: project, settings: settings,
                                           storage: scratch.appending(path: "storage-\(UUID().uuidString)"))
        defer { Fixtures.removeStoredSettings(for: directory) }
        return try XCTUnwrap(try renderer.render([WEReferenceRenderer.Shot(time: 2, cursor: WEEffectGallery.cursor)]).first)
    }

    /// The mean RGB inside `rect` (pixels of a 1920 × 1080 frame, from the top-left).
    private static func mean(_ image: WEReferenceImage, in rect: CGRect) -> [Double] {
        let scaleX = Double(image.width) / 1920, scaleY = Double(image.height) / 1080
        var sums = [0, 0, 0], count = 0
        for y in Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY) {
            for x in Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX) {
                let o = (y * image.width + x) * 4
                for c in 0..<3 { sums[c] += Int(image.pixels[o + c]) }
                count += 1
            }
        }
        return sums.map { Double($0) / Double(max(count, 1)) }
    }

    /// The mean absolute RGB difference inside `rect` (pixels of a 1920 × 1080 frame, from the top-left).
    private static func difference(_ a: WEReferenceImage, _ b: WEReferenceImage, in rect: CGRect) -> Double {
        let scaleX = Double(a.width) / 1920, scaleY = Double(a.height) / 1080
        var sum = 0, count = 0
        for y in Int(rect.minY * scaleY)..<Int(rect.maxY * scaleY) {
            for x in Int(rect.minX * scaleX)..<Int(rect.maxX * scaleX) {
                let o = (y * a.width + x) * 4
                for c in 0..<3 { sum += abs(Int(a.pixels[o + c]) - Int(b.pixels[o + c])) }
                count += 3
            }
        }
        return Double(sum) / Double(max(count, 1))
    }
}
