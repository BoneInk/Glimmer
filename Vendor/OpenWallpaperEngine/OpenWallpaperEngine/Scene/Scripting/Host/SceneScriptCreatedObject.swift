import Foundation

/// What the loader built for an object a script created (`thisScene.createLayer`). WE builds it
/// with the scene loader's own object factory (wallpaper64.exe 0x14018ba00 calls 0x14018ff60, like
/// the loader at 0x140187f22), so every kind comes out as it would at load.
enum SceneScriptCreatedObject {
    /// An image, text or shape layer.
    case layer(SceneMetalLayer)
    /// A particle system with its children, and how its own transform moves.
    case particles([SceneMetalParticleSystem], motion: SceneObjectMotion)
    /// A sound layer; it plays at once unless `startsilent`.
    case sound(SceneSoundContent)
    /// A model object (a clone of an authored one, `getInitialLayerConfig`): its `.mdl` and
    /// materials, its node in the 3D hierarchy, and how its own transform moves.
    case model(SceneModelObject, node: SceneTransformHierarchy3D.Node, motion: SceneObjectMotion)
}
