import Foundation

/// The layer and effect commands of Wallpaper Engine's context menus (its editor UI's
/// `callbackAssetContextMenu` and `contextMenuPropertyEffect`): Center and Align with Background,
/// Rotate CW and CCW, Copy and Paste Transforms, Move to Custom Position, and copying, pasting and
/// duplicating effects, one or all of a layer's, and pasting one's settings onto another.
extension SceneEditSession {
    // MARK: Transforms

    /// A layer's transform as Copy Transforms takes it: `origin`, `scale` and `angles`.
    public func copiedTransform(of layerID: Int) -> LayerTransform { transform(of: layerID) }

    /// Paste Transforms: the copied `origin`, `scale` and `angles` onto every layer, one undo step.
    public func pasteTransform(_ transform: LayerTransform, onto layerIDs: [Int], actionName: String) {
        let targets = layerIDs.filter { outline.layer($0) != nil }
        guard !targets.isEmpty else { return }
        setTransforms(Dictionary(uniqueKeysWithValues: targets.map { ($0, transform) }), actionName: actionName)
    }

    /// Rotate CW (−90°) and CCW (+90°): WE turns the layer about z (`rotateRenderable(id, 2, ±90°)`).
    public func rotate(_ layerIDs: [Int], by angle: Double, actionName: String) {
        var transforms: [Int: LayerTransform] = [:]
        for layerID in layerIDs where outline.layer(layerID) != nil {
            var transform = self.transform(of: layerID)
            transform.angles.z += angle
            transforms[layerID] = transform
        }
        guard !transforms.isEmpty else { return }
        setTransforms(transforms, actionName: actionName)
    }

    /// Center, and Align with Background with the layer's image `cropoffset` (WE's
    /// `centerRenderable`, wallpaperui.exe 0x1400b5e10): the origin to the scene's centre plus the
    /// offset; a layer in a group to its parent's origin.
    public func center(_ layerIDs: [Int], offset: (Int) -> SIMD2<Double>? = { _ in nil }, actionName: String) {
        guard let size = outline.size else { return }
        var transforms: [Int: LayerTransform] = [:]
        for layerID in layerIDs {
            guard let layer = outline.layer(layerID) else { continue }
            var transform = self.transform(of: layerID)
            if layer.parentID.flatMap(outline.layer) != nil {
                transform.origin = .zero
            } else {
                let shift = offset(layerID) ?? .zero
                transform.origin = SIMD3(size.x / 2 + shift.x, size.y / 2 + shift.y, 0)
            }
            transforms[layerID] = transform
        }
        guard !transforms.isEmpty else { return }
        setTransforms(transforms, actionName: actionName)
    }

    // MARK: Order

    /// The list's rows as the layer list shows them, topmost first, groups before their members.
    public var listRows: [Int] {
        func rows(_ nodes: [SceneOutline.Node]) -> [Int] {
            nodes.flatMap { [$0.id] + rows($0.children ?? []) }
        }
        return rows(outline.tree())
    }

    /// Move to Custom Position: the top-level layer (with what's in it) to row `position` of the
    /// list, 1 the top, the next top-level row at or after it as WE's editor picks it.
    public func moveToListPosition(_ layerID: Int, position: Int, actionName: String) {
        guard let layer = outline.layer(layerID), layer.parentID.flatMap(outline.layer) == nil else { return }
        let rows = listRows
        guard rows.count > 1, let current = rows.firstIndex(of: layerID) else { return }
        let moving = Set(subtree(of: layerID))
        var target = min(max(position - 1, 0), rows.count - 1)
        func isTopLevel(_ id: Int) -> Bool { outline.layer(id)?.parentID.flatMap(outline.layer) == nil }
        while target < rows.count, !isTopLevel(rows[target]) || moving.contains(rows[target]) && rows[target] != layerID {
            target += 1
        }
        guard target < rows.count, target != current else { return }
        let destination = rows[target]
        guard destination != layerID else { return }
        // Up the list is above (drawn after) the row there; down the list, below it.
        move([layerID], relativeTo: destination, above: target < current, actionName: actionName)
    }

    // MARK: Effects

    /// The effect as the edited scene has it, its edits applied (WE's `getEffectConfig`): what
    /// Copy Effect, Copy all Effects and Duplicate Effect take.
    public func effectConfig(_ effectKey: String, of layerID: Int) -> SceneJSONValue? {
        guard let layer = outline.layer(layerID), let index = layer.effects.firstIndex(where: { $0.key == effectKey }),
              let effects = appliedObject(layerID)?["effects"] as? [Any], effects.indices.contains(index) else { return nil }
        return SceneJSONValue(any: effects[index])
    }

