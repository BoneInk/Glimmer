import Foundation
import OWEControlProtocol
import OWESceneEditing

/// Scripts, user-property bindings and the wallpaper's own user properties, as the editor's script
/// editor, Bind to User Property… and user-property panel make them (`EditorAuthoringModel`,
/// `UserPropertyAuthoring`). A field is named by its path: an object field (`origin`, `alpha`,
/// `text`) or an effect's visibility (`effects.<index>.visible`).
extension SceneEditOperations {
    static var authoringOperations: [String: Operation] {
        [
            "set_script": { edit, context in
                let (layer, path) = try Self.fieldPath(edit, context)
                let source = try edit.required("script")
                let diagnostics = try Self.scriptDiagnostics(source)
                let attached = try Self.attach(source, to: path, of: layer, properties: try Self.scriptProperties(edit), context)
                return ["layer": .number(Double(layer.id)), "field": .string(path.description),
                        "script_properties": attached, "warnings": diagnostics]
            },
            "remove_script": { edit, context in
                let (layer, path) = try Self.fieldPath(edit, context)
                guard context.session.drivers(path, of: layer.id).script != nil else {
                    throw ControlError(.notFound, "\(path) of layer \(layer.id) has no script.")
                }
                context.session.removeScript(path, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "field": .string(path.description)]
            },
            "bind_field": { edit, context in
                let (layer, path) = try Self.fieldPath(edit, context)
                let property = try edit.required("property")
                guard let draft = context.properties.property(property) else {
                    throw ControlError(.notFound, "The wallpaper has no user property \"\(property)\"; add_user_property adds one.")
                }
                guard draft.kind.hasValue else { throw ControlError(.refused, "\"\(property)\" is a label; it has no value to bind.") }
                let condition = try edit.string("condition").flatMap { $0.isEmpty ? nil : $0 }
                context.session.bind(path, of: layer.id, to: SceneUserBinding(name: property, condition: condition), actionName: "")
                return ["layer": .number(Double(layer.id)), "field": .string(path.description), "property": .string(property)]
            },
            "unbind_field": { edit, context in
                let (layer, path) = try Self.fieldPath(edit, context)
                guard context.session.drivers(path, of: layer.id).user != nil else {
                    throw ControlError(.notFound, "\(path) of layer \(layer.id) isn't bound to a user property.")
                }
                context.session.unbind(path, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "field": .string(path.description)]
            },
            "add_user_property": addUserProperty,
            "update_user_property": updateUserProperty,
            "remove_user_property": { edit, context in
                let key = try Self.propertyKey(edit, context)
                context.properties.remove([key], actionName: "")
                return ["key": .string(key)]
            },
            "rename_user_property": { edit, context in
                let key = try Self.propertyKey(edit, context)
                let newKey = try edit.required("new_key")
                guard UserPropertyDraft.isValidKey(newKey) else {
                    throw ControlError(.invalidParams, "new_key must be letters, digits and underscores, starting with a letter.")
                }
                guard context.properties.rename(key, to: newKey, actionName: "") else {
                    throw ControlError(.refused, "\"\(newKey)\" is taken or the same as before.")
                }
                return ["key": .string(newKey)]
            },
            "move_user_property": { edit, context in
                let key = try Self.propertyKey(edit, context)
                let list = context.properties.properties
                let index = try edit.requiredInt("index")
                guard let from = list.firstIndex(where: { $0.key == key }), (0..<list.count).contains(index) else {
                    throw ControlError(.invalidParams, "index must be from 0 to \(list.count - 1).")
                }
                context.properties.move(fromOffsets: IndexSet(integer: from), toOffset: index > from ? index + 1 : index, actionName: "")
                return ["key": .string(key), "index": .number(Double(index))]
            },
        ]
    }

    // MARK: Scripts

    /// The field `field` names on the layer: an object field or `effects.<index>.visible`.
    static func fieldPath(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> (SceneLayer, SceneFieldPath) {
        let layer = try Self.layer(edit, context)
        let path = SceneFieldPath(try edit.required("field"))
        if path.objectField == nil {
            guard let index = path.effectIndex, path.components.count == 3, path.name == "visible",
                  layer.effects.contains(where: { $0.id == index && !$0.isAdded }) else {
                throw ControlError(.invalidParams, "field must be one of the layer's fields (origin, alpha, text, …) or effects.<index>.visible of one of its scene's effects.")
            }
        }
        return (layer, path)
    }

    /// The script's syntax problems: errors refuse it (as the script editor's Apply does), warnings come back.
    static func scriptDiagnostics(_ source: String) throws -> JSONValue {
        let diagnostics = SceneScriptSyntaxCheck.diagnostics(of: source)
        let errors = diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            let lines = errors.map { error in error.line.map { "line \($0): \(error.message)" } ?? error.message }
            throw ControlError(.invalidParams, "The script has errors and wasn't applied: " + lines.joined(separator: "; "))
        }
        return .array(diagnostics.map { diagnostic in
            ["line": diagnostic.line.map { .number(Double($0)) } ?? .null, "message": .string(diagnostic.message)]
        })
    }

    private static func scriptProperties(_ edit: ControlParameters) throws -> [String: SceneJSONValue]? {
        guard let text = try edit.string("script_properties"), !text.isEmpty else { return nil }
        guard case .object(let object) = SceneControlValues.parse(text) else {
            throw ControlError(.invalidParams, "script_properties must be a JSON object, such as {\"speed\": 2}.")
        }
        return object
    }

