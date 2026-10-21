import Foundation

/// A native action a script requested, in the order scripts issued them. The object model decodes
/// the command ring's records (opcodes 400–999) into these and hands them to its host after the
/// script phase of each frame; the host executes them before it reads the tables.
enum SceneScriptObjectCommand: Equatable {
    enum Playback: Equatable {
        case play, pause, stop
    }

    enum AnimationAction: Equatable {
        case play, pause, stop
        case setFrame(Double)
        /// `ITextureAnimation.join()`: back to the animation state shared by all users of the texture.
        case join
    }

    /// Materialize the layer the object model already described and put in `slot`
    /// (`thisScene.createLayer`). Its values are in the table; scripts may have changed them since.
    case create(slot: Int, source: SceneScriptLayerSource)
    /// Remove the layer after this frame's updates (`destroyLayer`). The slot is free afterwards.
    case destroy(slot: Int)
    /// Move the layer to `index` in draw order (`sortLayer`).
    case sort(slot: Int, index: Int)
    case setString(slot: Int, field: SceneScriptStringField, value: String)
    /// `ILayer.setParent`: hang the layer from the layer in `parent` (nil: no parent), from its
    /// rig's attachment named `attachment` when set. `objects-transforms.js` already rewrote the
    /// layer's own transform when the script asked to keep it in place.
    case setParent(slot: Int, parent: Int?, attachment: String?)
    /// `IEffect.setMaterialProperty` (`material` nil: every material of the effect that has the
    /// constant) and `IMaterial` member writes (`material` set).
    case setMaterialProperty(slot: Int, effect: Int, material: Int?, name: String, value: [Float])
    case executeMaterialFunction(slot: Int, effect: Int, name: String)
    case sound(slot: Int, Playback)
    case particles(slot: Int, Playback)
    /// `emitParticles(count?)`; nil when the script passed no count.
    case emitParticles(slot: Int, count: Int?)
    case animation(SceneScriptAnimationReference, AnimationAction)
    /// A puppet image's animation-layer or bone call (`SceneScriptRigCommand`).
    case rig(slot: Int, SceneScriptRigCommand)
    /// An `IVideoTexture` call on the image in `slot`.
    case video(slot: Int, SceneVideoTextureCommand)
}

/// What a script asked of an image's video texture (`IVideoTexture`).
enum SceneVideoTextureCommand: Equatable {
    case play, pause, stop
    /// `setCurrentTime`, in seconds.
    case seek(Double)
    case rate(Float)
    case loop(Bool)

    /// The command ring's form: [action, value?].
    init?(numbers: [Float]) {
        guard let action = numbers.first else { return nil }
        let value = numbers.count > 1 && numbers[1].isFinite ? Double(numbers[1]) : nil
        switch action {
        case 0: self = .play
        case 1: self = .pause
        case 2: self = .stop
        case 3: guard let value else { return nil }; self = .seek(max(0, value))
        case 4: guard let value else { return nil }; self = .rate(Float(max(0, min(value, 1e3))))
        case 5: guard let value else { return nil }; self = .loop(value != 0)
        default: return nil
        }
    }
}

/// Which animation a command is for: an animation of the object in `slot` (or of the scene when
/// `slot` is nil), of one of its effects or materials, or its texture animation.
struct SceneScriptAnimationReference: Equatable {
    var slot: Int?
    var effect: Int?
    var material: Int?
    var name: String
    var isTextureAnimation: Bool
    /// The animation's slot in the animation buffer.
    var animationSlot: Int
}
