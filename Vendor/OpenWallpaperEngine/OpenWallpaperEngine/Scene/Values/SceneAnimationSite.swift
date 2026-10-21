import Foundation

/// What owns an animated property: WE's animation `+0x08` (docs/timeline-plan.md §2.1). Two
/// animations link (`options.parent`, §2.5) only when they have the same owner, and
/// `animationEvent` goes to the owner's scripts (§3.3).
///
/// Object ids are scene.json's `id`, else the object's index (`SceneScriptSceneDescriber.objectID`).
enum SceneAnimationOwner: Hashable {
    /// `general`: the scene's settings.
    case scene
    /// A layer's own fields (`alpha`, `origin`, …).
    case object(Int)
    /// A particle system's `instanceoverride` block. Best guess: WE keeps the overrides as their
    /// own property block, so they don't link with the object's fields of the same name.
    case particleInstance(Int)
    /// An effect of a layer, by its index in `effects` (its `visible`).
    case effect(object: Int, effect: Int)
    /// A material of an effect, by pass index (`passes[pass].constantshadervalues`).
    case material(object: Int, effect: Int, pass: Int)
    /// An animation layer of a model or puppet, by its index in `animationlayers` (its animatable
    /// `rate` and `blend`, 0x14026c980). Scripts reach it through the layer
    /// (`getAnimationLayer(name).getAnimation(name)`), and its events go to the object's scripts.
    case animationLayer(object: Int, layer: Int)

    /// The layer the owner belongs to; nil for the scene.
    var objectID: Int? {
        switch self {
        case .scene: return nil
        case .object(let id), .particleInstance(let id): return id
        case .effect(let id, _), .material(let id, _, _), .animationLayer(let id, _): return id
        }
    }
}

/// One animatable property of a wallpaper: its owner and its key as scene.json spells it (the
/// property descriptor's key, `descriptor+0x38`, which `options.parent.key` names).
struct SceneAnimationSite: Hashable, CustomStringConvertible {
    var owner: SceneAnimationOwner
    var key: String

    init(owner: SceneAnimationOwner, key: String) {
        self.owner = owner
        self.key = key
    }

    /// The site of a script's animation record (`SceneScriptAnimationReference` and the
    /// description's `property`, as `SceneScriptSceneDescriber` names them): `general.<key>` for
    /// the scene, `instanceoverride.<key>` for particle overrides, `animationlayers.<index>.<key>`
    /// for an animation layer's fields, the key itself otherwise.
    /// `objectID` is the layer's id (nil for the scene); `effect`/`material` its effect and pass.
    init?(scriptProperty property: String, objectID: Int?, effect: Int?, material: Int?) {
        guard let objectID else {
            guard effect == nil, material == nil, property.hasPrefix(Self.scenePrefix) else { return nil }
            self.init(owner: .scene, key: String(property.dropFirst(Self.scenePrefix.count)))
            return
        }
        switch (effect, material) {
        case let (effect?, material?):
            self.init(owner: .material(object: objectID, effect: effect, pass: material), key: property)
        case let (effect?, nil):
            self.init(owner: .effect(object: objectID, effect: effect), key: property)
        case (nil, nil):
            if property.hasPrefix(Self.instancePrefix) {
                self.init(owner: .particleInstance(objectID), key: String(property.dropFirst(Self.instancePrefix.count)))
            } else if property.hasPrefix(Self.animationLayerPrefix) {
                let parts = property.dropFirst(Self.animationLayerPrefix.count).split(separator: ".", maxSplits: 1)
                guard parts.count == 2, let layer = Int(parts[0]), layer >= 0 else { return nil }
                self.init(owner: .animationLayer(object: objectID, layer: layer), key: String(parts[1]))
            } else {
                self.init(owner: .object(objectID), key: property)
            }
        case (nil, _?):
            return nil
        }
    }

    /// The property string `SceneScriptSceneDescriber` gives this site's script record.
    var scriptProperty: String {
        switch owner {
        case .scene: return Self.scenePrefix + key
        case .particleInstance: return Self.instancePrefix + key
        case .animationLayer(_, let layer): return "\(Self.animationLayerPrefix)\(layer).\(key)"
        case .object, .effect, .material: return key
        }
    }

    var description: String {
        switch owner {
        case .scene: return "general.\(key)"
        case .object(let id): return "object \(id) \(key)"
        case .particleInstance(let id): return "object \(id) instanceoverride.\(key)"
        case let .effect(id, effect): return "object \(id) effect \(effect) \(key)"
        case let .material(id, effect, pass): return "object \(id) effect \(effect) pass \(pass) \(key)"
        case let .animationLayer(id, layer): return "object \(id) animationlayers[\(layer)] \(key)"
        }
    }

    private static let scenePrefix = "general."
    private static let instancePrefix = "instanceoverride."
    /// `animationlayers.<index>.`, as the script site builder joins the field path.
    static let animationLayerPrefix = "animationlayers."
}
