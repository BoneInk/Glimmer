import Foundation
import OWESceneEditing

/// What a scene load reads (`Request`, whose `key` identifies the parse) and how the scene
/// file's stored edits are applied.
enum ScenePreparation {
    /// What a scene load reads, and so what its key covers.
    struct Request: Sendable {
        var directory: URL
        /// The project's scene file, e.g. `scene.json`.
        var sceneFile: String
        /// The saved Inspector edits (`_owe_scene_object_*`).
        var edits: [String: String]
        /// Stored user property values that can change the content.
        var userProperties: [String: String]
        /// The settings that affect preparation.
        var settings: String
        var displays: [SceneCacheKey.Display]
        /// The Wallpaper Editor's edits (`SceneEditOverlay`), applied under the Inspector's.
        var overlay: SceneEditOverlay? = nil

        var key: SceneCacheKey {
            SceneCacheKey(sources: SceneCacheKey.sources(of: directory), edits: keyedEdits,
                          userProperties: userProperties, displays: displays, settings: settings)
        }

        /// The edits the key covers: the Inspector's, and the overlay's by its digest.
        var keyedEdits: [String: String] {
            guard let overlay, overlay.hasSceneEdits else { return edits }
            var keyed = edits
            keyed[ScenePreparation.overlayKey] = overlay.digest
            return keyed
        }
    }

    /// Names the editor overlay among the cache key's edits; no stored edit has it (they all start
    /// with `_owe_scene_object_`).
    static let overlayKey = "editorOverlay"

    /// Splits stored values into the Inspector edits and the user properties that feed the key.
    static func split(storedValues values: [String: String]) -> (edits: [String: String], properties: [String: String]) {
        var edits: [String: String] = [:]
        var properties: [String: String] = [:]
        for (key, value) in values {
            if key.hasPrefix("_owe_scene_object_") { edits[key] = value }
            else if !key.hasPrefix("_owe_") { properties[key] = value }
        }
        return (edits, properties)
    }

    /// The scene document with its edits: Scene Edit / Export's replaced objects (its JSON editor
    /// edits an object as scene.json authors it), the Wallpaper Editor's overlay over them, then
    /// the Inspector's origin and scale, which stay the user's own on top; `data` itself when it
    /// isn't an object with an `objects` array.
    ///
    /// A replaced object goes under the overlay: on top, the replacement (a copy of the authored
    /// object) would drop every Wallpaper Editor edit of the layer, its added effects included.
    /// A layer only the overlay adds is replaced after it.
    static func resolvedScene(_ data: Data, edits values: [String: String],
                              overlay: SceneEditOverlay? = nil) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var authored = root["objects"] as? [[String: Any]] else { return data }
        var replaced = Set<Int>()
        replaceObjects(&authored, edits: values, replaced: &replaced)
        root["objects"] = authored
        if let overlay, overlay.hasSceneEdits { try overlay.apply(to: &root) }
        guard var objects = root["objects"] as? [[String: Any]] else { return data }
        replaceObjects(&objects, edits: values, replaced: &replaced)
        for index in objects.indices {
            let objectID = SceneObjects.objectID(objects[index], index: index)
            if let origin = values["_owe_scene_object_\(objectID)_origin"] {
                objects[index]["origin"] = origin
            }
            if let scale = values["_owe_scene_object_\(objectID)_scale"] {
                objects[index]["scale"] = scale
            }
        }
        root["objects"] = objects
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Replaces each object Scene Edit / Export saved as JSON (`_owe_scene_object_<id>_json`) and
    /// not yet `replaced`; the replacement keeps the object's id when it names none.
    private static func replaceObjects(_ objects: inout [[String: Any]], edits values: [String: String],
                                       replaced: inout Set<Int>) {
        for index in objects.indices {
            let objectID = SceneObjects.objectID(objects[index], index: index)
            // Optional: a stored value that isn't a JSON object is left out, as before.
            guard !replaced.contains(objectID), let override = values["_owe_scene_object_\(objectID)_json"],
                  let overrideData = override.data(using: .utf8),
                  var replacement = try? JSONSerialization.jsonObject(with: overrideData) as? [String: Any] else { continue }
            if replacement["id"] == nil, let id = objects[index]["id"] { replacement["id"] = id }
            objects[index] = replacement
            replaced.insert(objectID)
        }
    }
}
