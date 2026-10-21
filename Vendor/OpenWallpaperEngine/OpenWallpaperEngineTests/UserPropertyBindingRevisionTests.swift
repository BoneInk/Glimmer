import XCTest
@testable import OpenWallpaperEngine

/// Caches of bound values key on their owner's binding revision (`SceneBindingRevisions`): none is
/// reused across a change, and one that would be is counted (`staleReuses`).
final class UserPropertyBindingRevisionTests: XCTestCase {
    private struct Context: SceneValueContext {
        var properties: [String: String] = [:]
        var bindingRevision: UInt64?
        var synced: Set<String> = []
        func userProperty(_ name: String) -> String? { properties[name] }
        func isMusicSynced(_ name: String) -> Bool { synced.contains(name) }
    }

    func testRevisionsMovePerOwnerAndForTheScene() {
        var revisions = SceneBindingRevisions()
        let a = revisions.revision(of: "1")
        let b = revisions.revision(of: "2")
        revisions.bump([.object(1)])
        XCTAssertNotEqual(revisions.revision(of: "1"), a)
        XCTAssertEqual(revisions.revision(of: "2"), b, "only the owner moves")
        let before = revisions.revision(of: "2")
        revisions.bump([.scene])
        XCTAssertNotEqual(revisions.revision(of: "2"), before, "a scene-wide change moves every object")
    }

    func testACacheIsNeverReusedAcrossAChange() {
        var revisions = SceneBindingRevisions()
        var cache = SceneBindingCache<Int>()
        var computed = 0
        func read() -> Int {
            let revision = revisions.revision(of: "7")
            let reused = cache.revision == revision
            let value = cache.value(at: revision) { computed += 1; return computed }
            if reused { revisions.noteReuse(of: "7", cachedAt: cache.revision ?? revision) }
            return value
        }
        XCTAssertEqual(read(), 1)
        XCTAssertEqual(read(), 1, "kept while the revision stays")
        revisions.bump([.object(7)])
        XCTAssertEqual(read(), 2, "computed again after the change")
        XCTAssertEqual(revisions.staleReuses, 0)
        revisions.noteReuse(of: "7", cachedAt: 0)
        XCTAssertEqual(revisions.staleReuses, 1, "the hook catches a cache that forgot the revision")
    }

    func testUserConstantsAreKeptPerRevision() {
        let constant = ShaderConstantResolver.DynamicConstant(
            uniform: "g_Speed", source: .user(name: "speed", condition: nil, fallback: .literal(ShaderValue(1))), count: 1, isInt: false)
        var cache = SceneUserConstantCache()
        var context = Context(properties: ["speed": "2"], bindingRevision: 1)
        cache.begin([constant], in: context)
        XCTAssertEqual(cache.value(0, of: constant, in: context), ShaderValue(2))
        context.properties["speed"] = "3"
        cache.begin([constant], in: context)
        XCTAssertEqual(cache.value(0, of: constant, in: context), ShaderValue(2), "kept: no revision change yet")
        context.bindingRevision = 2
        cache.begin([constant], in: context)
        XCTAssertEqual(cache.value(0, of: constant, in: context), ShaderValue(3))

        context.synced = ["speed"]
        context.bindingRevision = 3
        cache.begin([constant], in: context)
        context.properties["speed"] = "4"
        XCTAssertEqual(cache.value(0, of: constant, in: context), ShaderValue(4), "a music-synced property resolves every frame")
    }

    func testMusicSyncCompanionsMoveTheirPropertysOwners() throws {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(#"""
            {"objects": [{"id": 3, "image": "a.json", "effects": [{"file": "e.json",
              "passes": [{"constantshadervalues": {"k": {"user": "tint", "value": "1 1 1"}}}]}]}]}
            """#.utf8))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        XCTAssertEqual(SceneBindingUpdate(keys: ["tint_musicSync"], table: table).owners, [.object(3)])
        XCTAssertEqual(SceneBindingUpdate(keys: ["tint_1_musicAmount"], table: table).owners, [.object(3)])
        XCTAssertEqual(SceneBindingUpdate(keys: ["tint_musicSync"], table: table).impact, .none)
    }
}
