import Foundation

/// Layer structure, as WE's editor changes it: add, duplicate, delete, rename, reorder, group and
/// ungroup, parent and unparent. Each is one undo step; a layer moved to another parent keeps
/// where it is on the scene, as in WE's editor.
extension SceneEditSession {
    // MARK: Reading

    /// The id an added layer gets: above every id the scene and the edits have used.
    public var nextObjectID: Int {
        var ids: [Int] = authored.layers.map(\.id)
        ids += outline.layers.map(\.id)
        ids += (overlay.added ?? []).map(\.id)
        ids += overlay.removed ?? []
        ids += overlay.particles?.removedObjects ?? []
        let addedParticles: [Int] = (overlay.particles?.addedObjects ?? []).compactMap { object in
            object["id"]?.doubleValue.map { Int($0) }
        }
        ids += addedParticles
        return max((ids.max() ?? -1) + 1, authored.layers.count)
    }

    /// The layer and every layer under it, the layer first.
    public func subtree(of layerID: Int) -> [Int] {
        var result = [layerID]
        var index = 0
        while index < result.count {
            for child in outline.children(of: result[index]) where !result.contains(child.id) { result.append(child.id) }
            index += 1
        }
        return result
    }

    /// The layer's own transform as a 2D matrix in its parent's space.
    public func localTransform(of layerID: Int) -> SceneTransform2D { transform(of: layerID).local }

    /// The parents' transforms composed: the layer's parent space to scene space.
    public func parentWorld(of layerID: Int) -> SceneTransform2D {
        var world = SceneTransform2D.identity
        for ancestor in outline.ancestors(of: layerID).reversed() {
            world = world.concatenating(localTransform(of: ancestor.id))
        }
        return world
    }

    public func worldTransform(of layerID: Int) -> SceneTransform2D {
        parentWorld(of: layerID).concatenating(localTransform(of: layerID))
    }

    /// The object as the edited scene has it (its effects included), for copying.
    public func appliedObject(_ layerID: Int) -> [String: Any]? {
        guard let data = authored.sceneData,
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        EditorLog.attempt("Scene edits: applying to layer \(layerID)") { try overlay.apply(to: &root) }
        let objects = root["objects"] as? [[String: Any]] ?? []
        for (index, object) in objects.enumerated() where SceneObjects.objectID(object, index: index) == layerID {
            return object
        }
        return nil
    }

    // MARK: Adding

    /// Adds a layer (its scene.json object, `SceneLayerFactory`) above the selection, or on top,
    /// and selects it. Returns its id.
    @discardableResult
    public func addLayer(_ object: [String: SceneJSONValue], actionName: String) -> Int {
        let id = nextObjectID
        var next = overlay
        var object = object
        object["id"] = nil
        next.addObject(.object(object), id: id)
        if let selected = selection, outline.layer(selected) != nil {
            var order = outline.layers.map(\.id)
            let after = subtree(of: selected).compactMap { order.firstIndex(of: $0) }.max() ?? (order.count - 1)
            order.insert(id, at: min(after + 1, order.count))
            next.order = order
        } else if let order = next.order {
            next.order = order + [id]
        }
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = id
        return id
    }

    /// Adds several layers in one undo step (a preset's objects), in order above the selection, or
    /// on top, and selects the first. Returns their ids.
    @discardableResult
    public func addLayers(_ objects: [[String: SceneJSONValue]], actionName: String) -> [Int] {
        guard !objects.isEmpty else { return [] }
        var next = overlay
        var ids: [Int] = []
        var id = nextObjectID
        for var object in objects {
            object["id"] = nil
            next.addObject(.object(object), id: id)
            ids.append(id)
            id += 1
        }
        if let selected = selection, outline.layer(selected) != nil {
            var order = outline.layers.map(\.id)
            let after = subtree(of: selected).compactMap { order.firstIndex(of: $0) }.max() ?? (order.count - 1)
            order.insert(contentsOf: ids, at: min(after + 1, order.count))
            next.order = order
        } else if let order = next.order {
            next.order = order + ids
        }
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = ids.first
        return ids
    }

