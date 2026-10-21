import Foundation
import OWEControlProtocol
import OWESceneEditing

/// Effect edits, as the editor's Effects section makes them (`EffectsSection`,
/// `SceneEditSession+Effects`): add from the catalog (copying a built-in effect's files first),
/// remove, reorder, turn on and off, and set a constant, combo or texture, or bind a constant to a
/// user property. Values are checked against the effect's own parameters (`effects_catalog`).
extension SceneEditOperations {
    static var effectOperations: [String: Operation] {
        [
            "add_effect": addEffect,
            "remove_effect": { edit, context in
                let layer = try Self.layer(edit, context)
                let effect = try Self.effect(edit, of: layer)
                context.session.removeEffect(effect.key, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "effect": .string(effect.key)]
            },
            "move_effect": { edit, context in
                let layer = try Self.layer(edit, context)
                let effect = try Self.effect(edit, of: layer)
                let index = try edit.requiredInt("index")
                guard let from = layer.effects.firstIndex(where: { $0.key == effect.key }),
                      (0..<layer.effects.count).contains(index) else {
                    throw ControlError(.invalidParams, "index must be from 0 to \(layer.effects.count - 1) (0 is applied first).")
                }
                // A list drag's destination is the position before which it lands.
                let destination = index > from ? index + 1 : index
                context.session.moveEffects(of: layer.id, from: IndexSet(integer: from), to: destination, actionName: "")
                let order = context.session.outline.layer(layer.id)?.effects.map { JSONValue.string($0.key) } ?? []
                return ["layer": .number(Double(layer.id)), "effects": .array(order)]
            },
            "set_effect_visible": { edit, context in
                let layer = try Self.layer(edit, context)
                let effect = try Self.effect(edit, of: layer)
                if case .userProperty(let property) = SceneFieldBinding(context.session.baseEffect(effect.key, of: layer.id)?.visible ?? effect.visible) {
                    throw ControlError(.refused, "The effect's visibility follows the user property \"\(property)\".")
                }
                context.session.setEffectVisible(try edit.requiredBool("visible"), effect: effect, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "effect": .string(effect.key)]
            },
            "set_effect_constant": setEffectConstant,
            "set_effect_combo": setEffectCombo,
            "set_effect_texture": setEffectTexture,
            "bind_effect_constant": { edit, context in
                let layer = try Self.layer(edit, context)
                let effect = try Self.effect(edit, of: layer)
                let key = try Self.constantKey(edit, effect: effect, context)
                let property = try edit.string("property").flatMap { $0.isEmpty ? nil : $0 }
                if let property, !context.properties.keys.contains(property) {
                    throw ControlError(.notFound, "The wallpaper has no user property \"\(property)\"; add_user_property adds one.")
                }
                context.session.bindEffectConstant(key, to: property, effect: effect.key, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "effect": .string(effect.key), "constant": .string(key)]
            },
        ]
    }

    private static func addEffect(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        guard layer.kind == .image || layer.kind == .text || layer.kind == .particle else {
            throw ControlError(.unsupported, "Layer \(layer.id) is a \(layer.kind.rawValue) layer; effects go on image, text and particle layers.")
        }
        let file = try edit.required("effect")
        let catalog = context.resources.effectCatalog(outline: context.session.authored)
        guard let entry = catalog.first(where: { $0.file == file || $0.folderName == file.lowercased() }) else {
            throw ControlError(.notFound, catalog.isEmpty
                ? "There are no effects to add: Wallpaper Engine's assets aren't installed (Settings › Assets)."
                : "No effect \"\(file)\" in the catalog. effects_catalog lists them (by file, such as effects/blur/effect.json).")
        }
        do {
            try context.resources.prepareEffect(entry)
        } catch {
            throw ControlError(.failed, "The effect's files couldn't be copied into the wallpaper's edits: \(error.localizedDescription)")
        }
        guard let key = context.session.addEffect(entry, to: layer.id, actionName: "") else {
            throw ControlError(.failed, "The effect couldn't be added to layer \(layer.id).")
        }
        return ["layer": .number(Double(layer.id)), "effect": .string(key), "file": .string(entry.file)]
    }

