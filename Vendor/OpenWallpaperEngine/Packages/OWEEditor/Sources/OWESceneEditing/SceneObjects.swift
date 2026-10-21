import Foundation

/// The objects of a scene.json document, as `JSONSerialization` reads them.
public enum SceneObjects {
    /// Object `index`'s id: its `id`, else its index in `objects`, the id the app's
    /// `SceneObjectIdentity` gives it, so the editor, the overlay and the renderer agree.
    public static func objectID(_ object: [String: Any], index: Int) -> Int {
        (object["id"] as? NSNumber)?.intValue ?? index
    }
}
