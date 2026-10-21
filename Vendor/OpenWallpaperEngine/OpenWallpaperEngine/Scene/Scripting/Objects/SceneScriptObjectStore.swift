import Foundation
import JavaScriptCore

/// The object model's shared memory and its allocation: the object table, effect visibility,
/// the material-constant pool, animation state and the scene buffer. Places descriptions into
/// slots (writing their values) and turns them into the records `objects-scene.js` builds live
/// objects from. Confined to the runtime's thread.
final class SceneScriptObjectStore {
    struct Capacity {
        var objects = 2048
        var effects = 8192
        var constantFloats = 65536
        var animations = 4096
        /// Puppet rigs (`SceneScriptRigLayout`).
        var rigs = 64

        static let standard = Capacity()
    }

    /// Per-animation floats in `animations` (docs/timeline-plan.md §3). The renderer writes the
    /// clock's state before each script frame; `objects-animations.js` applies WE's API rules to it
    /// in order and marks the slot dirty; the renderer reads a dirty slot back after the frame.
    enum AnimationLayout {
        /// `rate`, any float.
        static let rate = 0
        /// `IAnimation`: `time / frameDuration` in float (what `getFrame()` returns).
        /// `ITextureAnimation`: the override's integer frame.
        static let frame = 1
        /// `IAnimation`: 1 while `isPlaying()`. `ITextureAnimation`: the override's playing flag.
        static let playing = 2
        /// `AnimationFlags` bits.
        static let flags = 3
        /// Seconds: the timeline's time (`IAnimation`), or the override's time in its frame.
        static let time = 4
        /// `ITextureAnimation`: the texture's shared clock (frame, seconds in it), renderer-written.
        static let sharedFrame = 5
        static let sharedTime = 6
        static let stride = 8
    }

    /// The `flags` bits (WE's clock flags 0x20000000, 0x40000000, 0x80000000 and the texture
    /// wrapper's override byte, renumbered to fit a float).
    enum AnimationFlags {
        static let paused = 1
        static let finished = 2
        /// A mirror timeline running backwards.
        static let backwards = 4
        /// `ITextureAnimation`: a script took control from the shared clock.
        static let overridden = 8
    }

    struct PoolRange: Hashable {
        var offset: Int
        var count: Int
    }

    /// A material constant of a placed object: its slot, effect index, material (pass) index and
    /// scene.json key.
    struct ConstantKey: Hashable {
        var slot: Int
        var effect: Int
        var material: Int
        var name: String
    }

    /// What a live object slot holds besides its table row.
    private struct Allocation {
        var effects: [Int] = []
        var constants: [PoolRange] = []
        var constantKeys: [ConstantKey] = []
        var animations: [Int] = []
        var rig: Int?
    }

    let table: SceneScriptObjectTable
    /// One float per effect: `visible`.
    let effects: SceneScriptSlotBuffer
    /// Material constants, each 1…4 consecutive floats.
    let constants: SceneScriptSlotBuffer
    let animations: SceneScriptSlotBuffer
    /// One slot of `SceneScriptSceneField`s; dirty[0] settings, dirty[1] camera.
    let scene: SceneScriptSlotBuffer
    /// One slot per placed puppet rig (`SceneScriptRigLayout`).
    let rigs: SceneScriptSlotBuffer

    private var objectSlots: SceneScriptIndexAllocator
    private var effectSlots: SceneScriptIndexAllocator
    private var animationSlots: SceneScriptIndexAllocator
    private var rigSlots: SceneScriptIndexAllocator
    private var constantTop = 0
    private var freeConstants: [Int: [Int]] = [:]
    private var allocations: [Int: Allocation] = [:]
    private(set) var animationReferences: [Int: SceneScriptAnimationReference] = [:]
    /// What each placed animation was described as (its fps, length and property), by animation slot.
    private(set) var animationDescriptions: [Int: SceneScriptAnimationDescription] = [:]
    /// Each placed material constant's scene.json key, by its offset in the pool, so a write can
    /// name it without a string in the command ring (`materialSetConstant`).
    private(set) var constantNames: [Int: String] = [:]
    /// Each placed material constant's pool range, by its object, effect, material and key.
    private(set) var constantRanges: [ConstantKey: PoolRange] = [:]

