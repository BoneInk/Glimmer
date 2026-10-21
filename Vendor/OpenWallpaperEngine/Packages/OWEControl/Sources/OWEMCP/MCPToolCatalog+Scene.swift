import Foundation
import OWEControlProtocol

/// The scene and both editors (`docs/mcp.md`, "Scene and editors"): the edit model of the
/// Wallpaper Editor and Scene Edit / Export, driven through the app's own edit sessions, the
/// read tools, SceneScript, depth maps and the editors' windows.
extension MCPToolCatalog {
    static let sceneTools: [MCPTool] = sceneEditing + sceneReading + sceneAuthoring + sceneWindows

    private static let sceneWallpaper = JSONSchema.string(
        "A scene wallpaper's id from list_wallpapers (its folder name; its Workshop id or folder path also work).", minLength: 1)
    private static let layerID = JSONSchema.integer("A layer's id, from scene_get.")

    // MARK: - Edit operations

    /// The edits' description: every kind with its parameters.
    static var sceneEditsDescription: String {
        "The edits, applied in order, all or nothing, as one undo step. Each is an object with \"op\" and that op's parameters:\n"
            + ControlSceneEdits.operations.map { "- \($0.name) (\($0.parameters)): \($0.summary)" }.joined(separator: "\n")
    }

