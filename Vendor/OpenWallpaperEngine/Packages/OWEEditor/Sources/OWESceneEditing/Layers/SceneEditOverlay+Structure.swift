import Foundation

/// The overlay's structural edits: layers added, deleted and reordered, effects added, removed and
/// reordered (editor-plan notes §3, phases 2–3).
extension SceneEditOverlay {
    /// What decides the editor's outline (`SceneEditSession.outline`): the structure, the effects'
    /// order, and the fields that name, group or identify a layer. Other edits leave it as it is.
    struct OutlineSignature: Hashable {
        var added: [AddedObject]?
        var removed: [Int]?
        var order: [Int]?
        var objects: [String: ObjectSignature]
        /// The particle editor's added and deleted systems.
        var particleObjects: [SceneJSONValue]?
        var particlesRemoved: [Int]?
        /// The scene's size (`general.orthogonalprojection`), which the outline reads.
        var projection: SceneJSONValue?
    }

    struct ObjectSignature: Hashable {
        var fields: [String: SceneJSONValue]
        var effectOrder: [String]?
        var addedEffects: [String: SceneJSONValue]?
    }

    /// Fields the outline reads beyond values: names, groups, what a layer is.
    static let outlineFields: Set<String> = ["name", "parent", "image", "particle", "sound", "model", "light"]

    var outlineSignature: OutlineSignature {
        var objects: [String: ObjectSignature] = [:]
        for (key, edit) in self.objects {
            let fields = edit.fields.filter { Self.outlineFields.contains($0.key) }
            guard !fields.isEmpty || edit.effectOrder != nil || edit.addedEffects != nil else { continue }
            objects[key] = ObjectSignature(fields: fields, effectOrder: edit.effectOrder, addedEffects: edit.addedEffects)
        }
        return OutlineSignature(added: added, removed: removed, order: order, objects: objects,
                                particleObjects: particles?.addedObjects, particlesRemoved: particles?.removedObjects,
                                projection: general?["orthogonalprojection"])
    }

    /// The structure alone: what layers and effects there are, in which order, without any value edit.
    public var structureOnly: SceneEditOverlay {
        var result = SceneEditOverlay()
        result.added = added
        result.removed = removed
        result.order = order
        // An effect's files change what the scene builds: never drawn live, always read again.
        result.effectFiles = effectFiles
        if let particles, particles.changesObjects {
            result.particles = SceneParticleOverlay(addedObjects: particles.addedObjects,
                                                    removedObjects: particles.removedObjects)
        }
        for (key, edit) in objects where edit.effectOrder != nil || edit.addedEffects != nil {
            var structural = ObjectEdit()
            structural.effectOrder = edit.effectOrder
            structural.addedEffects = edit.addedEffects
            result.objects[key] = structural
        }
        return result
    }

    // MARK: Effects by key

    public func effectEdit(_ key: String, of objectID: Int) -> EffectEdit? {
        objects[String(objectID)]?.effects[key]
    }

    // MARK: Layers

    /// The added layer with `id`.
    public func addedObject(_ id: Int) -> AddedObject? {
        added?.first { $0.id == id }
    }

    /// Adds a layer's scene.json object under `id`, on top of the others unless `order` says.
    mutating func addObject(_ object: SceneJSONValue, id: Int) {
        var list = added ?? []
        list.removeAll { $0.id == id }
        list.append(AddedObject(id: id, object: object))
        added = list
    }

    /// Deletes layers: an added one leaves the overlay with its edits, an authored one is listed
    /// as removed. Their edits go, and the order forgets them.
    mutating func removeObjects(_ ids: Set<Int>) {
        guard !ids.isEmpty else { return }
        var list = added ?? []
        let addedIDs = Set(list.map(\.id))
        list.removeAll { ids.contains($0.id) }
        added = list.isEmpty ? nil : list
        var gone = Set(removed ?? [])
        gone.formUnion(ids.subtracting(addedIDs))
        removed = gone.isEmpty ? nil : gone.sorted()
        for id in ids { objects[String(id)] = nil }
        if let order {
            let kept = order.filter { !ids.contains($0) }
            self.order = kept.isEmpty ? nil : kept
        }
    }
}
