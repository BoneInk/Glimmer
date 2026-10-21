import Foundation
import simd

/// The script thread's view of one wallpaper instance's scene (docs/scenescript-plan.md WP11): it
/// is the `SceneScriptObjectHost` the object model talks to, keeps which object sits in which
/// table slot and the draw order, turns script commands into render state and events, and reads
/// the tables back after each frame. Confined to the script thread; the renderer only ever sees
/// the `SceneScriptFrameState` and events it hands over.
final class SceneScriptSceneMirror: SceneScriptObjectHost {
    private struct Object {
        var id: Int
        var kind: SceneScriptObjectDescription.Kind
        var parentID: Int?
        var disablesPropagation: Bool
        /// Its effects' slots in the effect buffer, in effect order.
        var effectSlots: [Int]
        /// A model's box and a model's or puppet's hit boxes, for the cursor pass.
        var cursorShape: SceneScriptCursorShape?
    }

    /// What an animation slot shows scripts: a timeline of the instance's `SceneAnimationSet`, or
    /// an image layer's texture animation.
    private enum AnimationTarget {
        case timeline(SceneAnimationSite)
        case texture(objectID: Int)
    }

    let describer: SceneScriptSceneDescriber
    private let description: SceneScriptSceneDescription
    /// Authored configurations by object id, for `createLayer(layer)` copies.
    private var configurations: [Int: [String: SceneJSON]] = [:]
    /// Layers `createLayer` described, waiting for their `.create` command.
    private var described: [Int: (description: SceneScriptObjectDescription, json: [String: SceneJSON])] = [:]
    private var nextCreatedID = SceneScriptSceneDescriber.firstCreatedID

    private weak var model: SceneScriptObjectModel?
    private var sync: SceneScriptTableSync?
    private var objects: [Int: Object] = [:]
    private var slotsByID: [Int: Int] = [:]
    /// Every live slot in draw order, bottom first, as `objects-scene.js` keeps `objects.order`.
    private var order: [Int] = []
    private var orderChanged = false
    /// Every placed animation slot and what it shows, in slot order; rebuilt when objects come and go.
    private var animationTargets: [(slot: Int, target: AnimationTarget)] = []
    /// The slot of each timeline site, for its events.
    private var animationSlots: [SceneAnimationSite: Int] = [:]
    /// Material constants a timeline drives: the site, the constant's owner and its pool range.
    private var animatedConstants: [(site: SceneAnimationSite, objectID: Int, effect: Int, material: Int,
                                     range: SceneScriptObjectStore.PoolRange)] = []
    /// The scene's settings a timeline drives (numbers and vectors: WE's setter skips a bool).
    private var animatedSettings: [(site: SceneAnimationSite, field: SceneScriptSceneField)] = []
    private var animationTargetsValid = false
    /// The set's frame the animation slots were last published for (`animationFrame`).
    private var publishedAnimationFrame: UInt64 = 0
    /// The image, text and model layers in draw order, for the cursor pass; rebuilt with the order.
    private var hitTestable: [SceneScriptCursorLayer.TableEntry] = []
    private var hitTestableValid = false
    private let rigs = SceneScriptRigMirror()

    private(set) var state = SceneScriptFrameState()
    private(set) var events: [SceneScriptRenderEvent] = []

    init(document: SceneJSON, describer: SceneScriptSceneDescriber) {
        self.describer = describer
        description = describer.scene(document)
        for (index, fields) in SceneScriptSceneDescriber.objects(of: document).enumerated() {
            configurations[SceneScriptSceneDescriber.objectID(fields, index: index)] = fields
        }
    }

    /// Once the object model placed the scene: learns every object's slot.
    func attach(to model: SceneScriptObjectModel) {
        self.model = model
        guard let store = model.store else { return }
        let sync = SceneScriptTableSync(store: store)
        self.sync = sync
        for object in description.objects {
            guard let slot = model.slot(forObjectID: object.id) else { continue }
            register(object, slot: slot, disablesPropagation: configurations[object.id].map(Self.disablesPropagation) ?? false)
            order.append(slot)
            sync.place(slot: slot, description: object)
        }
    }

    func slot(forObjectID id: Int) -> Int? { slotsByID[id] }

