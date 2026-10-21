import XCTest
@testable import OpenWallpaperEngine

/// A user property change is applied by the class of the bindings that read it
/// (`SceneBindingUpdate`): in place for uniform and object sites, by rebuilding only the owning
/// object for structural ones, and by rebuilding the content only for scene-wide structure.
final class SceneLiveBindingSitesTests: XCTestCase {
    private func update(_ json: String, _ keys: [String]) throws -> SceneBindingUpdate {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        return SceneBindingUpdate(keys: keys, table: table)
    }

    func testPerFrameSitesApplyInPlace() throws {
        let update = try update(#"""
        {"objects": [
          {"id": 1, "image": "models/a.json",
           "origin": {"user": "x", "value": "0 0 0"},
           "scale": {"user": "s", "value": "1 1 1"},
           "angles": {"user": "r", "value": "0 0 0"},
           "color": {"user": "tint", "value": "1 1 1"},
           "alpha": {"user": "fade", "value": 1},
           "brightness": {"user": "glow", "value": 1},
           "visible": {"user": "show", "value": true},
           "effects": [{"file": "e.json", "passes": [{"constantshadervalues": {"speed": {"user": "speed", "value": 1}}}]}]},
          {"id": 2, "text": {"value": "hi"}, "color": {"user": "textcolour", "value": "1 1 1"}}
        ]}
        """#, ["x", "s", "r", "tint", "fade", "glow", "show", "speed", "textcolour"])
        XCTAssertEqual(update.impact, .none)
        XCTAssertEqual(update.rebuild, [])
        XCTAssertEqual(update.owners, [.object(1), .object(2)])
    }

    func testStructuralSitesRebuildOnlyTheirObject() throws {
        let json = #"""
        {"general": {"bloom": {"user": "bloom", "value": true}},
         "objects": [
          {"id": 1, "image": "models/a.json",
           "size": {"user": "size", "value": "10 10"},
           "effects": [{"file": "e.json", "passes": [{"combos": {"MODE": {"user": "mode", "value": 0}}}]}]},
          {"id": 2, "text": {"user": "caption", "value": "hi"}},
          {"id": 3, "light": "point", "origin": {"user": "lightpos", "value": "0 0 0"}}
        ]}
        """#
        let objects = try update(json, ["size", "mode", "caption", "lightpos"])
        XCTAssertEqual(objects.impact, .none, "no whole-content rebuild")
        XCTAssertEqual(objects.rebuild, [1, 2, 3])
        XCTAssertEqual(try update(json, ["bloom"]).impact, .rebuildContent, "general is the scene's own structure")
    }

    func testTheHeaviestClassOfAPropertyWins() throws {
        let update = try update(#"""
        {"objects": [
          {"id": 1, "image": "models/a.json", "alpha": {"user": "p", "value": 1}},
          {"id": 2, "image": "models/b.json", "size": {"user": "p", "value": "4 4"}}
        ]}
        """#, ["p"])
        XCTAssertEqual(update.owners, [.object(1), .object(2)])
        XCTAssertEqual(update.rebuild, [2])
    }

    func testAppKeysKeepTheirOwnImpact() throws {
        let json = #"{"objects": [{"id": 1, "image": "models/a.json", "alpha": {"user": "p", "value": 1}}]}"#
        XCTAssertEqual(try update(json, [sceneObjectVisibilityKey(objectID: 1)]).impact, .rebuildContent)
        XCTAssertEqual(try update(json, ["p_musicSync"]).impact, .none)
        XCTAssertTrue(try update(json, ["unbound"]).isEmpty, "only scripts read it")
    }
}