    /// Every effect of the layer in order, as Copy all Effects takes them.
    public func effectConfigs(of layerID: Int) -> [SceneJSONValue] {
        (outline.layer(layerID)?.effects ?? []).compactMap { effectConfig($0.key, of: layerID) }
    }

    /// Paste Effect, Paste all Effects and Duplicate Effect (WE's `addEffectFromConfig`): the
    /// effects added to the layer on top, or just after `effectKey`, as one undo step. Returns
    /// their keys.
    @discardableResult
    public func addEffects(_ configs: [SceneJSONValue], to layerID: Int, after effectKey: String? = nil,
                           actionName: String) -> [String] {
        guard let layer = outline.layer(layerID) else { return [] }
        var keys = layer.effects.map(\.key)
        var used = ((overlay.objects[String(layerID)]?.addedEffects ?? [:]).keys + keys.filter { $0.hasPrefix("+") })
            .compactMap { Int($0.dropFirst()) }.max() ?? 0
        var next = overlay
        var added: [String] = []
        for config in configs {
            guard case .object(var effect) = config, effect["file"]?.stringValue?.isEmpty == false else { continue }
            effect[SceneEditOverlay.effectKeyMarker] = nil
            used += 1
            let key = "+\(used)"
            next.update(layerID) { edit in
                var effects = edit.addedEffects ?? [:]
                effects[key] = .object(effect)
                edit.addedEffects = effects
            }
            added.append(key)
        }
        guard !added.isEmpty else { return [] }
        if let effectKey, let index = keys.firstIndex(of: effectKey) {
            keys.insert(contentsOf: added, at: index + 1)
        } else {
            keys.append(contentsOf: added)
        }
        next.update(layerID) { $0.effectOrder = keys }
        normalizeEffectOrder(of: layerID, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
        return added
    }

    /// Paste Effect Settings (WE's `applyEffectConfig`, offered for an effect of the same file):
    /// the copied effect's first pass's constants (and the user properties they follow), combos,
    /// and every pass's textures onto the effect, one undo step. Its visibility stays.
    public func applyEffectSettings(_ config: SceneJSONValue, onto effectKey: String, of layerID: Int, actionName: String) {
        guard case .object(let source) = config, let target = outline.layer(layerID)?.effects.first(where: { $0.key == effectKey }),
              source["file"]?.stringValue == target.file else { return }
        let passes: [[String: SceneJSONValue]] = {
            guard case .array(let list)? = source["passes"] else { return [] }
            return list.map { if case .object(let pass) = $0 { return pass } else { return [:] } }
        }()
        let base = baseEffect(effectKey, of: layerID)
        var next = overlay
        next.updateEffect(key: effectKey, of: layerID) { edit in
            var constants: [String: SceneJSONValue] = [:], bindings: [String: String] = [:]
            if case .object(let values)? = passes.first?["constantshadervalues"] {
                for (key, value) in values {
                    let authored = base?.constants.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
                    let authoredProperty: String? = {
                        if case .userProperty(let name) = SceneFieldBinding(authored) { return name }
                        return nil
                    }()
                    var property: String?
                    if case .userProperty(let name) = SceneFieldBinding(value) { property = name }
                    if property != authoredProperty { bindings[key] = property ?? "" }
                    if let literal = SceneFieldBinding.literal(of: value),
                       !Self.same(literal, SceneFieldBinding.literal(of: authored)) {
                        constants[key] = literal
                    }
                }
            }
            edit.constants = constants
            edit.bindings = bindings.isEmpty ? nil : bindings
            var combos: [String: Int] = [:]
            if case .object(let values)? = passes.first?["combos"] {
                for (name, value) in values {
                    guard let number = value.doubleValue.map({ Int($0) }) else { continue }
                    let authored = base?.combos.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
                    if number != authored { combos[name] = number }
                }
            }
            edit.combos = combos.isEmpty ? nil : combos
            var textures: [String: SceneJSONValue] = [:]
            for (pass, values) in passes.enumerated() {
                guard case .array(let list)? = values["textures"] else { continue }
                let authoredList = pass == 0 ? (base?.textures ?? [])
                    : ((base?.passTextures.indices.contains(pass) ?? false) ? base!.passTextures[pass] : [])
                for (slot, value) in list.enumerated() where slot > 0 {
                    let authored = authoredList.indices.contains(slot) ? authoredList[slot] : SceneJSONValue.null
                    if value != authored { textures[SceneEditOverlay.EffectEdit.textureKey(pass: pass, slot: slot)] = value }
                }
            }
            edit.textures = textures.isEmpty ? nil : textures
        }
        commit(next, actionName: actionName, coalescingKey: nil)
    }
}
