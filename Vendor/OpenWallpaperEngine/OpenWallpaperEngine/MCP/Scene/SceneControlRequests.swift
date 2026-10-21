import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing

/// The control channel's requests for the scene and both editors (`docs/mcp.md`): the edit model
/// through headless edit sessions on the Wallpaper Editor's draft (`HeadlessSceneEditService`),
/// saving it, the read tools, SceneScript, depth maps and the editors' windows.
@MainActor
final class SceneControlRequests: ControlRequestGroup {
    let methods: Set<String> = [
        "scene_get", "scene_apply_edits", "scene_undo", "scene_redo", "wallpaper_editor_save", "wallpaper_editor_save_as_new",
        "scene_save", "scene_save_as_local_wallpaper",
        "scene_revert", "effects_catalog", "particles_catalog", "particles_get", "particles_restart", "puppets_list",
        "timeline_get", "timeline_preview", "script_get", "script_set", "script_check", "user_properties_get",
        "depth_generate", "depth_apply", "depth_remove", "use_depth_map_as_mask", "editor_close", "editor_set_tab",
    ]

    /// The tabs `editor_set_tab` names, and Scene Edit / Export's modes they are.
    static let tabs: [String: SceneInspectorMode] = [
        "wallpaper": .wallpaper, "screen_saver": .screenSaver, "iphone_ipad_export": .deviceExport, "android_export": .androidExport,
    ]

    private let service: HeadlessSceneEditService
    private let editors: SceneEditorControl
    private let particleSchema: () throws -> ParticleEditorSchema

    init(service: HeadlessSceneEditService, editors: SceneEditorControl,
         particleSchema: @escaping () throws -> ParticleEditorSchema = { try ParticleEditorServices.bundledSchema() }) {
        self.service = service
        self.editors = editors
        self.particleSchema = particleSchema
    }

    static func make(app: AppDelegate, model: AppControlModel) -> SceneControlRequests {
        let service = HeadlessSceneEditService(dependencies: .init(
            resources: { [unowned app] wallpaper in
                guard let found = model.find(wallpaper) else { throw AppControlModel.missing(wallpaper) }
                return try WallpaperSceneEditResources(wallpaper: found, depthMapGenerator: DepthMapPlugin.generator)
            },
            announce: { [unowned app] folder, actionName, step in
                app.editorChangeSync.appOverlayDidSave(folder: folder, actionName: actionName, step: step)
            },
            announceSave: { [unowned app] folder, overlay in
                app.editorChangeSync.appDraftDidSave(folder: folder, overlay: overlay)
            }))
        return SceneControlRequests(service: service, editors: AppSceneEditorControl(app: app, model: model))
    }