    /// The constant `constant` names, as the effect's parameters spell it.
    private static func constantKey(_ edit: ControlParameters, effect: SceneLayerEffect,
                                    _ context: SceneEditOperationContext) throws -> String {
        let key = try edit.required("constant")
        let parameters = context.resources.effectSchema(effect.file)?.parameters ?? []
        if let parameter = parameters.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { return parameter.key }
        if effect.constants.keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { return key }
        let known = parameters.map(\.key).joined(separator: ", ")
        throw ControlError(.notFound, "The effect \(effect.title) has no constant \"\(key)\". "
                           + (known.isEmpty ? "effects_catalog lists the effects' parameters." : "Its constants: \(known)."))
    }

    private static func setEffectConstant(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let effect = try Self.effect(edit, of: layer)
        let key = try Self.constantKey(edit, effect: effect, context)
        if let property = context.session.effectBinding(key, effect: effect.key, of: layer.id) {
            throw ControlError(.refused, "\(key) follows the user property \"\(property)\"; bind_effect_constant with an empty property frees it.")
        }
        let text = try edit.required("value")
        let parameter = context.resources.effectSchema(effect.file)?.parameters.first { $0.key == key }
        let value: SceneJSONValue
        if let parameter {
            let count = max(parameter.defaultValue.count, 1)
            let current = context.session.effectConstantComponents(key, effect: effect.key, of: layer.id, default: parameter.defaultValue)
            let components = try SceneControlValues.vector(text, count: count, fallback: current, name: "value")
            value = count == 1 ? .number(parameter.isInteger ? components[0].rounded() : components[0]) : SceneVector.value(components)
        } else {
            value = SceneControlValues.parse(text, like: context.session.effectConstant(key, effect: effect.key, of: layer.id))
        }
        let defaultValue = parameter.map { $0.defaultValue.count == 1 ? SceneJSONValue.number($0.defaultValue[0]) : SceneVector.value($0.defaultValue) }
        context.session.setEffectConstant(key, to: value, effect: effect.key, of: layer.id, defaultValue: defaultValue, actionName: "")
        return ["layer": .number(Double(layer.id)), "effect": .string(effect.key), "constant": .string(key),
                "value": SceneControlValues.json(value)]
    }

    private static func setEffectCombo(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let effect = try Self.effect(edit, of: layer)
        let name = try edit.required("combo")
        let combos = context.resources.effectSchema(effect.file)?.combos ?? []
        guard let combo = combos.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            let known = combos.map(\.name).joined(separator: ", ")
            throw ControlError(.notFound, "The effect \(effect.title) has no combo \"\(name)\". " + (known.isEmpty ? "It has none to set." : "Its combos: \(known)."))
        }
        guard let value = Int(try edit.required("value")) else { throw ControlError(.invalidParams, "value must be a whole number for a combo.") }
        if !combo.options.isEmpty, !combo.options.contains(where: { $0.value == value }) {
            let options = combo.options.map { "\($0.value) (\($0.title))" }.joined(separator: ", ")
            throw ControlError(.invalidParams, "\(combo.name) takes \(options).")
        }
        context.session.setEffectCombo(combo.name, to: value, effect: effect.key, of: layer.id, defaultValue: combo.defaultValue, actionName: "")
        return ["layer": .number(Double(layer.id)), "effect": .string(effect.key), "combo": .string(combo.name)]
    }

    private static func setEffectTexture(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let effect = try Self.effect(edit, of: layer)
        let slotNumber = try edit.requiredInt("slot")
        let passNumber = try edit.int("pass")
        let slots = context.resources.effectSchema(effect.file)?.textures ?? []
        guard let slot = slots.first(where: { $0.slot == slotNumber && (passNumber == nil || $0.pass == passNumber) }) else {
            let known = slots.map { "\($0.slot) (\($0.title))" }.joined(separator: ", ")
            throw ControlError(.notFound, "The effect \(effect.title) has no texture slot \(slotNumber). " + (known.isEmpty ? "It has none to set." : "Its slots: \(known)."))
        }
        let texture = try edit.string("texture").flatMap { $0.isEmpty ? nil : $0 }
        context.session.setEffectTexture(texture, slot: slot.slot, pass: slot.pass, effect: effect.key, of: layer.id,
                                         combo: slot.combo, actionName: "")
        return ["layer": .number(Double(layer.id)), "effect": .string(effect.key), "slot": .number(Double(slot.slot)),
                "pass": .number(Double(slot.pass))]
    }
}