    /// One edit: `op` and every parameter any op reads, each described once.
    static var sceneEditSchema: JSONValue {
        let text = { (description: String) in JSONSchema.string(description) }
        let number = { (description: String) in JSONSchema.number(description) }
        let integer = { (description: String) in JSONSchema.integer(description) }
        let flag = { (description: String) in JSONSchema.boolean(description) }
        let properties: [String: JSONValue] = [
            "op": JSONSchema.string("The kind of edit (see scene_apply_edits' edits).", oneOf: ControlSceneEdits.operations.map(\.name)),
            "layer": integer("The layer's id, from scene_get."),
            "layers": JSONSchema.integerArray("Layer ids, from scene_get."),
            "target": integer("The layer to move next to (move_layers)."),
            "position": text("move_layers: \"above\" or \"below\"; step_layer: \"top\" or \"bottom\"."),
            "steps": integer("Places to move a layer: positive is up (drawn later)."),
            "field": text("A layer field as scene.json names it (origin, alpha, text…), or effects.<index>.visible for scripts and bindings; the animated field for timeline edits."),
            "value": text("The value as text: a number, true/false, \"x y z\" for a vector or colour, or text; JSON for an object."),
            "origin": text("\"x y z\" in scene units."),
            "scale": text("\"x y z\" (set_transform), or \"x y\" (puppet_set_key)."),
            "angles": text("\"x y z\" in radians."),
            "visible": flag("Shown (true) or hidden."),
            "alpha": number("Opacity, 0 to 1."),
            "color": text("\"r g b\", each 0 to 1."),
            "blend_mode": integer("WE's blend mode number (0 Normal)."),
            "name": text("A name for the layer, bone, animation or clip."),
            "locked": flag("Locked on the editor's canvas."),
            "parent": integer("The new parent: a layer id (set_parent) or a bone index (puppet edits); omit for none."),
            "text": text("A text layer's text."),
            "font": text("A font: a WE font (systemfont_arial) or a fonts/… file of the wallpaper."),
            "point_size": number("Text size in points."),
            "text_script": text("\"clock\", \"date\" or \"none\"."),
            "key": text("A script option (set_text_script_property), material or instance-override key, or a user property's key."),
            "kind": text("add_layer: image, solid, text, composition, fullscreen or group."),
            "image_path": text("An absolute path of a PNG or JPEG on this Mac, imported into the wallpaper's edits."),
            "model": text("A models/…json the wallpaper or the editor has, for an image layer."),
            "width": number("Width in scene units."),
            "height": number("Height in scene units."),
            "x": number("x: scene units (add_layer) or pixels from the picture's centre (puppet edits)."),
            "y": number("y: scene units (add_layer) or pixels from the picture's centre (puppet edits)."),
            "above": integer("add_layer: the layer to add just above; on top when omitted."),
            "horizontal": text("left, center or right."),
            "vertical": text("bottom, center or top."),
            "setting": text("A scene setting as scene.json general names it."),
            "effect": text("An effect: its key from scene_get (\"0\", \"+1\"), or for add_effect its file from effects_catalog."),
            "index": integer("A position in a list (0 first)."),
            "to_index": integer("The position to move to (0 first)."),
            "constant": text("An effect parameter's key, from effects_catalog."),
            "combo": text("An effect combo's name, from effects_catalog."),
            "slot": integer("An effect texture slot, from effects_catalog."),
            "texture": text("A texture path; empty for the shader's default."),
            "property": text("A user property's key; empty unbinds (bind_effect_constant)."),
            "condition": text("A user property condition (JavaScript over the others, such as clock.value == 1)."),
            "system": text("A particles_catalog id (system:particles/… or preset:<preset>/<variant>)."),
            "section": text("system, emitter, initializer, operator, renderer, children or controlpoint."),
            "component": text("The WE name of the emitter, initializer, operator or renderer to add (particles_get lists them)."),
            "definition": text("A particle definition's path, for a child system (else the layer's own)."),
            "bone": integer("A bone's index, from puppets_list."),
            "angle": number("An angle in degrees."),
            "animation": integer("An animation's index, from puppets_list."),
            "animation_layer": integer("An animation layer's index, from puppets_list."),
            "frame": integer("A frame (0 first)."),
            "to_frame": integer("The frame to move to."),
            "channel": integer("One channel (0 is x); every channel with a keyframe there when omitted."),
            "fps": number("Frames per second."),
            "frames": integer("Length in frames."),
            "mode": text("loop, mirror or single."),
            "method": text("heat or distance."),
            "offset": integer("Places to move (negative is up the list)."),
            "blend": number("Blend weight, 0 to 1."),
            "rate": number("Playback rate (1 is normal)."),
            "additive": flag("Adds to the layers under it."),
            "blend_in": flag("Blends in when it starts."),
            "blend_out": flag("Blends out when it ends."),
            "blend_time": number("Seconds the blend takes."),
            "ease": text("linear, ease_in_out, ease_in, ease_out or hold."),
            "pass": integer("The effect's material pass (0 first; for set_effect_texture, the pass effects_catalog lists for the slot, such as Blur's mask in 3)."),
            "script": text("A SceneScript (an ES module exporting update, init…)."),
            "script_properties": text("The script's options as a JSON object, such as {\"speed\": 2}."),
            "property_kind": text("bool, slider, color, combo, text_input, file, directory, scenetexture, usershortcut, group or text."),
            "label": text("The text the user sees."),
            "new_key": text("The new key: letters, digits and underscores, starting with a letter."),
            "min": number("A slider's minimum."),
            "max": number("A slider's maximum."),
            "step": number("A slider's step."),
            "whole_numbers": flag("A slider takes whole numbers only."),
            "options": JSONSchema.objectArray("A combo's options.", item: JSONSchema.object([
                "label": JSONSchema.string("What the user sees."),
                "value": JSONSchema.string("The value it sets."),
            ], required: ["label", "value"])),
        ]
        return JSONSchema.object(properties, required: ["op"])
    }

    // MARK: - Tools