    private func register(_ object: SceneScriptObjectDescription, slot: Int, disablesPropagation: Bool) {
        objects[slot] = Object(id: object.id, kind: object.kind, parentID: object.parentID,
                               disablesPropagation: disablesPropagation,
                               effectSlots: model?.store?.effectBufferSlots(of: slot) ?? [],
                               cursorShape: object.cursorShape)
        slotsByID[object.id] = slot
        animationTargetsValid = false
        hitTestableValid = false
    }

    private static func disablesPropagation(_ fields: [String: SceneJSON]) -> Bool {
        if case .bool(let flag)? = fields["disablepropagation"] { return flag }
        return false
    }

    // MARK: - SceneScriptObjectHost

    func sceneScriptScene() -> SceneScriptSceneDescription { description }

    func sceneScriptDescribeLayer(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription? {
        var copying: [String: SceneJSON]?
        if case .copy(let slot) = source, let id = objects[slot]?.id {
            copying = configurations[id] ?? described[id]?.json
        }
        let id = nextCreatedID
        guard let made = describer.layer(source, id: id, copying: copying) else { return nil }
        nextCreatedID += 1
        described[id] = made
        return made.description
    }

    func sceneScriptPerform(_ command: SceneScriptObjectCommand) {
        switch command {
        case .create(let slot, _):
            guard let id = model?.objectID(forSlot: slot), let made = described.removeValue(forKey: id) else { return }
            register(made.description, slot: slot, disablesPropagation: Self.disablesPropagation(made.json))
            configurations[id] = made.json
            order.append(slot)
            orderChanged = true
            sync?.place(slot: slot, description: made.description)
            events.append(.create(id: id, object: made.json))
        case .destroy(let slot):
            guard let object = objects.removeValue(forKey: slot) else { return }
            slotsByID[object.id] = nil
            configurations[object.id] = nil
            order.removeAll { $0 == slot }
            orderChanged = true
            animationTargetsValid = false
            hitTestableValid = false
            state.objects[object.id] = nil
            rigs.forget(objectID: object.id)
            events.append(.destroy(id: object.id))
        case .sort(let slot, let index):
            guard let from = order.firstIndex(of: slot) else { return }
            order.remove(at: from)
            order.insert(slot, at: max(0, min(index, order.count)))
            orderChanged = true
            hitTestableValid = false
        case .setParent(let slot, let parentSlot, let attachment):
            guard var object = objects[slot] else { return }
            let parentID = parentSlot.flatMap { objects[$0]?.id }
            if parentSlot != nil, parentID == nil { return }
            object.parentID = parentID
            objects[slot] = object
            events.append(.setParent(id: object.id, parentID: parentID, attachment: parentID == nil ? nil : attachment))
        case .setString(let slot, let field, let value):
            update(slot) { $0.strings[field] = value }
        case .setMaterialProperty(let slot, let effect, let material, let name, let value):
            update(slot) { object in
                var writes = object.constants[effect] ?? []
                writes.removeAll { $0.material == material && $0.name == name }
                if material == nil { writes.removeAll { $0.name == name } }
                writes.append(SceneScriptConstantWrite(material: material, name: name, value: value))
                object.constants[effect] = writes
                object.effectRevision &+= 1
            }
        case .executeMaterialFunction(let slot, let effect, let name):
            guard let id = objects[slot]?.id else { return }
            events.append(.materialFunction(id: id, effect: effect, name: name))
        case .sound(let slot, let playback):
            guard let id = objects[slot]?.id else { return }
            events.append(.sound(id: id, playback))
        case .video(let slot, let command):
            guard let id = objects[slot]?.id else { return }
            events.append(.video(id: id, command))
        case .particles(let slot, let playback):
            update(slot) { $0.playback = playback }
        case .emitParticles(let slot, let count):
            guard let id = objects[slot]?.id else { return }
            events.append(.emit(id: id, count: count))
        case .animation:
            // `objects-animations.js` already applied the call to the animation buffer, in call
            // order; `readBack` hands the slot's state to the renderer's set.
            break
        case .rig(let slot, let command):
            guard let id = objects[slot]?.id else { return }
            events.append(.rig(id: id, command))
        }
    }

    /// Runs `change` on the render state of the object in `slot`, creating it from the table row.
    private func update(_ slot: Int, _ change: (inout SceneScriptObjectState) -> Void) {
        guard let id = objects[slot]?.id, let store = model?.store else { return }
        var object = state.objects[id] ?? SceneScriptObjectState(values: Self.row(slot, in: store))
        change(&object)
        state.objects[id] = object
    }

    private static func row(_ slot: Int, in store: SceneScriptObjectStore) -> [Float] {
        let base = SceneScriptObjectTable.index(slot: slot, field: 0)
        return (0..<SceneScriptObjectTable.Layout.stride).map { store.table.values[base + $0] }
    }

    // MARK: - Frame

    /// Before a frame: the renderer's values into the table, the timelines' states, the cursor.
    func prepare(_ input: SceneScriptFrameInput, cursor: SceneScriptCursorExtension?) {
        guard let sync else { return }
        for (id, feedback) in input.objects {
            guard let slot = slotsByID[id] else { continue }
            let owned = state.objects[id]?.owned ?? SceneScriptOwnedFields()
            sync.write(feedback, slot: slot, owned: owned)
            // A script-owned field a timeline drives gets the timeline's value back each frame
            // (§2.6): read the row back even if no script writes the object this frame.
            if !feedback.animated.isEmpty, owned.bits & feedback.animated.bits != 0, let store = model?.store {
                store.table.dirty[slot] = 1
            }
        }
        publishAnimations(input)
        if let store = model?.store, !input.rigs.isEmpty {
            rigs.publish(input.rigs, into: store.rigs) { [slotsByID] id in slotsByID[id].flatMap(store.rigSlot(of:)) }
        }
        if let store = model?.store {
            refreshAnimationTargets(store)
            feedAnimatedConstants(input, store: store)
        }
        guard let cursor, let table = model?.store?.table else { return }
        if !hitTestableValid {
            hitTestableValid = true
            hitTestable = order.compactMap { slot -> SceneScriptCursorLayer.TableEntry? in
                guard let object = objects[slot] else { return nil }
                switch object.kind {
                case .image, .text:
                    var order: [Int]?
                    if case .puppet(let bones)? = object.cursorShape?.kind { order = bones }
                    return SceneScriptCursorLayer.TableEntry(slot: slot, disablesPropagation: object.disablesPropagation,
                                                             hitBoxes: order == nil ? [] : object.cursorShape?.hitBoxes ?? [],
                                                             hitBoxOrder: order)
                case .model:
                    // Without model data (a missing `.mdl`, or a script's model data) WE never hits it.
                    var bounds: MDLBounds?
                    if case .model(let box)? = object.cursorShape?.kind { bounds = box }
                    return SceneScriptCursorLayer.TableEntry(slot: slot, disablesPropagation: object.disablesPropagation,
                                                             shape: .model(bounds), hitBoxes: object.cursorShape?.hitBoxes ?? [])
                default:
                    return nil
                }
            }
        }
        let worlds = input.cursorWorlds
        let layers = SceneScriptCursorLayer.layers(in: table, drawOrder: hitTestable, parentOf: { [objects, slotsByID] slot in
            objects[slot]?.parentID.flatMap { slotsByID[$0] }
        }, world: { [objects] slot in
            worlds.isEmpty ? nil : objects[slot].flatMap { worlds[$0.id] }
        }, boneWorlds: { [objects] slot in
            objects[slot].flatMap { input.rigs[$0.id]?.worlds }
        })
        let world = input.cursorScenePosition + input.shakeOffset
        cursor.publish(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(world.x, world.y, 0),
                                              leftButtonDown: input.input.cursorLeftDown,
                                              parallax: input.parallax, ray: input.cursorRay,
                                              viewForward: input.cursorViewForward, layers: layers))
    }

