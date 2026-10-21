import Foundation

/// A timeline or texture animation scripts can control (`IAnimation`, `ITextureAnimation`). Its
/// state lives in the animation buffer of `SceneScriptObjectModel`, which `SceneScriptSceneMirror`
/// fills from the renderer's `SceneAnimationSet` each frame; this is what it is placed with.
struct SceneScriptAnimationDescription {
    var name: String
    var fps: Double
    var frameCount: Int
    var duration: Double
    var rate: Double = 1
    var frame: Double = 0
    var playing: Bool = false
    /// The scene.json key of the property the animation drives, for property animations; what
    /// `thisObject.getAnimation()` returns in a script bound to that property.
    var property: String?
}