    /// Copies of the layers (and the layers under them), placed just above the originals and
    /// selected; a copy's name says it is one.
    @discardableResult
    public func duplicate(_ layerIDs: [Int], copyName: (String) -> String, actionName: String) -> [Int] {
        var next = overlay
        var order = outline.layers.map(\.id)
        var copies: [Int] = []
        var nextID = nextObjectID
        for root in layerIDs where outline.layer(root) != nil {
            let members = subtree(of: root).sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            var mapping: [Int: Int] = [:]
            for member in members { mapping[member] = nextID; nextID += 1 }
            var inserted: [Int] = []
            for member in members {
                guard let applied = appliedObject(member),
                      case .object(var object)? = SceneJSONValue(any: applied) else { continue }
                object["id"] = nil
                if member == root {
                    let name = outline.layer(root).map { $0.name ?? "" } ?? ""
                    object["name"] = .string(copyName(name))
                } else if let parent = object["parent"]?.doubleValue.map(Int.init), let mapped = mapping[parent] {
                    object["parent"] = .number(Double(mapped))
                }
                next.addObject(.object(object), id: mapping[member]!)
                inserted.append(mapping[member]!)
            }
            let after = members.compactMap { order.firstIndex(of: $0) }.max() ?? (order.count - 1)
            order.insert(contentsOf: inserted, at: min(after + 1, order.count))
            if let copy = mapping[root] { copies.append(copy) }
        }
        guard !copies.isEmpty else { return [] }
        next.order = order
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = copies.last
        return copies
    }

    // MARK: Deleting

