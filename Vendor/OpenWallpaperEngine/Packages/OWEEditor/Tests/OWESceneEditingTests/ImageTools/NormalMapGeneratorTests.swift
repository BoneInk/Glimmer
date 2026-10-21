import CoreGraphics
import XCTest
@testable import OWESceneEditing

/// WE's Normal Map Generation: its defaults, the normal of a gradient, the encoding, a cut-out's
/// rounded shape, and the result applied to a layer as WE's material panel imports it.
final class NormalMapGeneratorTests: XCTestCase {
    func testDefaultsAreWEs() {
        // normalConfig in WE's editor UI (`EditorCharacterSeparationModalCtrl`).
        let settings = NormalMapGenerator.Settings()
        XCTAssertEqual(settings.filter, 13)
        XCTAssertEqual(settings.blur, 63)
        XCTAssertEqual(settings.depth, 1)
        XCTAssertEqual(settings.threshold, 1)
        XCTAssertEqual(settings.detailsBlur, 21)
        XCTAssertEqual(settings.detailsDepth, 1)
        XCTAssertFalse(settings.detailsInvert)
        XCTAssertEqual(settings.exponent, 4)
    }

    func testSettingsClampToWEsSliders() {
        var settings = NormalMapGenerator.Settings()
        settings.blur = 64
        settings.detailsBlur = 0
        settings.exponent = 12
        settings.depth = -1
        let clamped = settings.clamped
        XCTAssertEqual(clamped.blur, 63)
        XCTAssertEqual(clamped.detailsBlur, 1)
        XCTAssertEqual(clamped.exponent, 8)
        XCTAssertEqual(clamped.depth, 0)
    }

    func testAFlatGradientFacesTheViewer() {
        let normal = NormalMapGenerator.normal(gx: 0, gy: 0, depth: 1, invert: false)
        XCTAssertEqual(normal, SIMD3<Float>(0, 0, 1))
        XCTAssertTrue(NormalMapGenerator.encode(normal) == (127, 127, 255))
    }

    func testARisingSlopeLeansAgainstIt() {
        // Rising to the right: the normal leans left; rising downwards (rows run down): up (+y).
        let right = NormalMapGenerator.normal(gx: 0.5, gy: 0, depth: 1, invert: false)
        XCTAssertLessThan(right.x, 0)
        XCTAssertEqual(right.y, 0, accuracy: 1e-6)
        let down = NormalMapGenerator.normal(gx: 0, gy: 0.5, depth: 1, invert: false)
        XCTAssertGreaterThan(down.y, 0)
        let inverted = NormalMapGenerator.normal(gx: 0.5, gy: 0, depth: 1, invert: true)
        XCTAssertGreaterThan(inverted.x, 0)
        // Depth 0 flattens it.
        XCTAssertEqual(NormalMapGenerator.normal(gx: 1, gy: 1, depth: 0, invert: false), SIMD3<Float>(0, 0, 1))
    }

    func testEncodingRoundsTowardsTheMiddle() {
        let encoded = NormalMapGenerator.encode(SIMD3<Float>(1, -1, 0))
        // (±0.707 × 0.5 + 0.5) × 255: 217.66 down to 217, 37.34 up to 38; z 127.5 down to 127.
        XCTAssertEqual(encoded.0, 217)
        XCTAssertEqual(encoded.1, 38)
        XCTAssertEqual(encoded.2, 127)
    }

