import Foundation

/// Scene objects rebuilt after a structural user-property change (a combo, a texture, a size):
/// the renderer swaps them in for the objects of the same ids and keeps everything else, the
/// scripts and timelines among it, running (`SceneMetalRenderer.replaceObjects`).
struct SceneObjectReplacement {
    /// The rebuilt objects' ids, as their layers and particle systems carry them.
    var objectIDs: Set<String>
    /// The rebuilt objects as content: their layers, particle systems and motions, in the scene's
    /// size, transforms and camera, which the renderer analyses the new layers against.
    var content: SceneMetalContent
}
