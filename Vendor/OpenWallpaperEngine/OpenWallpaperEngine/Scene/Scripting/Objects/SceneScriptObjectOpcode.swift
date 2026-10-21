import Foundation

/// The object model's command-ring opcodes (400–999). `objects-values.js` mirrors the numbers in
/// `__rt.objects.OP`; `SceneScriptObjectModel` decodes them into `SceneScriptObjectCommand`s.
extension SceneScriptCommandRing.Opcode {
    /// target slot. The source is kept natively from the synchronous describe.
    static let objectCreate = Self(rawValue: 400)
    /// target slot.
    static let objectDestroy = Self(rawValue: 401)
    /// target slot; numbers [index].
    static let objectSort = Self(rawValue: 402)
    /// target slot; strings [field, value].
    static let objectSetString = Self(rawValue: 403)
    /// `ILayer.setParent`: target slot; numbers [] (no parent) or [parent slot]; strings [] or
    /// [attachment name].
    static let objectSetParent = Self(rawValue: 404)
    /// target slot; numbers [effect, material or -1, components…]; strings [name].
    static let materialSetProperty = Self(rawValue: 410)
    /// target slot; numbers [effect]; strings [name].
    static let materialExecuteFunction = Self(rawValue: 411)
    /// `materialSetProperty` for a constant the material declares: target slot; numbers [effect,
    /// material or -1, the constant's pool offset, components…]; no strings (the store names it).
    static let materialSetConstant = Self(rawValue: 412)
    /// target slot.
    static let soundPlay = Self(rawValue: 420)
    static let soundPause = Self(rawValue: 421)
    static let soundStop = Self(rawValue: 422)
    /// target slot.
    static let particlesPlay = Self(rawValue: 430)
    static let particlesPause = Self(rawValue: 431)
    static let particlesStop = Self(rawValue: 432)
    /// target slot; numbers [] or [count].
    static let particlesEmit = Self(rawValue: 433)
    /// target animation slot.
    static let animationPlay = Self(rawValue: 440)
    static let animationPause = Self(rawValue: 441)
    static let animationStop = Self(rawValue: 442)
    /// target animation slot; numbers [frame].
    static let animationSetFrame = Self(rawValue: 443)
    static let animationJoin = Self(rawValue: 444)
    /// Puppet rigs (`SceneScriptRigLayout.decode`): target slot; numbers [key, singlePlay,
    /// additive, blendin, blendout, autosort, blendtime, rate, blend, visible]; strings [clip, name].
    static let rigLayerCreate = Self(rawValue: 450)
    /// target slot; numbers [key].
    static let rigLayerDestroy = Self(rawValue: 451)
    /// target slot; numbers [key, field (rate 0, blend 1, visible 2), value].
    static let rigLayerSet = Self(rawValue: 452)
    /// target slot; numbers [key, action (play 0, pause 1, stop 2, setFrame 3), frame?].
    static let rigLayerPlayback = Self(rawValue: 453)
    /// target slot; numbers [bone, 16 floats column-major].
    static let rigBoneLocal = Self(rawValue: 454)
    /// target slot; numbers [bone, 16 floats column-major, the world matrix].
    static let rigBoneWorld = Self(rawValue: 455)
    /// target slot; numbers [target index, weight].
    static let rigBlendShape = Self(rawValue: 456)
    /// target slot; numbers [bone, directional impulse xyz, angular impulse xyz (degrees)].
    static let rigBonePhysicsImpulse = Self(rawValue: 457)
    /// target slot; numbers [bone].
    static let rigBonePhysicsReset = Self(rawValue: 458)
    /// `IVideoTexture`: target slot; numbers [action (play 0, pause 1, stop 2, seek 3, rate 4,
    /// loop 5), value?].
    static let videoTexture = Self(rawValue: 460)

    /// Every object-model opcode with its JS name, for `__rt.objects.OP`.
    static let objectModelOpcodes: [String: Self] = [
        "create": .objectCreate, "destroy": .objectDestroy, "sort": .objectSort, "setString": .objectSetString,
        "setParent": .objectSetParent,
        "setMaterialProperty": .materialSetProperty, "executeMaterialFunction": .materialExecuteFunction,
        "setMaterialConstant": .materialSetConstant,
        "soundPlay": .soundPlay, "soundPause": .soundPause, "soundStop": .soundStop,
        "particlesPlay": .particlesPlay, "particlesPause": .particlesPause, "particlesStop": .particlesStop,
        "particlesEmit": .particlesEmit, "animationPlay": .animationPlay, "animationPause": .animationPause,
        "animationStop": .animationStop, "animationSetFrame": .animationSetFrame, "animationJoin": .animationJoin,
        "rigLayerCreate": .rigLayerCreate, "rigLayerDestroy": .rigLayerDestroy, "rigLayerSet": .rigLayerSet,
        "rigLayerPlayback": .rigLayerPlayback, "rigBoneLocal": .rigBoneLocal, "rigBoneWorld": .rigBoneWorld,
        "rigBlendShape": .rigBlendShape, "rigBonePhysicsImpulse": .rigBonePhysicsImpulse,
        "rigBonePhysicsReset": .rigBonePhysicsReset, "videoTexture": .videoTexture,
    ]
}