    /// Writes every animation slot's state as the renderer's set left it this frame (the clocks
    /// advanced before the scripts run, §1.9 P1), in `SceneScriptObjectStore.AnimationLayout`.
    /// The slots stay clean: only a script's call marks one dirty.
    private func publishAnimations(_ input: SceneScriptFrameInput) {
        guard let store = model?.store else { return }
        refreshAnimationTargets(store)
        publishedAnimationFrame = input.animationFrame
        typealias Layout = SceneScriptObjectStore.AnimationLayout
        typealias Flags = SceneScriptObjectStore.AnimationFlags
        let buffer = store.animations
        for (slot, target) in animationTargets {
            switch target {
            case .timeline(let site):
                guard let animation = input.animations[site] else { continue }
                var flags = 0
                if animation.flags.contains(.paused) { flags |= Flags.paused }
                if animation.flags.contains(.finished) { flags |= Flags.finished }
                if animation.flags.contains(.reversed) { flags |= Flags.backwards }
                buffer[slot, Layout.rate] = animation.rate
                buffer[slot, Layout.frame] = animation.frame
                buffer[slot, Layout.playing] = animation.isPlaying ? 1 : 0
                buffer[slot, Layout.flags] = Float(flags)
                buffer[slot, Layout.time] = animation.time
            case .texture(let id):
                guard let texture = input.textureAnimations[id] else { continue }
                let control = texture.control
                buffer[slot, Layout.rate] = control.rate
                buffer[slot, Layout.frame] = Float(control.frame)
                buffer[slot, Layout.playing] = control.playing ? 1 : 0
                buffer[slot, Layout.flags] = Float(control.overridden ? Flags.overridden : 0)
                buffer[slot, Layout.time] = control.time
                buffer[slot, Layout.sharedFrame] = Float(texture.sharedFrame)
                buffer[slot, Layout.sharedTime] = texture.sharedTime
            }
        }
    }

