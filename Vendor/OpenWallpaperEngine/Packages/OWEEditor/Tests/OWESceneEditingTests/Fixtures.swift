import Foundation
@testable import OWESceneEditing

/// A small 2D scene: an image, a text layer parented to it, a particle system without an id, a
/// layer whose visibility a user property sets and one whose origin a script drives.
enum Fixtures {
    static let sceneJSON = """
    {
      "camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
      "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0 0 0"},
      "objects": [
        {"id": 10, "name": "Background", "image": "models/bg.json", "origin": "960.00000 540.00000 0.00000",
         "scale": "1.00000 1.00000 1.00000", "angles": "0.00000 0.00000 0.00000", "size": "1920.00000 1080.00000",
         "alpha": 1, "color": "1 1 1", "colorBlendMode": 0,
         "effects": [
           {"file": "effects/waterripple/effect.json", "visible": true,
            "passes": [{"constantshadervalues": {"Speed": 1.5}}]},
           {"file": "effects/blur/effect.json", "name": "Soft", "visible": {"user": "showblur", "value": true}}
         ]},
        {"id": 11, "name": "Clock", "parent": 10, "text": {"value": "12:00", "script": "export function update(v) { return v; }"},
         "pointsize": 40, "origin": "100 50 0"},
        {"name": "Sparks", "particle": "particles/sparks.json", "origin": "500 500 0"},
        {"id": 13, "name": "Logo", "image": "models/logo.json", "size": "200 100",
         "visible": {"user": "showlogo", "value": true}, "origin": "1700 900 0"},
        {"id": 14, "name": "Moving", "image": "models/moving.json", "size": "100 100",
         "origin": {"script": "export function update(v) { return v; }", "value": "300 300 0"}}
      ]
    }
    """

    static var sceneData: Data { Data(sceneJSON.utf8) }

    static func object(_ id: Int, in data: Data) throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let objects = root["objects"] as! [[String: Any]]
        return objects.enumerated().first { index, object in ((object["id"] as? NSNumber)?.intValue ?? index) == id }!.element
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "OWESceneEditingTests-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
