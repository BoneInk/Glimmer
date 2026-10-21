import Foundation
import JavaScriptCore

/// The SceneScript object model (docs/scenescript-plan.md WP7): `thisScene`, the layers and their
/// effects, materials and animations as live JS objects over shared memory, and `thisLayer` /
/// `thisObject` for each script. A `SceneScriptRuntimeExtension`, one per runtime.
///
/// - Numeric members read and write `store`'s buffers directly; the renderer reads them after the
///   frame (dirty bytes mark script writes).
/// - Native actions (create, destroy, sort, strings, material writes, playback, animations) go
///   through the command ring as opcodes 400–999 and reach `host` as `SceneScriptObjectCommand`s.
/// - `createLayer` describes the new layer synchronously through the host, so the script gets a
///   live layer at once; the host materializes it when the `.create` command arrives.
final class SceneScriptObjectModel: SceneScriptRuntimeExtension {
    let scriptResources = ["objects-values", "objects-animations", "objects-effects", "objects-layers",
                           "objects-transforms", "objects-scene", "objects-modeldata"]

    /// `emitParticles(count)` never asks for more than this at once (objects-layers.js clamps to
    /// the same); the renderer still caps it to the system's own maximum.
    static let maximumEmitCount = 1_000_000
    /// Draw-order, effect and material indices beyond this address nothing.
    private static let maximumIndex = Int(Int32.max)

    private weak var host: SceneScriptObjectHost?
    /// The geometry `thisScene.createModelData` makes (`objects-modeldata.js`), shared with the
    /// loader and the renderer of this wallpaper instance.
    let modelData: SceneScriptModelDataStore
    private weak var runtime: SceneScriptRuntime?
    private let capacity: SceneScriptObjectStore.Capacity
    private(set) var store: SceneScriptObjectStore?
    private var pendingSources: [Int: SceneScriptLayerSource] = [:]
    private var reportedFull = false
    private var reportedInvalid = Set<Int32>()

    init(host: SceneScriptObjectHost, capacity: SceneScriptObjectStore.Capacity = .standard,
         modelData: SceneScriptModelDataStore = SceneScriptModelDataStore()) {
        self.host = host
        self.capacity = capacity
        self.modelData = modelData
    }

    func install(into runtime: SceneScriptRuntime) throws {
        guard let store = SceneScriptObjectStore(capacity: capacity, in: runtime.context) else {
            throw SceneScriptRuntime.CreationError(description: "the object table could not be allocated")
        }
        self.store = store
        self.runtime = runtime
        store.sharedBuffers.forEach(runtime.watch)
        store.table.install(on: runtime.rt)
        registerCommands(on: runtime.commandRing)

        let context = runtime.context
        guard let native = runtime.rt.forProperty("native"), let objects = JSValue(newObjectIn: context) else {
            throw SceneScriptRuntime.CreationError(description: "__rt.native is missing")
        }
        objects.setValue(SceneScriptObjectField.javaScriptObject, forProperty: "fields")
        objects.setValue(SceneScriptSceneField.javaScriptObject, forProperty: "sceneFields")
        objects.setValue(SceneScriptCommandRing.Opcode.objectModelOpcodes.mapValues { Int($0.rawValue) },
                         forProperty: "opcodes")
        objects.setValue(store.effects.javaScriptObject(in: context), forProperty: "effects")
        objects.setValue(store.constants.javaScriptObject(in: context), forProperty: "constants")
        objects.setValue(store.animations.javaScriptObject(in: context), forProperty: "animations")
        objects.setValue(store.scene.javaScriptObject(in: context), forProperty: "scene")
        typealias Layout = SceneScriptObjectStore.AnimationLayout
        typealias Flags = SceneScriptObjectStore.AnimationFlags
        objects.setValue(["rate": Layout.rate, "frame": Layout.frame, "playing": Layout.playing, "flags": Layout.flags,
                          "time": Layout.time, "sharedFrame": Layout.sharedFrame, "sharedTime": Layout.sharedTime,
                          "paused": Flags.paused, "finished": Flags.finished, "backwards": Flags.backwards,
                          "overridden": Flags.overridden],
                         forProperty: "animationLayout")
        objects.setValue(store.rigs.javaScriptObject(in: context), forProperty: "rigs")
        objects.setValue(SceneScriptRigLayout.javaScriptObject, forProperty: "rigLayout")
        objects.setValue(initialScene(store), forProperty: "initial")
        installNativeFunctions(on: objects)
        native.setValue(objects, forProperty: "objects")
    }

