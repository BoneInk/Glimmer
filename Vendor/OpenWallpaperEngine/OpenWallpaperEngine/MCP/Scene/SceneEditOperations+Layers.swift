import Foundation
import OWEControlProtocol
import OWESceneEditing

/// Layer edits: fields and transforms, names, locks, order and parents, text, adding, copying,
/// grouping and deleting layers, and the scene's own settings, as the layer list, the canvas and
/// the inspector make them (`LayerActions`, `SceneEditSession+Layers`).
extension SceneEditOperations {
    static var layerOperations: [String: Operation] {
        [
            "set_field": setField,
            "set_transform": setTransform,
            "set_origin": { edit, context in try setVector(edit, context, field: "origin") },
            "set_scale": { edit, context in try setVector(edit, context, field: "scale") },
            "set_angles": { edit, context in try setVector(edit, context, field: "angles") },
            "set_visible": { edit, context in
                let layer = try Self.layer(edit, context)
                try Self.editableField("visible", of: layer, context)
                context.session.setVisible(try edit.requiredBool("visible"), layer.id, actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "set_alpha": { edit, context in
                let alpha = try edit.requiredDouble("alpha")
                guard (0...1).contains(alpha) else { throw ControlError(.invalidParams, "alpha must be from 0 to 1.") }
                return try Self.setValue(.number(alpha), field: "alpha", edit, context)
            },
            "set_color": { edit, context in
                let color = try SceneControlValues.vector(try edit.required("color"), count: 3, fallback: [1, 1, 1], name: "color")
                return try setValue(SceneVector.value(color), field: "color", edit, context)
            },
            "set_blend_mode": { edit, context in
                let mode = try edit.requiredInt("blend_mode")
                guard mode >= 0 else { throw ControlError(.invalidParams, "blend_mode must be one of WE's blend modes (0 is Normal).") }
                return try Self.setValue(.number(Double(mode)), field: "colorBlendMode", edit, context)
            },
            "set_name": { edit, context in
                let layer = try Self.layer(edit, context)
                context.session.rename(layer.id, to: try edit.required("name"), actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "set_locked": { edit, context in
                let layer = try Self.layer(edit, context)
                context.session.setLocked(try edit.requiredBool("locked"), layer.id, actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "set_parent": setParent,
            "move_layers": moveLayers,
            "step_layer": stepLayer,
            "align_layer": alignLayer,
            "set_text": { edit, context in
                let layer = try Self.textLayer(edit, context)
                guard let text = try edit.string("text") else { throw ControlError(.invalidParams, "text is required.") }
                context.session.setText(text, of: layer.id, actionName: "", coalescing: false)
                return ["layer": .number(Double(layer.id))]
            },
            "set_font": { edit, context in
                let layer = try Self.textLayer(edit, context)
                return try Self.setValue(.string(try edit.required("font")), field: "font", in: layer, context)
            },
            "set_point_size": { edit, context in
                let layer = try Self.textLayer(edit, context)
                let size = try edit.requiredDouble("point_size")
                guard size > 0 else { throw ControlError(.invalidParams, "point_size must be above 0.") }
                return try Self.setValue(.number(size), field: "pointsize", in: layer, context)
            },
            "set_text_script": setTextScript,
            "set_text_script_property": { edit, context in
                let layer = try Self.textLayer(edit, context)
                guard context.session.textScript(of: layer.id) != nil else {
                    throw ControlError(.unsupported, "Layer \(layer.id)'s text has no script; set_text_script gives it one.")
                }
                let key = try edit.required("key")
                let current = context.session.textScriptProperties(of: layer.id)[key]
                let value = SceneControlValues.parse(try edit.required("value"), like: current)
                context.session.setTextScriptProperty(key, to: value, of: layer.id, actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "add_layer": addLayer,
            "remove_layers": { edit, context in
                let ids = try Self.layers(edit, context)
                context.session.delete(ids, actionName: "")
                return ["removed": .array(ids.map { .number(Double($0)) })]
            },
            "duplicate_layers": { edit, context in
                let ids = try Self.layers(edit, context)
                let copies = context.session.duplicate(ids, copyName: { name in
                    name.isEmpty ? String(localized: "Copy", comment: "The name of a copy of a layer without a name")
                        : String(localized: "\(name) Copy", comment: "The name of a copy of a layer")
                }, actionName: "")
                return ["layers": .array(copies.map { .number(Double($0)) })]
            },
            "group_layers": { edit, context in
                let ids = try Self.layers(edit, context)
                let name = try edit.string("name") ?? String(localized: "Group", comment: "The name of a new group of layers")
                guard let group = context.session.group(ids, name: name, actionName: "") else {
                    throw ControlError(.unsupported, "Those layers can't be grouped.")
                }
                return ["layer": .number(Double(group))]
            },
            "ungroup": { edit, context in
                let layer = try Self.layer(edit, context)
                guard !context.session.outline.children(of: layer.id).isEmpty else {
                    throw ControlError(.unsupported, "Layer \(layer.id) has no layers under it.")
                }
                context.session.ungroup(layer.id, actionName: "")
                return ["layer": .number(Double(layer.id))]
            },
            "set_scene_setting": { edit, context in
                let setting = try edit.required("setting")
                let current = context.session.overlay.generalSetting(setting) ?? context.session.authored.general[setting]
                let value = SceneControlValues.parse(try edit.required("value"), like: current)
                context.session.edit(actionName: "") { $0.setGeneralSetting(setting, to: value == current ? nil : value) }
                return ["setting": .string(setting)]
            },
        ]
    }

    // MARK: Fields

    private static func setField(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let field = try edit.required("field")
        guard !["id", "effects", "parent", "objects"].contains(field) else {
            throw ControlError(.refused, "\(field) isn't set with set_field: "
                               + (field == "parent" ? "use set_parent." : field == "effects" ? "use the effect edits." : "it names the layer."))
        }
        let current = context.session.staticValue(field, of: layer.id)
        let value = SceneControlValues.parse(try edit.required("value"), like: current)
        return try Self.setValue(value, field: field, in: layer, context)
    }

    static func setValue(_ value: SceneJSONValue, field: String, _ edit: ControlParameters,
                         _ context: SceneEditOperationContext) throws -> JSONValue {
        try Self.setValue(value, field: field, in: try Self.layer(edit, context), context)
    }

    static func setValue(_ value: SceneJSONValue, field: String, in layer: SceneLayer,
                         _ context: SceneEditOperationContext) throws -> JSONValue {
        try Self.editableField(field, of: layer, context)
        context.session.setValue(value, for: field, of: layer.id, actionName: "")
        return ["layer": .number(Double(layer.id)), "field": .string(field)]
    }

    private static func setVector(_ edit: ControlParameters, _ context: SceneEditOperationContext, field: String) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let fallback = field == "scale" ? [1.0, 1, 1] : [0.0, 0, 0]
        let current = SceneVector.components(context.session.staticValue(field, of: layer.id), fallback: fallback)
        let vector = try SceneControlValues.vector(try edit.required("value"), count: 3, fallback: current, name: "value")
        return try setValue(SceneVector.value(vector), field: field, in: layer, context)
    }

    private static func setTransform(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        var transform = context.session.transform(of: layer.id)
        func read(_ key: String, _ value: SIMD3<Double>) throws -> SIMD3<Double> {
            guard let text = try edit.string(key) else { return value }
            try Self.editableField(key, of: layer, context)
            let parts = try SceneControlValues.vector(text, count: 3, fallback: [value.x, value.y, value.z], name: key)
            return SIMD3(parts[0], parts[1], parts[2])
        }
        transform.origin = try read("origin", transform.origin)
        transform.scale = try read("scale", transform.scale)
        transform.angles = try read("angles", transform.angles)
        guard edit.has("origin") || edit.has("scale") || edit.has("angles") else {
            throw ControlError(.invalidParams, "set_transform needs origin, scale or angles.")
        }
        context.session.setTransform(transform, of: layer.id, actionName: "")
        return ["layer": .number(Double(layer.id))]
    }

    // MARK: Structure

    private static func setParent(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let ids = try Self.layers(edit, context)
        let parent = try edit.int("parent")
        if let parent {
            guard context.session.outline.layer(parent) != nil else { throw ControlError(.notFound, "No layer \(parent) to be the parent.") }
            for id in ids where !context.session.canParent(id, to: parent) {
                throw ControlError(.refused, "Layer \(id) can't go under \(parent): not under itself or a layer under it.")
            }
        }
        context.session.setParent(ids, to: parent, actionName: "")
        return ["layers": .array(ids.map { .number(Double($0)) }), "parent": parent.map { .number(Double($0)) } ?? .null]
    }

    private static func moveLayers(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let ids = try Self.layers(edit, context)
        let target = try Self.layer(edit, context, key: "target")
        let position = try edit.string("position") ?? "above"
        guard ["above", "below"].contains(position) else { throw ControlError(.invalidParams, "position must be \"above\" or \"below\".") }
        guard !ids.contains(where: { context.session.subtree(of: $0).contains(target.id) }) else {
            throw ControlError(.refused, "Layer \(target.id) moves with the layers being moved; pick another target.")
        }
        context.session.move(ids, relativeTo: target.id, above: position == "above", actionName: "")
        return ["order": .array(context.session.outline.layers.map { .number(Double($0.id)) })]
    }

    private static func stepLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        let steps: Int
        switch try edit.string("position") {
        case "top"?: steps = Int.max / 2
        case "bottom"?: steps = -(Int.max / 2)
        case nil:
            guard let count = try edit.int("steps"), count != 0 else {
                throw ControlError(.invalidParams, "step_layer needs steps (positive: up, drawn later) or position \"top\" or \"bottom\".")
            }
            steps = count
        default: throw ControlError(.invalidParams, "position must be \"top\" or \"bottom\".")
        }
        context.session.step(layer.id, by: steps, actionName: "")
        return ["order": .array(context.session.outline.layers.map { .number(Double($0.id)) })]
    }

    private static func alignLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.layer(edit, context)
        guard context.session.geometry(of: layer.id) != nil else {
            throw ControlError(.unsupported, "Layer \(layer.id) has no rectangle on the scene to align (a 3D scene, or a layer that isn't flat).")
        }
        let horizontal = try edit.string("horizontal").map { name -> Int in
            guard let index = ["left", "center", "right"].firstIndex(of: name) else {
                throw ControlError(.invalidParams, "horizontal must be \"left\", \"center\" or \"right\".")
            }
            return index
        }
        let vertical = try edit.string("vertical").map { name -> Int in
            guard let index = ["bottom", "center", "top"].firstIndex(of: name) else {
                throw ControlError(.invalidParams, "vertical must be \"bottom\", \"center\" or \"top\".")
            }
            return index
        }
        guard horizontal != nil || vertical != nil else { throw ControlError(.invalidParams, "align_layer needs horizontal or vertical.") }
        context.session.alignToScene(layer.id, horizontal: horizontal, vertical: vertical, actionName: "")
        return ["layer": .number(Double(layer.id))]
    }

    // MARK: Text

    private static func textLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> SceneLayer {
        let layer = try Self.layer(edit, context)
        guard layer.kind == .text else { throw ControlError(.unsupported, "Layer \(layer.id) isn't a text layer.") }
        return layer
    }

    private static func setTextScript(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let layer = try Self.textLayer(edit, context)
        let name = try edit.required("text_script")
        let script: SceneLayerFactory.TextScript?
        if name == "none" {
            script = nil
        } else if let found = SceneLayerFactory.TextScript(rawValue: name) {
            script = found
        } else {
            throw ControlError(.invalidParams, "text_script must be \"clock\", \"date\" or \"none\".")
        }
        context.session.setTextScript(script, of: layer.id, actionName: "")
        return ["layer": .number(Double(layer.id))]
    }

    // MARK: Adding

    private static func addLayer(_ edit: ControlParameters, _ context: SceneEditOperationContext) throws -> JSONValue {
        let session = context.session
        let (sceneSize, centre) = try SceneAddLayerDefaults.canvas(sceneData: context.resources.sceneData,
                                                                   overlay: session.overlay)
        let origin = SIMD2(try edit.double("x") ?? centre.x, try edit.double("y") ?? centre.y)
        func size(_ fallback: SIMD2<Double>) throws -> SIMD2<Double> {
            let size = SIMD2(try edit.double("width") ?? fallback.x, try edit.double("height") ?? fallback.y)
            guard size.x > 0, size.y > 0 else { throw ControlError(.invalidParams, "width and height must be above 0.") }
            return size
        }
        let kind = try edit.required("kind")
        let name = try edit.string("name")
        let object: [String: SceneJSONValue]
        switch kind {
        case "image":
            if let path = try edit.string("image_path") {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard url.path.hasPrefix("/") else { throw ControlError(.invalidParams, "image_path must be an absolute path.") }
                let image: EditorAssetStore.ImportedImage
                do {
                    image = try context.resources.assetStore.importImage(from: url)
                } catch {
                    throw ControlError(.failed, "\(url.lastPathComponent) couldn't be added: \(error.localizedDescription)")
                }
                object = SceneLayerFactory.image(name: name ?? image.title, model: image.model,
                                                 size: try size(image.size), origin: origin)
            } else if let model = try edit.string("model") {
                let modelSize = SceneAddLayerDefaults.imageSize(ofModel: model, readAsset: context.resources.readAsset)
                object = SceneLayerFactory.image(name: name ?? (model as NSString).lastPathComponent, model: model,
                                                 size: try size(modelSize ?? sceneSize / 2), origin: origin)
            } else {
                throw ControlError(.invalidParams, "An image layer needs image_path (a PNG or JPEG on this Mac) or model (a models/…json the wallpaper has).")
            }
        case "solid":
            let color = try edit.string("color").map { try SceneControlValues.vector($0, count: 3, fallback: [1, 1, 1], name: "color") } ?? [1, 1, 1]
            object = SceneLayerFactory.solid(name: name ?? String(localized: "Solid Color", comment: "The name of a new solid colour layer"),
                                             color: SIMD3(color[0], color[1], color[2]), size: try size(sceneSize), origin: origin)
        case "text":
            let script = try edit.string("text_script").map { value -> SceneLayerFactory.TextScript in
                guard let script = SceneLayerFactory.TextScript(rawValue: value) else {
                    throw ControlError(.invalidParams, "text_script must be \"clock\" or \"date\".")
                }
                return script
            }
            let text = try edit.string("text") ?? script?.placeholder ?? String(localized: "Text", comment: "The text of a new text layer")
            object = SceneLayerFactory.text(name: name ?? text, value: text, font: try edit.string("font") ?? "systemfont_arial",
                                            pointSize: try edit.double("point_size") ?? WETextDefaults.pointSize, origin: origin,
                                            script: script?.source, scriptProperties: script?.properties)
        case "composition":
            object = SceneLayerFactory.composition(name: name ?? String(localized: "Composition", comment: "The name of a new composition layer"),
                                                   size: try size(sceneSize / 2), origin: origin)
        case "fullscreen":
            object = SceneLayerFactory.fullscreen(name: name ?? String(localized: "Fullscreen", comment: "The name of a new fullscreen layer"))
        case "group":
            object = SceneLayerFactory.group(name: name ?? String(localized: "Group", comment: "The name of a new group of layers"), origin: origin)
        default:
            throw ControlError(.invalidParams, "kind must be image, solid, text, composition, fullscreen or group.")
        }
        // Above the layer `above` names, else on top, as the Add menu adds above the selection.
        session.selection = try edit.int("above").map { id in
            guard session.outline.layer(id) != nil else { throw ControlError(.notFound, "No layer \(id) to add above.") }
            return id
        }
        let id = session.addLayer(object, actionName: "")
        session.selection = nil
        return ["layer": .number(Double(id))]
    }
}
