import Foundation

/// The kinds of edit `scene_apply_edits` takes, shared by `owe-mcp` (the tool's schema and
/// description) and the app (`SceneEditOperations`, whose tests check it answers every one).
public enum ControlSceneEdits {
    /// One kind of edit: its name, the parameters it reads, and what it does.
    public struct Operation: Sendable {
        public let name: String
        public let parameters: String
        public let summary: String

        init(name: String, parameters: String, summary: String) {
            self.name = name
            self.parameters = parameters
            self.summary = summary
        }
    }

    /// Every edit kind, in the order the docs list them.
    public static let operations: [Operation] = [
        // Layers
        .init(name: "set_field", parameters: "layer, field, value", summary: "Sets any field of the layer's scene.json object (value as WE writes it: a number, true/false, \"x y z\", or text)."),
        .init(name: "set_transform", parameters: "layer, origin?, scale?, angles?", summary: "Sets the transform's parts at once (each \"x y z\")."),
        .init(name: "set_origin", parameters: "layer, value", summary: "Moves the layer: value is \"x y z\" in scene units (y up)."),
        .init(name: "set_scale", parameters: "layer, value", summary: "value is \"x y z\"."),
        .init(name: "set_angles", parameters: "layer, value", summary: "Rotation in radians, \"x y z\" (z turns a flat layer)."),
        .init(name: "set_visible", parameters: "layer, visible", summary: "Shows or hides the layer."),
        .init(name: "set_alpha", parameters: "layer, alpha", summary: "Opacity, 0 to 1."),
        .init(name: "set_color", parameters: "layer, color", summary: "Tint, \"r g b\" with each 0 to 1."),
        .init(name: "set_blend_mode", parameters: "layer, blend_mode", summary: "WE's blend mode number (0 Normal)."),
        .init(name: "set_name", parameters: "layer, name", summary: "Renames the layer."),
        .init(name: "set_locked", parameters: "layer, locked", summary: "Locks the layer on the editor's canvas (an editor setting, not a scene edit)."),
        .init(name: "set_parent", parameters: "layers, parent?", summary: "Puts the layers under parent (omit it for the top level), keeping where they are on the scene."),
        .init(name: "move_layers", parameters: "layers, target, position?", summary: "Moves the layers in the draw order to just above (default) or below target."),
        .init(name: "step_layer", parameters: "layer, steps | position", summary: "Moves the layer steps places up (positive, drawn later) or down, or position \"top\"/\"bottom\"."),
        .init(name: "align_layer", parameters: "layer, horizontal?, vertical?", summary: "Lines the layer up with the scene: horizontal left/center/right, vertical bottom/center/top."),
        .init(name: "set_text", parameters: "layer, text", summary: "A text layer's text."),
        .init(name: "set_font", parameters: "layer, font", summary: "A text layer's font (a WE font such as systemfont_arial, or a fonts/… file)."),
        .init(name: "set_point_size", parameters: "layer, point_size", summary: "A text layer's size in points."),
        .init(name: "set_text_script", parameters: "layer, text_script", summary: "Makes a text layer a clock or date (\"clock\", \"date\") or plain text again (\"none\")."),
        .init(name: "set_text_script_property", parameters: "layer, key, value", summary: "An option of the clock or date script (use24hFormat, showSeconds, delimiter, showWeekday)."),
        .init(name: "add_layer", parameters: "kind, name?, x?, y?, width?, height?, above?, image_path | model, color, text, font, point_size, text_script", summary: "Adds a layer: kind image (image_path: a PNG or JPEG on this Mac, imported into the wallpaper's edits; or model: a models/…json it has), solid, text, composition, fullscreen or group; on top, or above the layer `above`. Returns its id."),
        .init(name: "remove_layers", parameters: "layers", summary: "Deletes the layers and the layers under them."),
        .init(name: "duplicate_layers", parameters: "layers", summary: "Copies the layers (with the layers under them) just above the originals. Returns the copies' ids."),
        .init(name: "group_layers", parameters: "layers, name?", summary: "A new group with the layers in it. Returns its id."),
        .init(name: "ungroup", parameters: "layer", summary: "Moves a group's layers to its parent and deletes the group when it draws nothing."),
        .init(name: "set_scene_setting", parameters: "setting, value", summary: "A scene setting (scene.json general: clearcolor, cameraparallax, bloom…)."),
        // Effects
        .init(name: "add_effect", parameters: "layer, effect", summary: "Adds an effect from effects_catalog (its file, such as effects/blur/effect.json) on top of the layer's effects. Returns its key."),
        .init(name: "remove_effect", parameters: "layer, effect", summary: "Removes the effect (effect is its key from scene_get: \"0\", \"+1\")."),
        .init(name: "move_effect", parameters: "layer, effect, index", summary: "Moves the effect to index in the layer's list (0 is applied first)."),
        .init(name: "set_effect_visible", parameters: "layer, effect, visible", summary: "Turns the effect on or off."),
        .init(name: "set_effect_constant", parameters: "layer, effect, constant, value", summary: "Sets a parameter (a number, or \"x y z\" for a vector or colour), checked against the effect's parameters."),
        .init(name: "set_effect_combo", parameters: "layer, effect, combo, value", summary: "Sets a combo (a whole number from its options)."),
        .init(name: "set_effect_texture", parameters: "layer, effect, slot, pass?, texture", summary: "Sets a texture slot (a texture path such as masks/…; empty for the shader's default); pass picks the effect pass of a slot a later pass samples (effects_catalog lists each slot's pass)."),
        .init(name: "bind_effect_constant", parameters: "layer, effect, constant, property", summary: "Binds a parameter to a user property (empty property frees it)."),
        // Particles
        .init(name: "add_particle_system", parameters: "system, name?", summary: "Adds a system from particles_catalog (id system:… or preset:…/…). Returns its layer id."),
        .init(name: "add_blank_particle_system", parameters: "name?", summary: "Adds a system from WE's new-system template."),
        .init(name: "duplicate_particle_system", parameters: "layer, name?", summary: "Copies a particle layer, its edits included."),
        .init(name: "remove_particle_system", parameters: "layer", summary: "Deletes a particle layer."),
        .init(name: "set_particle_field", parameters: "layer | definition, section, index?, field, value", summary: "Sets a field of the system (section \"system\") or of item index of a section (emitter, initializer, operator, renderer, children, controlpoint), by its name in WE's particle editor (particles_get lists them). Empty value removes it."),
        .init(name: "add_particle_component", parameters: "layer | definition, section, component", summary: "Adds an emitter, initializer, operator or renderer (component: its WE name, such as movement) or a child or control point. Returns its index."),
        .init(name: "remove_particle_component", parameters: "layer | definition, section, index", summary: "Removes an item of a section."),
        .init(name: "move_particle_component", parameters: "layer | definition, section, index, to_index", summary: "Reorders an item of a section."),
        .init(name: "set_particle_material", parameters: "layer | definition, key, value", summary: "A value of the system's material (texture, blending, depthtest, cullmode…); empty removes it."),
        .init(name: "set_particle_override", parameters: "layer, key, value", summary: "The layer's instance override (alpha, rate, speed, size, count, lifetime, colorn); empty removes it."),
        // Puppets
        .init(name: "puppet_create", parameters: "layer", summary: "Makes a Puppet Warp rig for an image layer: a mesh fitted to its picture and one bone."),
        .init(name: "puppet_discard_edits", parameters: "layer", summary: "Drops the editor's changes to the layer's rig."),
        .init(name: "puppet_add_bone", parameters: "layer, x, y, parent?, name?, angle?", summary: "Adds a bone with its head at x, y (pixels from the picture's centre). Returns its index."),
        .init(name: "puppet_move_bone", parameters: "layer, bone, x, y", summary: "Moves a bone's head."),
        .init(name: "puppet_rotate_bone", parameters: "layer, bone, angle", summary: "Turns a bone to angle (degrees)."),
        .init(name: "puppet_rename_bone", parameters: "layer, bone, name", summary: "Renames a bone."),
        .init(name: "puppet_reparent_bone", parameters: "layer, bone, parent?", summary: "Puts a bone under another (omit parent for a root)."),
        .init(name: "puppet_delete_bone", parameters: "layer, bone", summary: "Deletes a bone."),
        .init(name: "puppet_auto_weights", parameters: "layer, method?", summary: "Weights the mesh to the bones again (heat, or distance)."),
        .init(name: "puppet_add_animation", parameters: "layer, name?, fps?, frames?, mode?", summary: "Adds an animation (mode loop, mirror or single). Returns its index."),
        .init(name: "puppet_update_animation", parameters: "layer, animation, name?, fps?, frames?, mode?", summary: "Changes an animation's options."),
        .init(name: "puppet_delete_animation", parameters: "layer, animation", summary: "Deletes an animation and the animation layers that play it."),
        .init(name: "puppet_set_key", parameters: "layer, animation, bone, frame, x?, y?, angle?, scale?", summary: "Keys a bone's pose at frame (position in pixels, angle in degrees, scale \"x y\"); unset parts keep the pose there."),
        .init(name: "puppet_delete_key", parameters: "layer, animation, frame, bone?", summary: "Deletes the keys at frame (one bone's, or every bone's)."),
        .init(name: "puppet_add_animation_layer", parameters: "layer, animation", summary: "Adds an animation layer that plays the animation."),
        .init(name: "puppet_update_animation_layer", parameters: "layer, animation_layer, animation?, blend?, rate?, visible?, additive?, blend_in?, blend_out?, blend_time?, name?", summary: "Changes an animation layer: its blend weight (0 to 1), rate, and the rest."),
        .init(name: "puppet_remove_animation_layer", parameters: "layer, animation_layer", summary: "Removes an animation layer."),
        .init(name: "puppet_move_animation_layer", parameters: "layer, animation_layer, offset", summary: "Moves an animation layer up or down the list."),
        // Timeline
        .init(name: "timeline_add_keyframe", parameters: "layer, field | effect + constant, frame, value?, fps?, frames?", summary: "Adds a keyframe on every channel (value \"x y z\", else the value there now), making the timeline when there is none."),
        .init(name: "timeline_set_keyframe", parameters: "layer, field | effect + constant, frame, value, channel?", summary: "Sets the keyframes' values at frame."),
        .init(name: "timeline_move_keyframe", parameters: "layer, field | effect + constant, frame, to_frame, channel?", summary: "Moves the keyframes at frame."),
        .init(name: "timeline_delete_keyframe", parameters: "layer, field | effect + constant, frame, channel?", summary: "Deletes the keyframes at frame."),
        .init(name: "timeline_set_ease", parameters: "layer, field | effect + constant, frame, ease, channel?", summary: "The curve at the keyframes: linear, ease_in_out, ease_in, ease_out or hold."),
        .init(name: "timeline_set_clip", parameters: "layer, field | effect + constant, fps?, frames?, mode?, name?", summary: "The timeline's options (mode loop, mirror or single; name for scripts' getAnimation)."),
        .init(name: "timeline_remove_track", parameters: "layer, field | effect + constant", summary: "Removes the property's timeline; it keeps its static value."),
        // Scripts, bindings, user properties
        .init(name: "set_script", parameters: "layer, field, script, script_properties?", summary: "Attaches a SceneScript to a field (origin, alpha, text, effects.<index>.visible…), after the script editor's syntax check."),
        .init(name: "remove_script", parameters: "layer, field", summary: "Removes the field's script; the field keeps its value."),
        .init(name: "bind_field", parameters: "layer, field, property, condition?", summary: "Binds a field to one of the wallpaper's user properties."),
        .init(name: "unbind_field", parameters: "layer, field", summary: "Frees a field from its user property."),
        .init(name: "add_user_property", parameters: "property_kind, label, key?, value?, min?, max?, step?, whole_numbers?, options?, condition?", summary: "Defines a user property of the wallpaper (bool, slider, color, combo, text_input, file, directory, scenetexture, usershortcut, group, or text for a label). Returns its key."),
        .init(name: "update_user_property", parameters: "key, label?, value?, min?, max?, step?, whole_numbers?, options?, condition?", summary: "Changes a user property's definition (value is its default)."),
        .init(name: "remove_user_property", parameters: "key", summary: "Removes a user property; bound fields keep their values."),
        .init(name: "rename_user_property", parameters: "key, new_key", summary: "Renames a user property's key, re-pointing conditions and bound fields."),
        .init(name: "move_user_property", parameters: "key, index", summary: "Moves a user property in the list."),
    ]
}
