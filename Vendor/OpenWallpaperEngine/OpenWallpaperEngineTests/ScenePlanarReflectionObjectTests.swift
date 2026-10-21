import XCTest
import Metal
import simd
import UniformTypeIdentifiers
@testable import OpenWallpaperEngine

/// The planar reflection's list beyond models (docs/models-plan.md §2.11): WE's factory puts
/// images, texts, particle systems and sprites in it too (0x14018ff60, `reflected` at 0x1401908f9),
/// and the pass draws each through its own draw with the mirrored camera. Written wallpapers with a
/// reflective model, drawn by the real loader and renderer (`ModelSceneHarness`).
final class ScenePlanarReflectionObjectTests: XCTestCase {
    private var scratch: URL!
    private var storage: URL!

    private static let size = SIMD2(320, 240)

    override func setUpWithError() throws {
        let id = UUID().uuidString
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-reflection-objects-\(id)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-reflection-objects-storage-\(id)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, storage].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Support

    /// The halo without back-face culling: the scene pass draws a perspective scene's sprites with
    /// the 2D path's winding, which culls them from the front (reported; not this test's subject).
    private static let dot = #"{"passes":[{"blending":"additive","shader":"genericparticle","cullmode":"nocull","#
        + #""textures":["particle/halo"]}]}"#
    /// Particles that stay put: born within 0.25 of the emitter, living long, not moving.
    private static let cloud = """
        {"emitter":[{"name":"sphererandom","rate":400,"distancemax":0.25}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},{"name":"sizerandom","min":0.3,"max":0.3}],
         "material":"materials/dot.json","maxcount":200}
        """

    /// A reflective floor (a flat box with `generic2` `REFLECTION`) at y = `floorY`.
    private static func floor(y: String) -> String {
        #"{"id":1,"name":"floor","model":"models/floor.mdl","origin":"0 \#(y) 0","scale":"4 0.1 4"}"#
    }

    private func files() -> [String: Data] {
        var floor = FixtureMDL.cubeModel(material: "materials/reflective.json")
        floor.meshes[0].materials = ["materials/reflective.json"]
        return ["models/floor.mdl": floor.data, "materials/dot.json": Data(Self.dot.utf8),
                "particles/cloud.json": Data(Self.cloud.utf8)]
    }