    private static let sceneEditing: [MCPTool] = [
        MCPTool("scene_apply_edits", title: "Apply Scene Edits",
                description: "Edits a scene wallpaper as the Wallpaper Editor does, through its edit model: layers, effects, particles, puppets, timelines, scripts, bindings and the wallpaper's own user properties. The edits go into the wallpaper's Wallpaper Editor draft (kept beside the wallpaper, never written into it): they show at once in its open Wallpaper Editor window and are one undo step there and for scene_undo, and the displays running the wallpaper show them only once wallpaper_editor_save saves the draft. scene_get gives the ids. " + sceneEditsDescription,
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "edits": JSONSchema.objectArray("The edits to apply, in order (see the tool's description).", item: sceneEditSchema, maxItems: 200),
                    "action_name": JSONSchema.string("The undo step's name in the editor's Edit menu (\"MCP Edit\" when omitted)."),
                ], required: ["wallpaper_id", "edits"]),
                annotations: .change) { message($0) },
        MCPTool("scene_undo", title: "Undo Scene Edit",
                description: "Undoes this client's last scene_apply_edits (or depth map, revert) of the wallpaper. An edit made in an editor window since starts a new history: Undo there undoes the client's edits too.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("scene_redo", title: "Redo Scene Edit",
                description: "Redoes what scene_undo undid.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("wallpaper_editor_save", title: "Save Wallpaper Editor Draft",
                description: "The Wallpaper Editor's File › Save: the wallpaper's draft (every unsaved scene_apply_edits, depth map and revert, and an open editor window's own changes) becomes the wallpaper's edits, which the displays, the screen saver and playlists running it then show. The wallpaper's own files aren't changed. scene_get's unsaved says whether there is anything to save.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("wallpaper_editor_save_as_new", title: "Save as New Wallpaper",
                description: "The Wallpaper Editor's File › Save as New Wallpaper: a new wallpaper in the library with the draft's edits baked in. The wallpaper and its draft stay as they are. Returns the new wallpaper's id.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "title": JSONSchema.string("The new wallpaper's title; \"<title> (Edited)\" when omitted."),
                ], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("scene_save", title: "Save Wallpaper Editor Draft (Deprecated)",
                description: "Deprecated: the older name of wallpaper_editor_save, which it does exactly; use wallpaper_editor_save.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("scene_save_as_local_wallpaper", title: "Save as New Wallpaper (Deprecated)",
                description: "Deprecated: the older name of wallpaper_editor_save_as_new, which it does exactly; use wallpaper_editor_save_as_new.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "title": JSONSchema.string("The new wallpaper's title; \"<title> (Edited)\" when omitted."),
                ], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("scene_revert", title: "Revert to Saved",
                description: "The Wallpaper Editor's File › Revert to Saved: the draft goes back to the wallpaper as last saved, dropping every unsaved edit. One undo step: scene_undo brings them back.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .destructive) { message($0) },
    ]

    private static let sceneReading: [MCPTool] = [
        MCPTool("scene_get", title: "Get Scene",
                description: "A scene wallpaper as the Wallpaper Editor shows it, its draft's edits included (unsaved says whether any aren't saved yet): its size and settings, and every layer with its id, name, kind, draw order, parent, visibility, lock, fields (transform, alpha, colour, blend mode, size, text, font…), user-property bindings, scripted fields, effects (key, file, visibility, constants, combos, textures, bindings), particle file and puppet; the wallpaper's own user properties; and the undo state.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            "\(wallpaperName(result["wallpaper"])) has \(count(result["layers"]?.arrayValue?.count ?? 0, "layer"))."
        },
        MCPTool("effects_catalog", title: "Effects Catalog",
                description: "The effects add_effect can add to the wallpaper's layers: Wallpaper Engine's built-in effects and the Workshop effects the wallpaper uses, each with its file, title, group, and its parameters (constants with defaults and ranges, combos with options, texture slots). Empty without Wallpaper Engine's assets.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "query": JSONSchema.string("Words to find in the effects' titles and descriptions."),
                ], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            count(result["effects"]?.arrayValue?.count ?? 0, "effect") + " to add."
        },
        MCPTool("particles_catalog", title: "Particle Systems Catalog",
                description: "The particle systems add_particle_system can add: Wallpaper Engine's default systems and every preset's variants, grouped as its editor groups them. Empty without Wallpaper Engine's assets.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "query": JSONSchema.string("Words to find in the systems' titles."),
                ], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            count(result["systems"]?.arrayValue?.count ?? 0, "particle system") + "."
        },
        MCPTool("particles_get", title: "Get Particle System",
                description: "A particle layer's definition as the particle editor shows it: the system's values, its emitters, initializers, operators, renderers, children and control points, its material, the layer's instance override, and the components and field names set_particle_field and add_particle_component take.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper, "layer": layerID], required: ["wallpaper_id", "layer"]),
                annotations: .readOnly) { result in
            "Particle system \(result["definition"]?.stringValue ?? "?")."
        },
        MCPTool("particles_restart", title: "Restart Particle System",
                description: "Starts a particle system again from nothing, as the particle editor's Restart does: in the open Wallpaper Editor window's canvas when there is one (the draft being edited; in_editor says so), else on the displays running the wallpaper as saved.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper, "layer": layerID], required: ["wallpaper_id", "layer"]),
                annotations: .idempotent) { message($0) },
        MCPTool("puppets_list", title: "List Puppets",
                description: "The wallpaper's Puppet Warp rigs: for each image layer with one, its bones (index, name, parent, position, angle), animations (name, mode, fps, frames, keyed frames by bone) and animation layers (the animation each plays, blend weight, rate…), as the puppet editor shows them.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            count(result["puppets"]?.arrayValue?.count ?? 0, "puppet") + "."
        },
        MCPTool("timeline_get", title: "Get Timelines",
                description: "The wallpaper's property timelines as the editor's timeline shows them: per layer, each animated property's track (fps, length in frames, mode, keyframes by channel) and what else it can animate.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "layer": JSONSchema.integer("Only this layer's timelines."),
                ], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            count(result["layers"]?.arrayValue?.count ?? 0, "layer") + " with timelines."
        },
        MCPTool("timeline_preview", title: "Preview Timeline",
                description: "Plays, pauses or seeks the timeline of the wallpaper's open Wallpaper Editor window (its canvas follows the playhead).",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "command": JSONSchema.string("What to do.", oneOf: ["play", "pause", "seek"]),
                    "seconds": JSONSchema.number("The playhead's time for seek, in seconds.", minimum: 0),
                ], required: ["wallpaper_id", "command"]), annotations: .idempotent) { message($0) },
        MCPTool("user_properties_get", title: "Get User Property Definitions",
                description: "The wallpaper's own user-property definitions as the editor's user-property panel authors them (key, kind, label, default, range, options, condition), and the fields bound to each. get_wallpaper gives their current values.",
                input: JSONSchema.object(["wallpaper_id": sceneWallpaper], required: ["wallpaper_id"]), annotations: .readOnly) { result in
            count(result["user_properties"]?.arrayValue?.count ?? 0, "user property", plural: "user properties") + "."
        },
    ]

    private static let sceneAuthoring: [MCPTool] = [
        MCPTool("script_get", title: "Get Script",
                description: "A layer field's SceneScript (field: origin, alpha, text, effects.<index>.visible…): its source, its options and what it declares, the user property bound to the field, and the layer's scripted fields.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper, "layer": layerID,
                    "field": JSONSchema.string("The field, as scene_get names it.", minLength: 1),
                ], required: ["wallpaper_id", "layer", "field"]), annotations: .readOnly) { result in
            result["script"]?.stringValue == nil ? "The field has no script." : "The field's script."
        },
        MCPTool("script_set", title: "Set Script",
                description: "Attaches a SceneScript to a layer field as the script editor's Apply does: its syntax is checked first (errors are returned with their lines and nothing changes), then it is one undo step and runs from the wallpaper's reload.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper, "layer": layerID,
                    "field": JSONSchema.string("The field, as scene_get names it.", minLength: 1),
                    "script": JSONSchema.string("The script: an ES module exporting update(value), init() and the other WE events.", minLength: 1),
                    "script_properties": JSONSchema.string("The script's options as a JSON object, such as {\"speed\": 2}."),
                    "action_name": JSONSchema.string("The undo step's name."),
                ], required: ["wallpaper_id", "layer", "field", "script"]), annotations: .idempotent) { message($0) },
        MCPTool("script_check", title: "Check Script",
                description: "Checks a SceneScript's syntax as the script editor does, without applying it: whether it is valid, and each problem with its line.",
                input: JSONSchema.object(["script": JSONSchema.string("The script.", minLength: 1)], required: ["script"]),
                annotations: .readOnly) { message($0) },
        MCPTool("depth_generate", title: "Generate Depth Map",
                description: "Generates a depth map on this Mac for an image or text layer (Create Mask from Depth Map; use_depth_map_as_mask then writes it as one of the layer's effects' masks) or, without layer, for the whole scene (Scene Depth Parallax); needs the Depth Map Generation plugin (plugin_status). For the scene, apply puts WE's Depth Parallax on with it at once; otherwise depth_apply does. When depth parallax is applied already, it follows the new map.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "layer": JSONSchema.integer("The layer; the whole scene when omitted."),
                    "smoothing": JSONSchema.number("Smoothing, 0 to 1 (0.25 by default).", minimum: 0, maximum: 1),
                    "apply": JSONSchema.boolean("The scene only: apply WE's Depth Parallax with it at once."),
                    "strength": JSONSchema.number("The depth parallax's strength, 0.01 to 2.", minimum: 0.01, maximum: 2),
                ], required: ["wallpaper_id"]), annotations: .change, longRunning: true) { message($0) },
        MCPTool("depth_apply", title: "Apply Depth Parallax",
                description: "Applies WE's Depth Parallax effect with the scene's depth map depth_generate made, on a fullscreen layer on top of the scene, or sets the applied one's strength. A layer's depth map doesn't apply depth parallax (use_depth_map_as_mask makes it a mask); a layer's depth parallax applied before can still have its strength set. One undo step.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "layer": JSONSchema.integer("Only to set the strength of a layer's depth parallax applied before; the scene when omitted."),
                    "strength": JSONSchema.number("Strength, 0.01 to 2.", minimum: 0.01, maximum: 2),
                ], required: ["wallpaper_id"]), annotations: .change) { message($0) },
        MCPTool("depth_remove", title: "Remove Depth Parallax",
                description: "Removes the layer's (or the scene's) depth parallax, and the fullscreen layer that carried it. One undo step.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "layer": JSONSchema.integer("The layer; the whole scene when omitted."),
                ], required: ["wallpaper_id"]), annotations: .destructive) { message($0) },
        MCPTool("use_depth_map_as_mask", title: "Use Depth Map as Mask",
                description: "Create Mask from Depth Map › Use as Mask for…: writes the layer's depth map (depth_generate) as the mask of one of its effects with a grey mask slot (Shake, Water Ripple, Tint…), so the effect shows where the mask is white (near, unless inverted); or, with effect \"opacity\", as the layer's opacity: the mask of its WE Opacity effect, added with the mask in the same undo step when the layer has none, so the layer is transparent where the mask is black. It is stored as WE stores a painted mask (an R8 .tex in materials/masks, named in the effect's pass textures), so Save as New Wallpaper writes a normal WE wallpaper. An existing mask is replaced (the result's replaced names it; scene_undo brings it back and its file is kept). One undo step.",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "layer": layerID,
                    "effect": JSONSchema.string("The effect's key from scene_get (\"0\", \"+1\"), or \"opacity\" for the layer's opacity (WE's Opacity effect, added if the layer has none).", minLength: 1),
                    "slot": JSONSchema.integer("The mask's texture slot, when the effect has several grey masks (scene_get lists them)."),
                    "invert": JSONSchema.boolean("Swap near and far, so the effect shows on what is far."),
                    "contrast": JSONSchema.number("The mask's contrast, 0.25 to 4 (1 by default): above 1 harder, below softer.", minimum: 0.25, maximum: 4),
                ], required: ["wallpaper_id", "layer", "effect"]), annotations: .change) { message($0) },
    ]

    private static let sceneWindows: [MCPTool] = [
        MCPTool("editor_close", title: "Close Editor",
                description: "Closes Scene Edit / Export (\"scene\"), or the Wallpaper Editor's window of a wallpaper (\"wallpaper\", which needs wallpaper_id). Edits are kept: they are saved as they are made.",
                input: JSONSchema.object([
                    "editor": JSONSchema.string("Which editor.", oneOf: ["scene", "wallpaper"]),
                    "wallpaper_id": JSONSchema.string("The wallpaper whose Wallpaper Editor window to close.", minLength: 1),
                ], required: ["editor"]), annotations: .idempotent) { message($0) },
        MCPTool("editor_set_tab", title: "Switch Scene Edit / Export Tab",
                description: "Opens Scene Edit / Export on a scene wallpaper in one of its tabs: Wallpaper (edits the running wallpaper), Screen Saver, iPhone & iPad Export, or Android Export (frames it for an Android device or a custom size and exports a .mpkg: a pre-rendered loop of the edited version, or the scene with its edits baked in).",
                input: JSONSchema.object([
                    "wallpaper_id": sceneWallpaper,
                    "tab": JSONSchema.string("The tab.", oneOf: ["wallpaper", "screen_saver", "iphone_ipad_export", "android_export"]),
                ], required: ["wallpaper_id", "tab"]), annotations: .idempotent) { message($0) },
    ]
}
