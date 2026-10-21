import Foundation

/// One scene object as the renderer describes it to the object model: at load for every object of
/// the scene, and for each `thisScene.createLayer` (`SceneScriptObjectHost`). Numbers are in the
/// object table's units (angles in radians); a field left out gets
/// `SceneScriptObjectField.defaultValue`.
struct SceneScriptObjectDescription {
    /// Which `ILayer` part applies. Members of other parts exist on every layer and are inert.
    enum Kind: String, CaseIterable {
        case image, text, sound, particle, model, group, camera, light
    }

    struct Effect {
        /// The effect's custom name (`IEffect.name`), or its file name when it has none.
        var name: String
        var visible: Bool
        /// One per pass, in pass order: `effects[i].passes[j]` is material `j` of effect `i`.
        var materials: [Material]
        /// Property animations of the effect (`property` "visible").
        var animations: [SceneScriptAnimationDescription] = []
    }

    struct Material {
        /// Every shader constant the material has, by its scene.json key (`constantshadervalues`),
        /// with its current value (1…4 components). `IMaterial` exposes each as a member.
        var constants: [Constant]
        /// Property animations of constants (`property` is the constant's key).
        var animations: [SceneScriptAnimationDescription] = []
    }

    struct Constant {
        var name: String
        var value: [Float]
    }

    var kind: Kind
    /// scene.json `id`.
    var id: Int
    var name: String
    var parentID: Int?
    var values: [SceneScriptObjectField: [Float]] = [:]
    /// Text and layout strings (`text`, `font`, `alignment`, …).
    var strings: [SceneScriptStringField: String] = [:]
    var effects: [Effect] = []
    /// The image's spritesheet animation (`getTextureAnimation()`), if its texture has one.
    var textureAnimation: SceneScriptAnimationDescription?
    /// The duration in seconds of the image's video texture (`getVideoTexture()`), if its texture
    /// is a video.
    var videoDuration: Double?
    /// Named timeline animations of the object and its properties (`property` is the scene.json
    /// key, e.g. "alpha", "origin", "instanceoverride.rate").
    var animations: [SceneScriptAnimationDescription] = []
    /// The object as authored in scene.json (`getInitialLayerConfig`), as a JSON object.
    var initialConfigurationJSON: String?
    /// A Puppet Warp image's rig (bones, clips, animation layers, attachments).
    var rig: SceneScriptRigDescription?
    /// What the cursor pass tests a model with, beyond its world matrix, and a model's or puppet's
    /// named hit boxes.
    var cursorShape: SceneScriptCursorShape?
}
