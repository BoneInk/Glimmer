# MCP Server

Open Wallpaper Engine can be controlled by MCP clients: AI assistants and other tools that speak
the [Model Context Protocol](https://modelcontextprotocol.io). The **MCP Server** plugin adds
`owe-mcp`, a server the client starts, which passes each tool call to the running app. Nothing is
installed or listening until you install the plugin.

## Setup

1. Open **Settings › Plugins › MCP Server** and click **Install**. This copies the `owe-mcp` the
   app ships (signed and notarized with it) to
   `~/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp`, and the app starts
   accepting MCP clients.
2. Open **Copy Configuration For** and pick your client. The snippet for that client, with the
   installed path, goes to the clipboard; paste it where [Client setup](#client-setup) says.
   Hovering a client in the menu shows where its configuration lives.
3. Ask the client to list your wallpapers. When Open Wallpaper Engine isn't running, the first tool
   call starts it in the background and waits for it (up to 30 seconds).

**Remove** in the same place deletes `owe-mcp`, closes the connection and every client's
connection, and stops accepting clients. An app update refreshes the installed `owe-mcp` the next
time the app starts.

## Client setup

Every snippet names the server `open-wallpaper-engine` and starts `owe-mcp` by its absolute path,
with no arguments. The path below is an example: **Copy Configuration For** fills in yours. Merge
the snippet into the file when it already has other servers. Formats checked against each client's
documentation in October 2026.

| Client | Where | Docs |
| --- | --- | --- |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` (Settings › Developer › Edit Config) | [modelcontextprotocol.io](https://modelcontextprotocol.io/docs/develop/connect-local-servers) |
| Claude Code | Terminal | [code.claude.com](https://code.claude.com/docs/en/mcp) |
| VS Code / GitHub Copilot | `.vscode/mcp.json`, or **MCP: Open User Configuration** | [code.visualstudio.com](https://code.visualstudio.com/docs/copilot/customization/mcp-servers) |
| Cursor | `~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project | [cursor.com](https://cursor.com/docs/context/mcp) |
| Kiro | `~/.kiro/settings/mcp.json`, or `.kiro/settings/mcp.json` in a workspace | [kiro.dev](https://kiro.dev/docs/mcp/configuration/) |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` (Devin Desktop, its successor: `~/.config/devin/mcp_config.json`) | [docs.devin.ai](https://docs.devin.ai/desktop/cascade/mcp) |
| Zed | Zed's `settings.json` | [zed.dev](https://zed.dev/docs/ai/mcp) |
| OpenAI Codex CLI | `~/.codex/config.toml` | [learn.chatgpt.com](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) |
| Gemini CLI | `~/.gemini/settings.json`, or `.gemini/settings.json` in a project | [gemini-cli](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/mcp-server.md) |
| Cline | `cline_mcp_settings.json` (MCP Servers › Configure); the CLI reads `~/.cline/mcp.json` | [docs.cline.bot](https://docs.cline.bot/mcp/configuring-mcp-servers) |
| Continue | `.continue/mcpServers/open-wallpaper-engine.yaml` | [docs.continue.dev](https://docs.continue.dev/customize/deep-dives/mcp) |

**Claude Desktop, Cursor, Windsurf, Gemini CLI** (`mcpServers`):

```json
{
  "mcpServers": {
    "open-wallpaper-engine": {
      "command": "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp"
    }
  }
}
```

**Kiro** adds `"args": []` and `"disabled": false`; **Cline** those and `"autoApprove": []`.

**Claude Code:**

```sh
claude mcp add open-wallpaper-engine -- '/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp'
```

**VS Code / GitHub Copilot** (`servers`):

```json
{
  "servers": {
    "open-wallpaper-engine": {
      "type": "stdio",
      "command": "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp"
    }
  }
}
```

**Zed** (`context_servers`):

```json
{
  "context_servers": {
    "open-wallpaper-engine": {
      "command": "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

**OpenAI Codex CLI:**

```toml
[mcp_servers.open-wallpaper-engine]
command = "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp"
```

**Continue:**

```yaml
name: Open Wallpaper Engine
version: 0.0.1
schema: v1
mcpServers:
  - name: open-wallpaper-engine
    type: stdio
    command: "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp"
```

**Any other client** that starts stdio servers: `{"type": "stdio", "command": "/Users/you/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp", "args": []}`.

### Compatibility

- Protocol revisions 2025-06-18, 2025-03-26 and 2024-11-05: `owe-mcp` answers in the revision the
  client asks for (the latest for any other), and sends only what that revision has: titles and
  structured tool results from 2025-06-18, tool annotations from 2025-03-26, JSON-RPC batches
  before 2025-06-18. Every tool result also carries its JSON as text.
- Tool schemas are plain JSON Schema: an object of simply typed, described properties, enums for
  choices, no `$ref`, `oneOf`, `anyOf` or `additionalProperties` (unknown arguments are still
  refused). A number or boolean given for a text property is taken as its text.
- `snapshot` returns MCP image content; with `"format": "path"` it saves the PNG to a temporary
  file (owner-only) and returns its path instead, for clients that can't show images.
- stdout carries only JSON-RPC; diagnostics go to stderr.

## Tools

Every tool returns structured content (the JSON below) with a one-line summary, and the same JSON as
text for clients that don't read structured content. Ids come from `list_wallpapers` (a wallpaper's
folder name; its Workshop id or folder path also work) and `list_displays`. Where a tool takes
`display`, leaving it out means every display wallpapers are shown on.

The tools come in areas: the basics (below: displays, the library, playback, user properties,
playlists, snapshots), [the scene and its editors](#scene-and-editors), [the library
and the app](#library-and-app), and [Live Photo export, the screen saver and the lock
screen](#export-screen-saver-and-lock-screen). The other areas' results all carry a `message`,
the sentence their summary shows.

| Tool | Arguments | What it does |
|---|---|---|
| `list_displays` | none | The displays: `id`, `name`, `main`, `enabled` (wallpapers shown), `width`/`height` in points, `scale`, `rule` (Settings › Performance › Playback's state: `run`, `mute`, `pause`, `stop`) and the `wallpaper` each shows. |
| `get_status` | `display?` | Per display, the wallpaper (`id`, `title`, `type`) and whether it is `playing`; `paused`, `stopped`, `volume` (0–1), `muted`, and the active `playlist`. |
| `list_wallpapers` | `query?`, `type?` (`scene`, `video`, `web`, `application`), `tags?`, `limit?` (1–500, 50 by default), `offset?` | Searches the library (the Installed tab, without its filters), by title, tags and description. Returns `total` and each wallpaper's `id`, `title`, `type`, `tags`, `folder` and `workshop_id`. |
| `get_wallpaper` | `id` | The wallpaper's details, the `displays` showing it, and its user `properties`: `key`, `title`, `type`, `value`, `default`, `condition`; sliders add `min`, `max`, `step`, `whole_numbers`; combos add `options` (`label`, `value`) and `free_text`. |
| `set_wallpaper` | `id`, `display?` | Shows the wallpaper, as applying it in the library does. A web wallpaper must have been trusted in the app once ("Don't ask again for this wallpaper"), and is refused again once its files change; the app never skips that question for a client. |
| `pause`, `resume`, `toggle_playback` | none | Pauses or resumes every wallpaper, as the menu bar does; `resume` (and the toggle, when stopped) also ends a stop. Returns `paused` and `stopped`. |
| `stop` | none | Stop Wallpapers from the menu bar: every wallpaper is unloaded (freeing its CPU, GPU and memory) and the desktop shows the macOS desktop picture until `resume`, which loads each display's wallpaper again. Application rules keep evaluating and apply on resume; nothing they do loads a wallpaper while stopped. Returns `paused` and `stopped`. |
| `set_volume` | `level` (0–1) | The wallpapers' volume. Returns `volume` and `muted`. |
| `set_muted` | `muted` | Mute and Unmute from the menu bar; unmuting brings back the volume from before. |
| `set_user_property` | `id`, `key`, `value` (text; a JSON number or boolean works too) | Changes one user property, as the Details panel does, live on the displays showing the wallpaper (each display's own properties, or the shared ones while "Sync properties across displays" is on). The value must fit the property: a number within a slider's range (whole when it takes whole numbers), `true`/`false` for a checkbox, a combo option's value or label, a colour as `"r g b"` with each 0–1 (or `#rrggbb`, or `[r, g, b]`), text, or an existing absolute path for a file or folder. |
| `list_playlists` | none | Each playlist's `id`, `name`, `wallpapers`, `duration_seconds`, `active`, `rotating`, `shuffle` and the `displays` it last played on. |
| `play_playlist` | `name`, `display?` | Makes the playlist active and starts rotating it, as its shortcut does. Names match case-insensitively. |
| `next_wallpaper`, `previous_wallpaper` | `display?` | Next and Previous Wallpaper from the menu: the active playlist's next or previous item where it plays, else a random library wallpaper, skipping web wallpapers not trusted yet (next), or the one shown before (previous). |
| `import_wallpaper` | `path` | File › Import Wallpaper from Folder…: a wallpaper folder (with `project.json`), a folder of them, or a `.zip`. Returns the `imported` wallpapers and what was `skipped`, with why (a folder of that name is already in the library, for example). |
| `open_editor` | `id`, `editor` (`scene` or `wallpaper`) | Opens a scene wallpaper in Scene Edit / Export or the Wallpaper Editor, for you to edit. |
| `snapshot` | `display?` (the main display by default), `format?` (`image` by default, or `path`) | A PNG of the wallpaper on that display, at most 960 pixels wide, as image content (with `path`: saved to a temporary file whose path is returned). `source` says what it is: `loading_snapshot` (the scene's own frame, which the app captures for its loading screen), `video_frame`, or `preview` (the wallpaper's preview image, when there is no frame yet). |

Playback and volume are app-wide in Open Wallpaper Engine (as in the menu bar), so `pause`,
`resume`, `stop`, `toggle_playback`, `set_volume` and `set_muted` take no display.

### Scene and editors

A client edits a scene wallpaper through the same edit model as the Wallpaper Editor: the app
keeps a **headless edit session** per wallpaper, over the wallpaper's **Wallpaper Editor draft**
(`<support>/editor/Drafts/<identity>.json`, beside the saved overlay `<support>/editor/<identity>.json`),
with the editor's own undo semantics. Nothing is written into the wallpaper's files. Every change
goes through the session calls the editors' controls make (with their checks) and into the draft,
as the editor's window keeps its own.

**The draft is the editor's, until it is saved.** Nothing that runs the wallpaper sees the draft:
not the displays, the screen saver, playlists, or the readers of the wallpaper (`snapshot`,
`get_wallpaper`). An open Wallpaper Editor window of the wallpaper shows it in its canvas.
`wallpaper_editor_save` (the editor's File › Save) makes it the wallpaper's edits: the displays
running the wallpaper then draw a value change at once (transform, opacity, colour, effect values)
or reload once, and a particle document change rebuilds only its systems. `scene_get`'s `unsaved`
says whether the draft has anything to save. A draft left unsaved stays on disk: the Wallpaper
Editor offers to resume or discard it when the wallpaper is opened.

**Open editors see the changes.** After each change the app tells the Wallpaper Editor's process
(`app.overlayDidSave`, with the undo step's name); its open window of the wallpaper takes the change
as an undo step of its own, so **Undo in the window undoes the client's edit**, and that Undo goes
into the draft like any of the window's edits. The window's own changes go into the same draft, so
`wallpaper_editor_save` saves them too, and the window then has nothing unsaved (`app.draftDidSave`).
An edit made in a window since the client's last request starts the client's session over with a
fresh undo history, so `scene_undo` never undoes the user's work. The Scene Edit / Export window's
Wallpaper tab edits the running wallpaper, which shows the change at once.

| Tool | Arguments | What it does |
|---|---|---|
| `scene_get` | `wallpaper_id` | The scene as the Wallpaper Editor shows it, the draft's edits included, with `unsaved` (whether the draft has anything `wallpaper_editor_save` would save): `size`, `general` (scene settings), `layers` (each: `id`, `name`, `kind`, `image_role`, `order`, `parent`, `visible`, `locked`, `edited`, `fields`, `bindings` (field → user property), `scripts` (scripted fields), `effects` (`key`, `file`, `title`, `visible`, `added`, `constants`, `combos`, `textures`, `bindings`), `text`, `text_script`, `particle`, `puppet` (`none`, `authored`, `edited`)), the wallpaper's `user_properties`, and `undo` (`can_undo`, `can_redo`, `undo_action`, `redo_action`). |
| `scene_apply_edits` | `wallpaper_id`, `edits`, `action_name?` | Applies the edits (below) to the draft in order, **all or nothing, as one undo step** (named `action_name`, "MCP Edit" by default). Returns each edit's `results` (new ids and keys) and `undo`. |
| `scene_undo`, `scene_redo` | `wallpaper_id` | Undoes or redoes the client's last step. `done` says whether there was one. |
| `wallpaper_editor_save` | `wallpaper_id` | File › Save: the draft (the client's edits and an open window's) becomes the wallpaper's edits, which every running copy of it applies once. `saved` is false when there was nothing to save. |
| `wallpaper_editor_save_as_new` | `wallpaper_id`, `title?` | File › Save as New Wallpaper: a new wallpaper with the draft's edits baked in, added to the library; the wallpaper and its draft stay as they are. Returns its `id`. |
| `scene_save` | `wallpaper_id` | **Deprecated:** the older name of `wallpaper_editor_save`, which it does exactly. |
| `scene_save_as_local_wallpaper` | `wallpaper_id`, `title?` | **Deprecated:** the older name of `wallpaper_editor_save_as_new`, which it does exactly. |
| `scene_revert` | `wallpaper_id` | File › Revert to Saved: the draft goes back to the wallpaper as last saved, one undo step. |
| `effects_catalog` | `wallpaper_id`, `query?` | The effects `add_effect` takes (Wallpaper Engine's built-in effects and the Workshop effects the wallpaper uses), each with `file`, `title`, `group`, `passes` and its parameters: `constants` (`key`, `default`, `min`, `max`, `integer`, `color`), `combos` (`name`, `options`), `textures` (`slot`, `mask`). Empty without WE's assets. |
| `particles_catalog` | `wallpaper_id`, `query?` | The systems `add_particle_system` takes: WE's default systems (`system:particles/…`) and every preset's variants (`preset:<preset>/<variant>`). Empty without WE's assets. |
| `particles_get` | `wallpaper_id`, `layer` | A particle layer's definition as the particle editor shows it: `system`, `sections` (emitter, initializer, operator, renderer, children, controlpoint), `material`, `instance_override`, and the addable `components` with their field names. |
| `particles_restart` | `wallpaper_id`, `layer` | Starts the system again from nothing: in the open Wallpaper Editor window's canvas when there is one (the draft being edited; `in_editor` is true), else on the displays running the wallpaper, as saved. |
| `puppets_list` | `wallpaper_id` | Each Puppet Warp rig: `bones` (`index`, `name`, `parent`, `x`, `y`, `angle` in degrees), `animations` (`name`, `mode`, `fps`, `frames`, `keys_by_bone`) and `animation_layers` (`animation`, `blend`, `rate`, `visible`, `additive`, `blend_in`, `blend_out`, `blend_time`). |
| `timeline_get` | `wallpaper_id`, `layer?` | Per layer, each property timeline (`key` or `effect` + `pass` + `key`, `fps`, `frames`, `mode`, `relative`, `channels` of keyframes `frame`, `value`, `hold`) and what else it can animate (`animatable`). |
| `timeline_preview` | `wallpaper_id`, `command` (`play`, `pause`, `seek`), `seconds?` | Drives the timeline of the wallpaper's open Wallpaper Editor window (its canvas follows the playhead). |
| `script_get` | `wallpaper_id`, `layer`, `field` | A field's SceneScript: `script`, `script_properties`, `declared_properties`, the bound `user_property`, `animated`, and the layer's `scripted_fields`. |
| `script_set` | `wallpaper_id`, `layer`, `field`, `script`, `script_properties?`, `action_name?` | The script editor's Apply: the syntax is checked first (errors come back with their lines and nothing changes), then the script is attached as one undo step; it runs from the wallpaper's reload. |
| `script_check` | `script` | The syntax check alone: `valid` and `diagnostics` (`line`, `message`, `severity`). |
| `user_properties_get` | `wallpaper_id` | The wallpaper's own user-property definitions as the editor authors them (`key`, `kind`, `label`, `value` (default), `min`, `max`, `step`, `whole_numbers`, `options`, `condition`), whether they were `edited`, and the `bound_fields` of each. `get_wallpaper` gives their current values; `set_user_property` changes a value. |
| `depth_generate` | `wallpaper_id`, `layer?`, `smoothing?`, `apply?`, `strength?` | Generate, on this Mac, for an image or text layer (Create Mask from Depth Map) or, without `layer`, the scene (Scene Depth Parallax). Needs the Depth Map Generation plugin; without it the call says to install it in Settings › Plugins (`plugin_status` shows it). For the scene, `apply` applies WE's Depth Parallax with it at once; an applied depth parallax follows the new map. |
| `depth_apply` | `wallpaper_id`, `layer?`, `strength?` | Applies WE's Depth Parallax with the scene's generated map on a fullscreen layer on top of the scene, or sets the applied one's strength (0.01–2). A layer's map doesn't apply depth parallax (`use_depth_map_as_mask` makes it a mask); `layer` only sets the strength of a layer's depth parallax applied before. One undo step. |
| `depth_remove` | `wallpaper_id`, `layer?` | Removes the depth parallax (and the fullscreen layer that carried it). One undo step. |
| `use_depth_map_as_mask` | `wallpaper_id`, `layer`, `effect`, `slot?`, `invert?`, `contrast?` | Use as Mask for…: writes the layer's generated map as the mask of its effect `effect` (its key from `scene_get`) with a grey mask slot (`slot` when it has several), `invert` swapping near and far and `contrast` (0.25–4, 1 by default) hardening or softening it. `effect: "opacity"` is Layer Opacity: the mask of the layer's WE Opacity effect (`effects/opacity`), added with the mask when the layer has none, so the layer is transparent where the mask is black; the result's `layer_opacity` and `added_effect` say so and `effect` is the effect's key. Stored as WE stores a painted mask (an R8 `.tex` in `materials/masks`, named in the pass's `textures`, the slot's combo `MASK` on). An existing mask is replaced (`replaced` names it; `scene_undo` brings it back, its file is kept). One undo step, adding the effect included. |
| `open_editor` | `id`, `editor` (`scene`, `wallpaper`) | Opens either editor on a scene wallpaper (above). |
| `editor_close` | `editor`, `wallpaper_id?` | Closes the Scene Edit / Export window, or the Wallpaper Editor's window of a wallpaper (`wallpaper_id`) without asking: its unsaved changes stay in the draft, which the editor offers to resume when the wallpaper is opened again. |
| `editor_set_tab` | `wallpaper_id`, `tab` (`wallpaper`, `screen_saver`, `iphone_ipad_export`, `android_export`) | Opens Scene Edit / Export on the wallpaper in that tab. |

#### Scene edits

`scene_apply_edits` takes `edits`, a list of objects, each with an `op` and that op's parameters.
Layers are named by their `id` (`scene_get`), effects by their `key` (`"0"` for the scene's first,
`"+1"` for the first one added), bones, animations and animation layers by their index
(`puppets_list`). Values are text as scene.json writes them: a number (`"0.5"`), `"true"`/`"false"`,
a vector or colour as `"x y z"` (a list of numbers works too), a JSON object where one is needed. A
field a user property sets is refused until `unbind_field` frees it, as the editors show no value
for it. Each edit is checked before anything changes (the layer, effect, parameter, range, option);
the first that fails names its place (`edits[2] (set_effect_combo): …`) and nothing is changed.

**Layers**

| op | Parameters | What it does |
|---|---|---|
| `set_field` | `layer`, `field`, `value` | Sets any field of the layer's scene.json object (value as WE writes it: a number, true/false, "x y z", or text). |
| `set_transform` | `layer`, `origin?`, `scale?`, `angles?` | Sets the transform's parts at once (each "x y z"). |
| `set_origin` | `layer`, `value` | Moves the layer: value is "x y z" in scene units (y up). |
| `set_scale` | `layer`, `value` | value is "x y z". |
| `set_angles` | `layer`, `value` | Rotation in radians, "x y z" (z turns a flat layer). |
| `set_visible` | `layer`, `visible` | Shows or hides the layer. |
| `set_alpha` | `layer`, `alpha` | Opacity, 0 to 1. |
| `set_color` | `layer`, `color` | Tint, "r g b" with each 0 to 1. |
| `set_blend_mode` | `layer`, `blend_mode` | WE's blend mode number (0 Normal). |
| `set_name` | `layer`, `name` | Renames the layer. |
| `set_locked` | `layer`, `locked` | Locks the layer on the editor's canvas (an editor setting, not a scene edit). |
| `set_parent` | `layers`, `parent?` | Puts the layers under parent (omit it for the top level), keeping where they are on the scene. |
| `move_layers` | `layers`, `target`, `position?` | Moves the layers in the draw order to just above (default) or below target. |
| `step_layer` | `layer`, `steps | position` | Moves the layer steps places up (positive, drawn later) or down, or position "top"/"bottom". |
| `align_layer` | `layer`, `horizontal?`, `vertical?` | Lines the layer up with the scene: horizontal left/center/right, vertical bottom/center/top. |
| `set_text` | `layer`, `text` | A text layer's text. |
| `set_font` | `layer`, `font` | A text layer's font (a WE font such as systemfont_arial, or a fonts/… file). |
| `set_point_size` | `layer`, `point_size` | A text layer's size in points. |
| `set_text_script` | `layer`, `text_script` | Makes a text layer a clock or date ("clock", "date") or plain text again ("none"). |
| `set_text_script_property` | `layer`, `key`, `value` | An option of the clock or date script (use24hFormat, showSeconds, delimiter, showWeekday). |
| `add_layer` | `kind`, `name?`, `x?`, `y?`, `width?`, `height?`, `above?`, `image_path | model`, `color`, `text`, `font`, `point_size`, `text_script` | Adds a layer: kind image (image_path: a PNG or JPEG on this Mac, imported into the wallpaper's edits; or model: a models/…json it has), solid, text, composition, fullscreen or group; on top, or above the layer `above`. Returns its id. |
| `remove_layers` | `layers` | Deletes the layers and the layers under them. |
| `duplicate_layers` | `layers` | Copies the layers (with the layers under them) just above the originals. Returns the copies' ids. |
| `group_layers` | `layers`, `name?` | A new group with the layers in it. Returns its id. |
| `ungroup` | `layer` | Moves a group's layers to its parent and deletes the group when it draws nothing. |
| `set_scene_setting` | `setting`, `value` | A scene setting (scene.json general: clearcolor, cameraparallax, bloom…). |

**Effects**

| op | Parameters | What it does |
|---|---|---|
| `add_effect` | `layer`, `effect` | Adds an effect from effects_catalog (its file, such as effects/blur/effect.json) on top of the layer's effects. Returns its key. |
| `remove_effect` | `layer`, `effect` | Removes the effect (effect is its key from scene_get: "0", "+1"). |
| `move_effect` | `layer`, `effect`, `index` | Moves the effect to index in the layer's list (0 is applied first). |
| `set_effect_visible` | `layer`, `effect`, `visible` | Turns the effect on or off. |
| `set_effect_constant` | `layer`, `effect`, `constant`, `value` | Sets a parameter (a number, or "x y z" for a vector or colour), checked against the effect's parameters. |
| `set_effect_combo` | `layer`, `effect`, `combo`, `value` | Sets a combo (a whole number from its options). |
| `set_effect_texture` | `layer`, `effect`, `slot`, `pass?`, `texture` | Sets a texture slot (a texture path such as masks/…; empty for the shader's default). `pass` picks a slot a later effect pass samples (`effects_catalog` lists each slot's pass; Blur's mask is in pass 3), written to that pass's `textures` as WE does. |
| `bind_effect_constant` | `layer`, `effect`, `constant`, `property` | Binds a parameter to a user property (empty property frees it). |

**Particles**

| op | Parameters | What it does |
|---|---|---|
| `add_particle_system` | `system`, `name?` | Adds a system from particles_catalog (id system:… or preset:…/…). Returns its layer id. |
| `add_blank_particle_system` | `name?` | Adds a system from WE's new-system template. |
| `duplicate_particle_system` | `layer`, `name?` | Copies a particle layer, its edits included. |
| `remove_particle_system` | `layer` | Deletes a particle layer. |
| `set_particle_field` | `layer | definition`, `section`, `index?`, `field`, `value` | Sets a field of the system (section "system") or of item index of a section (emitter, initializer, operator, renderer, children, controlpoint), by its name in WE's particle editor (particles_get lists them). Empty value removes it. |
| `add_particle_component` | `layer | definition`, `section`, `component` | Adds an emitter, initializer, operator or renderer (component: its WE name, such as movement) or a child or control point. Returns its index. |
| `remove_particle_component` | `layer | definition`, `section`, `index` | Removes an item of a section. |
| `move_particle_component` | `layer | definition`, `section`, `index`, `to_index` | Reorders an item of a section. |
| `set_particle_material` | `layer | definition`, `key`, `value` | A value of the system's material (texture, blending, depthtest, cullmode…); empty removes it. |
| `set_particle_override` | `layer`, `key`, `value` | The layer's instance override (alpha, rate, speed, size, count, lifetime, colorn); empty removes it. |

**Puppets**

| op | Parameters | What it does |
|---|---|---|
| `puppet_create` | `layer` | Makes a Puppet Warp rig for an image layer: a mesh fitted to its picture and one bone. |
| `puppet_discard_edits` | `layer` | Drops the editor's changes to the layer's rig. |
| `puppet_add_bone` | `layer`, `x`, `y`, `parent?`, `name?`, `angle?` | Adds a bone with its head at x, y (pixels from the picture's centre). Returns its index. |
| `puppet_move_bone` | `layer`, `bone`, `x`, `y` | Moves a bone's head. |
| `puppet_rotate_bone` | `layer`, `bone`, `angle` | Turns a bone to angle (degrees). |
| `puppet_rename_bone` | `layer`, `bone`, `name` | Renames a bone. |
| `puppet_reparent_bone` | `layer`, `bone`, `parent?` | Puts a bone under another (omit parent for a root). |
| `puppet_delete_bone` | `layer`, `bone` | Deletes a bone. |
| `puppet_auto_weights` | `layer`, `method?` | Weights the mesh to the bones again (heat, or distance). |
| `puppet_add_animation` | `layer`, `name?`, `fps?`, `frames?`, `mode?` | Adds an animation (mode loop, mirror or single). Returns its index. |
| `puppet_update_animation` | `layer`, `animation`, `name?`, `fps?`, `frames?`, `mode?` | Changes an animation's options. |
| `puppet_delete_animation` | `layer`, `animation` | Deletes an animation and the animation layers that play it. |
| `puppet_set_key` | `layer`, `animation`, `bone`, `frame`, `x?`, `y?`, `angle?`, `scale?` | Keys a bone's pose at frame (position in pixels, angle in degrees, scale "x y"); unset parts keep the pose there. |
| `puppet_delete_key` | `layer`, `animation`, `frame`, `bone?` | Deletes the keys at frame (one bone's, or every bone's). |
| `puppet_add_animation_layer` | `layer`, `animation` | Adds an animation layer that plays the animation. |
| `puppet_update_animation_layer` | `layer`, `animation_layer`, `animation?`, `blend?`, `rate?`, `visible?`, `additive?`, `blend_in?`, `blend_out?`, `blend_time?`, `name?` | Changes an animation layer: its blend weight (0 to 1), rate, and the rest. |
| `puppet_remove_animation_layer` | `layer`, `animation_layer` | Removes an animation layer. |
| `puppet_move_animation_layer` | `layer`, `animation_layer`, `offset` | Moves an animation layer up or down the list. |

**Timeline**

| op | Parameters | What it does |
|---|---|---|
| `timeline_add_keyframe` | `layer`, `field | effect + constant`, `frame`, `value?`, `fps?`, `frames?` | Adds a keyframe on every channel (value "x y z", else the value there now), making the timeline when there is none. |
| `timeline_set_keyframe` | `layer`, `field | effect + constant`, `frame`, `value`, `channel?` | Sets the keyframes' values at frame. |
| `timeline_move_keyframe` | `layer`, `field | effect + constant`, `frame`, `to_frame`, `channel?` | Moves the keyframes at frame. |
| `timeline_delete_keyframe` | `layer`, `field | effect + constant`, `frame`, `channel?` | Deletes the keyframes at frame. |
| `timeline_set_ease` | `layer`, `field | effect + constant`, `frame`, `ease`, `channel?` | The curve at the keyframes: linear, ease_in_out, ease_in, ease_out or hold. |
| `timeline_set_clip` | `layer`, `field | effect + constant`, `fps?`, `frames?`, `mode?`, `name?` | The timeline's options (mode loop, mirror or single; name for scripts' getAnimation). |
| `timeline_remove_track` | `layer`, `field | effect + constant` | Removes the property's timeline; it keeps its static value. |

**Scripts, bindings, user properties**

| op | Parameters | What it does |
|---|---|---|
| `set_script` | `layer`, `field`, `script`, `script_properties?` | Attaches a SceneScript to a field (origin, alpha, text, effects.<index>.visible…), after the script editor's syntax check. |
| `remove_script` | `layer`, `field` | Removes the field's script; the field keeps its value. |
| `bind_field` | `layer`, `field`, `property`, `condition?` | Binds a field to one of the wallpaper's user properties. |
| `unbind_field` | `layer`, `field` | Frees a field from its user property. |
| `add_user_property` | `property_kind`, `label`, `key?`, `value?`, `min?`, `max?`, `step?`, `whole_numbers?`, `options?`, `condition?` | Defines a user property of the wallpaper (bool, slider, color, combo, text_input, file, directory, scenetexture, usershortcut, group, or text for a label). Returns its key. |
| `update_user_property` | `key`, `label?`, `value?`, `min?`, `max?`, `step?`, `whole_numbers?`, `options?`, `condition?` | Changes a user property's definition (value is its default). |
| `remove_user_property` | `key` | Removes a user property; bound fields keep their values. |
| `rename_user_property` | `key`, `new_key` | Renames a user property's key, re-pointing conditions and bound fields. |
| `move_user_property` | `key`, `index` | Moves a user property in the list. |


**Examples.** Move a layer, fade it and add a blur, as one undo step:

```json
{"name": "scene_apply_edits", "arguments": {
  "wallpaper_id": "2984716315",
  "action_name": "Soften the clouds",
  "edits": [
    {"op": "set_origin", "layer": 12, "value": "960 700 0"},
    {"op": "set_alpha", "layer": 12, "alpha": 0.6},
    {"op": "add_effect", "layer": 12, "effect": "effects/blur/effect.json"},
    {"op": "set_effect_constant", "layer": 12, "effect": "+1", "constant": "strength", "value": "4"}
  ]}}
```

```json
{"results": [{"op": "set_origin", "layer": 12, "field": "origin"}, {"op": "set_alpha", "layer": 12, "field": "alpha"},
             {"op": "add_effect", "layer": 12, "effect": "+1", "file": "effects/blur/effect.json"},
             {"op": "set_effect_constant", "layer": 12, "effect": "+1", "constant": "strength", "value": 4}],
 "undo": {"can_undo": true, "can_redo": false, "undo_action": "Soften the clouds", "redo_action": null},
 "message": "Applied 4 edits to the draft of \"Clouds\" as one undo step; it shows in its open Wallpaper Editor window, and on the displays once wallpaper_editor_save saves it."}
```

Then save the draft, so the displays show it:

```json
{"name": "wallpaper_editor_save", "arguments": {"wallpaper_id": "2984716315"}}
```

Add a clock, a user property that hides it, and fade it in with a timeline:

```json
{"name": "scene_apply_edits", "arguments": {"wallpaper_id": "2984716315", "edits": [
  {"op": "add_layer", "kind": "text", "text_script": "clock", "x": 960, "y": 540, "point_size": 96},
  {"op": "add_user_property", "property_kind": "bool", "label": "Show clock", "key": "showclock", "value": "true"}
]}}
```

```json
{"name": "scene_apply_edits", "arguments": {"wallpaper_id": "2984716315", "edits": [
  {"op": "bind_field", "layer": 31, "field": "visible", "property": "showclock"},
  {"op": "timeline_add_keyframe", "layer": 31, "field": "alpha", "frame": 0, "value": "0"},
  {"op": "timeline_add_keyframe", "layer": 31, "field": "alpha", "frame": 60, "value": "1"},
  {"op": "timeline_set_ease", "layer": 31, "field": "alpha", "frame": 60, "ease": "ease_out"}
]}}
```

Rain from WE's presets, denser, and a script on a layer's angle:

```json
{"name": "scene_apply_edits", "arguments": {"wallpaper_id": "2984716315", "edits": [
  {"op": "add_particle_system", "system": "preset:rain/0"},
  {"op": "set_particle_override", "layer": 32, "key": "count", "value": "2"}
]}}
```

```json
{"name": "script_set", "arguments": {"wallpaper_id": "2984716315", "layer": 12, "field": "angles",
  "script": "export function update(value) { value.z = Math.sin(engine.runtime) * 0.1; return value; }"}}
```

A puppet that waves:

```json
{"name": "scene_apply_edits", "arguments": {"wallpaper_id": "2984716315", "edits": [
  {"op": "puppet_create", "layer": 7},
  {"op": "puppet_add_bone", "layer": 7, "parent": 0, "name": "Arm", "x": 40, "y": 80},
  {"op": "puppet_add_animation", "layer": 7, "name": "Wave", "frames": 60},
  {"op": "puppet_set_key", "layer": 7, "animation": 0, "bone": 1, "frame": 30, "angle": 25},
  {"op": "puppet_update_animation_layer", "layer": 7, "animation_layer": 0, "blend": 0.8}
]}}
```

A mistake changes nothing:

```json
{"content": [{"type": "text", "text": "edits[1] (set_effect_combo): MODE takes 0 (Soft), 1 (Hard). Nothing was changed."}], "isError": true}
```

### Library and app

Playlists, favourites, the Installed tab's folders, deleting wallpapers, the displays wallpapers are shown on, the app's
settings, its caches and the plugins' status. Each tool does what the app's own control does, through the same
view models, so a change saves and applies as it does from the app. Every result carries a
`message` saying what happened.

| Tool | Arguments | What it does |
|---|---|---|
| `playlist_create` | `name`, `wallpaper_ids?` | Creates a playlist, as the playlist sidebar does, with those wallpapers in order (repeats dropped), and makes it the active playlist. A name another playlist has (case-insensitive) is refused. |
| `playlist_update` | `playlist`, `change_wallpaper?` (`logon`, `timer`, `daytime`, `dayofweek`, `never`), `duration_seconds?` (5–3600), `change_when_video_ends?`, `change_while_paused?`, `begin_with_first_wallpaper?`, `first_wallpaper_at_startup_only?`, `daytime_ends?` (`"HH:MM"` or `""` per wallpaper), `transition?` (`none_reduce_flicker`, `none`, `random` or a kind such as `fade`, `glass_shatter`), `transition_pool?` (kinds), `transition_time_ms?` (0–3000) | A playlist's own options, as its view and its Playlist Settings sheet set them ([playlists.md](playlists.md)). The duration snaps to the view's steps (5 s below a minute, 15 s from a minute on), the transition time to 50 ms. The timer's options apply only with `change_wallpaper: "timer"`; `first_wallpaper_at_startup_only` needs `begin_with_first_wallpaper`. `daytime_ends` gives each wallpaper's end in order (the last always runs to midnight; ends never go back). The result's `playlist.settings` has them all, with `daytime_slots` (start and end) for `daytime` and `weekdays` for `dayofweek`. Rotate, shuffle and repeat are app-wide: `settings_set`'s `playlist_rotate`, `playlist_shuffle`, `playlist_repeat`. |
| `playlist_add_items` | `playlist`, `wallpaper_ids` | Appends wallpapers, as Add to Playlist in the library's menu does; one already in the playlist stays where it is. |
| `playlist_remove_items` | `playlist`, `wallpaper_ids` | Removes wallpapers from the playlist (they stay in the library). Every id must be in the playlist, or nothing is removed. |
| `playlist_move_item` | `playlist`, `wallpaper_id`, `offset` | Moves a wallpaper up (negative) or down (positive) that many places, one place at a time as Move Up and Move Down do. |
| `playlist_delete` | `playlist`, `confirm` | Deletes the playlist (its wallpapers stay in the library), as its Delete button does. Needs `confirm: true`. |
| `wallpaper_set_favorite` | `id`, `favorite` | Favourites a wallpaper or not, as the library's heart does (the My Favourites filter). |
| `folders_list` | none | The Installed tab's folders: each one's `id`, `name`, `path` (`"Games / Retro"`), `color`, `icon`, `wallpaper_ids` (installed wallpapers filed in it) and `subfolders`, plus `top_level_wallpaper_count`. A wallpaper is in one folder at most. |
| `folder_create` | `name`, `parent?` (an id or path such as `"Games/Retro"`, case-insensitive) | Create Folder in the Installed tab: a folder at the top level or inside `parent`. Names may repeat, as in Wallpaper Engine. |
| `wallpaper_move_to_folder` | `wallpaper_ids`, `folder?` (an id or path; omitted or `""` is the top level) | Move to Folder: takes each wallpaper out of its folder and files it in `folder`, or back at the top level. Nothing is copied or deleted. |
| `wallpaper_delete` | `id`, `confirm`, `to_trash?` (`true` by default) | Unsubscribe in the library: moves the wallpaper's folder to the Trash (or deletes it at once with `to_trash: false`), takes it off the displays showing it, forgets its library index entry and snapshots, and removes Workshop dependencies nothing else uses. Only folders in the wallpaper storage folder. Steam subscriptions are not touched. Needs `confirm: true`. |
| `display_settings_get` | `display?` | Each display's `id`, `name`, `main`, `enabled` (wallpapers shown on it), `rule` (the playback rule's state) and `wallpaper`. |
| `display_settings_set` | `display`, `enabled` | Display Settings' Enabled switch: shows wallpapers on the display, or the desktop picture. |
| `settings_get` | `keys?` | Each allow-listed setting: `key`, `value`, `type` (`boolean`, `integer`, `choice`, `action`), `values` or `minimum`/`maximum`, and `description`. |
| `settings_set` | `key`, `value` (text; a JSON number or boolean works too) | Sets one allow-listed setting through Settings' own model, as its control does. Returns the setting as `settings_get` lists it. |
| `caches_get` | none | Settings › Performance › Caches: `total_bytes`, the space Open Wallpaper Engine's caches take on disk, and each cache's `id` and `bytes` (`textures`, `loading_snapshots`, `editor_previews`, `video_textures`, `legacy_video_textures`, `repaired_videos`, `display_pictures`, `shader_variants`, `pipeline_archives`, and `metal_shader_cache`, the GPU shader cache macOS keeps for the app). Entries unused for 60 days are deleted automatically. |
| `caches_clear` | `confirm` | Clear Caches: deletes every cache entry except what the wallpapers on screen use (and the editor's previews while the Wallpaper Editor runs), and clears the GPU shader cache at the app's next launch. Returns `removed_entries`, `removed_bytes` and `metal_shader_cache_cleared_at_next_launch`. Wallpapers load slower once afterwards. Needs `confirm: true`. |
| `plugin_status` | none | Settings › Plugins' entries: `id`, `name`, `installed`, `enabled` (the Screen Saver's toggle; null otherwise), `version`, `update_available`, `detail`. Status only. |

`playlist` takes a playlist's name (case-insensitive) or id from `list_playlists`. Playlist tools
return the playlist as `list_playlists` writes it, plus `change_when_video_ends`.

**Settings keys** (`settings_set` key → the app's setting):

| Key | Values | App setting |
|---|---|---|
| `other_application_focused` | `keep_running`, `mute`, `pause`, `pause_all` | Performance › Other Application Focused |
| `other_application_maximized`, `other_application_fullscreen` | `keep_running`, `mute`, `pause`, `pause_all`, `stop` | Other Application Maximized / Fullscreen |
| `other_application_playing_audio` | `keep_running`, `mute`, `pause` | Other Application Playing Audio |
| `display_asleep`, `laptop_on_battery` | `keep_running`, `pause`, `stop` | Display asleep, Laptop on battery |
| `quality_preset` | `low`, `medium`, `high`, `ultra` (an action; reads as null) | The Preset buttons (`setQuality`) |
| `anti_aliasing` | `none`, `msaa_x2`, `msaa_x4`, `msaa_x8` | Anti-aliasing |
| `post_processing` | `disabled`, `enabled`, `ultra`, `display_hdr` (only with an HDR display) | Post-Processing |
| `texture_resolution` | `high_quality`, `high_performance`, `automatic` | Texture Resolution |
| `scene_detail` | `match_display`, `full` | Effect Detail |
| `render_resolution` | `your_display`, `uhd4k`, `full` (the earlier `display` and `retina` set `your_display`, `4k` sets `uhd4k`) | Render Resolution |
| `upscaling` | `off`, `bilinear` (the earlier `metalfx` sets `bilinear`: MetalFX was removed) | Upscaling |
| `render_scale` | `50`, `67`, `75` | Render Scale |
| `shadows`, `volumetrics` | `disabled`, `low`, `medium`, `high`, `ultra` | Shadows, Volumetrics |
| `fps` | 10–240, whole (240: no limit) | FPS slider (also marks the rate as the user's own, as the slider does) |
| `quality_efficiency` | 1–5, whole | Quality ↔ Efficiency |
| `particle_budget` | `low`, `medium`, `high`, `unlimited` | Particle Budget |
| `reflections` | boolean | Reflections |
| `sync_properties_across_displays` | boolean | Optimizations › Sync properties across displays |
| `video_framework` | `avkit`, `metal` | Video Framework |
| `audio_output`, `reload_on_output_device_change`, `media_integration` | boolean | Audio Output, Reload when changing output device, Media integration support |
| `optimise_textures`, `cheaper_shadows`, `web_standard_resolution`, `reduced_resolution_particles` | boolean | Optimise textures, Cheaper shadows, Render web wallpapers at standard resolution, Draw large glowing particles at half resolution |
| `process_priority` | `normal`, `below_normal` | Process Priority |
| `pause_on_vram_exhausted` | boolean | Pause when VRAM is exhausted |
| `appearance` | `light`, `dark`, `follow_system` | General › Theme |
| `adjust_menu_bar_tint` | boolean | General › Adjust Menu Bar Color |
| `wallpaper_placement` | `fill`, `fit`, `center`, `stretch`, `zoom` | The details panel's Placement |
| `playlist_rotate`, `playlist_shuffle`, `playlist_repeat` | boolean | The playlist view's Rotate automatically, Shuffle, Repeat |

Example:

```json
{"name": "playlist_create", "arguments": {"name": "Night", "wallpaper_ids": ["2873465123", "my-scene"]}}
```
```json
{"playlist": {"id": "6F0C…", "name": "Night", "active": true, "rotating": false, "shuffle": false,
  "duration_seconds": 300, "change_when_video_ends": false, "displays": [],
  "wallpapers": [{"id": "2873465123", "title": "Rainy Window", "type": "scene"},
                 {"id": "my-scene", "title": "My Scene", "type": "scene"}]},
 "message": "Created the playlist \"Night\" with 2 wallpapers; it is now the active playlist."}
```

```json
{"name": "wallpaper_delete", "arguments": {"id": "2873465123", "confirm": true}}
```
```json
{"deleted": {"id": "2873465123", "title": "Rainy Window", "type": "scene", "tags": ["Nature"],
  "folder": "/Volumes/…/2873465123", "workshop_id": "2873465123"},
 "to_trash": true, "message": "Moved \"Rainy Window\" to the Trash; it is no longer in the library."}
```

```json
{"name": "display_settings_set", "arguments": {"display": "2", "enabled": false}}
```
```json
{"display": {"id": "2", "name": "Studio Display", "main": false, "enabled": false, "rule": "run", "wallpaper": null},
 "message": "Wallpapers are off on Studio Display; it shows the desktop picture."}
```

```json
{"name": "settings_set", "arguments": {"key": "fps", "value": "60"}}
```
```json
{"setting": {"key": "fps", "value": 60, "type": "integer", "minimum": 10, "maximum": 240,
  "description": "The most frames a second scene and web wallpapers draw; 240 means no limit. …"},
 "message": "fps is 60."}
```

```json
{"name": "plugin_status", "arguments": {}}
```
```json
{"plugins": [
  {"id": "screen_saver", "name": "Screen Saver", "installed": true, "enabled": true, "version": null, "update_available": false, "detail": null},
  {"id": "chromium_engine", "name": "Chromium web engine", "installed": false, "enabled": null, "version": null, "update_available": false, "detail": null},
  {"id": "depth_map_generation", "name": "Depth Map Generation", "installed": true, "enabled": null, "version": "depth-anything-v2-small-f16-…", "update_available": false, "detail": null},
  {"id": "mcp_server", "name": "MCP Server", "installed": true, "enabled": null, "version": "1.0.0", "update_available": false, "detail": null}],
 "message": "Screen Saver: installed; Chromium web engine: not installed; Depth Map Generation: installed; MCP Server: installed."}
```

**Rules.**

- `playlist_delete`, `wallpaper_delete` and `caches_clear` refuse (`refused`) without `confirm: true`; a client
  should ask the user first. `playlist_remove_items` is marked destructive too.
- `wallpaper_delete` deletes only a library wallpaper's folder inside the wallpaper storage folder,
  through the library's own Unsubscribe steps; it never touches Steam.
- `settings_set` refuses (`refused`, with where to change it in the app) launch at login
  (`auto_start`), restart after crashing, crash reporting, updates, web wallpaper trust and plugins
  (security-relevant); the language and the log level; the screen saver and the lock screen picture
  (the system tools own those); application rules (a list of apps, edited in Settings ›
  Performance); and auto refresh, which has no control in the app. An unknown key lists the keys.
- None of the allow-listed settings shows a macOS permission prompt.
- Plugins are reported only; installing and removing them stays in Settings › Plugins.
- Not offered, because Open Wallpaper Engine has no such control: renaming a playlist. A
  wallpaper's tags and age rating are read with `get_wallpaper`; the app's own editors for them
  rewrite `project.json` through a model that drops its user properties, so they are not exposed.

### Export, screen saver and lock screen

Scene Edit / Export's **iPhone & iPad Export** and **Screen Saver** modes, and Settings ›
General's **Show Wallpaper on Lock Screen**. Each tool runs the
code those controls run. None of them opens a window or System Settings, changes a system setting,
or makes macOS ask for a permission.

| Tool | Arguments | What it does |
|---|---|---|
| `devices_list` | `query?` | The iPhones and iPads the export makes Live Photo lock screens for, newest first: `id` (the name), `name`, `family` (`iPhone`, `iPad`), `width`/`height` in pixels (portrait) and `year`. `query` narrows them as the mode's device search does (name, family, year, or a resolution such as `1320x2868`). |
| `export_settings_get` | `wallpaper_id?` | What the export remembers: the `device`, `save_to_photos` ("Also Save to Photos Album"), `photos_album` and `photos_access` (`authorized`, `limited`, `denied`, `restricted`, `not_determined`; reading it never asks), and the ranges `export_live_photo` takes (`qualities`, `max_zoom`, `clip_lengths`, `clip_timeline_seconds`, `frame_rate`). With `wallpaper_id`, also the `scene`'s `width`/`height` in scene units, which the crop's centre is measured in. |
| `export_live_photo` | `wallpaper_id`, `device?`, `crop?` (`zoom` 1–3, `center_x`, `center_y`), `clip?` (`start`, `length` 1–3 s), `settings?` (`quality`: `best`, `high`, `smaller`; `save_to_photos`), `output_folder?` | Renders a scene as a Live Photo (HEIC + MOV) as the mode's Save does, with the wallpaper's own property values and edits (what the mode copies when it opens), and waits for it. `device` defaults to the remembered one; the crop defaults to the whole-scene window, centred; without `clip.start` the clip is the window with the most motion, as the mode picks it. Returns the `photo` and `movie` paths, the `crop` and `clip` used, and `photos` (`off`, `skipped`, `saved`, `failed`, `needs_access`). Without `output_folder` the files stay in the app's cache (`in_cache`) until the mode's next export clears it; `output_folder` must be an existing absolute folder (files of the same name are replaced). |
| `export_android` | `wallpaper_id` or `wallpaper_ids`, `mode?` (`high_quality`, `balanced`, `pre_rendered`), `options?` (`pixel_art`, `texture_reduction` 1/2/4, `cropping`: `phone`/`original`, `video_preset`: `original`/`full_hd`/`uhd_4k`, `fps` 24/30/60, `alignment` 0–1), `output_folder?` | Scene Edit / Export's Android Export: one `<title>.mpkg` per wallpaper (unique names) for Wallpaper Engine's Android app, and waits for them. Videos are packed as they are; scenes are Dynamic (`balanced` by default) or a pre-rendered 30 s video. Returns the `folder`, each of the `packages` (`wallpaper_id`, `title`, `type`, `mode`, `path`, `size`, `preview`), and what was `skipped` (web and application wallpapers, with the reason) or `failed`. Without `output_folder` the packages go to the app's export cache folder. |
| `android_send_wifi` | `package_paths` (from `export_android`) or `wallpaper_id` / `wallpaper_ids` (exported first, with `export_android`'s `mode?`, `options?`, `output_folder?`), `address?` | The Android export's "Send over Wi-Fi" without its sheet: serves only those packages on the Mac's local network behind a random 50-bit token, GET only, for 15 minutes, and returns the `url` (`http://owe-fileshare.<mac>.local:<port>/<token>/` while the name is advertised, else `http://<IPv4>:<port>/<token>/`), `expires_at`, `expires_in_seconds`, the Mac's local-network `addresses` (`address` picks one; the primary interface's by default), the `files` (`index`, `title`, `type`: `sceneDynamic`, `scenePreRendered`, `video`, `size`, `path`, `download_name`) and the `export` it made, if any. `package_paths` must be WE mobile packages (`.mpkg`, `PKGM`). A new call replaces the previous session. Refused with `unavailable` when the Mac has no local-network address. |
| `screensaver_get` | `wallpaper_id?` | `plugin_enabled` (Settings › Plugins › Screen Saver) and the `selection`: the wallpaper set as the screen saver (`wallpaper`, `folder`, `kind`: `live`: drawn live, a scene with its screen saver choices, a video as it is, and `picked`, when it was set), or null while the screen saver draws the desktop's wallpapers live; `same_as_wallpaper`, Settings › General › Screen Saver Same as Wallpaper, is true exactly then. With `wallpaper_id`, its screen saver version: `eligible` (scenes only), `is_screen_saver`, `own_choices` (the screen saver has its own saved choices; else it follows the wallpaper's values), the `layers` (`id`, `name`, `kind`, `visible` as the screen saver shows it, `authored_visible`) and the user `properties`. |
| `screensaver_set_layers` | `wallpaper_id`, `layers?` (`[{layer, visible}]`, `layer` by id or name), `properties?` (`[{key, value}]`) | The Screen Saver mode's layer switches and user properties, saved as the screen saver's own choices for that scene (`ScreenSaverSettingsStore`), never touching the desktop. Values are checked as `set_user_property` checks them. Values equal to the wallpaper's own are not saved (`saved: false`): the screen saver follows the wallpaper until its choices first differ, as in the mode. The screen saver draws the wallpaper with them while it is set as the screen saver. |
| `screensaver_set` | `wallpaper_id` | "Set as Screen Saver": a scene becomes the screen saver, drawn live with its screen saver choices while the screen saver runs; a web wallpaper or WebM video is drawn live through the Chromium engine (refused with `unavailable` while the engine isn't installed); a video wallpaper is drawn live as it is. Nothing is recorded. When the Screen Saver plugin is off, this turns it on (`enabled_plugin`), which installs the saver, as the mode does. It turns Screen Saver Same as Wallpaper off (`same_as_wallpaper` false). Returns the `selection`. |
| `screensaver_stop_using` | none | "Stop Using as Screen Saver": the screen saver draws the desktop's wallpapers live again, which is Screen Saver Same as Wallpaper on (`same_as_wallpaper` true). `stopped` is false when nothing was set. |
| `lock_screen_get` | none | `enabled`, `may_change_desktop_picture` (false in an isolated copy), `follows` (the selected display's wallpaper) and per display its `wallpaper`, `picture` (the desktop picture the lock screen shows) and `is_lock_screen_picture`. |
| `lock_screen_set` | `enabled` | Turns Show Wallpaper on Lock Screen on (the pictures are applied at once) or off (the user's pictures come back), as Settings › General does. |
| `lock_screen_refresh` | none | Draws each display's picture again now from the wallpaper it shows, as turning the setting on does. |

Export a Live Photo for an iPhone into a folder, keeping the clip's automatic start:

```json
{"name": "export_live_photo", "arguments": {
  "wallpaper_id": "2849384121", "device": "iPhone 17 Pro",
  "crop": {"zoom": 1.4, "center_x": 1100},
  "settings": {"quality": "high"},
  "output_folder": "/Users/you/Pictures/Live Photos"}}
```

```json
{
  "wallpaper": {"id": "2849384121", "title": "Rainy Window", "type": "scene", "...": "..."},
  "device": {"id": "iPhone 17 Pro", "name": "iPhone 17 Pro", "family": "iPhone", "width": 1206, "height": 2622, "year": 2025},
  "photo": "/Users/you/Pictures/Live Photos/Rainy Window.HEIC",
  "movie": "/Users/you/Pictures/Live Photos/Rainy Window.MOV",
  "in_cache": false,
  "crop": {"zoom": 1.4, "center_x": 1100, "center_y": 540, "scene_width": 1920, "scene_height": 1080},
  "clip": {"start": 6.2, "length": 3, "automatic": true},
  "quality": "high",
  "photos": {"status": "saved", "album": "Open Wallpaper Engine"},
  "message": "Exported \"Rainy Window\" as a Live Photo for iPhone 17 Pro (1206×2622): Rainy Window.HEIC and Rainy Window.MOV in /Users/you/Pictures/Live Photos/. Also saved to the \"Open Wallpaper Engine\" album in Photos (Also Save to Photos Album is on)."
}
```

Hide a clock in the screen saver's version, then make it the screen saver:

```json
{"name": "screensaver_set_layers", "arguments": {"wallpaper_id": "2849384121",
  "layers": [{"layer": "Clock", "visible": false}], "properties": [{"key": "rain", "value": "true"}]}}
```

```json
{
  "wallpaper": {"id": "2849384121", "title": "Rainy Window", "type": "scene", "...": "..."},
  "saved": true,
  "layers": [{"id": 1, "name": "Background", "kind": "image", "visible": true, "authored_visible": true},
             {"id": 4, "name": "Clock", "kind": "text", "visible": false, "authored_visible": true}],
  "properties": {"rain": "true", "speed": "1"},
  "message": "Saved the screen saver's choices for \"Rainy Window\": hid \"Clock\" and set rain to true. The desktop is unchanged; the screen saver draws it with them while it is set as the screen saver (screensaver_set)."
}
```

```json
{"name": "screensaver_set", "arguments": {"wallpaper_id": "2849384121"}}
```

```json
{
  "wallpaper": {"id": "2849384121", "title": "Rainy Window", "type": "scene", "...": "..."},
  "selection": {"wallpaper": {"id": "2849384121", "...": "..."}, "folder": "/…/2849384121", "kind": "live", "picked": "2026-10-04T09:12:44Z"},
  "enabled_plugin": false,
  "message": "\"Rainy Window\" is the screen saver, drawn live with its screen saver choices (screensaver_set_layers). To use it, pick \"Open Wallpaper Engine\" in System Settings › Screen Saver if it isn't your screen saver yet."
}
```

The lock screen:

```json
{"name": "lock_screen_get", "arguments": {}}
```

```json
{
  "enabled": true, "may_change_desktop_picture": true,
  "follows": {"id": "2849384121", "title": "Rainy Window", "type": "scene", "...": "..."},
  "displays": [{"id": "1", "name": "Built-in Retina Display", "wallpaper": {"id": "2849384121", "...": "..."},
                "picture": "/…/lock-1-a.heic", "is_lock_screen_picture": true}],
  "message": "Show Wallpaper on Lock Screen is on: each display's lock screen shows \"Rainy Window\"'s snapshot, the wallpaper Open Wallpaper Engine shows on its selected display (it follows that wallpaper on every display; there is no other choice)."
}
```

What these tools don't do, and why:

- **Photos access is never asked for.** "Also Save to Photos Album" is the user's setting. When it
  is on and access is granted, an export also goes to that album; when access was never asked or
  was refused, the files are exported and the message says to allow it once in the app (turn the
  option on in the iPhone & iPad Export mode's Export Settings) or in System Settings › Privacy &
  Security › Photos. `save_to_photos: false` leaves one export out; nothing turns the album on.
- **AirDrop** isn't offered: it opens a sharing window for the user.
- **Choosing the macOS screen saver** is the user's: Open Wallpaper Engine only opens System
  Settings › Screen Saver for them, so no tool does that or changes a system setting. The messages
  say to pick "Open Wallpaper Engine" there.
- **The Screen Saver plugin** is installed or removed only in Settings › Plugins. The one exception
  is OWE's own: `screensaver_set` turns it on when it is off, as the Screen Saver mode does.
- **Other wallpaper types.** Export and layer choices are for scenes, as the modes are, and
  `screensaver_set` takes scenes, videos and web wallpapers (web pages and WebM videos only with
  the Chromium engine installed); application wallpapers are refused.
- **Lock screen.** It follows the wallpaper OWE shows on its selected display, on every display;
  there is no choice to expose. An isolated copy never changes the desktop picture, so
  `lock_screen_refresh` is refused there; it is also refused while the setting is off.
- **One at a time.** A second `export_live_photo` or `export_android` while one renders, or a second
  `screensaver_set` while a video is being put in place, is refused with `unavailable`.
- **An open Screen Saver mode.** If Scene Edit / Export has the same wallpaper open in its
  Screen Saver mode, its own copy of the choices replaces what `screensaver_set_layers` saved when
  the mode next saves (as it does after each change and when it closes).

`export_live_photo`, `export_android`, `screensaver_set` and `depth_generate` may take minutes, so `owe-mcp` waits up to
15 minutes for them instead of the usual two. When the call carries `_meta.progressToken`,
`owe-mcp` sends `notifications/progress` every 5 seconds until it answers (a count with no total:
the app doesn't say how far it is), so a client that resets its timeout on progress keeps
waiting. A client that gives up sooner gets no answer, but the app finishes the work;
`screensaver_get` and the export's folder show the result.

### What clients can't do

The plugin never touches Steam accounts, logins, Workshop subscriptions or account actions; it
can't install or remove plugins (`plugin_status` only reads them), runs no commands, and reaches
nothing outside Open Wallpaper Engine's own data. Edits are kept beside a wallpaper, never written
into its files. Every tool carries MCP's annotations (`readOnlyHint`, `destructiveHint`,
`idempotentHint`), so a client can ask before anything that changes or removes something; the
tools that delete what the user made (`wallpaper_delete`, `playlist_delete`) also need
`confirm: true`. Anything that would make macOS ask for a permission the first time is refused
with what to do once in the app instead.

### Resources

`resources/list` offers `owe://library` (every wallpaper, as `list_wallpapers` returns them) and
`owe://status` (what `get_status` returns).

## Security model

- **Opt-in.** Nothing listens until the plugin is installed. Removing it closes the socket and
  every connection, and deletes `owe-mcp`.
- **Local only.** `owe-mcp` talks to the app over a Unix domain socket,
  `~/Library/Application Support/Open Wallpaper Engine/Control/control.sock`. There is no network
  port for the channel itself. `android_send_wifi` is the one tool that opens one: a listener on the
  Mac's local network that serves only the packages it names, behind a random token, for 15
  minutes (see [architecture](architecture.md#android-export-androidexport)).
  A socket's path is limited to 103 bytes; when that path is longer (a long user name), the socket
  goes in your own temporary folder instead (`/var/folders/…/T/owe-<hash>/control.sock`, which
  only you can enter), and `owe-mcp` finds it the same way. An isolated copy
  (`OWE_ISOLATED_STATE=<tag>`) always has its socket at
  `/private/tmp/owe-<your uid>/isolated-<hash of the tag>.sock`: short whatever the tag, and the
  same for the copy and every `owe-mcp` given the tag, whatever temporary folder each was started
  with.
- **Owner-only.** The socket's folder is `0700` and the socket `0600`, and the app checks that each
  connection comes from your own user account (`getpeereid`) before reading from it. Other users
  on the Mac can't connect. Under `/private/tmp`, where anyone can make a folder, the app listens
  and `owe-mcp` connects only in a real folder that belongs to you (not a link), so another user
  can't put a socket of theirs in an isolated copy's place.
- **No more than the app's own controls.** Every request goes through what the app's buttons and
  menus do, on the app's main thread: a web wallpaper still needs your trust in the app before a
  client can set it, safe restart still holds back a wallpaper that stopped the app, an import
  copies only wallpaper folders, as the Import button does, and a scene edit goes through the
  editors' own edit model, undo included, into the Wallpaper Editor's draft beside the wallpaper,
  which the wallpaper runs only once the client or the user saves it.
- **What a client can reach.** Anything running as your user could already change the app's
  settings files; the socket adds no access beyond that. Treat an MCP client like any program you
  run: it can change your wallpapers, their edits, playlists and settings, and import folders it
  can read; it can delete only with `confirm: true`.

The wire format between `owe-mcp` and the app is one JSON object per line, with a `version`
(`ControlRequest`, `ControlResponse` in `Packages/OWEControl`); the app refuses requests of another
version, so an `owe-mcp` from a different release says so instead of misbehaving.

## Troubleshooting

- **"Open Wallpaper Engine is running but doesn't accept MCP clients"**: the plugin isn't installed
  in this copy of the app. Install it in Settings › Plugins.
- **"didn't start within 30 seconds"**: the app couldn't be started, or started without the plugin
  (it was removed). Start the app yourself and check Settings › Plugins › MCP Server.
- **The client says the server failed to start**: check the path in its configuration. Copy it
  again with **Copy Configuration For**; it must be absolute (clients don't expand `~`).
- **Paths with spaces.** The path contains spaces (`Application Support`). In JSON, TOML and YAML
  it is one quoted string, as the snippets write it: don't split it into `args`. In a shell, quote
  it. Run it by hand to see its messages on stderr:
  `"$HOME/Library/Application Support/Open Wallpaper Engine/Plugins/MCP/owe-mcp" --help`.
- **The app isn't running.** The first tool call starts it in the background and waits up to 30
  seconds. A client that times out sooner can simply try again once the app is up.
- **The plugin isn't installed** (or was removed): `owe-mcp` is gone from Application Support, so
  the client can't start it, or a running copy answers *"its MCP Server plugin isn't installed"*.
  Install it again in Settings › Plugins and copy the configuration again.
- **"MCP clients can't connect"** under the plugin in Settings: the socket couldn't be opened. The
  message says why; the app's log has the details:
  `/usr/bin/log show --last 10m --predicate 'process == "Open Wallpaper Engine"' | grep MCP`.
- **A development copy.** A copy launched isolated (`OWE_ISOLATED_STATE=<tag>`) keeps its own
  support folder, so the plugin it installs talks only to it. To point any `owe-mcp` at an isolated
  copy, run it with the same `OWE_ISOLATED_STATE` (it then uses the copy's socket under
  `/private/tmp/owe-<uid>/`), or with `--socket <path>`.

## For developers

- `Packages/OWEControl` (`swift test --package-path Packages/OWEControl`): `OWEControlProtocol` is
  the wire format, the socket server and client and the plugin's layout; `OWEMCP` is the MCP
  server: JSON-RPC 2.0 over stdio (protocol versions 2025-06-18, 2025-03-26 and 2024-11-05,
  `MCPProtocolVersion`), the tools' schemas and the launcher; `MCPClientConfiguration` writes each
  client's snippet. `MCPCompatibilityTests` and `MCPClientConfigurationTests` keep them honest.
- `MCPServer/main.swift` is the `owe-mcp` executable (target OWEMCPServer), embedded in
  `Contents/Helpers`.
- `OpenWallpaperEngine/MCP/` is the app's side: the plugin (`MCPServerPlugin`), its Settings row,
  the request router (`ControlRequestRouter`) and the app model it drives (`AppControlModel`).
  The router hands the other areas' requests to request groups (`ControlRequestGroup`): `MCP/Scene/`
  (`SceneControlRequests`: the headless edit sessions `HeadlessSceneEditService` and
  `HeadlessSceneDocument`, the edit kinds `SceneEditOperations`, the editors' windows),
  `MCP/Library/` and `MCP/System/`. The edit kinds are listed once, in
  `OWEControlProtocol/ControlSceneEdits`, which the tool's schema and the app's tests both read.