    func testReorientingOntoStraightUpKeepsTheDetail() {
        let detail = SIMD3<Float>(0.3, -0.2, 0.932737905)
        let result = NormalMapGenerator.reoriented(detail, onto: SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(result.x, detail.x, accuracy: 1e-5)
        XCTAssertEqual(result.y, detail.y, accuracy: 1e-5)
        XCTAssertEqual(result.z, detail.z, accuracy: 1e-5)
        // A flat detail takes the shape's normal.
        let base = SIMD3<Float>(0.6, 0, 0.8)
        let flat = NormalMapGenerator.reoriented(SIMD3<Float>(0, 0, 1), onto: base)
        XCTAssertEqual(flat.x, base.x, accuracy: 1e-5)
        XCTAssertEqual(flat.z, base.z, accuracy: 1e-5)
    }

    /// An opaque disc on a transparent square: a dome, lit from every side.
    private func disc(size: Int = 96) -> RGBAImage {
        var image = RGBAImage(width: size, height: size)
        let centre = Float(size) / 2, radius = Float(size) * 0.35
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - centre, dy = Float(y) + 0.5 - centre
                let index = (y * size + x) * 4
                image.pixels[index] = 200
                image.pixels[index + 1] = 120
                image.pixels[index + 2] = 60
                image.pixels[index + 3] = dx * dx + dy * dy <= radius * radius ? 255 : 0
            }
        }
        return image
    }

    func testACutOutGetsARoundedShape() {
        let image = disc()
        let normals = NormalMapGenerator.generate(image, settings: NormalMapGenerator.Settings())
        XCTAssertEqual(normals.width, 96)
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let index = (y * 96 + x) * 4
            return (normals.pixels[index], normals.pixels[index + 1], normals.pixels[index + 2], normals.pixels[index + 3])
        }
        let left = pixel(20, 48), right = pixel(76, 48), top = pixel(48, 20), bottom = pixel(48, 76), centre = pixel(48, 48)
        XCTAssertLessThan(left.0, 120, "the left edge faces left")
        XCTAssertGreaterThan(right.0, 135, "the right edge faces right")
        XCTAssertGreaterThan(top.1, 135, "the top edge faces up")
        XCTAssertLessThan(bottom.1, 120, "the bottom edge faces down")
        XCTAssertGreaterThan(centre.2, 240, "the middle faces the viewer")
        // The picture's alpha is kept.
        XCTAssertEqual(left.3, 255)
        XCTAssertEqual(pixel(0, 0).3, 0)
    }

    func testAnOpaquePictureHasOnlyDetails() {
        var image = RGBAImage(width: 64, height: 32)
        for y in 0..<32 {
            for x in 0..<64 {
                let index = (y * 64 + x) * 4
                let value = UInt8(x * 4)
                image.pixels[index] = value
                image.pixels[index + 1] = value
                image.pixels[index + 2] = value
                image.pixels[index + 3] = 255
            }
        }
        var settings = NormalMapGenerator.Settings()
        settings.detailsBlur = 1
        let normals = NormalMapGenerator.generate(image, settings: settings)
        let index = (16 * 64 + 32) * 4
        // Brighter to the right: the surface rises, its normal leans left; nothing up or down.
        XCTAssertLessThan(normals.pixels[index], 127)
        XCTAssertEqual(Int(normals.pixels[index + 1]), 127, accuracy: 1)
        settings.detailsInvert = true
        let inverted = NormalMapGenerator.generate(image, settings: settings)
        XCTAssertGreaterThan(inverted.pixels[index], 128)
    }

    // MARK: Applying

    private final class Encoder: EditorTextureEncoding, @unchecked Sendable {
        var normalMaps: [CGSize] = []
        func texture(_ image: CGImage, options: TextureImportOptions) throws -> Data { Data() }
        func normalMap(_ image: CGImage) throws -> Data {
            normalMaps.append(CGSize(width: image.width, height: image.height))
            return Data("rg88n \(image.width)x\(image.height)".utf8)
        }
        func spriteSheet(_ frames: [TextureImportFrame], options: TextureImportOptions) throws -> (data: Data, size: SIMD2<Double>) {
            (Data(), .zero)
        }
        func video(_ url: URL) throws -> (data: Data, size: SIMD2<Double>) { (Data(), .zero) }
    }

    private let files: [String: Data] = [
        "models/bg.json": Data(#"{"autosize": true, "material": "materials/bg.json", "puppet": "models/bg_puppet.mdl"}"#.utf8),
        "materials/bg.json": Data(#"""
        {"passes": [{"blending": "translucent", "shader": "genericimage2", "textures": ["bg"],
                     "combos": {"VERSION": 2}, "constantshadervalues": {"metallic": 0.4}}]}
        """#.utf8),
    ]

    @MainActor
    func testApplyingWritesTheNormalMapAndACopyOfTheMaterial() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let encoder = Encoder()
        let store = EditorAssetStore(directory: directory, encoder: encoder)
        let undoManager = UndoManager()
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        let readFile: (String) -> Data? = { path in self.files[path] ?? store.url(for: path).flatMap { try? Data(contentsOf: $0) } }
        let normal = try XCTUnwrap(RGBAImage(width: 4, height: 2).cgImage)

        let texture = try session.applyNormalMap(normal, to: 10, store: store, readFile: readFile, actionName: "Generate Normal Map")

        XCTAssertTrue(texture.hasPrefix("editor/bg-"))
        XCTAssertTrue(texture.hasSuffix("_normal"), "WE names it <texture>_normal")
        XCTAssertNotNil(store.url(for: "materials/\(texture).tex"))
        XCTAssertEqual(encoder.normalMaps, [CGSize(width: 4, height: 2)])
        let overlay = session.overlay
        let model = try XCTUnwrap(overlay.field("image", of: 10)?.stringValue)
        XCTAssertTrue(model.hasPrefix("models/editor/bg-"))
        let applied = try XCTUnwrap(ImageLayerMaterial(modelPath: model, readFile: readFile))
        XCTAssertEqual(applied.texture, "bg")
        XCTAssertEqual(applied.normalMap, texture)
        XCTAssertEqual(applied.combos, ["VERSION": 2, "LIGHTING": 1], "the normal map draws only with lighting or reflection")
        XCTAssertEqual(applied.model["puppet"] as? String, "models/bg_puppet.mdl", "the rest of the model is kept")
        let pass = try XCTUnwrap((applied.material["passes"] as? [[String: Any]])?.first)
        XCTAssertEqual((pass["constantshadervalues"] as? [String: Any])?["metallic"] as? Double, 0.4)

        // Remove Normal Map, then two undos give the wallpaper's own model back.
        try session.removeNormalMap(of: 10, store: store, readFile: readFile, actionName: "Remove Normal Map")
        let removedModel = try XCTUnwrap(session.overlay.field("image", of: 10)?.stringValue)
        let removed = try XCTUnwrap(ImageLayerMaterial(modelPath: removedModel, readFile: readFile))
        XCTAssertNil(removed.normalMap)
        XCTAssertEqual(removed.textures.count, 1)
        session.undo()
        session.undo()
        let undone = session.overlay
        XCTAssertNil(undone.field("image", of: 10))
    }

    func testReflectionAloneIsKept() throws {
        let material = try XCTUnwrap(ImageLayerMaterial(modelPath: "m.json", readFile: { path in
            path == "m.json" ? Data(#"{"material": "x.json"}"#.utf8)
                : Data(#"{"passes": [{"textures": ["a"], "combos": {"REFLECTION": 1}}]}"#.utf8)
        }))
        let changed = material.materialWithNormalMap("a_normal")
        let pass = try XCTUnwrap((changed["passes"] as? [[String: Any]])?.first)
        XCTAssertEqual(pass["combos"] as? [String: Int], ["REFLECTION": 1])
        XCTAssertEqual(pass["textures"] as? [String], ["a", "a_normal"])
    }

    @MainActor
    func testOnlyPicturesHaveAMaterial() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData))
        let text = try XCTUnwrap(session.outline.layer(11))
        XCTAssertNil(ImageLayerMaterial(layer: text, readFile: { _ in nil }))
    }
}
