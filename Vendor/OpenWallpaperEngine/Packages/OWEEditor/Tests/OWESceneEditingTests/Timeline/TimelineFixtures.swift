import Foundation
@testable import OWESceneEditing

/// A 2D scene with timelines: layer 1's alpha fades (scene.json's own animation), layer 2 has
/// none, and layer 1's first effect has a numeric constant and a colour.
enum TimelineFixtures {
    static let sceneJSON = """
    {
      "general": {"orthogonalprojection": {"width": 1920, "height": 1080}},
      "objects": [
        {"id": 1, "name": "Logo", "image": "models/logo.json", "size": "200 100", "origin": "960 540 0",
         "alpha": {"value": 1, "animation": {
            "c0": [{"frame": 0, "value": 0, "back": {"enabled": true, "x": -1, "y": 0}, "front": {"enabled": true, "x": 1, "y": 0}},
                   {"frame": 30, "value": 1, "back": {"enabled": true, "x": -1, "y": 0}, "front": {"enabled": true, "x": 1, "y": 0},
                    "magic": true}],
            "options": {"fps": 30, "length": 60, "mode": "loop", "wraploop": false, "startpaused": false,
                        "events": [{"name": "half", "frame": 15}]}}},
         "effects": [
           {"file": "effects/tint/effect.json",
            "passes": [{"constantshadervalues": {"strength": 0.5, "tint": "1 0.5 0", "noise": "textures/noise"}}]}
         ]},
        {"id": 2, "name": "Title", "text": "Hello", "origin": "100 50 0", "visible": {"user": "showtitle", "value": true},
         "scale": {"user": "titlescale", "value": "1 1 1"}}
      ]
    }
    """

    static var sceneData: Data { Data(sceneJSON.utf8) }

    static let alpha = TimelineTarget.field("alpha", of: 1)
    static let origin = TimelineTarget.field("origin", of: 1)
    static let strength = TimelineTarget.constant("strength", effect: 0, of: 1)
    static let tint = TimelineTarget.constant("tint", effect: 0, of: 1)

    @MainActor
    static func editor() throws -> (SceneTimelineEditor, SceneEditSession) {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData), undoManager: undoManager)
        let editor = SceneTimelineEditor(session: session, index: try TimelineSceneIndex(sceneData: sceneData))
        return (editor, session)
    }

    /// The object `id` of scene.json with the overlay applied.
    static func appliedObject(_ id: Int, overlay: SceneEditOverlay) throws -> [String: Any] {
        let data = try overlay.applied(to: sceneData)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let objects = root["objects"] as! [[String: Any]]
        return objects.first { ($0["id"] as? NSNumber)?.intValue == id }!
    }
}
