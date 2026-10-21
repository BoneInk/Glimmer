import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing

/// The scene as the read tools write it: the layer tree with what the editor shows of each layer
/// (`scene_get`), its puppets, timelines, scripts and user properties, and the catalogs.
@MainActor
enum SceneControlSnapshot {
    // MARK: scene_get

    static func scene(_ document: HeadlessSceneDocument) -> JSONValue {
        let session = document.session
        let outline = session.outline
        let size: JSONValue = outline.size.map { ["width": .number($0.x), "height": .number($0.y)] } ?? .null
        return [
            "wallpaper": ControlLookup.json(document.wallpaper),
            "size": size,
            "general": .object(outline.general.mapValues(SceneControlValues.json)
                .merging((session.overlay.general ?? [:]).mapValues(SceneControlValues.json)) { _, edited in edited }),
            "layers": .array(outline.layers.map { layer(session, $0, resources: document.resources) }),
            "edited": .bool(session.overlay.hasSceneEdits),
            "unsaved": .bool(document.hasUnsavedChanges),
            "undo": undoState(session),
            "user_properties": .array(UserPropertyAuthoring(session: session, projectJSON: document.resources.projectJSON)
                .properties.map(userProperty)),
        ]
    }

    static func undoState(_ session: SceneEditSession) -> JSONValue {
        [
            "can_undo": .bool(session.canUndo), "can_redo": .bool(session.canRedo),
            "undo_action": session.canUndo ? .string(session.undoManager.undoActionName) : .null,
            "redo_action": session.canRedo ? .string(session.undoManager.redoActionName) : .null,
        ]
    }

    /// The fields a layer's entry always shows (as the inspector does), with WE's value when unset.
    private static let shownFields = ["origin", "scale", "angles", "alpha", "color", "colorBlendMode", "visible", "size"]

