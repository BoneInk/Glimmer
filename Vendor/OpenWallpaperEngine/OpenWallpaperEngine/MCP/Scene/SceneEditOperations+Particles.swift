import Foundation
import OWEControlProtocol
import OWESceneEditing

/// Particle edits, as the particle editor makes them (`ParticleEditingModel`): systems added from
/// WE's catalog (a default system or a preset's variant), blank, duplicated or deleted; the
/// definition's emitters, initializers, operators, renderers, children and control points added,
/// removed, reordered and set field by field (WE's particle editor schema names the fields); the
/// material; and a layer's instance override.
extension SceneEditOperations {
    static var particleOperations: [String: Operation] {
        [
            "add_particle_system": addParticleSystem,
            "add_blank_particle_system": { edit, context in
                let name = try edit.string("name") ?? String(localized: "Particle System", comment: "The name of a new particle system")
                let id = try context.particles().addBlankSystem(name: name, actionName: "")
                context.session.selection = nil
                return ["layer": .number(Double(id))]
            },
            "duplicate_particle_system": { edit, context in
                let layer = try Self.particleLayer(edit, context)
                let name = try edit.string("name") ?? String(localized: "\(layer.name ?? "") Copy", comment: "The name of a copy of a layer")
                guard let id = try context.particles().duplicateSystem(layer.id, name: name, actionName: "") else {
                    throw ControlError(.failed, "Layer \(layer.id) couldn't be duplicated.")
                }
                context.session.selection = nil
                return ["layer": .number(Double(id))]
            },
            "remove_particle_system": { edit, context in
                let layer = try Self.particleLayer(edit, context)
                try context.particles().deleteSystem(layer.id, actionName: "")
                return ["removed": .number(Double(layer.id))]
            },
            "set_particle_field": setParticleField,
            "add_particle_component": { edit, context in
                let (model, path) = try Self.definition(edit, context)
                let section = try Self.particleSection(edit, lists: true)
                let name = try edit.string("component")
                guard let component = model.schema.component(section, name: name), component.isAddable else {
                    let offered = model.schema.components(in: section).filter(\.isAddable).compactMap(\.name).joined(separator: ", ")
                    throw ControlError(.notFound, "No \(section.rawValue) \"\(name ?? "")\" to add. " + (offered.isEmpty ? "" : "WE offers: \(offered)."))
                }
                guard let index = model.addComponent(component, to: path, actionName: "") else {
                    throw ControlError(.refused, "The system's \(section.rawValue) list is full.")
                }
                return ["definition": .string(path), "section": .string(section.rawValue), "index": .number(Double(index))]
            },
            "remove_particle_component": { edit, context in
                let (model, path) = try Self.definition(edit, context)
                let section = try Self.particleSection(edit, lists: true)
                let index = try Self.componentIndex(edit, section: section, model: model, path: path)
                model.removeComponent(section, at: index, from: path, actionName: "")
                return ["definition": .string(path), "section": .string(section.rawValue)]
            },
            "move_particle_component": { edit, context in
                let (model, path) = try Self.definition(edit, context)
                let section = try Self.particleSection(edit, lists: true)
                let index = try Self.componentIndex(edit, section: section, model: model, path: path)
                let count = model.definition(path)?.items(section).count ?? 0
                let target = try edit.requiredInt("to_index")
                guard (0..<count).contains(target) else { throw ControlError(.invalidParams, "to_index must be from 0 to \(count - 1).") }
                model.moveComponent(section, from: index, to: target, in: path, actionName: "")
                return ["definition": .string(path), "section": .string(section.rawValue), "index": .number(Double(target))]
            },
            "set_particle_material": { edit, context in
                let (model, path) = try Self.definition(edit, context)
                guard model.material(ofDefinition: path) != nil else {
                    throw ControlError(.unsupported, "The system's material can't be read.")
                }
                let key = try edit.required("key")
                let value = try edit.string("value").flatMap { $0.isEmpty ? nil : $0 }
                model.editMaterial(ofDefinition: path, actionName: "") { $0.setString(value, for: key) }
                return ["definition": .string(path), "key": .string(key)]
            },
            "set_particle_override": { edit, context in
                let layer = try Self.particleLayer(edit, context)
                let model = try context.particles()
                let key = try edit.required("key")
                if case .userProperty(let property) = SceneFieldBinding(model.instanceOverride(of: layer.id)[key]) {
                    throw ControlError(.refused, "\(key) follows the user property \"\(property)\".")
                }
                let text = try edit.string("value")
                let value = text.flatMap { $0.isEmpty ? nil : SceneControlValues.parse($0, like: model.instanceOverride(of: layer.id)[key]) }
                model.setInstanceOverride(key, to: value, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id)), "key": .string(key)]
            },
        ]
    }

    private static func particleLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> SceneLayer {
        let layer = try Self.layer(edit, context)
        guard layer.kind == .particle else { throw ControlError(.unsupported, "Layer \(layer.id) isn't a particle system.") }
        return layer
    }

    /// The model and the definition the edit names: `definition` (a child's path), else the
    /// layer's own.
    private static func definition(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> (ParticleEditingModel, String) {
        let model = try context.particles()
        let path: String
        if let given = try edit.string("definition") {
            path = given
        } else {
            let layer = try Self.particleLayer(edit, context)
            guard let own = model.particlePath(of: layer.id) else { throw ControlError(.unsupported, "Layer \(layer.id) names no particle file.") }
            path = own
        }
        guard model.definition(path) != nil else {
            throw ControlError(.notFound, "The particle definition \(path) can't be read (the wallpaper's file, or WE's assets, aren't there).")
        }
        return (model, path)
    }

    private static func particleSection(_ edit: ControlParameters, lists: Bool) throws -> ParticleEditorSchema.Section {
        let name = try edit.required("section")
        let section = name == "system" ? ParticleEditorSchema.Section.system : ParticleEditorSchema.Section(rawValue: name)
        guard let section, section != .instanceoverride, !lists || section.listKey != nil else {
            let names = ParticleEditorSchema.Section.lists.map(\.rawValue) + (lists ? [] : ["system"])
            throw ControlError(.invalidParams, "section must be one of \(names.joined(separator: ", ")).")
        }
        return section
    }

    private static func componentIndex(_ edit: ControlParameters, section: ParticleEditorSchema.Section,
                                       model: ParticleEditingModel, path: String) throws -> Int {
        let index = try edit.requiredInt("index")
        let count = model.definition(path)?.items(section).count ?? 0
        guard (0..<count).contains(index) else {
            throw ControlError(.invalidParams, count == 0 ? "The system has no \(section.rawValue) items."
                               : "index must be from 0 to \(count - 1) for \(section.rawValue).")
        }
        return index
    }

    private static func setParticleField(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let (model, path) = try Self.definition(edit, context)
        let section = try Self.particleSection(edit, lists: false)
        guard let definition = model.definition(path) else { throw ControlError(.notFound, "No definition \(path).") }
        let index: Int? = section == .system ? nil : try Self.componentIndex(edit, section: section, model: model, path: path)
        let item = index.flatMap { definition.item(section, at: $0) } ?? definition.root
        let componentName = section.isTyped ? item["name"]?.stringValue : nil
        guard let component = model.schema.component(section, name: componentName) else {
            throw ControlError(.unsupported, "WE's particle editor has no fields for this \(section.rawValue) (\(componentName ?? "?")).")
        }
        let name = try edit.required("field")
        guard let field = component.field(name) ?? component.fields.first(where: { $0.key == name && $0.bit == nil }) else {
            let fields = component.fields.map(\.id).joined(separator: ", ")
            throw ControlError(.notFound, "\(component.title) has no field \"\(name)\". Its fields: \(fields).")
        }
        let shown = ParticleDefinition.shownValue(of: field, in: item, pixelUnits: model.pixelUnits)
        let text = try edit.string("value")
        let value: SceneJSONValue? = try text.flatMap { text in
            guard !text.isEmpty else { return nil }
            let parsed = SceneControlValues.parse(text, like: field.kind == .vec2 || field.kind == .vec3 ? .string("") : shown)
            if let number = parsed.doubleValue {
                if let minimum = field.minimum, number < minimum { throw ControlError(.invalidParams, "\(field.id) must be at least \(minimum).") }
                if let maximum = field.maximum, number > maximum, field.kind != .number {
                    throw ControlError(.invalidParams, "\(field.id) must be at most \(maximum).")
                }
            }
            if !field.options.isEmpty, !field.options.contains(where: { $0.value == parsed }) {
                let options = field.options.map { "\(SceneControlValues.json($0.value)) (\($0.label))" }.joined(separator: ", ")
                throw ControlError(.invalidParams, "\(field.id) takes \(options).")
            }
            return parsed
        }
        model.setField(field, to: value, section: section, index: index, definition: path, actionName: "")
        return ["definition": .string(path), "section": .string(section.rawValue), "field": .string(field.id)]
    }

    private static func addParticleSystem(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let model = try context.particles()
        let id = try edit.required("system")
        let catalog = context.resources.particleCatalog()
        let item = catalog.items.first { $0.id == id || $0.id == "system:\(id)" }
        let layer: Int?
        switch item?.source {
        case .system(let path)?:
            layer = model.addSystem(from: path, name: try edit.string("name") ?? item?.title ?? path, actionName: "")
        case .preset(let preset, let variant)?:
            layer = model.addPreset(preset, variant: variant, actionName: "")
        case nil:
            throw ControlError(.notFound, catalog.items.isEmpty
                ? "There are no particle systems to add: Wallpaper Engine's assets aren't installed (Settings › Assets)."
                : "No particle system \"\(id)\" in the catalog. particles_catalog lists them (ids such as system:particles/… or preset:rain/0).")
        }
        context.session.selection = nil
        guard let layer else { throw ControlError(.failed, "The particle system's files can't be read.") }
        return ["layer": .number(Double(layer))]
    }
}
