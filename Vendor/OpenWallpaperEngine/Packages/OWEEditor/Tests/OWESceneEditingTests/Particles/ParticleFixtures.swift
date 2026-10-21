import Foundation
import XCTest
@testable import OWESceneEditing

/// WE's particle editor schema (docs/we-particle-editor-schema.json), and a small scene with
/// particle systems whose files a dictionary holds.
enum ParticleFixtures {
    static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    static var schemaURL: URL { repositoryRoot.appending(path: "docs/we-particle-editor-schema.json") }

    static func schema() throws -> ParticleEditorSchema {
        try ParticleEditorSchema(data: Data(contentsOf: schemaURL))
    }

    /// Two systems on a 1920 × 1080 scene (one shares its definition with the other's child), an
    /// image, and a system without an id.
    static let sceneJSON = """
    {
      "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
      "objects": [
        {"id": 1, "name": "Background", "image": "models/bg.json", "size": "1920 1080", "origin": "960 540 0"},
        {"id": 5, "name": "Rain", "particle": "particles/rain.json", "origin": "960 900 0",
         "instanceoverride": {"alpha": 0.8, "count": {"user": "raincount", "value": 1}}},
        {"name": "Sparks", "particle": "particles/sparks.json", "origin": "100 100 0", "angles": "0 0 1.5707963"}
      ]
    }
    """

    static let rainJSON = """
    {
      "material": "materials/particle/drop.json",
      "maxcount": 300,
      "emitter": [{"id": 1, "name": "sphererandom", "rate": 50, "distancemax": 900}],
      "initializer": [{"id": 2, "name": "lifetimerandom", "min": 1, "max": 2},
                      {"id": 3, "name": "sizerandom", "min": 4, "max": 8}],
      "operator": [{"id": 4, "name": "movement", "gravity": "0 -900 0"},
                   {"id": 5, "name": "alphafade", "fadeintime": 0.1, "fadeouttime": 0.3}],
      "children": null,
      "controlpoint": [{"id": 0, "flags": 0, "offset": "0 0 0"}, {"id": 1, "flags": 0, "offset": "100 50 0"}]
    }
    """

    static let sparksJSON = """
    {"material": "materials/particle/halo.json", "maxcount": 50,
     "emitter": [{"name": "boxrandom", "rate": 5}],
     "children": [{"name": "particles/rain.json", "type": "static"}]}
    """

    static let dropMaterialJSON = """
    {"passes": [{"shader": "genericparticle", "blending": "additive", "textures": ["particle/drop"]}]}
    """

    static var files: [String: Data] {
        ["particles/rain.json": Data(rainJSON.utf8), "particles/sparks.json": Data(sparksJSON.utf8),
         "materials/particle/drop.json": Data(dropMaterialJSON.utf8),
         "materials/particle/halo.json": Data(dropMaterialJSON.utf8)]
    }

    @MainActor
    static func model(files: [String: Data] = files, sceneJSON: String = sceneJSON) throws -> ParticleEditingModel {
        let undoManager = UndoManager()
        // No run loop turns in a test: groups are the session's own.
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Data(sceneJSON.utf8)), undoManager: undoManager)
        session.coalescingInterval = 0
        return ParticleEditingModel(session: session, schema: try schema(), readAsset: { files[$0] })
    }
}