    private static func layer(_ session: SceneEditSession, _ layer: SceneLayer, resources: SceneEditResources) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        for key in Set(layer.fields.keys).union(shownFields) where !["effects", "id", "parent", "name"].contains(key) {
            if let value = session.value(key, of: layer.id) { fields[key] = SceneControlValues.json(value) }
        }
        var bindings: [String: JSONValue] = [:]
        var scripts: [String: JSONValue] = [:]
        for key in layer.fields.keys {
            let path = SceneFieldPath(components: [key])
            let drivers = session.drivers(path, of: layer.id)
            if let user = drivers.user { bindings[key] = .string(user.name) }
            if drivers.script != nil { scripts[key] = .bool(true) }
        }
        for effect in layer.effects {
            let path = SceneFieldPath.effect(effect.id)
            if let user = session.drivers(path, of: layer.id).user { bindings[path.description] = .string(user.name) }
            if session.drivers(path, of: layer.id).script != nil { scripts[path.description] = .bool(true) }
        }
        var object: [String: JSONValue] = [
            "id": .number(Double(layer.id)),
            "name": layer.name.map { .string($0) } ?? .null,
            "kind": .string(layer.kind.rawValue),
            "order": .number(Double(layer.index)),
            "parent": layer.parentID.map { .number(Double($0)) } ?? .null,
            "visible": .bool(session.isVisible(layer.id)),
            "locked": .bool(session.isLocked(layer.id)),
            "edited": .bool(session.isEdited(layer.id)),
            "fields": .object(fields),
            "bindings": .object(bindings),
            "scripts": .object(scripts),
            "effects": .array(layer.effects.map { effect(session, $0, of: layer.id) }),
        ]
        if let role = layer.imageRole { object["image_role"] = .string(role.rawValue) }
        if let text = session.textContent(of: layer.id) { object["text"] = .string(text) }
        if layer.kind == .text { object["text_script"] = SceneLayerFactory.TextScript(source: session.textScript(of: layer.id)).map { .string($0.rawValue) } ?? .null }
        if layer.kind == .particle {
            object["particle"] = session.value("particle", of: layer.id).map(SceneControlValues.json) ?? .null
        }
        if layer.imageRole == .picture {
            let rig = session.puppet(of: layer.id) != nil ? "edited"
                : (PuppetSource.load(layer: layer, assets: resources.puppetAssets)?.rigPath != nil ? "authored" : "none")
            object["puppet"] = .string(rig)
        }
        return .object(object)
    }

    private static func effect(_ session: SceneEditSession, _ effect: SceneLayerEffect, of layerID: Int) -> JSONValue {
        var constants: [String: JSONValue] = [:]
        let edits = session.overlay.effectEdit(effect.key, of: layerID)
        let editedConstants: [String] = edits.map { Array($0.constants.keys) } ?? []
        for key in Set(effect.constants.keys).union(editedConstants) {
            constants[key] = SceneControlValues.json(session.effectConstant(key, effect: effect.key, of: layerID))
        }
        var combos: [String: JSONValue] = [:]
        let editedCombos: [String] = Array((edits?.combos ?? [:]).keys)
        for key in Set(effect.combos.keys).union(editedCombos) {
            combos[key] = .number(Double(session.effectCombo(key, effect: effect.key, of: layerID, default: 0)))
        }
        var bindings: [String: JSONValue] = [:]
        let editedBindings: [String] = Array((edits?.bindings ?? [:]).keys)
        for key in Set(effect.constants.keys).union(editedBindings) {
            if let property = session.effectBinding(key, effect: effect.key, of: layerID) { bindings[key] = .string(property) }
        }
        // By slot for the first pass ("1"), "pass:slot" for a later one ("3:1", Blur's mask).
        var textures: [String: JSONValue] = [:]
        for (pass, authored) in (effect.passTextures.isEmpty ? [effect.textures] : effect.passTextures).enumerated() {
            for slot in 0..<authored.count {
                if let texture = session.effectTexture(slot, pass: pass, effect: effect.key, of: layerID) {
                    textures[SceneEditOverlay.EffectEdit.textureKey(pass: pass, slot: slot)] = .string(texture)
                }
            }
        }
        for (key, value) in edits?.textures ?? [:] where textures[key] == nil {
            if let texture = value.stringValue { textures[key] = .string(texture) }
        }
        return [
            "key": .string(effect.key), "file": .string(effect.file), "title": .string(effect.title),
            "visible": .bool(session.isEffectVisible(effect, of: layerID)), "added": .bool(effect.isAdded),
            "passes": .number(Double(effect.passCount)), "constants": .object(constants), "combos": .object(combos),
            "textures": .object(textures), "bindings": .object(bindings),
        ]
    }

    static func userProperty(_ draft: UserPropertyDraft) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(draft.key), "kind": .string(draft.kind.rawValue), "label": .string(draft.text),
            "value": draft.value.map(SceneControlValues.json) ?? .null,
            "condition": draft.condition.map { .string($0) } ?? .null,
        ]
        if draft.kind == .slider {
            object["min"] = draft.minimum.map { .number($0) } ?? .null
            object["max"] = draft.maximum.map { .number($0) } ?? .null
            object["step"] = draft.step.map { .number($0) } ?? .null
            object["whole_numbers"] = .bool(draft.fraction == false)
        }
        if draft.kind == .combo {
            object["options"] = .array(draft.options.map { ["label": .string($0.label), "value": .string($0.value)] })
        }
        return .object(object)
    }

    // MARK: Puppets

    static func puppets(_ document: HeadlessSceneDocument) -> JSONValue {
        let session = document.session
        let rigs: [JSONValue] = session.outline.layers.filter { $0.imageRole == .picture }.compactMap { layer in
            let source = PuppetSource.load(layer: layer, assets: document.resources.puppetAssets)
            guard let rig = session.puppet(of: layer.id) ?? source?.document else { return nil }
            return [
                "layer": .number(Double(layer.id)), "name": layer.name.map { .string($0) } ?? .null,
                "edited": .bool(session.puppet(of: layer.id) != nil),
                "image_size": ["width": .number(Double(rig.imageSize.x)), "height": .number(Double(rig.imageSize.y))],
                "vertices": .number(Double(rig.mesh.vertices.count)),
                "bones": .array(rig.bones.enumerated().map { index, bone in
                    let local = bone.rest ?? bone.local
                    return [
                        "index": .number(Double(index)), "name": .string(bone.name),
                        "parent": bone.parent.map { .number(Double($0)) } ?? .null,
                        "x": .number(Double(local.translation.x)), "y": .number(Double(local.translation.y)),
                        "angle": .number(Double(local.euler.z) * 180 / .pi),
                        "physics": .bool(bone.physics != nil),
                    ]
                }),
                "animations": .array(rig.clips.enumerated().map { index, clip in
                    var keys: [String: JSONValue] = [:]
                    for (bone, track) in clip.tracks.enumerated() where !track.isEmpty {
                        keys[String(bone)] = .array(track.keys.keys.sorted().map { .number(Double($0)) })
                    }
                    return [
                        "index": .number(Double(index)), "name": .string(clip.name), "mode": .string(clip.mode.rawValue),
                        "fps": .number(Double(clip.fps)), "frames": .number(Double(clip.frames)), "keys_by_bone": .object(keys),
                    ]
                }),
                "animation_layers": .array(rig.layers.enumerated().map { index, animationLayer in
                    [
                        "index": .number(Double(index)), "name": .string(animationLayer.name),
                        "animation": rig.clips.firstIndex { $0.id == animationLayer.clipID }.map { .number(Double($0)) } ?? .null,
                        "visible": .bool(animationLayer.visible), "blend": .number(Double(animationLayer.blend)),
                        "rate": .number(Double(animationLayer.rate)), "additive": .bool(animationLayer.additive),
                        "blend_in": .bool(animationLayer.blendIn), "blend_out": .bool(animationLayer.blendOut),
                        "blend_time": .number(Double(animationLayer.blendTime)),
                    ]
                }),
            ]
        }
        return ["puppets": .array(rigs)]
    }

    // MARK: Timelines

    static func timelines(_ document: HeadlessSceneDocument, layer: Int?) -> JSONValue {
        let timeline = SceneTimelineEditor(session: document.session, index: document.timelineIndex)
        let layers = layer.map { [$0] } ?? document.timelineIndex.layers
        let entries: [JSONValue] = layers.map { id in
            let properties = document.timelineIndex.properties(of: id)
            return [
                "layer": .number(Double(id)),
                "tracks": .array(properties.compactMap { property -> JSONValue? in
                    guard let clip = timeline.clip(property.target) else { return nil }
                    guard case .object(var track) = SceneEditOperations.trackJSON(property.target) else { return nil }
                    track["fps"] = .number(clip.fps)
                    track["frames"] = .number(Double(clip.length))
                    track["mode"] = .string(clip.mode.rawValue)
                    track["relative"] = .bool(clip.relative)
                    track["name"] = clip.name.map { .string($0) } ?? .null
                    track["channels"] = .array(clip.channels.map { channel in
                        .array(channel.map { keyframe in
                            ["frame": .number(Double(keyframe.frame)), "value": .number(keyframe.value), "hold": .bool(keyframe.step)]
                        })
                    })
                    return .object(track)
                }),
                "animatable": .array(properties.filter { !$0.isUserBound }.map { SceneEditOperations.trackJSON($0.target) }),
            ]
        }
        return ["layers": .array(entries)]
    }

    // MARK: Scripts

    static func script(_ document: HeadlessSceneDocument, layer: SceneLayer, path: SceneFieldPath) -> JSONValue {
        let drivers = document.session.drivers(path, of: layer.id)
        return [
            "layer": .number(Double(layer.id)), "field": .string(path.description),
            "script": drivers.script.map { .string($0.source) } ?? .null,
            "script_properties": .object((drivers.script?.scriptProperties ?? [:]).mapValues(SceneControlValues.json)),
            "declared_properties": .array(drivers.script.map { SceneScriptPropertyDeclaration.declarations(in: $0.source) }?.map { declaration in
                ["name": .string(declaration.name), "label": .string(declaration.label), "kind": .string(declaration.kind.rawValue),
                 "default": declaration.value.map(SceneControlValues.json) ?? .null]
            } ?? []),
            "user_property": drivers.user.map { .string($0.name) } ?? .null,
            "animated": .bool(drivers.hasAnimation),
            "scripted_fields": .array(document.session.scriptedFields(of: layer.id).map { .string($0.description) }),
        ]
    }

    // MARK: Catalogs

    static func effects(_ document: HeadlessSceneDocument, query: String) -> JSONValue {
        let entries = EffectCatalog.filter(document.resources.effectCatalog(outline: document.session.authored), query: query)
        return [
            "effects": .array(entries.map { entry in
                let schema = document.resources.effectSchema(entry.file)
                return [
                    "file": .string(entry.file), "title": .string(entry.title), "group": .string(entry.groupTitle),
                    "summary": .string(entry.summary), "workshop": .bool(entry.isWorkshop),
                    "passes": .number(Double(schema?.passCount ?? entry.passCount)),
                    "constants": .array((schema?.parameters ?? []).map { parameter in
                        [
                            "key": .string(parameter.key), "title": .string(parameter.title),
                            "default": .array(parameter.defaultValue.map { .number($0) }),
                            "min": .number(parameter.minimum), "max": .number(parameter.maximum),
                            "integer": .bool(parameter.isInteger), "color": .bool(parameter.isColor),
                        ]
                    }),
                    "combos": .array((schema?.combos ?? []).map { combo in
                        [
                            "name": .string(combo.name), "title": .string(combo.title), "default": .number(Double(combo.defaultValue)),
                            "options": .array(combo.options.map { ["value": .number(Double($0.value)), "title": .string($0.title)] }),
                        ]
                    }),
                    "textures": .array((schema?.textures ?? []).map { slot in
                        ["slot": .number(Double(slot.slot)), "pass": .number(Double(slot.pass)), "title": .string(slot.title),
                         "mask": .bool(slot.isMask),
                         "default": slot.defaultTexture.map { .string($0) } ?? .null]
                    }),
                ]
            }),
        ]
    }

    static func particles(_ document: HeadlessSceneDocument, query: String) -> JSONValue {
        let catalog = document.resources.particleCatalog()
        let items = ParticleCatalog.filter(catalog.items, query: query)
        return [
            "systems": .array(items.map { item in
                var object: [String: JSONValue] = [
                    "id": .string(item.id), "title": .string(item.title), "summary": .string(item.summary),
                    "group": .string(item.group.title), "scene_3d": .bool(item.is3D),
                ]
                switch item.source {
                case .system(let path): object["kind"] = "system"; object["path"] = .string(path)
                case .preset(let preset, let variant):
                    object["kind"] = "preset"
                    object["preset"] = .string(preset.id)
                    object["variant"] = .string(variant.title)
                }
                return .object(object)
            }),
            "has_presets": .bool(catalog.hasPresets),
        ]
    }

    /// A particle layer's definition as the scene reads it, with the editor's field names.
    static func particleSystem(_ document: HeadlessSceneDocument, layer: SceneLayer, schema: ParticleEditorSchema) -> JSONValue {
        let model = ParticleEditingModel(session: document.session, schema: schema, readAsset: { [resources = document.resources] in resources.readAsset($0) })
        let path = model.particlePath(of: layer.id)
        let definition = path.flatMap(model.definition)
        var sections: [String: JSONValue] = [:]
        for section in ParticleEditorSchema.Section.lists {
            sections[section.rawValue] = .array((definition?.items(section) ?? []).map { item in
                .object(item.mapValues(SceneControlValues.json))
            })
        }
        return [
            "layer": .number(Double(layer.id)), "definition": path.map { .string($0) } ?? .null,
            "edited": .bool(path.map(model.isEdited) ?? false),
            "system": definition.map { .object($0.root.filter { !(ParticleEditorSchema.Section.lists.compactMap(\.listKey)).contains($0.key) }.mapValues(SceneControlValues.json)) } ?? .null,
            "sections": .object(sections),
            "material": path.flatMap(model.material(ofDefinition:)).map { SceneControlValues.json($0.json) } ?? .null,
            "instance_override": .object(model.instanceOverride(of: layer.id).mapValues(SceneControlValues.json)),
            "components": .array(ParticleEditorSchema.Section.lists.flatMap { section in
                schema.components(in: section).filter(\.isAddable).map { component in
                    ["section": .string(section.rawValue), "component": component.name.map { .string($0) } ?? .null,
                     "title": .string(component.title), "fields": .array(component.fields.map { .string($0.id) })]
                }
            }),
        ]
    }
}