    /// The `rigAnimation` inbox events for this frame's puppets and models with clip events or
    /// ended layers, in object order (WE's object loop, 0x1401891a0, walks the scene's objects in
    /// order [I: the slots follow the scene's order]). Objects no script can reach are left out.
    func rigAnimationEvents(_ rigs: [Int: SceneScriptRigFeedback]) -> [SceneScriptEvent] {
        var events: [SceneScriptEvent] = []
        for (id, feedback) in rigs where !feedback.events.isEmpty || !feedback.ended.isEmpty {
            guard let slot = slotsByID[id] else { continue }
            events.append(.rigAnimation(objectSlot: slot, events: feedback.events.map(\.name)))
        }
        events.sort { ($0.target ?? 0) < ($1.target ?? 0) }
        return events
    }

    /// The `animationEvent` inbox events for this frame's timeline events, each for the slot of
    /// its clock owner (docs/timeline-plan.md §3.3). Events of a site no script can reach are dropped.
    func animationEvents(_ events: [SceneAnimationEvent]) -> [SceneScriptEvent] {
        guard !events.isEmpty, let store = model?.store else { return [] }
        refreshAnimationTargets(store)
        return events.compactMap { event in
            animationSlots[event.site].map {
                SceneScriptEvent.animationEvent(animationSlot: $0, name: event.name, frame: Double(event.frame))
            }
        }
    }

    /// Maps each placed animation slot to its site: the record's owner (the scene, a layer, an
    /// effect or a material) and property, as `SceneScriptSceneDescriber` named it.
    private func refreshAnimationTargets(_ store: SceneScriptObjectStore) {
        guard !animationTargetsValid else { return }
        animationTargetsValid = true
        animationTargets.removeAll(keepingCapacity: true)
        animationSlots.removeAll(keepingCapacity: true)
        animatedConstants.removeAll(keepingCapacity: true)
        animatedSettings.removeAll(keepingCapacity: true)
        for slot in store.animationReferences.keys.sorted() {
            guard let reference = store.animationReferences[slot] else { continue }
            let objectID = reference.slot.flatMap { objects[$0]?.id }
            if reference.slot != nil, objectID == nil { continue }
            if reference.isTextureAnimation {
                if let objectID { animationTargets.append((slot, .texture(objectID: objectID))) }
                continue
            }
            guard let property = store.animationDescriptions[slot]?.property,
                  let site = SceneAnimationSite(scriptProperty: property, objectID: objectID,
                                                effect: reference.effect, material: reference.material) else { continue }
            animationTargets.append((slot, .timeline(site)))
            animationSlots[site] = slot
            if case let .material(id, effect, material) = site.owner, let objectSlot = reference.slot,
               let range = store.constantRanges[.init(slot: objectSlot, effect: effect, material: material, name: site.key)] {
                animatedConstants.append((site, id, effect, material, range))
            }
            if site.owner == .scene, let field = SceneScriptSceneField(rawValue: site.key), field.type != .bool,
               !field.isCamera {
                animatedSettings.append((site, field))
            }
        }
    }