    /// Sets what `thisObject` is for `scriptID` (and which property `getAnimation()` defaults to).
    /// Call before the `load` that defines the script. Without a binding, `thisObject` is the
    /// script's layer, or the scene for scripts without one. `SceneScriptInstance.binding` does the
    /// same when the instance is added; it wins over this.
    func bind(scriptID: String, to binding: SceneScriptObjectBinding) {
        guard let objects = runtime?.rt.forProperty("objects") else { return }
        objects.invokeMethod("bind", withArguments: [scriptID, binding.javaScriptObject])
    }

    /// The object table slot of the layer with scene.json id `id`.
    func slot(forObjectID id: Int) -> Int? {
        guard let value = runtime?.rt.forProperty("objects")?.invokeMethod("slotForID", withArguments: [id]),
              value.isNumber else { return nil }
        let slot = Int(value.toInt32())
        return slot >= 0 ? slot : nil
    }

    /// The scene.json id of the live layer in `slot` (a `createLayer` layer's is the id its
    /// description gave it).
    func objectID(forSlot slot: Int) -> Int? {
        guard let layer = runtime?.rt.forProperty("objects")?.invokeMethod("layerForSlot", withArguments: [slot]),
              layer.isObject, let id = layer.forProperty("_id"), id.isNumber else { return nil }
        return SceneScriptNumber.index(id.toDouble(), in: -(1 << 53)...(1 << 53))
    }

    // MARK: - Native functions

    private func initialScene(_ store: SceneScriptObjectStore) -> [String: Any] {
        guard let description = host?.sceneScriptScene() else { return ["objects": [], "animations": []] }
        var records: [[String: Any]] = []
        for object in description.objects {
            if let record = store.place(object) {
                records.append(record)
            } else {
                reportFull(object.name)
            }
        }
        let animations = store.placeScene(settings: description.settings, animations: description.animations)
        return ["objects": records, "animations": animations]
    }

    private func installNativeFunctions(on objects: JSValue) {
        let create: @convention(block) (String, String, Int32, String) -> Any = { [weak self] kind, payload, sourceSlot, workshopID in
            self?.createLayer(kind: kind, payload: payload, sourceSlot: Int(sourceSlot), workshopID: workshopID) ?? NSNull()
        }
        objects.setValue(create, forProperty: "create")
        installModelDataFunctions(on: objects)
    }

    /// `thisScene.createLayer`: describes and places the layer now, materializes it on `.create`.
    /// `workshopID` is the calling script's `__workshopId` ("" without one).
    private func createLayer(kind: String, payload: String, sourceSlot: Int, workshopID: String) -> Any {
        guard let store, let host else { return NSNull() }
        let source: SceneScriptLayerSource
        switch kind {
        case "asset": source = .asset(payload, workshopID: workshopID.isEmpty ? nil : workshopID)
        case "configuration": source = .configuration(json: payload)
        case "copy":
            guard store.isLive(sourceSlot) else { return NSNull() }
            source = .copy(slot: sourceSlot)
        default: return NSNull()
        }
        guard let description = host.sceneScriptDescribeLayer(source) else {
            OWELog.error(.script, "\(runtime?.identity.wallpaperID ?? ""): createLayer could not make a layer from \(source)")
            return NSNull()
        }
        guard let record = store.place(description), let slot = record["slot"] as? Int else {
            reportFull(description.name)
            return NSNull()
        }
        pendingSources[slot] = source
        return record
    }

    private func reportFull(_ name: String) {
        guard !reportedFull else { return }
        reportedFull = true
        OWELog.error(.script, "\(runtime?.identity.wallpaperID ?? ""): the SceneScript object table is full; "
                     + "'\(name)' and later layers are not scriptable")
    }

    // MARK: - Commands

    private func registerCommands(on ring: SceneScriptCommandRing) {
        for opcode in SceneScriptCommandRing.Opcode.objectModelOpcodes.values {
            ring.register(opcode) { [weak self] command in self?.execute(command) }
        }
    }

    private func execute(_ ringCommand: SceneScriptCommandRing.Command) {
        guard let store, let command = decode(ringCommand, store: store) else {
            if reportedInvalid.insert(ringCommand.opcode.rawValue).inserted {
                OWELog.error(.script, "SceneScript command \(ringCommand.opcode.rawValue) for target "
                             + "\(ringCommand.target) is malformed or targets no live object; dropped")
            }
            return
        }
        host?.sceneScriptPerform(command)
        if case .destroy(let slot) = command {
            pendingSources[slot] = nil
            store.release(slot: slot)
        }
    }

