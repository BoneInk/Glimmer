import Foundation

extension SceneEditOverlay {
    /// The key an effect gets in a scene applied for the editor's outline (`apply(to:markingEffectKeys:)`):
    /// the edit key it is changed by. Never written into a scene the renderer or a saved copy reads.
    static let effectKeyMarker = "__oweEditorEffectKey"

    /// scene.json with the scene edits applied; `sceneData` itself when there are none.
    public func applied(to sceneData: Data) throws -> Data {
        guard hasSceneEdits else { return sceneData }
        guard var root = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any] else {
            throw SceneEditOverlayError.notAScene
        }
        try apply(to: &root)
        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Applies the scene edits to a decoded scene.json. An object or effect an edit names that the
    /// scene no longer has is skipped: the wallpaper was updated under the edits.
    public func apply(to root: inout [String: Any]) throws {
        try apply(to: &root, markingEffectKeys: false)
    }

    /// `markingEffectKeys`: every effect carries its edit key (`effectKeyMarker`), for the outline.
    func apply(to root: inout [String: Any], markingEffectKeys: Bool) throws {
        guard var objects = root["objects"] as? [[String: Any]] else { throw SceneEditOverlayError.notAScene }
        if let general, !general.isEmpty {
            var settings = root["general"] as? [String: Any] ?? [:]
            for (name, value) in general {
                // A user-bound or scripted setting keeps its driver; the edit is its value.
                settings[name] = Self.merged(settings[name], with: value.any)
            }
            root["general"] = settings
        }
        if hasStructureEdits {
            // Added, deleted or moved layers would shift the index an object without an id is
            // known by: it keeps that index as its id.
            for index in objects.indices where objects[index]["id"] == nil { objects[index]["id"] = index }
            var taken = Set(objects.enumerated().map { SceneObjects.objectID($1, index: $0) })
            for added in added ?? [] {
                guard case .object = added.object, var object = added.object.any as? [String: Any],
                      taken.insert(added.id).inserted else { continue }
                object["id"] = added.id
                objects.append(object)
            }
        }
        // The particle systems the editor added, after the scene's own (each has its id).
        if let particles { objects += particles.addedObjectDictionaries }
        // Scripts and bindings first (added layers included): a value edit of a field they drive
        // is its start value.
        if let authoring {
            root["objects"] = objects
            authoring.applyDrivers(to: &root)
            objects = root["objects"] as? [[String: Any]] ?? objects
        }
        for index in objects.indices {
            let objectID = SceneObjects.objectID(objects[index], index: index)
            let edit = self.objects[String(objectID)]
            if let edit, edit.hasSceneEdits {
                for (name, value) in edit.fields {
                    // Null drops the field (a layer taken out of its group loses `parent`).
                    if value == .null {
                        objects[index].removeValue(forKey: name)
                    } else if name == "visible", value == .bool(false), Self.isUserBound(objects[index][name]) {
                        // Hidden by hand over the user property that shows it
                        // (`SceneEditSession.setVisible`). WE reads a bound `visible` from the
                        // property, its `value` only while the property has none, so the one way
                        // to keep it hidden is a plain `false`.
                        objects[index][name] = false
                    } else {
                        objects[index][name] = Self.merged(objects[index][name], with: value.any)
                    }
                }
            }
            guard edit?.hasSceneEdits == true || markingEffectKeys else { continue }
            Self.applyEffects(edit ?? ObjectEdit(), to: &objects[index], markingKeys: markingEffectKeys)
        }
        particles?.removeDeleted(from: &objects)
        if let removed, !removed.isEmpty {
            let gone = Set(removed)
            objects = objects.enumerated()
                .filter { !gone.contains(SceneObjects.objectID($1, index: $0)) }
                .map(\.element)
        }
        if let order { objects = Self.ordered(objects, by: order) }
        timelines?.apply(to: &objects)
        root["objects"] = objects
    }

    /// `objects` in `order` (by id); an object the order doesn't name keeps its place after the
    /// object it followed (one the wallpaper gained since the edit).
    static func ordered(_ objects: [[String: Any]], by order: [Int]) -> [[String: Any]] {
        var position: [Int: Int] = [:]
        for (index, id) in order.enumerated() where position[id] == nil { position[id] = index }
        let ids: [Int] = objects.enumerated().map { SceneObjects.objectID($1, index: $0) }
        var result: [[String: Any]] = []
        var unplaced: [(after: Int?, object: [String: Any])] = []
        var previous: Int?
        for (object, id) in zip(objects, ids) {
            if position[id] == nil { unplaced.append((previous, object)) } else { previous = id }
        }
        let placed: [(object: [String: Any], id: Int)] = zip(objects, ids)
            .filter { position[$0.1] != nil }
            .sorted { position[$0.1]! < position[$1.1]! }
            .map { (object: $0.0, id: $0.1) }
        for object in unplaced where object.after == nil { result.append(object.object) }
        for (object, id) in placed {
            result.append(object)
            for follower in unplaced where follower.after == id { result.append(follower.object) }
        }
        return result
    }