    private func harness(_ name: String, objects: [String], general: String = #""clearcolor":"0 0 0""#) throws -> ModelSceneHarness {
        let wallpaper = try ModelFixtureWallpaper(in: scratch, name: name, objects: objects, general: general, files: files())
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                            storage: storage)
        try harness.settle(seconds: 20)
        harness.frame(step: 0)
        XCTAssertEqual(harness.gpuErrors, [])
        return harness
    }

    private struct Image {
        let width: Int
        let height: Int
        /// RGBA, row 0 at the top.
        let bytes: [UInt8]

        init(_ texture: MTLTexture, device: MTLDevice) throws {
            width = texture.width
            height = texture.height
            bytes = try TextureUploadTests.read(texture, device: device)
        }

        /// A picture for review, when `OWE_REFLECTION_OUT` names a folder.
        func write(_ name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["OWE_REFLECTION_OUT"], !folder.isEmpty else { return }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = URL(fileURLWithPath: folder).appending(path: name + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }

        func rgb(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let i = (y * width + x) * 4
            return SIMD3(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }

        /// The centre of the pixels in `columns` × `rows` (fractions of the size) that `matches`,
        /// and how many there are.
        func centroid(columns: ClosedRange<Float>, rows: ClosedRange<Float>,
                      where matches: (SIMD3<Int>) -> Bool) -> (center: SIMD2<Float>, count: Int) {
            var sum = SIMD2<Float>.zero, count = 0
            let x0 = Int(columns.lowerBound * Float(width)), x1 = min(width - 1, Int(columns.upperBound * Float(width)))
            let y0 = Int(rows.lowerBound * Float(height)), y1 = min(height - 1, Int(rows.upperBound * Float(height)))
            for y in y0...y1 {
                for x in x0...x1 where matches(rgb(x, y)) {
                    sum += SIMD2(Float(x), Float(y))
                    count += 1
                }
            }
            return (count > 0 ? sum / Float(count) : SIMD2(-1, -1), count)
        }
    }

    private static func lit(_ c: SIMD3<Int>) -> Bool { max(c.x, c.y, c.z) > 60 }
    private static func red(_ c: SIMD3<Int>) -> Bool { c.x > 150 && c.y < 60 && c.z < 60 }
    private static func yellow(_ c: SIMD3<Int>) -> Bool { c.x > 150 && c.y > 150 && c.z < 60 }

    // MARK: - Perspective

    /// An image, a text and a particle system above a reflective floor, looked at level from
    /// z = 6: the mirror across y = 0 projects each where its own picture is flipped upside down
    /// (row y ↦ height − 1 − y, the same columns), so each object's pixels in `_rt_Reflection`
    /// have the centre of its pixels in the scene target flipped. An image with `reflected: false`
    /// draws in the scene and not in the reflection.
    func testImagesTextsAndParticlesAreMirroredAcrossYZero() throws {
        _ = try Fixtures.assets()
        let harness = try harness("perspective", objects: [
            Self.floor(y: "-2"),
            #"{"id":2,"name":"red","image":"models/util/solidlayer.json","origin":"-2 1.2 0","size":"0.8 0.8","color":"1 0 0"}"#,
            #"{"id":3,"name":"label","text":{"value":"HH"},"origin":"0 1.2 0","scale":"0.01 0.01 0.01","size":"160 80","#
                + #""pointsize":48}"#,
            #"{"id":4,"name":"cloud","particle":"particles/cloud.json","origin":"2 1.2 0"}"#,
            #"{"id":5,"name":"unreflected","image":"models/util/solidlayer.json","origin":"0 2.2 0","size":"0.8 0.4","#
                + #""color":"1 1 0","reflected":false}"#,
        ])
        defer { harness.close() }
        let reflection = try XCTUnwrap(harness.renderer.planarReflection)
        XCTAssertEqual(reflection.drawnObjects, ["2", "3", "4"], "the image, the text and the particles, in scene order")
        XCTAssertEqual(reflection.drawnModels, [], "the floor is reflective")
        let scene = try Image(try XCTUnwrap(harness.renderer.lastSceneTarget), device: harness.device)
        let mirror = try Image(try XCTUnwrap(reflection.texture), device: harness.device)
        try scene.write("perspective-scene")
        try mirror.write("perspective-reflection")
        XCTAssertEqual(SIMD2(mirror.width, mirror.height), SIMD2(scene.width, scene.height))
        let height = Float(scene.height)

        // Each object's band of columns: the upper half of the scene, the lower half of the mirror.
        let bands: [(name: String, columns: ClosedRange<Float>, matches: (SIMD3<Int>) -> Bool)] = [
            ("image", 0.05...0.35, Self.red), ("text", 0.38...0.62, Self.lit), ("particles", 0.65...0.95, Self.lit),
        ]
        for band in bands {
            let seen = scene.centroid(columns: band.columns, rows: 0.2...0.5, where: band.matches)
            let mirrored = mirror.centroid(columns: band.columns, rows: 0.5...0.8, where: band.matches)
            XCTAssertGreaterThan(seen.count, 20, "\(band.name) draws in the scene")
            XCTAssertGreaterThan(mirrored.count, 20, "\(band.name) draws in the reflection")
            XCTAssertEqual(Float(mirrored.count), Float(seen.count), accuracy: Float(seen.count) * 0.1 + 4,
                           "\(band.name): as many pixels mirrored")
            XCTAssertEqual(mirrored.center.x, seen.center.x, accuracy: 1.5, "\(band.name): the same columns")
            XCTAssertEqual(mirrored.center.y, height - 1 - seen.center.y, accuracy: 1.5, "\(band.name): flipped rows")
            XCTAssertEqual(mirror.centroid(columns: band.columns, rows: 0...0.5, where: Self.lit).count, 0,
                           "\(band.name): nothing where the object itself is")
        }
        XCTAssertGreaterThan(scene.centroid(columns: 0.38...0.62, rows: 0...0.2, where: Self.yellow).count, 20,
                             "the unreflected image draws in the scene")
        XCTAssertEqual(mirror.centroid(columns: 0...1, rows: 0...1, where: Self.yellow).count, 0,
                       "and not in the reflection")
    }

    /// With the reflection setting off the pass only clears: nothing is drawn.
    func testTheSettingOffDrawsNoObjects() throws {
        _ = try Fixtures.assets()
        let harness = try harness("off", objects: [
            Self.floor(y: "-2"),
            #"{"id":2,"name":"red","image":"models/util/solidlayer.json","origin":"-2 1.2 0","size":"0.8 0.8","color":"1 0 0"}"#,
        ])
        defer { harness.close() }
        XCTAssertEqual(harness.renderer.planarReflection?.drawnObjects, ["2"])
        harness.renderer.renderSettings.reflection = false
        harness.frame(step: 0)
        XCTAssertEqual(harness.renderer.planarReflection?.drawnObjects, [])
    }

    // MARK: - Orthographic

    /// An orthographic scene with a reflective model: WE's mirrored view is the orthographic
    /// one times diag(1, −1, 1, 1), so a layer below the scene's bottom edge (y < 0, off the
    /// screen) lands inside the reflection, as far above the bottom edge as it lies below it; one
    /// inside the scene lands below it, off the target.
    func testAnOrthographicLayerBelowTheSceneLandsAboveItsBottomEdge() throws {
        _ = try Fixtures.assets()
        let harness = try harness("orthographic", objects: [
            Self.floor(y: "-500"),
            #"{"id":2,"name":"below","image":"models/util/solidlayer.json","origin":"100 -40 0","size":"40 20","color":"1 0 0"}"#,
            #"{"id":3,"name":"inside","image":"models/util/solidlayer.json","origin":"220 120 0","size":"40 40","#
                + #""color":"1 1 0"}"#,
        ], general: #""clearcolor":"0 0 0","orthogonalprojection":{"width":320,"height":240}"#)
        defer { harness.close() }
        let reflection = try XCTUnwrap(harness.renderer.planarReflection)
        XCTAssertEqual(reflection.drawnObjects, ["2", "3"])
        let mirror = try Image(try XCTUnwrap(reflection.texture), device: harness.device)
        let scene = try Image(try XCTUnwrap(harness.renderer.lastSceneTarget), device: harness.device)
        try scene.write("orthographic-scene")
        try mirror.write("orthographic-reflection")
        let pixelsPerUnit = Float(mirror.height) / 240
        let below = mirror.centroid(columns: 0...1, rows: 0...1, where: Self.red)
        // Mirrored to y = 40 above the bottom edge: row height − 40 · pixels per unit.
        XCTAssertGreaterThan(below.count, 100)
        XCTAssertEqual(below.center.x, 100 * pixelsPerUnit - 0.5, accuracy: 1)
        XCTAssertEqual(below.center.y, Float(mirror.height) - 40 * pixelsPerUnit - 0.5, accuracy: 1)
        XCTAssertEqual(scene.centroid(columns: 0...1, rows: 0...1, where: Self.red).count, 0, "off the scene itself")
        XCTAssertEqual(mirror.centroid(columns: 0...1, rows: 0...1, where: Self.yellow).count, 0, "mirrored off the target")
        XCTAssertGreaterThan(scene.centroid(columns: 0...1, rows: 0...1, where: Self.yellow).count, 100)
    }
}
