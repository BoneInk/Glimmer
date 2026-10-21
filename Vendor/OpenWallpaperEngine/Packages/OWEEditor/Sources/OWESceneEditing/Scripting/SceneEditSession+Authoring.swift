import Foundation

/// Scripts and user-property bindings of the session's layers: what drives a field (as authored,
/// with the editor's changes), and the undoable changes themselves, kept in the overlay's
/// `authoring` like every other edit.
extension SceneEditSession {
    // MARK: Reading

    /// The field as scene.json authored it: an object field, or an effect's `visible`.
    public func authoredField(_ path: SceneFieldPath, of layerID: Int) -> SceneJSONValue? {
        guard let layer = baseOutline.layer(layerID) else { return nil }
        if let field = path.objectField { return layer.fields[field] }
        if let index = path.effectIndex, path.components.count == 3, path.name == "visible",
           layer.effects.indices.contains(index) {
            return layer.effects[index].visible
        }
        return nil
    }

    /// The field with the editor's script and binding changes applied, as the scene now loads it.
    public func drivenField(_ path: SceneFieldPath, of layerID: Int) -> SceneJSONValue? {
        let authored = authoredField(path, of: layerID)
        guard let edit = overlay.authoring?.driverEdit(path, of: layerID) else { return authored }
        return edit.applied(to: authored)
    }

    public func drivers(_ path: SceneFieldPath, of layerID: Int) -> SceneFieldDrivers {
        SceneFieldDrivers(drivenField(path, of: layerID))
    }

    /// How an effect's `visible` gets its value, with the editor's bindings.
    public func effectBinding(_ effect: SceneLayerEffect, of layerID: Int) -> SceneFieldBinding {
        SceneFieldBinding(drivenField(.effect(effect.id), of: layerID))
    }

    /// The layer's fields that run a script, in the order WE runs them (`visible`, `origin`,
    /// `scale`, `angles`, `alpha`, `color`, `text`, then by name, then its effects).
    public func scriptedFields(of layerID: Int) -> [SceneFieldPath] {
        guard let layer = outline.layer(layerID) else { return [] }
        var paths = Set(layer.fields.keys.map { SceneFieldPath(components: [$0]) })
        paths.formUnion(layer.effects.map { SceneFieldPath.effect($0.id) })
        for key in (overlay.authoring?.drivers[String(layerID)] ?? [:]).keys { paths.insert(SceneFieldPath(key)) }
        return paths.filter { drivers($0, of: layerID).script != nil }.sorted(by: Self.runOrder)
    }

    /// Every field bound to user property `key` across the scene, as the scene now loads it.
    public func fields(boundTo key: String) -> [(layer: Int, path: SceneFieldPath)] {
        var found: [(layer: Int, path: SceneFieldPath)] = []
        for layer in outline.layers {
            var paths = Set(layer.fields.keys.map { SceneFieldPath(components: [$0]) })
            paths.formUnion(layer.effects.map { SceneFieldPath.effect($0.id) })
            for edited in (overlay.authoring?.drivers[String(layer.id)] ?? [:]).keys { paths.insert(SceneFieldPath(edited)) }
            for path in paths.sorted(by: Self.runOrder) where drivers(path, of: layer.id).user?.name == key {
                found.append((layer.id, path))
            }
        }
        return found
    }

    nonisolated static let scriptFieldOrder = ["visible", "origin", "scale", "angles", "alpha", "color", "text"]

    nonisolated static func runOrder(_ lhs: SceneFieldPath, _ rhs: SceneFieldPath) -> Bool {
        func rank(_ path: SceneFieldPath) -> (Int, Int, String) {
            if let field = path.objectField {
                return (0, scriptFieldOrder.firstIndex(of: field) ?? scriptFieldOrder.count, field)
            }
            return (1, path.effectIndex ?? Int.max, path.description)
        }
        return rank(lhs) < rank(rhs)
    }

    /// The value a script or binding starts from: the field's current value, else WE's default.
    func startValue(_ path: SceneFieldPath, of layerID: Int) -> SceneJSONValue? {
        if let field = path.objectField {
            return value(field, of: layerID) ?? Self.defaults[field]
        }
        if let index = path.effectIndex, let effect = outline.layer(layerID)?.effects.first(where: { $0.id == index }) {
            return .bool(isEffectVisible(effect, of: layerID))
        }
        return nil
    }

    // MARK: Scripts

    /// Attaches `script` to the field (replacing its script), one undo step. The field keeps its
    /// value as the script's start value.
    public func attachScript(_ script: SceneScriptAttachment, to path: SceneFieldPath, of layerID: Int,
                             actionName: String) {
        changeDrivers(path, of: layerID, actionName: actionName) { edit in
            edit.attach(script)
        }
    }

    /// Removes the field's script; the field keeps its value.
    public func removeScript(_ path: SceneFieldPath, of layerID: Int, actionName: String) {
        let authored = SceneFieldDrivers(authoredField(path, of: layerID)).script != nil
        changeDrivers(path, of: layerID, actionName: actionName) { edit in
            edit.detachScript(authored: authored)
        }
    }

    // MARK: User-property bindings

    /// Binds the field to a user property (`Bind to User Property…`): the property sets it from
    /// now on, as WE's editor binds one; its value stays the fallback.
    public func bind(_ path: SceneFieldPath, of layerID: Int, to binding: SceneUserBinding, actionName: String) {
        changeDrivers(path, of: layerID, actionName: actionName) { edit in
            edit.bind(binding)
        }
    }

    public func unbind(_ path: SceneFieldPath, of layerID: Int, actionName: String) {
        let authored = SceneFieldDrivers(authoredField(path, of: layerID)).user != nil
        changeDrivers(path, of: layerID, actionName: actionName) { edit in
            edit.unbind(authored: authored)
        }
    }

    private func changeDrivers(_ path: SceneFieldPath, of layerID: Int, actionName: String,
                               _ change: (inout SceneFieldDriverEdit) -> Void) {
        editOverlay(actionName: actionName) { overlay in
            changeDrivers(in: &overlay, path, of: layerID, change)
        }
    }

    /// Changes the field's driver edit inside `overlay` (several changes can make one undo step).
    /// A field the scene doesn't have gets its current value as the start value.
    func changeDrivers(in overlay: inout SceneEditOverlay, _ path: SceneFieldPath, of layerID: Int,
                       _ change: (inout SceneFieldDriverEdit) -> Void) {
        var authoring = overlay.authoring ?? SceneAuthoring()
        var edit = authoring.driverEdit(path, of: layerID) ?? SceneFieldDriverEdit()
        change(&edit)
        if authoredField(path, of: layerID) == nil { edit.value = startValue(path, of: layerID) }
        authoring.setDriverEdit(edit, path, of: layerID)
        overlay.authoring = authoring.isEmpty ? nil : authoring
    }
}
