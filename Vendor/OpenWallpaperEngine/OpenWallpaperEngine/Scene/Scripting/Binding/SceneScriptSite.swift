import Foundation

/// One attachment site as the loader found it: the instance to add to the runtime and the property
/// it is bound to.
struct SceneScriptSite {
    var instance: SceneScriptInstance
    var property: SceneScriptBoundProperty
    /// scene.json `id` of the object, or nil for `general.*` (and for asset-pack objects without one).
    var objectID: Int?
    /// The object's index in the document's `objects`, or nil for `general.*`.
    var objectIndex: Int?
}
