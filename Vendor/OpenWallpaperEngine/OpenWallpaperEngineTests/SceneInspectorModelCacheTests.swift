import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export reads each effect file's shaders once per open, and parses each layer's
/// JSON once per text.
final class SceneInspectorModelCacheTests: XCTestCase {
    func testEffectShadersAreReadOncePerEffectFile() throws {
        let root = ShaderVariantTests.weAssets
        var reads = 0
        let shaders = SceneInspectorEffectShaders { path in
            reads += 1
            return FileManager.default.contents(atPath: root.appending(path: path).path)
        }
        let first = shaders.parameters(for: "effects/shake/effect.json")
        let readsOnce = reads
        XCTAssertGreaterThan(readsOnce, 0)
        let again = shaders.parameters(for: "effects/shake/effect.json")
        XCTAssertEqual(reads, readsOnce, "a second layer with the same effect reads nothing")
        XCTAssertEqual(again.map(\.materialKey), first.map(\.materialKey))
        let uncached = SceneEffectParameters.parameters(for: "effects/shake/effect.json") {
            FileManager.default.contents(atPath: root.appending(path: $0).path)
        }
        XCTAssertEqual(first.map(\.materialKey), uncached.map(\.materialKey))
        XCTAssertEqual(shaders.combos(for: "effects/shake/effect.json").map(\.combo),
                       SceneEffectParameters.combos(for: "effects/shake/effect.json") {
                           FileManager.default.contents(atPath: root.appending(path: $0).path)
                       }.map(\.combo))
    }

    func testLayerFieldsFollowAnEditedJSONText() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-inspector-\(UUID().uuidString)",
                                                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // scratch cleanup
        let project = #"{"file": "scene.json", "title": "Cache", "type": "scene"}"#
        try Data(project.utf8).write(to: directory.appending(path: "project.json"))
        let scene = #"{"camera": {}, "general": {}, "objects": [{"id": 7, "name": "A", "origin": "1 2 3", "alpha": 0.5, "colorBlendMode": 3}]}"#
        try Data(scene.utf8).write(to: directory.appending(path: "scene.json"))
        let wallpaper = WEWallpaper(using: try WEProject.read(in: directory), where: directory)

        let model = SceneInspectorModel(wallpaper: wallpaper, scopes: [.isolated("cache-\(UUID().uuidString)")])
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(model.origin(for: item), SIMD3<Double>(1, 2, 3))
        XCTAssertEqual(model.alpha(for: item), 0.5)
        XCTAssertEqual(model.blendMode(for: item), 3)

        // The JSON editor's text binding writes `rawObject` directly.
        model.items[0].rawObject = #"{"id": 7, "origin": "4 5 6", "alpha": 0.25}"#
        let edited = model.items[0]
        XCTAssertEqual(model.origin(for: edited), SIMD3<Double>(4, 5, 6))
        XCTAssertEqual(model.alpha(for: edited), 0.25)
        XCTAssertEqual(model.blendMode(for: edited), 0)
        XCTAssertEqual(model.alpha(for: item), 0.5, "the text an item carries is the one read")

        model.items[0].rawObject = "not json"
        XCTAssertEqual(model.origin(for: model.items[0]), SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(model.alpha(for: model.items[0]), 1, "not an object: WE's default")
    }
}