    private func decode(_ command: SceneScriptCommandRing.Command, store: SceneScriptObjectStore) -> SceneScriptObjectCommand? {
        typealias Opcode = SceneScriptCommandRing.Opcode
        let target = Int(command.target)
        let numbers = command.numbers
        if [Opcode.animationPlay, .animationPause, .animationStop, .animationSetFrame, .animationJoin]
            .contains(command.opcode) {
            guard let reference = store.animationReferences[target] else { return nil }
            switch command.opcode {
            case .animationPlay: return .animation(reference, .play)
            case .animationPause: return .animation(reference, .pause)
            case .animationStop: return .animation(reference, .stop)
            case .animationJoin: return .animation(reference, .join)
            default:
                guard let frame = numbers.first, frame.isFinite else { return nil }
                return .animation(reference, .setFrame(Double(frame)))
            }
        }
        guard store.isLive(target) else { return nil }
        // Ring numbers are whatever scripts pushed (NaN, ±Infinity, 1e39 → inf after Float32):
        // every integer goes through SceneScriptNumber, and a command with an unusable one is dropped.
        switch command.opcode {
        case .objectCreate:
            guard let source = pendingSources[target] else { return nil }
            return .create(slot: target, source: source)
        case .objectDestroy: return .destroy(slot: target)
        case .objectSort:
            guard let number = numbers.first,
                  let index = SceneScriptNumber.integer(number, clampedTo: 0...Self.maximumIndex) else { return nil }
            return .sort(slot: target, index: index)
        case .objectSetString:
            guard command.strings.count == 2, let field = SceneScriptStringField(rawValue: command.strings[0]) else {
                return nil
            }
            return .setString(slot: target, field: field, value: command.strings[1])
        case .objectSetParent:
            guard let number = numbers.first else {
                return .setParent(slot: target, parent: nil, attachment: nil)
            }
            guard let parent = SceneScriptNumber.index(number, in: 0...Self.maximumIndex), parent != target,
                  store.isLive(parent) else { return nil }
            let attachment = command.strings.first.flatMap { $0.isEmpty ? nil : $0 }
            return .setParent(slot: target, parent: parent, attachment: attachment)
        case .materialSetProperty:
            guard numbers.count >= 3, let name = command.strings.first,
                  let effect = SceneScriptNumber.index(numbers[0], in: 0...Self.maximumIndex),
                  let material = SceneScriptNumber.index(numbers[1], in: -1...Self.maximumIndex) else { return nil }
            return .setMaterialProperty(slot: target, effect: effect, material: material < 0 ? nil : material,
                                        name: name, value: Array(numbers.dropFirst(2)))
        case .materialSetConstant:
            guard numbers.count >= 4,
                  let effect = SceneScriptNumber.index(numbers[0], in: 0...Self.maximumIndex),
                  let material = SceneScriptNumber.index(numbers[1], in: -1...Self.maximumIndex),
                  let offset = SceneScriptNumber.index(numbers[2], in: 0...Int(Int32.max)),
                  let name = store.constantNames[offset] else { return nil }
            return .setMaterialProperty(slot: target, effect: effect, material: material < 0 ? nil : material,
                                        name: name, value: Array(numbers.dropFirst(3)))
        case .materialExecuteFunction:
            guard let number = numbers.first, let name = command.strings.first,
                  let effect = SceneScriptNumber.index(number, in: 0...Self.maximumIndex) else { return nil }
            return .executeMaterialFunction(slot: target, effect: effect, name: name)
        case .videoTexture:
            return SceneVideoTextureCommand(numbers: numbers).map { .video(slot: target, $0) }
        case .soundPlay: return .sound(slot: target, .play)
        case .soundPause: return .sound(slot: target, .pause)
        case .soundStop: return .sound(slot: target, .stop)
        case .particlesPlay: return .particles(slot: target, .play)
        case .particlesPause: return .particles(slot: target, .pause)
        case .particlesStop: return .particles(slot: target, .stop)
        case .particlesEmit:
            guard let number = numbers.first else { return .emitParticles(slot: target, count: nil) }
            guard let count = SceneScriptNumber.integer(number, clampedTo: 0...Self.maximumEmitCount) else { return nil }
            return .emitParticles(slot: target, count: count)
        case .rigLayerCreate, .rigLayerDestroy, .rigLayerSet, .rigLayerPlayback, .rigBoneLocal, .rigBoneWorld, .rigBlendShape,
             .rigBonePhysicsImpulse, .rigBonePhysicsReset:
            guard store.rigSlot(of: target) != nil else { return nil }
            return SceneScriptRigLayout.decode(command.opcode, numbers: numbers, strings: command.strings)
                .map { .rig(slot: target, $0) }
        default: return nil
        }
    }
}