    /// The object's effects as edited: added and removed, in their order, each with its edit.
    static func applyEffects(_ edit: ObjectEdit, to object: inout [String: Any], markingKeys: Bool) {
        let authored = object["effects"] as? [[String: Any]] ?? []
        guard !authored.isEmpty || !(edit.addedEffects ?? [:]).isEmpty || markingKeys else { return }
        var byKey: [String: [String: Any]] = [:]
        for (index, effect) in authored.enumerated() { byKey[String(index)] = effect }
        for (key, value) in edit.addedEffects ?? [:] {
            if let effect = value.any as? [String: Any] { byKey[key] = effect }
        }
        for (key, effectEdit) in edit.effects {
            guard var effect = byKey[key] else { continue }
            apply(effectEdit, to: &effect)
            byKey[key] = effect
        }
        let keys = edit.effectOrder ?? defaultEffectOrder(authoredCount: authored.count, added: edit.addedEffects)
        var effects: [[String: Any]] = []
        for key in keys {
            guard var effect = byKey[key] else { continue }
            if markingKeys { effect[effectKeyMarker] = key }
            effects.append(effect)
        }
        if effects.isEmpty && object["effects"] == nil { return }
        object["effects"] = effects
    }

    /// The authored effects in their order, then the added ones in the order they were added.
    static func defaultEffectOrder(authoredCount: Int, added: [String: SceneJSONValue]?) -> [String] {
        (0..<authoredCount).map(String.init) + addedKeysInOrder(added)
    }

    static func addedKeysInOrder(_ added: [String: SceneJSONValue]?) -> [String] {
        (added ?? [:]).keys.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
    }

    /// One effect's edit: `visible`, its first pass's constants, combos and bindings, and its
    /// passes' textures.
    static func apply(_ edit: EffectEdit, to effect: inout [String: Any]) {
        if let visible = edit.visible {
            effect["visible"] = merged(effect["visible"], with: visible)
        }
        let bindings = edit.bindings ?? [:], combos = edit.combos ?? [:], textures = edit.textures ?? [:]
        guard !edit.constants.isEmpty || !bindings.isEmpty || !combos.isEmpty || !textures.isEmpty else { return }
        var passes = effect["passes"] as? [[String: Any]] ?? []
        if passes.isEmpty { passes = [[:]] }
        var pass = passes[0]
        // A scene effect's pass keeps its constants in `constantshadervalues`, the only key WE and
        // the renderer read (`WEObjectEffectPass`).
        let constantsKey = "constantshadervalues"
        var constants = pass[constantsKey] as? [String: Any] ?? [:]
        for (constant, value) in edit.constants {
            // WE's keys are matched without case (`SceneEffectPlanBuilder`); keep the authored spelling.
            let key = authoredKey(constant, in: constants)
            constants[key] = merged(constants[key], with: value.any)
        }
        for (constant, property) in bindings {
            let key = authoredKey(constant, in: constants)
            let literal = SceneFieldBinding.literal(of: SceneJSONValue(any: constants[key]))
            if property.isEmpty {
                constants[key] = literal?.any
            } else {
                var bound: [String: Any] = ["user": property]
                if let literal { bound["value"] = literal.any }
                constants[key] = bound
            }
        }
        if !constants.isEmpty || pass[constantsKey] != nil { pass[constantsKey] = constants }
        if !combos.isEmpty {
            var passCombos = pass["combos"] as? [String: Any] ?? [:]
            for (combo, value) in combos { passCombos[authoredKey(combo, in: passCombos)] = value }
            pass["combos"] = passCombos
        }
        passes[0] = pass
        for (key, value) in textures {
            guard let (index, slot) = EffectEdit.passAndSlot(key), (0..<32).contains(slot), index < 64 else { continue }
            while passes.count <= index { passes.append([:]) }
            var slots = passes[index]["textures"] as? [Any] ?? []
            while slots.count <= slot { slots.append(NSNull()) }
            slots[slot] = value.any
            passes[index]["textures"] = slots
        }
        effect["passes"] = passes
    }

    /// `{"user": …}` (with or without a `value`).
    static func isUserBound(_ value: Any?) -> Bool {
        (value as? [String: Any])?["user"] != nil
    }

    static func authoredKey(_ key: String, in dictionary: [String: Any]) -> String {
        dictionary.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
    }

    /// An edit of a field the scene drives (a script or an animation) sets its starting `value`
    /// and keeps the driver; any other edit replaces the field. An edit that is itself a binding
    /// (`{"user": …}`, a script or an animation) replaces the field whole; one of those set to null
    /// drops it (`{"value": "x", "script": null}` takes a text layer's script away).
    static func merged(_ existing: Any?, with value: Any) -> Any {
        if let replacing = value as? [String: Any],
           replacing["user"] != nil || replacing["script"] != nil || replacing["animation"] != nil {
            return replacing.filter { !($0.value is NSNull) }
        }
        guard var object = existing as? [String: Any],
              object["script"] != nil || object["animation"] != nil || object["value"] != nil || object["user"] != nil else {
            return value
        }
        object["value"] = value
        return object
    }
}
