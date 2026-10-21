import Foundation

/// Save as New Wallpaper for the editor's puppets: each layer's rig written as a WE `.mdl`
/// (`PuppetMDLWriter`), a model JSON naming it (`"puppet"`, as WE's image models do,
/// docs/models-plan.md §2.13) and the layer pointed at that model with its `animationlayers`.
/// New files get names of their own, so a model or rig other layers share is never changed.
public enum PuppetSceneBake {
    public struct Result {
        /// scene.json with the layers' new models and animation layers.
        public var scene: Data
        /// The new files by their path in the wallpaper.
        public var files: [String: Data]
    }

    public enum BakeError: Error, Equatable, LocalizedError {
        /// The layer the puppet belongs to is gone or isn't an image.
        case noImageLayer(String)

        public var errorDescription: String? {
            switch self {
            case .noImageLayer(let key): return "The puppet's layer \(key) is no longer an image layer."
            }
        }
    }

    /// `scene` with `overlay`'s puppets baked in. `readFile` reads a file of the wallpaper by
    /// its path (nil when it has none), for the layer's model JSON and to keep new names free.
    public static func bake(_ overlay: SceneEditOverlay, into scene: Data,
                            readFile: (String) -> Data?) throws -> Result {
        guard let puppets = overlay.puppets, !puppets.isEmpty else { return Result(scene: scene, files: [:]) }
        guard var root = try JSONSerialization.jsonObject(with: scene) as? [String: Any],
              var objects = root["objects"] as? [[String: Any]] else { throw SceneEditOverlayError.notAScene }
        var files: [String: Data] = [:]
        func isFree(_ path: String) -> Bool { files[path] == nil && readFile(path) == nil }
        for (key, document) in puppets.sorted(by: { $0.key < $1.key }) {
            guard let index = objects.indices.first(where: { (index: Int) -> Bool in
                let id: Int = SceneObjects.objectID(objects[index], index: index)
                return String(id) == key
            }), let modelPath = objects[index]["image"] as? String else { throw BakeError.noImageLayer(key) }
            var model = readFile(modelPath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                ?? ["material": document.material]
            let base = (modelPath as NSString).deletingPathExtension
            var stem = "\(base)_puppet_\(key)"
            var number = 2
            while !isFree(stem + ".json") || !isFree(stem + ".mdl") {
                stem = "\(base)_puppet_\(key)_\(number)"
                number += 1
            }
            let rigPath = stem + ".mdl"
            model["puppet"] = rigPath
            files[rigPath] = try PuppetMDLWriter.write(document)
            files[stem + ".json"] = try JSONSerialization.data(withJSONObject: model, options: [.prettyPrinted, .sortedKeys])
            objects[index]["image"] = stem + ".json"
            if document.layers.isEmpty {
                objects[index].removeValue(forKey: "animationlayers")
            } else {
                objects[index]["animationlayers"] = document.layers.map(\.json)
            }
        }
        root["objects"] = objects
        return Result(scene: try JSONSerialization.data(withJSONObject: root), files: files)
    }
}
