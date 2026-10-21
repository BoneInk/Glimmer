import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// A model pass whose shader declares `INSTANCECOUNT` (WE's `fur4`, "Fur quality" 5, 9, 13 or 21)
/// draws that many instances of each mesh in one draw, `gl_InstanceID` 0 to `INSTANCECOUNT − 1`,
/// as `fur4.vert` reads them: every fur shell, not the base mesh alone.
final class ModelInstancedShellTests: XCTestCase {
    private var scratch: URL!
    private var storage: URL!

    override func setUpWithError() throws {
        let id = UUID().uuidString
        scratch = FileManager.default.temporaryDirectory.appending(path: "owe-model-shells-\(id)")
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-model-shells-storage-\(id)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in [scratch, storage].compactMap({ $0 }) where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static let size = SIMD2(320, 180)

    private func draw(material: String) throws -> ModelSceneHarness {
        let model = FixtureMDL.cubeModel(material: material)
        let wallpaper = try ModelFixtureWallpaper(
            in: scratch, name: (material as NSString).lastPathComponent,
            objects: [#"{"id":1,"name":"cube","model":"models/cube.mdl","origin":"0 0 0"}"#],
            files: ["models/cube.mdl": model.data])
        let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                            storage: storage)
        try harness.settle(seconds: 10)
        _ = harness.run(frames: 4)
        XCTAssertEqual(harness.gpuErrors, [])
        return harness
    }

    /// Lit pixels of the last frame in columns `columns` (fractions of the width).
    private func lit(_ harness: ModelSceneHarness, columns: ClosedRange<Float>) throws -> Int {
        let bytes = try TextureUploadTests.read(try XCTUnwrap(harness.renderer.sharedFrame), device: harness.device)
        let width = harness.renderer.sharedFrame?.width ?? Self.size.x
        let height = bytes.count / 4 / max(width, 1)
        let low = Int(columns.lowerBound * Float(width)), high = min(width, Int(columns.upperBound * Float(width)))
        var count = 0
        for y in 0..<height {
            for x in low..<high {
                let i = (y * width + x) * 4
                if max(bytes[i], bytes[i + 1], bytes[i + 2]) > 24 { count += 1 }
            }
        }
        return count
    }

    /// `INSTANCECOUNT` 3 (the material's combo): three instances, at x −3, 0 and 3.
    func testAnInstanceCountComboDrawsEveryInstance() throws {
        let harness = try draw(material: "materials/shells.json")
        defer { harness.close() }
        let mesh = try XCTUnwrap(harness.content.spatial.models.first?.plan?.meshes.first)
        XCTAssertEqual(mesh.material.instanceCount, 3)
        let models = try XCTUnwrap(harness.models)
        XCTAssertEqual(models.instancesEncoded, models.drawsEncoded * 3)
        XCTAssertGreaterThan(try lit(harness, columns: 0...0.4), 100, "instance 0 (x −3) draws")
        XCTAssertGreaterThan(try lit(harness, columns: 0.45...0.55), 100, "instance 1 (x 0) draws")
        XCTAssertGreaterThan(try lit(harness, columns: 0.6...1), 100, "instance 2 (x 3) draws")
    }

    /// Without the combo in the material, the shader's default (5, "low").
    func testTheComboDefaultIsTheInstanceCount() throws {
        let harness = try draw(material: "materials/shells_default.json")
        defer { harness.close() }
        XCTAssertEqual(harness.content.spatial.models.first?.plan?.meshes.first?.material.instanceCount, 5)
    }

    /// A shader without the combo draws one instance.
    func testAShaderWithoutTheComboDrawsOnce() throws {
        let harness = try draw(material: "materials/facecolor.json")
        defer { harness.close() }
        XCTAssertEqual(harness.content.spatial.models.first?.plan?.meshes.first?.material.instanceCount, 1)
        let models = try XCTUnwrap(harness.models)
        XCTAssertEqual(models.instancesEncoded, models.drawsEncoded)
    }

    /// WE's `fur4` with "Fur quality" high (13): every shell drawn, the outer ones pushed out
    /// along the normals past the bare mesh's silhouette (`g_FurDistance` from the albedo's alpha,
    /// `util/white`'s 1).
    func testFur4DrawsEveryShell() throws {
        _ = try Fixtures.assets()
        let materials = [
            "materials/fur.json": #"{"passes":[{"shader":"fur4","combos":{"INSTANCECOUNT":13,"LIGHTING":0,"FOG":0},"constantshadervalues":{"furdistance":1},"textures":["util/white"]}]}"#,
            "materials/bare.json": #"{"passes":[{"shader":"generic4","combos":{"LIGHTING":0,"FOG":0},"textures":["util/white"]}]}"#,
        ]
        var counts: [String: Int] = [:]
        for name in ["fur", "bare"] {
            let model = FixtureMDL.cubeModel(material: "materials/\(name).json")
            let wallpaper = try ModelFixtureWallpaper(
                in: scratch, name: name,
                objects: [#"{"id":1,"name":"cube","model":"models/cube.mdl","origin":"0 0 0","scale":"0.5 0.5 0.5"}"#],
                files: ["models/cube.mdl": model.data].merging(materials.mapValues { Data($0.utf8) }) { $1 })
            let harness = try ModelSceneHarness(directory: wallpaper.directory, settings: SceneRenderSettings(), size: Self.size,
                                                storage: storage)
            defer { harness.close() }
            try harness.settle(seconds: 10)
            _ = harness.run(frames: 4)
            XCTAssertEqual(harness.gpuErrors, [], name)
            let models = try XCTUnwrap(harness.models)
            XCTAssertGreaterThan(models.drawsEncoded, 0, "\(name) draws")
            if name == "fur" {
                XCTAssertEqual(harness.content.spatial.models.first?.plan?.meshes.first?.material.instanceCount, 13)
                XCTAssertEqual(models.instancesEncoded, models.drawsEncoded * 13)
            }
            counts[name] = try lit(harness, columns: 0...1)
        }
        XCTAssertGreaterThan(counts["fur"] ?? 0, (counts["bare"] ?? 0) + 100, "the shells reach past the bare cube: \(counts)")
    }
}
