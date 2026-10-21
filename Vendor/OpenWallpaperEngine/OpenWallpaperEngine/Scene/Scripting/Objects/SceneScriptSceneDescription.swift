import Foundation

/// The scene as the object model first sees it (`SceneScriptObjectHost.sceneScriptScene()`).
struct SceneScriptSceneDescription {
    /// Every object of the scene in draw order (scene.json `objects` order), including sounds,
    /// particle systems and groups.
    var objects: [SceneScriptObjectDescription]
    /// `general` values in the scene buffer's units; left-out fields get their default.
    var settings: [SceneScriptSceneField: [Float]] = [:]
    /// Scene-level animations (`thisScene.getAnimation`), including `general.*` property ones.
    var animations: [SceneScriptAnimationDescription] = []
}
