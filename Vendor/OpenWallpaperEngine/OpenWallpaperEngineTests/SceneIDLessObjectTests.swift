import XCTest
@testable import OpenWallpaperEngine

/// Objects without an `id` are known by their index in `objects`, everywhere: parent links, text
/// property keys, visibility and the spatial content (roadmap notes item 23).
@MainActor
final class SceneIDLessObjectTests: XCTestCase {
    private let json = #"""
    {"camera": {}, "general": {}, "objects": [
      {"name": "parent", "origin": "0 0 5"},
      {"name": "child", "parent": 0},
      {"name": "clock", "text": {"value": "12:00"}, "font": "a.ttf", "pointsize": 20},
      {"name": "date", "text": {"value": "Mon"}, "font": "b.ttf", "pointsize": 30}
    ]}
    """#

    private func scene() throws -> WEScene {
        try decodeTolerant(WEScene.self, from: Data(json.utf8))
    }

    func testIdentityIsTheIndex() throws {
        let objects = try scene().objects
        XCTAssertEqual(objects.enumerated().map { SceneObjectIdentity.id(of: $1, at: $0) }, [0, 1, 2, 3])
        XCTAssertEqual(SceneObjectIdentity.assigningFallbackIDs(objects).map(\.id), [0, 1, 2, 3])
    }

    func testParentLinkResolvesWithoutIDs() throws {
        let content = SceneSpatialContentBuilder(readFile: { _ in nil }, wallpaperName: "test")
            .build(try scene(), context: SpatialProperties())
        XCTAssertEqual(SceneWorldMatrix.translation(content.transforms.world(of: "1")), SIMD3(0, 0, 5),
                       "the child inherits its id-less parent's origin")
    }

    func testTextKeysAreDistinct() throws {
        let values = SceneContentLoader.userPropertyValues(stored: [:], declared: [:], scene: try scene())
        XCTAssertEqual(values["_owe_text_2_font"], "a.ttf")
        XCTAssertEqual(values["_owe_text_3_font"], "b.ttf")
        XCTAssertEqual(values["_owe_text_2_size"], "20.0")
        XCTAssertEqual(values["_owe_text_3_size"], "30.0")
        XCTAssertNil(values["_owe_text_-1_font"])
    }

    func testVisibilityKeysEachObject() throws {
        let visibility = SceneUserVisibility(objects: try scene().objects)
        let values = ["_owe_text_3_enabled": "false"]
        let resolved = visibility.resolve { values[$0] }
        XCTAssertEqual(resolved.objects, ["0": true, "1": true, "2": true, "3": false])
    }

    /// Two id-less layers built through the loader each keep their own id (their index), not a
    /// shared -1: two solid layers, each with its own colour.
    func testTwoIDLessLayersKeepTheirOwnIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-idless-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appending(path: "models"), withIntermediateDirectories: true)
        defer {
            Fixtures.removeStoredSettings(for: directory)
            try? FileManager.default.removeItem(at: directory) // Optional: a temporary folder.
        }
        let files = [
            "models/solid.json": #"{"solidlayer":true,"material":"materials/util/solidlayer.json"}"#,
            "materials/util/solidlayer.json": #"{"passes":[{"shader":"flat","textures":[null]}]}"#,
            "scene.json": #"""
            {"camera":{"center":"0 0 -1","eye":"0 0 0","up":"0 1 0"},"version":1,
             "general":{"clearcolor":"0 0 0","orthogonalprojection":{"width":64,"height":64}},
             "objects":[
              {"name":"red","image":"models/solid.json","origin":"16 32 0","size":"8 8","color":"1 0 0"},
              {"name":"green","image":"models/solid.json","origin":"48 32 0","size":"8 8","color":"0 1 0"}
             ]}
            """#,
            "project.json": #"{"file":"scene.json","title":"Fixture: id-less objects","type":"scene"}"#,
        ]
        try FileManager.default.createDirectory(at: directory.appending(path: "materials/util"), withIntermediateDirectories: true)
        for (path, text) in files { try Data(text.utf8).write(to: directory.appending(path: path)) }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        XCTAssertEqual(content.layers.map(\.id), ["0", "1"])
        XCTAssertEqual(content.layers.map(\.name), ["red", "green"])
        XCTAssertEqual(content.layers.map(\.solidFill), [SIMD4<Float>(1, 0, 0, 1), SIMD4<Float>(0, 1, 0, 1)] as [SIMD4<Float>?])
        XCTAssertEqual(content.objectIDs, [0, 1])
    }
}
