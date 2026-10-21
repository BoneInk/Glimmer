import Foundation

/// One effect gizmo of a layer as the session has its values: the layout the canvas draws and the
/// constant behind each role.
public struct EffectGizmoInstance: Hashable, Sendable, Identifiable {
    /// `<effect key>:<gizmo index>`, or `<effect key>:<constant>` for a lone position constant.
    public var id: String
    public var effectKey: String
    public var layout: EffectGizmoLayout
    /// Role to the effect's constant it sets.
    public var keys: [String: String]
    /// Roles whose constant a user property sets: drawn, not dragged.
    public var boundRoles: Set<String>
}

extension SceneEditSession {
    /// The effect's canvas gizmos: each of `schema.gizmos` its combos show (WE's `condition`), and
    /// a point handle for each `"position": true` constant no gizmo sets.
    public func effectGizmos(_ effect: SceneLayerEffect, of layerID: Int, schema: EffectSchema) -> [EffectGizmoInstance] {
        func combo(_ name: String) -> Int {
            let declared = schema.combos.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return effectCombo(name, effect: effect.key, of: layerID, default: declared?.defaultValue ?? 0)
        }
        func instance(id: String, kind: EffectGizmo.Kind?, keys: [String: String]) -> EffectGizmoInstance {
            var values: [String: [Double]] = [:], ranges: [String: ClosedRange<Double>] = [:], bound = Set<String>()
            for (role, key) in keys {
                let parameter = schema.parameter(key)
                let value = effectConstantComponents(key, effect: effect.key, of: layerID, default: parameter?.defaultValue ?? [])
                if !value.isEmpty { values[role] = value }
                if let parameter, parameter.maximum > parameter.minimum, !parameter.isDirection {
                    ranges[role] = parameter.minimum...parameter.maximum
                }
                if effectBinding(key, effect: effect.key, of: layerID) != nil { bound.insert(role) }
            }
            return EffectGizmoInstance(id: id, effectKey: effect.key, layout: EffectGizmoLayout(kind: kind, values: values, ranges: ranges),
                                       keys: keys, boundRoles: bound)
        }
        var result: [EffectGizmoInstance] = []
        // A gizmo's constants are its own, shown or not (an emitter its combo turns off has no handle).
        let covered = Set(schema.gizmos.flatMap { $0.vars.values.map { $0.lowercased() } })
        for (index, gizmo) in schema.gizmos.enumerated() where gizmo.shows(combo: combo) {
            result.append(instance(id: "\(effect.key):\(index)", kind: gizmo.kind, keys: gizmo.vars))
        }
        for parameter in schema.parameters where parameter.control == .position && !covered.contains(parameter.key.lowercased()) {
            result.append(instance(id: "\(effect.key):\(parameter.key)", kind: nil, keys: ["position": parameter.key]))
        }
        return result
    }

    /// Sets several of an effect's constants as one edit (a gizmo handle that sets a ratio and an
    /// angle together); `coalescingKey` merges a drag's run of them into one undo step. A value
    /// equal to the scene's (or, unset there, to the shader's default) drops its edit.
    public func setEffectConstants(_ values: [String: [Double]], effect effectKey: String, of layerID: Int,
                                   schema: EffectSchema, actionName: String, coalescingKey: String? = nil) {
        var next = overlay
        next.updateEffect(key: effectKey, of: layerID) { edit in
            for (key, components) in values where !components.isEmpty {
                let parameter = schema.parameter(key)
                let rounded = parameter?.isInteger == true ? components.map { $0.rounded() } : components
                let value: SceneJSONValue = rounded.count == 1 ? .number(rounded[0]) : SceneVector.value(rounded)
                let fallback = parameter.map { $0.defaultValue.count == 1 ? SceneJSONValue.number($0.defaultValue[0])
                                                                           : SceneVector.value($0.defaultValue) }
                let authored = SceneFieldBinding.literal(of: authoredConstant(key, effect: effectKey, of: layerID)) ?? fallback
                let existing = edit.constants.keys.first { $0.caseInsensitiveCompare(key) == .orderedSame } ?? key
                edit.constants[existing] = Self.same(value, authored) ? nil : value
            }
        }
        commit(next, actionName: actionName, coalescingKey: coalescingKey.map { "\(layerID):effect:\(effectKey):\($0)" })
    }
}
