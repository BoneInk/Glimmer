import Foundation

/// A layer's effects as WE's editor edits them: added from the catalog, removed, reordered,
/// turned on and off, and every parameter set: constants, combos, textures and masks, and
/// constants bound to a user property. Effects are named by their key (`SceneLayerEffect.key`).
extension SceneEditSession {
    // MARK: Reading

    /// The effect's constant as the scene now has it: the edit, else the scene's (a driven
    /// constant's starting value); nil when neither sets it (the shader's default applies).
    public func effectConstant(_ key: String, effect effectKey: String, of layerID: Int) -> SceneJSONValue? {
        if let edit = overlay.effectEdit(effectKey, of: layerID)?.constants.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return edit.value
        }
        return SceneFieldBinding.literal(of: authoredConstant(key, effect: effectKey, of: layerID))
    }

    /// The constant as the structure-only scene has it (an added effect's own value).
    func authoredConstant(_ key: String, effect effectKey: String, of layerID: Int) -> SceneJSONValue? {
        baseEffect(effectKey, of: layerID)?.constants.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// The constant's components, or `fallback` (the shader's default) where nothing sets them.
    public func effectConstantComponents(_ key: String, effect effectKey: String, of layerID: Int, default fallback: [Double]) -> [Double] {
        SceneVector.components(effectConstant(key, effect: effectKey, of: layerID), fallback: fallback)
    }

    /// The user property the constant follows, if any: the edit's binding, else the scene's.
    public func effectBinding(_ key: String, effect effectKey: String, of layerID: Int) -> String? {
        if let edit = overlay.effectEdit(effectKey, of: layerID)?.bindings?.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) {
            return edit.value.isEmpty ? nil : edit.value
        }
        if case .userProperty(let name) = SceneFieldBinding(authoredConstant(key, effect: effectKey, of: layerID)) { return name }
        return nil
    }

    /// Whether a script or a timeline sets the constant (an edit then sets where it starts).
    public func isEffectConstantDriven(_ key: String, effect effectKey: String, of layerID: Int) -> Bool {
        SceneFieldBinding(authoredConstant(key, effect: effectKey, of: layerID)) == .driven
    }

    public func effectCombo(_ name: String, effect effectKey: String, of layerID: Int, default fallback: Int) -> Int {
        if let edit = overlay.effectEdit(effectKey, of: layerID)?.combos?.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
            return edit.value
        }
        return baseEffect(effectKey, of: layerID)?.combos.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? fallback
    }

    /// The texture in `slot` of the effect's pass `pass` (the first by default); nil for the
    /// shader's default.
    public func effectTexture(_ slot: Int, pass: Int = 0, effect effectKey: String, of layerID: Int) -> String? {
        let key = SceneEditOverlay.EffectEdit.textureKey(pass: pass, slot: slot)
        if let edit = overlay.effectEdit(effectKey, of: layerID)?.textures?[key] { return edit.stringValue }
        return Self.authoredTexture(baseEffect(effectKey, of: layerID), pass: pass, slot: slot)
    }

    private static func authoredTexture(_ effect: SceneLayerEffect?, pass: Int, slot: Int) -> String? {
        guard let effect else { return nil }
        let textures = pass == 0 ? effect.textures : (effect.passTextures.indices.contains(pass) ? effect.passTextures[pass] : [])
        return textures.indices.contains(slot) ? textures[slot].stringValue : nil
    }

    // MARK: Structure

    /// Adds `entry` on top of the layer's effects (applied last) and returns its key.
    @discardableResult
    public func addEffect(_ entry: EffectCatalogEntry, to layerID: Int, actionName: String) -> String? {
        guard let (next, key) = overlay(adding: entry, to: layerID) else { return nil }
        commit(next, actionName: actionName, coalescingKey: nil)
        return key
    }

    /// Adds `entry` on top of the layer's effects with `path` in `slot` of pass `pass` (its combo
    /// on, as `setEffectTexture` sets it), as one undo step; returns the effect's key.
    @discardableResult
    public func addEffect(_ entry: EffectCatalogEntry, to layerID: Int, texture path: String, slot: Int, pass: Int = 0,
                          combo: String? = nil, actionName: String) -> String? {
        guard let added = overlay(adding: entry, to: layerID) else { return nil }
        var next = added.0
        let key = added.1
        setTexture(path, slot: slot, pass: pass, effect: key, of: layerID, combo: combo, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
        return key
    }

    /// The overlay with `entry` added on top of the layer's effects, and the new effect's key.
    private func overlay(adding entry: EffectCatalogEntry, to layerID: Int) -> (SceneEditOverlay, String)? {
        guard let layer = outline.layer(layerID) else { return nil }
        let keys = layer.effects.map(\.key)
        let used = (overlay.objects[String(layerID)]?.addedEffects ?? [:]).keys.compactMap { Int($0.dropFirst()) }
            + keys.filter { $0.hasPrefix("+") }.compactMap { Int($0.dropFirst()) }
        let key = "+\((used.max() ?? 0) + 1)"
        let effect: [String: SceneJSONValue] = [
            "file": .string(entry.file),
            "name": .string(""),
            "visible": .bool(true),
            "passes": .array(Array(repeating: .object([:]), count: max(entry.passCount, 1))),
        ]
        var next = overlay
        next.update(layerID) { edit in
            var added = edit.addedEffects ?? [:]
            added[key] = .object(effect)
            edit.addedEffects = added
            if edit.effectOrder != nil { edit.effectOrder = keys + [key] }
        }
        return (next, key)
    }

    /// Removes the effect: an added one leaves the overlay with its edits, an authored one leaves
    /// the order.
    public func removeEffect(_ effectKey: String, of layerID: Int, actionName: String) {
        guard let layer = outline.layer(layerID), layer.effects.contains(where: { $0.key == effectKey }) else { return }
        let remaining = layer.effects.map(\.key).filter { $0 != effectKey }
        var next = overlay
        next.update(layerID) { edit in
            if effectKey.hasPrefix("+") {
                edit.addedEffects?[effectKey] = nil
                if edit.addedEffects?.isEmpty == true { edit.addedEffects = nil }
            }
            edit.effects[effectKey] = nil
            edit.effectOrder = remaining
        }
        normalizeEffectOrder(of: layerID, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Moves effects as a list drag does (`source` offsets to `destination`, before that position).
    public func moveEffects(of layerID: Int, from source: IndexSet, to destination: Int, actionName: String) {
        guard let layer = outline.layer(layerID) else { return }
        var keys = layer.effects.map(\.key)
        let moving = source.sorted().filter { keys.indices.contains($0) }.map { keys[$0] }
        guard !moving.isEmpty else { return }
        let before = destination < keys.count ? keys[destination] : nil
        keys.removeAll { moving.contains($0) }
        let position = before.flatMap { key in keys.firstIndex(of: key) } ?? keys.count
        keys.insert(contentsOf: moving, at: position)
        var next = overlay
        next.update(layerID) { $0.effectOrder = keys }
        normalizeEffectOrder(of: layerID, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Drops an order that is the scene's own (the authored effects, then the added ones).
    func normalizeEffectOrder(of layerID: Int, in next: inout SceneEditOverlay) {
        let authoredCount = authoredEffectCount(of: layerID)
        next.update(layerID) { edit in
            guard let order = edit.effectOrder else { return }
            if order == SceneEditOverlay.defaultEffectOrder(authoredCount: authoredCount, added: edit.addedEffects) {
                edit.effectOrder = nil
            }
        }
    }

    /// The effects the layer's scene object lists (an added layer's own).
    private func authoredEffectCount(of layerID: Int) -> Int {
        if let added = overlay.addedObject(layerID), case .array(let effects)? = added.object["effects"] { return effects.count }
        guard let data = authored.sceneData,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { return 0 }
        for (index, object) in objects.enumerated() where SceneObjects.objectID(object, index: index) == layerID {
            return (object["effects"] as? [Any])?.count ?? 0
        }
        return 0
    }

    // MARK: Values

    /// Sets a constant. A value equal to the scene's drops the edit; `defaultValue` (the shader's)
    /// counts as the scene's for a constant the scene doesn't set.
    public func setEffectConstant(_ key: String, to value: SceneJSONValue, effect effectKey: String, of layerID: Int,
                                  defaultValue: SceneJSONValue? = nil, actionName: String, coalescing: Bool = false) {
        let authored = SceneFieldBinding.literal(of: authoredConstant(key, effect: effectKey, of: layerID)) ?? defaultValue
        var next = overlay
        next.updateEffect(key: effectKey, of: layerID) { edit in
            let existing = edit.constants.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
            edit.constants[existing] = Self.same(value, authored) ? nil : value
        }
        commit(next, actionName: actionName, coalescingKey: coalescing ? "\(layerID):effect:\(effectKey):\(key)" : nil)
    }

    public func setEffectCombo(_ name: String, to value: Int, effect effectKey: String, of layerID: Int,
                               defaultValue: Int, actionName: String) {
        let authored = baseEffect(effectKey, of: layerID)?.combos.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            ?? defaultValue
        var next = overlay
        next.updateEffect(key: effectKey, of: layerID) { edit in
            var combos = edit.combos ?? [:]
            let existing = combos.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            combos[existing] = value == authored ? nil : value
            edit.combos = combos.isEmpty ? nil : combos
        }
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    /// Sets the texture in `slot` of pass `pass` (a texture path such as `masks/…`, nil for the
    /// shader's default). A first-pass slot with a combo (`MASK`) switches it on while a texture is
    /// set, as WE does; a later pass's combo follows its bound texture when the scene is drawn, as
    /// WE's scenes leave it.
    public func setEffectTexture(_ path: String?, slot: Int, pass: Int = 0, effect effectKey: String, of layerID: Int,
                                 combo: String? = nil, actionName: String) {
        var next = overlay
        setTexture(path, slot: slot, pass: pass, effect: effectKey, of: layerID, combo: combo, in: &next)
        commit(next, actionName: actionName, coalescingKey: nil)
    }

    private func setTexture(_ path: String?, slot: Int, pass: Int, effect effectKey: String, of layerID: Int,
                            combo: String?, in next: inout SceneEditOverlay) {
        let authoredPath = Self.authoredTexture(baseEffect(effectKey, of: layerID), pass: pass, slot: slot)
        next.updateEffect(key: effectKey, of: layerID) { edit in
            var textures = edit.textures ?? [:]
            textures[SceneEditOverlay.EffectEdit.textureKey(pass: pass, slot: slot)] =
                path == authoredPath ? nil : (path.map(SceneJSONValue.string) ?? .null)
            edit.textures = textures.isEmpty ? nil : textures
            if pass == 0, let combo {
                var combos = edit.combos ?? [:]
                let authoredCombo = self.baseEffect(effectKey, of: layerID)?.combos
                    .first { $0.key.caseInsensitiveCompare(combo) == .orderedSame }?.value
                let wanted = path == nil ? 0 : 1
                combos[combo] = wanted == (authoredCombo ?? (authoredPath == nil ? 0 : 1)) ? nil : wanted
                edit.combos = combos.isEmpty ? nil : combos
            }
        }
    }

    /// Binds the constant to user property `property` (nil: the constant's own value again).
    public func bindEffectConstant(_ key: String, to property: String?, effect effectKey: String, of layerID: Int,
                                   actionName: String) {
        let authored = SceneFieldBinding(authoredConstant(key, effect: effectKey, of: layerID))
        var authoredName: String?
        if case .userProperty(let name) = authored { authoredName = name }
        var next = overlay
        next.updateEffect(key: effectKey, of: layerID) { edit in
            var bindings = edit.bindings ?? [:]
            let existing = bindings.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
            if property == authoredName {
                bindings[existing] = nil
            } else {
                bindings[existing] = property ?? ""
            }
            edit.bindings = bindings.isEmpty ? nil : bindings
        }
        commit(next, actionName: actionName, coalescingKey: nil)
    }
}
