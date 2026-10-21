import Foundation

/// What `thisScene.createLayer(configuration)` was given (IScene.createLayer).
enum SceneScriptLayerSource: Equatable {
    /// An asset path such as `'models/bar.json'`, or an `IAssetHandle`'s path, with the
    /// `__workshopId` the calling script exports (WE's editor inserts it because "asset references
    /// may break" without it): the host tries the path under that Workshop item first
    /// (`assetPaths`).
    case asset(String, workshopID: String? = nil)
    /// A configuration object in scene.json form, serialized by WE's `_Internal.stringifyConfig`
    /// (vectors become `"x y z"` strings). A `text` member makes it a text layer.
    case configuration(json: String)
    /// Another layer as the starting point: its authored configuration with its current values.
    case copy(slot: Int)

    /// The paths to try for an asset, in order: under the script's Workshop item
    /// (`models/bar.json` → `models/workshop/<id>/bar.json`, where WE's editor puts an imported
    /// item's assets), then as written.
    static func assetPaths(_ path: String, workshopID: String?) -> [String] {
        guard let workshopID, !workshopID.isEmpty, let slash = path.firstIndex(of: "/") else { return [path] }
        let directory = path[..<slash]
        let file = path[path.index(after: slash)...]
        return ["\(directory)/workshop/\(workshopID)/\(file)", path]
    }
}
