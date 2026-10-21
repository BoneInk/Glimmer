import simd

/// What scripts left in one scene object after a frame, for the renderer (docs/scenescript-plan.md
/// §4.3, WP11). A field counts once a script wrote it (a bound script's return, a member write):
/// from then on the object table is its value and the renderer draws it; until then the renderer
/// keeps its own value (authored, user-bound, animated) and feeds it into the table for scripts.
struct SceneScriptObjectState {
    /// Fields scripts wrote, by `SceneScriptObjectField` index (`SceneScriptOwnedFields`).
    var owned = SceneScriptOwnedFields()
    /// The object's table row (`SceneScriptObjectTable.Layout`).
    var values: [Float]
    /// Script-set strings (`text`, `font`, alignments), as the last `setString` left them.
    var strings: [SceneScriptStringField: String] = [:]
    /// `effects[i].visible` for effects scripts changed.
    var effectVisible: [Int: Bool] = [:]
    /// Material constants scripts set, per effect: `(material, name, value)`; `material` nil means
    /// every material of the effect that has the constant (`IEffect.setMaterialProperty`).
    var constants: [Int: [SceneScriptConstantWrite]] = [:]
    /// Bumped whenever `effectVisible` or `constants` change, so effect chains cached as static
    /// re-render.
    var effectRevision = 0
    /// Particle playback as scripts set it (`play`/`pause`/`stop`); nil until one did.
    var playback: SceneScriptObjectCommand.Playback?

    init(values: [Float]) {
        self.values = values
    }

    func owns(_ field: SceneScriptObjectField) -> Bool { owned.contains(field) }

    /// Takes back scripts' writes of constant `name` of `effect`'s `material`, whose timeline
    /// wrote it again (docs/timeline-plan.md §2.6: a script's write wins for its frame only). An
    /// effect-wide write keeps reaching the effect's other materials. True when one was dropped.
    mutating func dropConstantWrites(effect: Int, material: Int, name: String) -> Bool {
        guard var writes = constants[effect], writes.contains(where: { $0.targets(name, material: material) }) else {
            return false
        }
        writes.removeAll { $0.material == material && $0.targets(name, material: material) }
        for index in writes.indices where writes[index].targets(name, material: material) {
            writes[index].excluded.append(material)
        }
        constants[effect] = writes
        effectRevision &+= 1
        return true
    }

    /// The field's table value when scripts own it.
    func value(_ field: SceneScriptObjectField) -> [Float]? {
        guard owned.contains(field) else { return nil }
        let base = field.offset
        return (0..<field.components).map { values[base + $0] }
    }

    func scalar(_ field: SceneScriptObjectField) -> Float? {
        owned.contains(field) ? values[field.offset] : nil
    }

    func vector2(_ field: SceneScriptObjectField) -> SIMD2<Float>? {
        guard owned.contains(field) else { return nil }
        return SIMD2(values[field.offset], values[field.offset + 1])
    }

    func vector3(_ field: SceneScriptObjectField) -> SIMD3<Float>? {
        guard owned.contains(field) else { return nil }
        return SIMD3(values[field.offset], values[field.offset + 1], values[field.offset + 2])
    }

    func flag(_ field: SceneScriptObjectField) -> Bool? {
        owned.contains(field) ? values[field.offset] != 0 : nil
    }
}

/// A set of `SceneScriptObjectField`s (48 of them, at most 64), as a bit mask.
struct SceneScriptOwnedFields: Equatable {
    private(set) var bits: UInt64 = 0

    private static let indices: [SceneScriptObjectField: Int] = {
        Dictionary(uniqueKeysWithValues: SceneScriptObjectField.allCases.enumerated().map { ($0.element, $0.offset) })
    }()

    /// The field's bit in `bits`.
    static func bit(_ field: SceneScriptObjectField) -> UInt64 {
        indices[field].map { 1 << UInt64($0) } ?? 0
    }

    func contains(_ field: SceneScriptObjectField) -> Bool {
        bits & Self.bit(field) != 0
    }

    mutating func insert(_ field: SceneScriptObjectField) {
        bits |= Self.bit(field)
    }

    /// Hot paths keep a field's bit (`bit(_:)`) instead of looking it up.
    func contains(bit: UInt64) -> Bool { bits & bit != 0 }

    mutating func insert(bit: UInt64) { bits |= bit }

    var isEmpty: Bool { bits == 0 }
}

