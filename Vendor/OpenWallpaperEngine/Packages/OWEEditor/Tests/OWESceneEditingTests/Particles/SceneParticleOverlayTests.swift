import XCTest
@testable import OWESceneEditing

/// The particle editor's part of the overlay: kept, read back and applied where the scene loads
/// (added systems after the scene's own, deleted ones left out), told apart from scene edits for
/// the running wallpaper, and written into a local copy.
final class SceneParticleOverlayTests: XCTestCase {
    private var sceneData: Data { Data(ParticleFixtures.sceneJSON.utf8) }

    private func edited() -> SceneEditOverlay {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("10 20 0"), of: 5)
        overlay.updateParticles { particles in
            particles.assets["particles/editor/particle_system.json"] = ParticleDefinition.template.json
            particles.addedObjects = [.object(["id": .number(7), "name": .string("Added"),
                                               "particle": .string("particles/editor/particle_system.json"),
                                               "origin": .string("960 540 0")])]
            particles.removedObjects = [5, 5]
        }
        return overlay
    }

    func testTheOverlayRoundTrips() throws {
        let overlay = edited()
        XCTAssertEqual(overlay.particles?.removedObjects, [5], "kept once, sorted")
        let decoded = try SceneEditOverlay.decoded(from: overlay.encoded())
        XCTAssertEqual(decoded, overlay)
        XCTAssertEqual(decoded.digest, overlay.digest)
        XCTAssertTrue(overlay.hasSceneEdits)
        XCTAssertFalse(overlay.isEmpty)
    }

    func testAnOverlayWithoutParticlesIsWrittenAsBefore() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(0.5), of: 1)
        let text = try XCTUnwrap(String(data: overlay.encoded(), encoding: .utf8))
        XCTAssertFalse(text.contains("particles"), "no key, so the digest of an older overlay stays")
        overlay.updateParticles { $0.assets["a.json"] = .object([:]) }
        overlay.updateParticles { $0.assets["a.json"] = nil }
        XCTAssertNil(overlay.particles, "an emptied particle overlay is dropped")
        let older = Data(#"{"version": 1, "objects": {"1": {"fields": {"alpha": 0.5}, "effects": {}}}}"#.utf8)
        XCTAssertEqual(try SceneEditOverlay.decoded(from: older), overlay, "an overlay from before the particle editor reads")
    }

    func testTheLoaderAddsAndLeavesOutSystems() throws {
        let applied = try edited().applied(to: sceneData)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: applied) as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.map { $0["name"] as? String }, ["Background", "Sparks", "Added"])
        XCTAssertEqual(objects.last?["particle"] as? String, "particles/editor/particle_system.json")
        let outline = try SceneOutline(sceneData: applied)
        XCTAssertEqual(outline.layers.map(\.kind), [.image, .particle, .particle])
    }

    func testAnObjectWithoutAnIDIsDeletedByItsAuthoredIndex() throws {
        var overlay = SceneEditOverlay()
        overlay.setField("origin", to: .string("1 1 0"), of: 2)
        overlay.updateParticles { $0.removedObjects = [1] }
        let fixtureWithoutIDs = Data(#"{"objects": [{"name": "a", "image": "a"}, {"name": "b", "particle": "b"}, {"name": "c", "particle": "c"}]}"#.utf8)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: overlay.applied(to: fixtureWithoutIDs)) as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [[String: Any]])
        XCTAssertEqual(objects.map { $0["name"] as? String }, ["a", "c"])
        XCTAssertEqual(objects.last?["origin"] as? String, "1 1 0", "the edit named c by its index before b was deleted")
    }

    func testTheOutlineShowsTheAddedSystemsAndNotTheDeleted() throws {
        let outline = try SceneOutline(sceneData: sceneData)
        let applied = outline.applying(edited().particles)
        XCTAssertEqual(applied.layers.map(\.id), [1, 2, 7], "Sparks has no id: its index")
        XCTAssertNil(applied.layer(5))
        XCTAssertEqual(applied.layer(7)?.kind, .particle)
        XCTAssertEqual(applied.layer(7)?.index, 3, "drawn after the scene's own")
        XCTAssertEqual(applied.size, outline.size)
        XCTAssertEqual(outline.nextObjectID(besides: edited().particles), 8)
    }

    func testOnlyParticleDocumentsChangingLeavesTheSceneRunning() {
        let before = edited()
        var after = before
        after.updateParticles { $0.assets["particles/editor/particle_system.json"] = .object(["maxcount": .number(1)]) }
        after.updateParticles { $0.assets["materials/editor/x.json"] = .object([:]) }
        XCTAssertEqual(after.liveChange(from: before),
                       .particleAssets(["particles/editor/particle_system.json", "materials/editor/x.json"]))
        var moved = after
        moved.setField("origin", to: .string("0 0 0"), of: 7)
        XCTAssertEqual(moved.liveChange(from: after), .scene, "a field of the scene")
        var added = after
        added.updateParticles { $0.removedObjects.append(1) }
        XCTAssertEqual(added.liveChange(from: after), .scene, "the scene's objects")
    }

    func testTheDocumentsAreWrittenAsFilesOfALocalCopy() throws {
        let overlay = edited()
        let files = try XCTUnwrap(overlay.particles?.assetFiles())
        let definition = try ParticleDefinition(data: try XCTUnwrap(files["particles/editor/particle_system.json"]))
        XCTAssertEqual(definition, .template)
        XCTAssertNotNil(overlay.particles?.assetData()["particles/editor/particle_system.json"])

        let root = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"title": "Rain", "file": "scene.json", "workshopid": "1"}"#.utf8).write(to: source.appending(path: "project.json"))
        try sceneData.write(to: source.appending(path: "scene.json"))
        let library = root.appending(path: "library", directoryHint: .isDirectory)
        let folder = try LocalWallpaperWriter().save(.init(directory: source, sceneFile: "scene.json"),
                                                     scene: try overlay.applied(to: sceneData), title: "Rain (Edited)",
                                                     into: library, additionalFiles: files)
        let written = try Data(contentsOf: folder.appending(path: "particles/editor/particle_system.json"))
        XCTAssertEqual(try ParticleDefinition(data: written), .template)
        XCTAssertThrowsError(try LocalWallpaperWriter().save(.init(directory: source, sceneFile: "scene.json"),
                                                             scene: sceneData, title: "x", into: library,
                                                             additionalFiles: ["../escape.json": Data()]))
    }
}
