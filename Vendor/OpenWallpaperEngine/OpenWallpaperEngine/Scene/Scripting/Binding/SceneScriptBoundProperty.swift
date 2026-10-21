import Foundation

/// What the runtime needs to know about the property a script is bound to (plan §4.3): its path
/// and type for WE's converter, and the user properties it and its `scriptproperties` follow.
struct SceneScriptBoundProperty: Equatable {
    /// The scene.json field path relative to the object (`alpha`, `effects.1.visible`,
    /// `effects.0.passes.0.constantshadervalues.multiply`, `instanceoverride.rate`), or
    /// `general.<key>` for the scene's own fields.
    var path: String
    var type: SceneScriptPropertyType
    /// The user property the value itself follows (`{"script", "user", "value"}`): when it changes,
    /// the property takes the new value before the frame's `applyUserProperties`.
    var user: SceneScriptUserReference?
    /// `scriptproperties` keys bound to user properties (`{"user": …, "value": …}` entries): when
    /// one changes, WE's `_Internal.updateScriptProperties` injects the new value into the script.
    var scriptPropertyUsers: [String: SceneScriptUserReference] = [:]

    /// The object `sceneScriptBinding.js` keeps per script.
    var javaScriptObject: [String: Any] {
        var object: [String: Any] = ["path": path, "type": type.rawValue,
                                     "scriptUsers": scriptPropertyUsers.mapValues(\.javaScriptObject)]
        if let user { object["user"] = user.javaScriptObject }
        return object
    }
}