    /// The material constants' and scene settings' side of §2.6 (P2): the timeline's setter writes
    /// them every frame before the scripts run, so a bound `update(value)` and every read see the
    /// animated value, and a script's write holds for its frame only (test-risks TF1, TF3).
    private func feedAnimatedConstants(_ input: SceneScriptFrameInput, store: SceneScriptObjectStore) {
        for constant in animatedConstants {
            guard let animation = input.animations[constant.site] else { continue }
            for component in 0..<constant.range.count {
                store.constants[constant.range.offset + component, 0] = animation.value[component]
            }
            guard var object = state.objects[constant.objectID],
                  object.dropConstantWrites(effect: constant.effect, material: constant.material, name: constant.site.key)
            else { continue }
            state.objects[constant.objectID] = object
        }
        for setting in animatedSettings {
            guard let animation = input.animations[setting.site] else { continue }
            sync?.writeScene(setting.field, animation.value)
            state.scene.owned.remove(setting.field)
        }
    }

    /// After a frame: what scripts wrote, into `state`. Returns the state and the events since
    /// the last call.
    func readBack() -> (state: SceneScriptFrameState, events: [SceneScriptRenderEvent]) {
        if let sync, let store = model?.store {
            for (slot, object) in objects {
                let effects = object.effectSlots.isEmpty ? [:] : sync.readEffects(object.effectSlots)
                guard sync.isDirty(slot) else {
                    if !effects.isEmpty { update(slot) { $0.merge(effects: effects) } }
                    continue
                }
                let current = state.objects[object.id]
                let read = sync.read(slot: slot, owned: current?.owned ?? SceneScriptOwnedFields())
                if current == nil, read.owned.isEmpty, effects.isEmpty { continue }
                var updated = current ?? SceneScriptObjectState(values: read.row)
                updated.owned = read.owned
                updated.values = read.row
                updated.merge(effects: effects)
                state.objects[object.id] = updated
            }
            _ = sync.readScene(into: &state.scene)
            store.constants.dirty.pointer.update(repeating: 0, count: store.constants.dirty.count)
            readAnimations(store)
        }
        if orderChanged {
            orderChanged = false
            state.order = order.compactMap { objects[$0]?.id }
        }
        defer { events.removeAll(keepingCapacity: true) }
        return (state, events)
    }

    /// The animation slots scripts called into this frame, as render events: a timeline's time,
    /// run-time flags and rate, or a layer's whole texture override (§3.1, §3.2).
    private func readAnimations(_ store: SceneScriptObjectStore) {
        typealias Layout = SceneScriptObjectStore.AnimationLayout
        typealias Flags = SceneScriptObjectStore.AnimationFlags
        let buffer = store.animations
        refreshAnimationTargets(store)
        for (slot, target) in animationTargets where buffer.dirty[slot] != 0 {
            buffer.dirty[slot] = 0
            let flags = Int(exactly: buffer[slot, Layout.flags]) ?? 0
            switch target {
            case .timeline(let site):
                var clock: SceneTimelineClock.Flags = []
                if flags & Flags.paused != 0 { clock.insert(.paused) }
                if flags & Flags.finished != 0 { clock.insert(.finished) }
                if flags & Flags.backwards != 0 { clock.insert(.reversed) }
                events.append(.animation(site, time: buffer[slot, Layout.time], flags: clock, rate: buffer[slot, Layout.rate],
                                         frame: publishedAnimationFrame))
            case .texture(let id):
                let control = SceneTextureAnimationControl(
                    rate: buffer[slot, Layout.rate], frame: SceneTimelineClock.convertTruncating(buffer[slot, Layout.frame]),
                    time: buffer[slot, Layout.time], playing: buffer[slot, Layout.playing] != 0,
                    overridden: flags & Flags.overridden != 0)
                events.append(.textureAnimation(id: id, control, frame: publishedAnimationFrame))
            }
        }
    }

    func markHalted() {
        state.halted = true
    }
}

private extension SceneScriptObjectState {
    mutating func merge(effects: [Int: Bool]) {
        guard !effects.isEmpty else { return }
        for (index, visible) in effects { effectVisible[index] = visible }
        effectRevision &+= 1
    }
}