    func result(for method: String, _ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue {
        switch method {
        case "script_check": return try scriptCheck(params)
        case "editor_close": return try editorClose(params, lookup)
        case "editor_set_tab": return try editorSetTab(params, lookup)
        case "timeline_preview": return try timelinePreview(params, lookup)
        default: break
        }
        let wallpaper = try lookup.sceneWallpaper(try params.required("wallpaper_id"))
        let document = try service.document(for: wallpaper)
        switch method {
        case "scene_get": return SceneControlSnapshot.scene(document)
        case "scene_apply_edits": return try applyEdits(params, document)
        case "scene_undo", "scene_redo": return undo(document, redo: method == "scene_redo")
        // The older names (deprecated) do the same, so existing clients keep working.
        case "wallpaper_editor_save", "scene_save": return try save(document)
        case "wallpaper_editor_save_as_new", "scene_save_as_local_wallpaper": return try saveAsNew(params, document)
        case "scene_revert": return revert(params, document)
        case "effects_catalog":
            return SceneControlSnapshot.effects(document, query: try params.string("query") ?? "")
        case "particles_catalog":
            return SceneControlSnapshot.particles(document, query: try params.string("query") ?? "")
        case "particles_get": return try particlesGet(params, document)
        case "particles_restart": return try await particlesRestart(params, document)
        case "puppets_list": return SceneControlSnapshot.puppets(document)
        case "timeline_get": return SceneControlSnapshot.timelines(document, layer: try params.int("layer"))
        case "script_get": return try scriptGet(params, document)
        case "script_set": return try scriptSet(params, document)
        case "user_properties_get":
            let properties = UserPropertyAuthoring(session: document.session, projectJSON: document.resources.projectJSON)
            return [
                "user_properties": .array(properties.properties.map(SceneControlSnapshot.userProperty)),
                "edited": .bool(properties.isEdited),
                "bound_fields": .object(Dictionary(uniqueKeysWithValues: properties.properties.map { draft in
                    (draft.key, JSONValue.array(document.session.fields(boundTo: draft.key).map { bound in
                        ["layer": .number(Double(bound.layer)), "field": .string(bound.path.description)]
                    }))
                })),
            ]
        case "depth_generate": return try await depthGenerate(params, document)
        case "depth_apply": return try depthApply(params, document)
        case "depth_remove": return try depthRemove(params, document)
        case "use_depth_map_as_mask": return try useDepthMapAsMask(params, document)
        default:
            throw ControlError(.unknownMethod, "The app doesn't know \"\(method)\".")
        }
    }

    // MARK: Editing

    private func applyEdits(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let edits = try params.objects("edits")
        guard !edits.isEmpty else { throw ControlError(.invalidParams, "edits is required: a list of edits, each with its \"op\".") }
        let results = try document.apply(edits, actionName: try params.string("action_name"))
        let count = edits.count
        return [
            "results": .array(results),
            "undo": SceneControlSnapshot.undoState(document.session),
            "message": .string("Applied \(count) edit\(count == 1 ? "" : "s") to the draft of \"\(document.wallpaper.title)\" as one undo step; it shows in its open Wallpaper Editor window, and on the displays once wallpaper_editor_save saves it."),
        ]
    }

    private func undo(_ document: HeadlessSceneDocument, redo: Bool) -> JSONValue {
        let name = redo ? document.session.undoManager.redoActionName : document.session.undoManager.undoActionName
        let done = redo ? document.redo() : document.undo()
        let verb = redo ? "Redid" : "Undid"
        return [
            "done": .bool(done), "action": done ? .string(name) : .null,
            "undo": SceneControlSnapshot.undoState(document.session),
            "message": .string(done ? "\(verb) \"\(name)\" on \"\(document.wallpaper.title)\"."
                : "Nothing to \(redo ? "redo" : "undo") in this client's edits of \"\(document.wallpaper.title)\"."),
        ]
    }

    private func save(_ document: HeadlessSceneDocument) throws -> JSONValue {
        let saved = try document.save()
        return [
            "saved": .bool(saved), "unsaved": .bool(document.hasUnsavedChanges),
            "message": .string(saved
                ? "Saved the changes to \"\(document.wallpaper.title)\": the displays running it show them now (the wallpaper's own files aren't changed; the edits are kept beside it)."
                : "\"\(document.wallpaper.title)\" has no unsaved changes."),
        ]
    }

    private func saveAsNew(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let title = try params.string("title").flatMap { $0.isEmpty ? nil : $0 }
            ?? String(localized: "\(document.wallpaper.title) (Edited)", comment: "Wallpaper Editor: the suggested title of a wallpaper saved with its edits")
        let folder: URL
        do {
            folder = try editors.saveAsNewWallpaper(document, title: title)
        } catch let error as ControlError {
            throw error
        } catch {
            throw ControlError(.failed, "\"\(document.wallpaper.title)\" couldn't be saved as a new wallpaper: \(error.localizedDescription)")
        }
        return [
            "id": .string(folder.lastPathComponent), "title": .string(title), "folder": .string(folder.path),
            "message": .string("Saved \"\(title)\" to the library with the edits (id \(folder.lastPathComponent)). \"\(document.wallpaper.title)\" and its draft are as they were."),
        ]
    }

    private func revert(_ params: ControlParameters, _ document: HeadlessSceneDocument) -> JSONValue {
        let reverted = document.revertToSaved()
        return [
            "reverted": .bool(reverted), "undo": SceneControlSnapshot.undoState(document.session),
            "message": .string(reverted ? "The draft of \"\(document.wallpaper.title)\" is back to the last save (scene_undo brings the changes back)."
                : "\"\(document.wallpaper.title)\" has no unsaved changes to its scene."),
        ]
    }

    // MARK: Particles

    private func particleLayer(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> SceneLayer {
        let id = try params.requiredInt("layer")
        guard let layer = document.session.outline.layer(id), layer.kind == .particle else {
            throw ControlError(.notFound, "Layer \(id) isn't a particle system. scene_get lists the layers.")
        }
        return layer
    }

    private func particlesGet(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let layer = try particleLayer(params, document)
        let schema: ParticleEditorSchema
        do {
            schema = try particleSchema()
        } catch {
            throw ControlError(.unavailable, "The particle editor's schema can't be read: \(error.localizedDescription)")
        }
        return SceneControlSnapshot.particleSystem(document, layer: layer, schema: schema)
    }

    private func particlesRestart(_ params: ControlParameters, _ document: HeadlessSceneDocument) async throws -> JSONValue {
        let layer = try particleLayer(params, document)
        let inEditor = await editors.restartParticles(document, layer: layer.id)
        return [
            "layer": .number(Double(layer.id)), "in_editor": .bool(inEditor),
            "message": .string(inEditor
                ? "Particle system \(layer.id) starts again from nothing in the open Wallpaper Editor window's canvas (the draft)."
                : "Particle system \(layer.id) starts again from nothing on the displays running the wallpaper."),
        ]
    }

    // MARK: Scripts

    private func scriptCheck(_ params: ControlParameters) throws -> JSONValue {
        let diagnostics = SceneScriptSyntaxCheck.diagnostics(of: try params.required("script"))
        let errors = diagnostics.filter { $0.severity == .error }.count
        return [
            "valid": .bool(errors == 0),
            "diagnostics": .array(diagnostics.map { diagnostic in
                [
                    "line": diagnostic.line.map { .number(Double($0)) } ?? .null, "message": .string(diagnostic.message),
                    "severity": .string(diagnostic.severity == .error ? "error" : "warning"),
                ]
            }),
            "message": .string(errors == 0 ? "The script's syntax is valid." : "The script has \(errors) error\(errors == 1 ? "" : "s")."),
        ]
    }

    private func scriptGet(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let context = SceneEditOperationContext(session: document.session, resources: document.resources,
                                                timelineIndex: document.timelineIndex, particleSchema: particleSchema)
        let (layer, path) = try SceneEditOperations.fieldPath(params, context)
        return SceneControlSnapshot.script(document, layer: layer, path: path)
    }

    /// The script editor's Apply: checked first, then attached as one undo step.
    private func scriptSet(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        var edit = params.raw
        edit["op"] = "set_script"
        edit["wallpaper_id"] = nil
        let results = try document.apply([ControlParameters(edit)], actionName: try params.string("action_name"))
        var result = results.first?.objectValue ?? [:]
        result["message"] = .string("Applied the script to \(result["field"]?.stringValue ?? "the field") of layer \(result["layer"]?.intValue.map(String.init) ?? "?"); it runs from the wallpaper's reload.")
        return .object(result)
    }

    // MARK: Depth maps

    private func depthModel(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> DepthMapSectionModel {
        guard editors.isDepthMapPluginInstalled else {
            throw ControlError(.unavailable, "Depth Map Generation isn't installed. The user installs it in Open Wallpaper Engine's Settings › Plugins; plugin_status shows it.")
        }
        let layer = try params.int("layer")
        if let layer, document.session.outline.layer(layer) == nil { throw ControlError(.notFound, "No layer \(layer).") }
        guard let model = document.depthModel(layer: layer) else { throw ControlError(.unavailable, "Depth maps can't be made here.") }
        guard model.isSupported else { throw ControlError(.unsupported, "Only image and text layers can have a mask from a depth map.") }
        return model
    }

    private func depthGenerate(_ params: ControlParameters, _ document: HeadlessSceneDocument) async throws -> JSONValue {
        let model = try depthModel(params, document)
        if let smoothing = try params.double("smoothing") {
            guard (0...1).contains(smoothing) else { throw ControlError(.invalidParams, "smoothing must be from 0 to 1.") }
            model.smoothing = smoothing
        }
        await model.generate()
        if let problem = model.problem { throw ControlError(.failed, "The depth map couldn't be made: \(problem)") }
        if try params.bool("apply") == true { return try depthApply(params, document) }
        let next = model.layerID == nil ? "depth_apply puts WE's Depth Parallax on the scene with it."
            : "use_depth_map_as_mask writes it as the mask of one of the layer's effects."
        return [
            "texture": model.generatedTexture.map { .string($0) } ?? .null, "one_frame": .bool(model.isOneFrame),
            "applied": .bool(model.isApplied),
            "message": .string(model.isApplied ? "Made a new depth map; the applied depth parallax now uses it."
                : "Made the depth map; " + next),
        ]
    }

    private func depthApply(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let model = try depthModel(params, document)
        // Depth parallax is the scene's; a layer's depth map makes masks.
        if model.layerID != nil, try !model.isApplied || params.double("strength") == nil {
            throw ControlError(.refused, "Depth parallax goes on the whole scene: call depth_apply without layer. A layer's depth map becomes an effect's mask with use_depth_map_as_mask.")
        }
        if let strength = try params.double("strength") {
            guard SceneDepthParallax.strengthRange.contains(strength) else {
                throw ControlError(.invalidParams, "strength must be from \(SceneDepthParallax.strengthRange.lowerBound) to \(SceneDepthParallax.strengthRange.upperBound).")
            }
            if model.isApplied {
                model.strength = strength
                return ["applied": true, "message": .string("Set the depth parallax's strength to \(strength).")]
            }
            model.pendingStrength = strength
        }
        guard model.generatedTexture != nil || model.appliedTexture != nil else {
            throw ControlError(.refused, "There is no depth map for it yet; depth_generate makes one.")
        }
        model.apply()
        if let problem = model.problem { throw ControlError(.failed, "Depth parallax couldn't be applied: \(problem)") }
        return ["applied": .bool(model.isApplied), "texture": model.appliedTexture.map { .string($0) } ?? .null,
                "message": .string("Applied WE's Depth Parallax with the depth map; it follows the pointer.")]
    }

    private func useDepthMapAsMask(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        guard let layer = try params.int("layer") else { throw ControlError(.invalidParams, "layer is required.") }
        let model = try depthModel(params, document)
        guard model.generatedTexture != nil else {
            throw ControlError(.refused, "There is no depth map for the layer yet; depth_generate makes one.")
        }
        let targets = model.maskTargets
        guard !targets.isEmpty else {
            throw ControlError(.refused, "The layer has no effect with a mask, and WE's Opacity effect isn't available (Settings › Assets); add one first (add_effect), such as Shake, Water Ripple or Tint.")
        }
        let effect = try params.required("effect")
        let slot = try params.int("slot")
        let layerOpacity = effect.caseInsensitiveCompare("opacity") == .orderedSame
        let matching = layerOpacity ? targets.filter(\.isLayerOpacity)
            : targets.filter { $0.effectKey == effect && (slot == nil || $0.slot.slot == slot) }
        guard let target = matching.first, matching.count == 1 else {
            let known = targets.map { target in
                target.isLayerOpacity ? "effect \"opacity\" (\(target.title)\(target.addsEffect ? ", adds WE's Opacity effect" : ""))"
                    : "effect \"\(target.effectKey)\" slot \(target.slot.slot) (\(target.title))"
            }.joined(separator: ", ")
            throw ControlError(matching.isEmpty ? .notFound : .invalidParams,
                               (matching.isEmpty ? "No mask to fill there. " : "The effect has several masks; give slot. ") + "Masks: \(known).")
        }
        let contrast = try params.double("contrast") ?? DepthMask.defaultContrast
        guard DepthMask.contrastRange.contains(contrast) else {
            throw ControlError(.invalidParams, "contrast must be from \(DepthMask.contrastRange.lowerBound) to \(DepthMask.contrastRange.upperBound).")
        }
        model.maskInverted = try params.bool("invert") ?? false
        model.maskContrast = contrast
        model.useAsMask(target)
        if let problem = model.problem { throw ControlError(.failed, "The mask couldn't be written: \(problem)") }
        let effectKey = target.addsEffect ? (model.maskTargets.first(where: \.isLayerOpacity)?.effectKey ?? "") : target.effectKey
        let mask = document.session.effectTexture(target.slot.slot, pass: target.slot.pass, effect: effectKey, of: layer)
        let message = target.addsEffect ? "Added WE's Opacity effect with the depth map as its mask: the layer is now transparent where the mask is black (scene_undo takes both off)."
            : target.replacesMask ? "Replaced the effect's mask with the depth map (scene_undo brings the old one back; its file is kept)."
            : target.isLayerOpacity ? "The depth map is now the layer's opacity (its Opacity effect's mask)."
            : "The depth map is now the effect's mask."
        return ["layer": .number(Double(layer)), "effect": .string(effectKey), "slot": .number(Double(target.slot.slot)),
                "layer_opacity": .bool(target.isLayerOpacity), "added_effect": .bool(target.addsEffect),
                "mask": mask.map { .string($0) } ?? .null, "replaced": target.currentMask.map { .string($0) } ?? .null,
                "message": .string(message)]
    }

    private func depthRemove(_ params: ControlParameters, _ document: HeadlessSceneDocument) throws -> JSONValue {
        let model = try depthModel(params, document)
        guard model.isApplied else { throw ControlError(.notFound, "It has no depth parallax to remove.") }
        model.remove()
        return ["applied": .bool(model.isApplied), "message": .string("Removed the depth parallax (scene_undo brings it back).")]
    }

    // MARK: Editors

    private func editor(_ params: ControlParameters) throws -> String {
        let editor = try params.required("editor")
        guard ["scene", "wallpaper"].contains(editor) else { throw ControlError(.invalidParams, "editor must be \"scene\" or \"wallpaper\".") }
        return editor
    }

    private func editorClose(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        if try editor(params) == "scene" {
            let closed = editors.closeSceneEditor()
            return ["closed": .bool(closed), "message": .string(closed ? "Closed Scene Edit / Export." : "Scene Edit / Export wasn't open.")]
        }
        let wallpaper = try lookup.sceneWallpaper(try params.required("wallpaper_id"))
        let sent = editors.closeWallpaperEditor(wallpaper)
        return ["closed": .bool(sent), "message": .string(sent ? "Asked the Wallpaper Editor to close \"\(wallpaper.title)\"."
                    : "The Wallpaper Editor isn't running.")]
    }

    private func editorSetTab(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let name = try params.required("tab")
        guard let mode = Self.tabs[name] else {
            throw ControlError(.invalidParams, "tab must be one of \(Self.tabs.keys.sorted().joined(separator: ", ")).")
        }
        let wallpaper = try lookup.sceneWallpaper(try params.required("wallpaper_id"))
        try editors.showSceneEditor(wallpaper, mode: mode)
        return ["tab": .string(name), "message": .string("Scene Edit / Export shows \"\(wallpaper.title)\" on its \(name) tab.")]
    }

    private func timelinePreview(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let command = try params.required("command")
        guard ["play", "pause", "seek"].contains(command) else { throw ControlError(.invalidParams, "command must be play, pause or seek.") }
        let seconds = try params.double("seconds")
        if command == "seek" {
            guard let seconds, seconds >= 0 else { throw ControlError(.invalidParams, "seek needs seconds, 0 or later.") }
        }
        let wallpaper = try lookup.sceneWallpaper(try params.required("wallpaper_id"))
        guard editors.controlTimeline(wallpaper, command: command, seconds: seconds) else {
            throw ControlError(.unavailable, "The Wallpaper Editor isn't running; open_editor with editor \"wallpaper\" opens it, then its timeline can be played.")
        }
        return ["command": .string(command), "message": .string("Sent \(command) to the timeline of \"\(wallpaper.title)\"'s Wallpaper Editor window.")]
    }
}