    init?(capacity: Capacity, in context: JSContext) {
        guard let table = SceneScriptObjectTable(capacity: capacity.objects, in: context),
              let effects = SceneScriptSlotBuffer(stride: 1, capacity: capacity.effects, in: context),
              let constants = SceneScriptSlotBuffer(stride: 1, capacity: capacity.constantFloats, dirtyCount: 1, in: context),
              let animations = SceneScriptSlotBuffer(stride: AnimationLayout.stride, capacity: capacity.animations,
                                                     in: context),
              let scene = SceneScriptSlotBuffer(stride: SceneScriptSceneField.Layout.stride, capacity: 1,
                                                dirtyCount: SceneScriptSceneField.Layout.dirtyCount, in: context),
              let rigs = SceneScriptSlotBuffer(stride: SceneScriptRigLayout.stride, capacity: capacity.rigs, in: context)
        else { return nil }
        self.table = table
        self.effects = effects
        self.constants = constants
        self.animations = animations
        self.scene = scene
        self.rigs = rigs
        rigSlots = SceneScriptIndexAllocator(capacity: capacity.rigs)
        objectSlots = SceneScriptIndexAllocator(capacity: capacity.objects)
        effectSlots = SceneScriptIndexAllocator(capacity: capacity.effects)
        animationSlots = SceneScriptIndexAllocator(capacity: capacity.animations)
    }

    /// Every buffer scripts can reach, for `SceneScriptRuntime.watch(_:)`.
    var sharedBuffers: [SceneScriptDetachable] {
        table.sharedBuffers + effects.sharedBuffers + constants.sharedBuffers + animations.sharedBuffers
            + scene.sharedBuffers + rigs.sharedBuffers
    }

    /// The rig buffer slot of a live object, when it is a puppet.
    func rigSlot(of slot: Int) -> Int? { allocations[slot]?.rig }

    func isLive(_ slot: Int) -> Bool { allocations[slot] != nil }

    /// The effect-buffer slots of a live object's effects, in effect order.
    func effectBufferSlots(of slot: Int) -> [Int] { allocations[slot]?.effects ?? [] }

    // MARK: - Scene

    /// Writes the scene settings and places the scene-level animations; returns their records.
    func placeScene(settings: [SceneScriptSceneField: [Float]],
                    animations sceneAnimations: [SceneScriptAnimationDescription]) -> [[String: Any]] {
        for field in SceneScriptSceneField.allCases {
            scene.write(settings[field] ?? field.defaultValue, slot: 0, offset: field.offset)
        }
        var ignored = Allocation()
        return sceneAnimations.compactMap {
            place($0, reference: SceneScriptAnimationReference(slot: nil, effect: nil, material: nil, name: $0.name,
                                                                isTextureAnimation: false, animationSlot: -1),
                  into: &ignored)
        }
    }

    // MARK: - Objects

    /// Allocates a slot for `description`, writes its values and returns its JS record, or nil when
    /// a buffer is full (logged by the caller).
    func place(_ description: SceneScriptObjectDescription) -> [String: Any]? {
        guard let slot = objectSlots.take() else { return nil }
        var allocation = Allocation()
        table.reset(slot: slot, with: description.values)
        let reference = SceneScriptAnimationReference(slot: slot, effect: nil, material: nil, name: "",
                                                      isTextureAnimation: false, animationSlot: -1)
        var effectRecords: [[String: Any]] = []
        for (index, effect) in description.effects.enumerated() {
            guard let record = place(effect, index: index, slot: slot, into: &allocation) else {
                release(allocation)
                objectSlots.give(slot)
                return nil
            }
            effectRecords.append(record)
        }
        var textureAnimation: Any = NSNull()
        if let animation = description.textureAnimation {
            var textureReference = reference
            textureReference.isTextureAnimation = true
            guard let record = place(animation, reference: textureReference, into: &allocation) else {
                release(allocation)
                objectSlots.give(slot)
                return nil
            }
            textureAnimation = record
        }
        let animationRecords = description.animations.compactMap { place($0, reference: reference, into: &allocation) }
        var rig: Any = NSNull()
        if let described = description.rig {
            if let rigSlot = rigSlots.take() {
                allocation.rig = rigSlot
                SceneScriptRigLayout.write(described, into: rigs, slot: rigSlot)
                rig = described.javaScriptRecord(slot: rigSlot)
            } else {
                OWELog.error(.script, "The SceneScript rig buffer is full; '\(description.name)' has no bone or animation-layer API")
            }
        }
        allocations[slot] = allocation
        var strings: [String: String] = [:]
        for (field, value) in description.strings where field != .name { strings[field.rawValue] = value }
        return [
            "slot": slot, "kind": description.kind.rawValue, "id": description.id, "name": description.name,
            "parentID": description.parentID.map { $0 as Any } ?? NSNull(), "strings": strings,
            "effects": effectRecords, "textureAnimation": textureAnimation, "animations": animationRecords,
            "config": description.initialConfigurationJSON.map { $0 as Any } ?? NSNull(), "rig": rig,
            "video": description.videoDuration.map { ["duration": $0] as Any } ?? NSNull(),
        ]
    }