/// One `setMaterialProperty` a script made (plan §4.3): what the renderer writes into every pass
/// uniform bound to `name`.
struct SceneScriptConstantWrite: Equatable {
    /// The material (pass) index, or nil for every material of the effect.
    var material: Int?
    /// The scene.json constant key (`constantshadervalues`), matched like the loader matches it.
    var name: String
    var value: [Float]
    /// Materials an effect-wide write (`material` nil) no longer reaches: those whose constant a
    /// timeline drives, where the write held for its frame only.
    var excluded: [Int] = []

    /// Whether the write reaches material (pass) `index`.
    func reaches(material index: Int) -> Bool {
        material.map { $0 == index } ?? !excluded.contains(index)
    }

    /// Whether the write is to constant `name` (as the renderer matches it, ignoring case) of
    /// material `index`.
    func targets(_ name: String, material index: Int) -> Bool {
        reaches(material: index) && self.name.lowercased() == name.lowercased()
    }
}

/// The scene's own settings scripts wrote (`thisScene.bloomstrength`, `camerashake`, …).
struct SceneScriptSceneState: Equatable {
    var owned = Set<SceneScriptSceneField>()
    /// The scene buffer (`SceneScriptSceneField.offset`).
    var values: [Float] = Array(repeating: 0, count: SceneScriptSceneField.Layout.stride)

    func scalar(_ field: SceneScriptSceneField) -> Float? {
        owned.contains(field) ? values[field.offset] : nil
    }

    func flag(_ field: SceneScriptSceneField) -> Bool? {
        owned.contains(field) ? values[field.offset] != 0 : nil
    }

    func vector3(_ field: SceneScriptSceneField) -> SIMD3<Float>? {
        guard owned.contains(field) else { return nil }
        return SIMD3(values[field.offset], values[field.offset + 1], values[field.offset + 2])
    }
}

/// Everything scripts left after a frame, handed from the script thread to the renderer.
struct SceneScriptFrameState {
    /// Objects scripts touched, by scene.json id (and the ids `createLayer` layers got).
    var objects: [Int: SceneScriptObjectState] = [:]
    var scene = SceneScriptSceneState()
    /// Every object in draw order, bottom first, once scripts created, sorted or destroyed any;
    /// nil while the scene's own order stands.
    var order: [Int]?
    /// The watchdog stopped the scripts (plan §1.9 P5): they never run again for this wallpaper.
    var halted = false
}

/// A structural change the renderer applies once (the rest of `SceneScriptFrameState` is state).
enum SceneScriptRenderEvent {
    /// `thisScene.createLayer`: build and draw this object (scene.json form, `id` set).
    case create(id: Int, object: [String: SceneJSON])
    /// `thisScene.destroyLayer`: stop drawing it and free its GPU state after the frame.
    case destroy(id: Int)
    /// `ILayer.setParent`: object `id` now hangs from `parentID` (nil: a root), from the parent's
    /// attachment named `attachment` when set.
    case setParent(id: Int, parentID: Int?, attachment: String?)
    /// `IParticleSystem.emitParticles(count)`.
    case emit(id: Int, count: Int?)
    /// `IEffect.executeMaterialFunction(name)` on effect `effect` (its index in the object's
    /// `effects`) of object `id`: runs effect.json's function `name` once.
    case materialFunction(id: Int, effect: Int, name: String)
    /// `ISoundLayer.play()`, `pause()`, `stop()`.
    case sound(id: Int, SceneScriptObjectCommand.Playback)
    /// What a script's `IAnimation` calls left of a timeline's clock (`SceneAnimationSet.restore`),
    /// in the script frame that saw the set's frame `frame` (`SceneScriptFrameInput.animationFrame`).
    /// An event, not state, so a frame's calls are never lost to a later frame's; the set replays
    /// the advances made since `frame`, so a script frame that overran the draw loses none.
    case animation(SceneAnimationSite, time: Float, flags: SceneTimelineClock.Flags, rate: Float, frame: UInt64)
    /// What a script's `ITextureAnimation` calls left of layer `id`'s override, in the script
    /// frame that saw the set's frame `frame`.
    case textureAnimation(id: Int, SceneTextureAnimationControl, frame: UInt64)
    /// A script's call on puppet image `id`'s animation layers or bones, in call order.
    case rig(id: Int, SceneScriptRigCommand)
    /// `IVideoTexture` calls on image `id`'s video texture, in call order.
    case video(id: Int, SceneVideoTextureCommand)
}