    /// Deletes the layers and every layer under them.
    public func delete(_ layerIDs: [Int], actionName: String) {
        var ids = Set<Int>()
        for id in layerIDs where outline.layer(id) != nil { ids.formUnion(subtree(of: id)) }
        guard !ids.isEmpty else { return }
        var next = overlay
        next.removeObjects(ids)
        normalizeOrder(&next)
        if let selection, ids.contains(selection) { self.selection = nil }
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    // MARK: Naming

    public func rename(_ layerID: Int, to name: String, actionName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard outline.layer(layerID) != nil else { return }
        setValue(.string(trimmed), for: "name", of: layerID, actionName: actionName)
    }

    // MARK: Order

    /// Moves the layers (each with the layers under it) in the draw order: to just above
    /// `target` (drawn after it), or just below it. Their parents stay.
    public func move(_ layerIDs: [Int], relativeTo target: Int, above: Bool, actionName: String) {
        var order = outline.layers.map(\.id)
        var moving: [Int] = []
        for id in order where layerIDs.contains(where: { subtree(of: $0).contains(id) }) { moving.append(id) }
        guard !moving.isEmpty, !moving.contains(target), order.contains(target) else { return }
        order.removeAll { moving.contains($0) }
        let targetGroup = subtree(of: target)
        let indices = targetGroup.compactMap { order.firstIndex(of: $0) }
        let position = above ? (indices.max() ?? 0) + 1 : (indices.min() ?? 0)
        order.insert(contentsOf: moving, at: min(position, order.count))
        commitOrder(order, actionName: actionName)
    }

    /// One step up (drawn later) or down among its siblings, or to the top or bottom of them.
    public func step(_ layerID: Int, by steps: Int, actionName: String) {
        guard let layer = outline.layer(layerID) else { return }
        let siblings = outline.children(of: layer.parentID.flatMap { outline.layer($0) != nil ? $0 : nil })
        guard let index = siblings.firstIndex(where: { $0.id == layerID }) else { return }
        let target = min(max(index + steps, 0), siblings.count - 1)
        guard target != index else { return }
        move([layerID], relativeTo: siblings[target].id, above: steps > 0, actionName: actionName)
    }

    private func commitOrder(_ order: [Int], actionName: String) {
        var next = overlay
        next.order = order
        normalizeOrder(&next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Drops an order that is the scene's own.
    func normalizeOrder(_ next: inout SceneEditOverlay) {
        guard let order = next.order else { return }
        if order == authoredOrder(of: next) { next.order = nil }
    }

    /// The order the scene has without a reorder: authored layers that remain, then the added ones.
    private func authoredOrder(of overlay: SceneEditOverlay) -> [Int] {
        var structure = overlay.structureOnly
        structure.order = nil
        guard let data = authored.sceneData,
              let outline = EditorLog.attempt("Scene edits: authored order", { try Self.outline(of: data, with: structure) }) else {
            return authored.layers.map(\.id)
        }
        return outline.layers.map(\.id)
    }

    // MARK: Parents

    /// Whether `layerID` can go under `parent`: not under itself or a layer under it.
    public func canParent(_ layerID: Int, to parent: Int?) -> Bool {
        guard let parent else { return outline.layer(layerID)?.parentID != nil }
        return outline.layer(parent) != nil && !subtree(of: layerID).contains(parent)
            && outline.layer(layerID)?.parentID != parent
    }

    /// Puts the layers under `parent` (nil: the top level), keeping where they are on the scene.
    public func setParent(_ layerIDs: [Int], to parent: Int?, actionName: String) {
        var next = overlay
        reparent(layerIDs, to: parent, newParentWorld: parent.map(worldTransform(of:)) ?? .identity, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// A new group at the layers' centre with the layers in it, selected.
    @discardableResult
    public func group(_ layerIDs: [Int], name: String, actionName: String) -> Int? {
        let members = layerIDs.filter { outline.layer($0) != nil }
        guard !members.isEmpty else { return nil }
        // The group goes where the first member's parent is, so the members keep their nesting.
        let parent = outline.layer(members[0])?.parentID.flatMap { outline.layer($0) != nil ? $0 : nil }
        let parentWorld = parent.map(worldTransform(of:)) ?? .identity
        let points = members.map { worldTransform(of: $0).apply(.zero) }
        let centre = points.reduce(SIMD2<Double>.zero, +) / Double(points.count)
        let local = parentWorld.inverted?.apply(centre) ?? centre
        var object = SceneLayerFactory.group(name: name, origin: local)
        if let parent { object["parent"] = .number(Double(parent)) }
        let id = nextObjectID
        var next = overlay
        next.addObject(.object(object), id: id)
        var order = outline.layers.map(\.id)
        let first = members.compactMap { order.firstIndex(of: $0) }.min() ?? order.count
        order.insert(id, at: first)
        next.order = order
        let groupWorld = parentWorld.concatenating(SceneTransform2D.layer(translation: local, rotation: 0, scale: SIMD2(1, 1)))
        reparent(members, to: id, newParentWorld: groupWorld, in: &next, isNewParent: true)
        commit(next, actionName: actionName, coalescingKey: nil)
        selection = id
        return id
    }

    /// Moves the group's layers to its parent, keeping where they are, and deletes the group
    /// when it draws nothing itself.
    public func ungroup(_ groupID: Int, actionName: String) {
        guard let group = outline.layer(groupID) else { return }
        let children = outline.children(of: groupID).map(\.id)
        let parent = group.parentID.flatMap { outline.layer($0) != nil ? $0 : nil }
        var next = overlay
        reparent(children, to: parent, newParentWorld: parent.map(worldTransform(of:)) ?? .identity, in: &next)
        if group.kind == .group || group.kind == .other { next.removeObjects([groupID]) }
        normalizeOrder(&next)
        if selection == groupID { selection = children.first }
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Sets `parent` and a local transform that keeps each layer's place on the scene.
    /// `isNewParent`: the parent is a group being made in `next`, which no layer is under yet.
    private func reparent(_ layerIDs: [Int], to parent: Int?, newParentWorld: SceneTransform2D,
                          in next: inout SceneEditOverlay, isNewParent: Bool = false) {
        guard let inverse = newParentWorld.inverted else { return }
        for id in layerIDs where (isNewParent || canParent(id, to: parent)) && isEditable("parent", of: id) {
            let world = worldTransform(of: id)
            let local = inverse.concatenating(world)
            let current = transform(of: id)
            let decomposed = Self.decompose(local)
            next.setField("parent", to: normalizedParent(parent, of: id), of: id)
            let origin = SIMD3(decomposed.translation.x, decomposed.translation.y, current.origin.z)
            let scale = SIMD3(decomposed.scale.x, decomposed.scale.y, current.scale.z)
            let angles = SIMD3(current.angles.x, current.angles.y, decomposed.rotation)
            for (field, vector, was) in [("origin", origin, current.origin), ("scale", scale, current.scale),
                                         ("angles", angles, current.angles)] where !Self.close(vector, was) {
                guard isEditable(field, of: id) else { continue }
                next.setField(field, to: normalizedField(SceneVector.value([vector.x, vector.y, vector.z]), field: field, of: id),
                              of: id)
            }
        }
    }

    private func normalizedParent(_ parent: Int?, of layerID: Int) -> SceneJSONValue? {
        let authored = baseOutline.layer(layerID)?.parentID
        if parent == authored { return nil }
        return parent.map { .number(Double($0)) } ?? .null
    }

    /// `value` unless it is what the structure-only scene has (then no edit).
    func normalizedField(_ value: SceneJSONValue, field: String, of layerID: Int) -> SceneJSONValue? {
        let authored = SceneFieldBinding.literal(of: baseOutline.layer(layerID)?.fields[field]) ?? Self.defaults[field]
        return Self.same(value, authored) ? nil : value
    }

    static func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        (0..<3).allSatisfy { abs(a[$0] - b[$0]) <= 1e-6 * max(1, abs(a[$0])) }
    }

    /// Translation, rotation (radians) and scale of a 2D transform without skew; a mirrored one
    /// keeps the flip in its y scale.
    public static func decompose(_ transform: SceneTransform2D) -> (translation: SIMD2<Double>, rotation: Double, scale: SIMD2<Double>) {
        let scaleX = (transform.a * transform.a + transform.b * transform.b).squareRoot()
        let rotation = atan2(transform.b, transform.a)
        let scaleY = scaleX > 1e-12 ? transform.determinant / scaleX : (transform.c * transform.c + transform.d * transform.d).squareRoot()
        return (SIMD2(transform.tx, transform.ty), rotation, SIMD2(scaleX, scaleY))
    }
}
