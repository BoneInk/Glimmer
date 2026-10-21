import Foundation

/// What the object model needs from the renderer that owns the wallpaper instance (WP11 implements
/// it; tests use a fake). All calls come on the runtime's thread.
protocol SceneScriptObjectHost: AnyObject {
    /// The scene's objects in draw order, its settings and scene-level animations. Read once, when
    /// the runtime is created.
    func sceneScriptScene() -> SceneScriptSceneDescription

    /// Describes the layer `thisScene.createLayer` asks for, synchronously, so the script gets a
    /// live layer at once; the object is materialized later through `.create`. Nil when the asset
    /// or configuration cannot make a layer (the script then gets `null`). Must not change the scene.
    func sceneScriptDescribeLayer(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription?

    /// Executes one script command after the script phase, in issue order.
    func sceneScriptPerform(_ command: SceneScriptObjectCommand)
}