    /// Frees everything `slot` holds. The JS object was detached when it was destroyed.
    func release(slot: Int) {
        guard let allocation = allocations.removeValue(forKey: slot) else { return }
        release(allocation)
        table.dirty[slot] = 0
        objectSlots.give(slot)
    }

    private func release(_ allocation: Allocation) {
        allocation.effects.forEach { effectSlots.give($0) }
        allocation.rig.map { rigSlots.give($0) }
        allocation.animations.forEach {
            animationSlots.give($0)
            animationReferences[$0] = nil
            animationDescriptions[$0] = nil
        }
        for range in allocation.constants {
            freeConstants[range.count, default: []].append(range.offset)
            constantNames[range.offset] = nil
        }
        allocation.constantKeys.forEach { constantRanges[$0] = nil }
    }

    private func place(_ effect: SceneScriptObjectDescription.Effect, index: Int, slot: Int,
                       into allocation: inout Allocation) -> [String: Any]? {
        guard let effectSlot = effectSlots.take() else { return nil }
        allocation.effects.append(effectSlot)
        effects[effectSlot, 0] = effect.visible ? 1 : 0
        effects.dirty[effectSlot] = 0
        let reference = SceneScriptAnimationReference(slot: slot, effect: index, material: nil, name: "",
                                                      isTextureAnimation: false, animationSlot: -1)
        var materials: [[String: Any]] = []
        for (materialIndex, material) in effect.materials.enumerated() {
            var constantRecords: [[String: Any]] = []
            for constant in material.constants {
                let count = min(4, max(1, constant.value.count))
                guard let offset = takeConstants(count) else { return nil }
                let range = PoolRange(offset: offset, count: count)
                let key = ConstantKey(slot: slot, effect: index, material: materialIndex, name: constant.name)
                allocation.constants.append(range)
                allocation.constantKeys.append(key)
                constantNames[offset] = constant.name
                constantRanges[key] = range
                var value = constant.value
                while value.count < count { value.append(0) }
                constants.write(Array(value.prefix(count)), slot: offset, offset: 0)
                constantRecords.append(["name": constant.name, "offset": offset, "count": count])
            }
            var materialReference = reference
            materialReference.material = materialIndex
            let animations = material.animations.compactMap { place($0, reference: materialReference, into: &allocation) }
            materials.append(["constants": constantRecords, "animations": animations])
        }
        let animations = effect.animations.compactMap { place($0, reference: reference, into: &allocation) }
        return ["index": index, "slot": effectSlot, "name": effect.name, "materials": materials, "animations": animations]
    }

    private func place(_ animation: SceneScriptAnimationDescription, reference: SceneScriptAnimationReference,
                       into allocation: inout Allocation) -> [String: Any]? {
        guard let animationSlot = animationSlots.take() else { return nil }
        allocation.animations.append(animationSlot)
        // A timeline that isn't playing is paused; a texture's override starts off and playing.
        let flags = reference.isTextureAnimation || animation.playing ? 0 : AnimationFlags.paused
        let time = animation.fps > 0 ? Float(animation.frame / animation.fps) : 0
        animations.write([Float(animation.rate), Float(animation.frame), animation.playing ? 1 : 0, Float(flags), time,
                          Float(animation.frame), 0, 0],
                         slot: animationSlot, offset: 0)
        animations.dirty[animationSlot] = 0
        var placed = reference
        placed.name = animation.name
        placed.animationSlot = animationSlot
        animationReferences[animationSlot] = placed
        animationDescriptions[animationSlot] = animation
        return ["slot": animationSlot, "name": animation.name, "fps": animation.fps,
                "frameCount": animation.frameCount, "duration": animation.duration,
                "property": animation.property.map { $0 as Any } ?? NSNull()]
    }

    private func takeConstants(_ count: Int) -> Int? {
        if var free = freeConstants[count], let offset = free.popLast() {
            freeConstants[count] = free
            return offset
        }
        guard constantTop + count <= constants.capacity else { return nil }
        defer { constantTop += count }
        return constantTop
    }
}

/// Hands out the indices 0..<capacity, lowest first, and takes freed ones back.
struct SceneScriptIndexAllocator {
    let capacity: Int
    private var next = 0
    private var free: [Int] = []

    init(capacity: Int) { self.capacity = capacity }

    mutating func take() -> Int? {
        if let index = free.popLast() { return index }
        guard next < capacity else { return nil }
        defer { next += 1 }
        return next
    }

    mutating func give(_ index: Int) { free.append(index) }
}