    /// Attaches the script as the script editor's Apply does: script properties the script no
    /// longer declares are dropped, `given` ones set. Returns the script properties it keeps.
    static func attach(_ source: String, to path: SceneFieldPath, of layer: SceneLayer,
                       properties given: [String: SceneJSONValue]?, _ context: SceneEditOperationContext) throws -> JSONValue {
        let existing = context.session.drivers(path, of: layer.id).script
        let declared = Set(SceneScriptPropertyDeclaration.declarations(in: source).map(\.name))
        var kept = existing?.scriptProperties?.filter { declared.contains($0.key) } ?? [:]
        for (key, value) in given ?? [:] { kept[key] = value }
        context.session.attachScript(SceneScriptAttachment(source: source, scriptProperties: kept), to: path, of: layer.id, actionName: "")
        return .object(kept.mapValues(SceneControlValues.json))
    }

    // MARK: User properties

    private static func propertyKey(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> String {
        let key = try edit.required("key")
        guard context.properties.property(key) != nil else {
            let keys = context.properties.properties.map(\.key).joined(separator: ", ")
            throw ControlError(.notFound, "The wallpaper has no user property \"\(key)\". " + (keys.isEmpty ? "It has none." : "Its properties: \(keys)."))
        }
        return key
    }

    private static func propertyKind(_ edit: ControlParameters) throws -> UserPropertyDraft.Kind {
        let name = try edit.required("property_kind").lowercased()
        let kind = UserPropertyDraft.Kind(rawValue: name == "text_input" ? "textinput" : name)
        guard UserPropertyDraft.Kind.authorable.contains(kind) else {
            throw ControlError(.invalidParams, "property_kind must be one of bool, slider, color, combo, text_input, file, directory, scenetexture, usershortcut, group, text.")
        }
        return kind
    }

    private static func addUserProperty(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let kind = try Self.propertyKind(edit)
        let label = try edit.required("label")
        var key = context.properties.add(kind, label: label, actionName: "")
        if let wanted = try edit.string("key"), wanted != key {
            guard UserPropertyDraft.isValidKey(wanted), context.properties.rename(key, to: wanted, actionName: "") else {
                throw ControlError(.invalidParams, "key \"\(wanted)\" is taken or isn't letters, digits and underscores starting with a letter.")
            }
            key = wanted
        }
        if edit.has("value") || edit.has("min") || edit.has("max") || edit.has("step") || edit.has("options") || edit.has("condition") {
            try Self.update(key, edit, context)
        }
        return ["key": .string(key)]
    }

    private static func updateUserProperty(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let key = try Self.propertyKey(edit, context)
        try Self.update(key, edit, context)
        return ["key": .string(key)]
    }

    /// Sets the property's label, default, range, options and condition, as its editor does.
    private static func update(_ key: String, _ edit: ControlParameters, _ context: SceneEditOperationContext) throws {
        guard var draft = context.properties.property(key) else { return }
        if let label = try edit.string("label") { draft.text = label }
        if let text = try edit.string("value") {
            draft.value = try Self.propertyValue(text, for: draft)
        }
        if let minimum = try edit.double("min") { draft.minimum = minimum }
        if let maximum = try edit.double("max") { draft.maximum = maximum }
        if let step = try edit.double("step") {
            guard step > 0 else { throw ControlError(.invalidParams, "step must be above 0.") }
            draft.step = step
        }
        if let wholeNumbers = try edit.bool("whole_numbers") { draft.fraction = wholeNumbers ? false : nil }
        if let minimum = draft.minimum, let maximum = draft.maximum, minimum > maximum {
            throw ControlError(.invalidParams, "min must not be above max.")
        }
        if edit.has("options") {
            let options = try edit.objects("options").map { option in
                UserPropertyDraft.Option(label: try option.required("label"), value: try option.required("value"))
            }
            guard draft.kind == .combo || options.isEmpty else { throw ControlError(.invalidParams, "Only a combo has options.") }
            draft.options = options
        }
        if let condition = try edit.string("condition") {
            draft.condition = condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : condition
        }
        let updated = draft
        context.properties.update(key, actionName: "", coalescing: false) { $0 = updated }
    }

    /// A default for the property's kind: true/false, a number within its range, a combo option's
    /// value, a colour `"r g b"` (0–1 each), or text.
    private static func propertyValue(_ text: String, for draft: UserPropertyDraft) throws -> SceneJSONValue {
        switch draft.kind {
        case .bool:
            guard text == "true" || text == "false" else { throw ControlError(.invalidParams, "A checkbox's value is true or false.") }
            return .bool(text == "true")
        case .slider:
            guard let number = Double(text), number.isFinite else { throw ControlError(.invalidParams, "A slider's value is a number.") }
            return .number(number)
        case .color:
            let parts = try SceneControlValues.vector(text, count: 3, fallback: [1, 1, 1], name: "value")
            guard parts.allSatisfy({ (0...1).contains($0) }) else { throw ControlError(.invalidParams, "A colour is \"r g b\", each 0 to 1.") }
            return SceneVector.value(parts)
        case .combo:
            guard draft.options.isEmpty || draft.options.contains(where: { $0.value == text }) else {
                throw ControlError(.invalidParams, "A combo's value is one of its options' values: \(draft.options.map(\.value).joined(separator: ", ")).")
            }
            return .string(text)
        case .text:
            throw ControlError(.refused, "A label has no value.")
        default:
            return .string(text)
        }
    }
}
