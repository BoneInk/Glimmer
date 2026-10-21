import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// A model material with several passes draws every pass, in the material's order, each with its
/// own blending and depth state, over what the passes before drew (a material's passes draw so
/// everywhere in WE: an effect's, an image's).
final class ModelMultiPassTests: XCTestCase {
    private var scratch: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-model-passes-\(id)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-model-passes-storage-\(id)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, storage].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let size = SIMD2(320, 180)

    /// Draws a cube in a material made of `passes` (pass JSON objects).
    private func draw(_ name: String, passes: [String]) throws -> ModelSceneHarness {
        let material = #"{"passes":[\#(passes.joined(separator: ","))]}"#
        let wallpaper = try ModelFixtureWallpaper(
            in: scratch, name: name, objects: [#"{"id":1,"name":"cube","model":"models/cube.mdl","origin":"0 0 0"}"#],
            files: ["models/cube.mdl": FixtureMDL.cubeModel(material: "materials/\(name).json").data,
                    "materials/\(name).json": Data(material.utf8)])
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                            storage: storage)
        try harness.settle(seconds: 10)
        _ = harness.run(frames: 4)
        XCTAssertEqual(harness.gpuErrors, [], name)
        return harness
    }

    private static func pass(tint: String, extra: String = "") -> String {
        #"{"shader":"facecolor","constantshadervalues":{"tint":"\#(tint) 1"},"textures":[]\#(extra)}"#
    }

    /// The colour at the centre of the last frame (the cube's front face).
    private func centre(_ harness: ModelSceneHarness) throws -> SIMD3<Int> {
        let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
        let width = harness.renderer.sharedFrame?.width ?? Self.size.x
        let height = bytes.count / 4 / max(width, 1)
        let i = ((height / 2) * width + width / 2) * 4
        return SIMD3(Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// Red, then green added over it (depth test off, as an equal depth fails WE's GREATER test):
    /// yellow. With the first pass alone the face stayed red.
    func testASecondAdditivePassBlendsOverTheFirst() throws {
        let harness = try draw("additive2", passes: [
            Self.pass(tint: "1 0 0"),
            Self.pass(tint: "0 1 0", extra: #","blending":"additive","depthtest":"disabled""#),
        ])
        defer { harness.close() }
        let material = try XCTUnwrap(harness.content.spatial.models.first?.plan?.meshes.first?.material)
        XCTAssertEqual(material.passes.count, 2)
        XCTAssertEqual(material.passes.map(\.blending), ["normal", "additive"])
        XCTAssertEqual(material.laterPasses.first?.raster.depthTest, false)
        XCTAssertNil(material.laterPasses.first?.shadowCaster, "the shadow variant is the first pass's")
        let colour = try centre(harness)
        XCTAssertGreaterThan(colour.x, 200, "the first pass's red: \(colour)")
        XCTAssertGreaterThan(colour.y, 200, "the second pass's green: \(colour)")
        XCTAssertLessThan(colour.z, 40, "\(colour)")
    }

    /// Three opaque passes: the last drawn wins, so the passes draw in the material's order.
    func testPassesDrawInTheMaterialsOrder() throws {
        let harness = try draw("order", passes: [
            Self.pass(tint: "1 0 0"),
            Self.pass(tint: "0 1 0", extra: #","depthtest":"disabled""#),
            Self.pass(tint: "0 0 1", extra: #","depthtest":"disabled""#),
        ])
        defer { harness.close() }
        let colour = try centre(harness)
        XCTAssertGreaterThan(colour.z, 200, "the last pass's blue: \(colour)")
        XCTAssertLessThan(colour.x, 40, "\(colour)")
        XCTAssertLessThan(colour.y, 40, "\(colour)")
    }

    /// A later pass whose shader isn't there is logged and left out; the first still draws.
    func testALaterPassThatCantBeMadeIsLeftOut() throws {
        let log = ModelLogWindow()
        let harness = try draw("broken", passes: [
            Self.pass(tint: "1 0 0"),
            #"{"shader":"no_such_shader","textures":[]}"#,
        ])
        defer { harness.close() }
        let material = try XCTUnwrap(harness.content.spatial.models.first?.plan?.meshes.first?.material)
        XCTAssertEqual(material.passes.count, 1)
        XCTAssertFalse(log.lines(containing: "pass 2 can't be made").isEmpty, "the left-out pass is logged")
        XCTAssertGreaterThan(try centre(harness).x, 200, "the first pass draws")
    }
}
