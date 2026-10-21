# Model import and the Model Editor

How the Wallpaper Editor imports FBX and OBJ models as Wallpaper Engine (2.3 and later) does,
what it writes, and what is still a guess. The `.mdl` format itself is in
[`models-plan.md`](models-plan.md) §1.

## What Wallpaper Engine does

Sources: WE 2.8.0.42's install (`bin/resourcecompiler64.exe`, `bin/wallpaperui.exe`,
`ui/dist/scripts/scripts.js`), its default projects (`projects/defaultprojects/*/models/`, which
keep each model's source, configuration and compiled `.mdl` side by side), the library's
imported models, and the docs at docs.wallpaperengine.io/en/scene/models/.

- **Import.** Add Asset › Model (or a model dropped on New Project) copies the source into the
  project, writes its configuration `models/<name>.json` and compiles the `.mdl` with
  `resourcecompiler64.exe -mdl`, which reads the source with **Assimp**
  (`assimp-vc143-mt64.dll`; it accepts `.obj .fbx .blend .dae .3ds .lxo .gltf`). The docs ask for
  FBX, or OBJ for simple models without animation, −Z forward and +Y up, and textures beside
  the model. The editor recompiles a model whose `.mdl` isn't the writer's current version
  (`MDLV0023`, models-plan §1.1) before it uses it.
- **Configuration** (`models/<name>.json`; capture 546, WE 2.8.0.42, and
  `resourcecompiler64.exe`, which reads every list from `editor`, 0x14009f3a9…): at the top
  level `normals`, `tangentspace`, `seconduvchannel`, `skinning` (the blend indices and weights,
  and so the skeleton, are written only when it is true, 0x1400207bf; WE writes it for a skinned
  import) and `skins` (a list of `{material: replacement}`, one material per skin and mesh);
  in `editor`: `animationmapping` (`{"Rig|walk": 41, "Rig|wave": 42}`: each animation's id, from
  the editor's object counter; `null` without animations), `additionalfiles` (Add FBX File),
  `clips` (`[{animation: "<animation name>", start, end, frameoffset, id, matchloop,
  motionflags, name: "Rig|walk (Clip 0)", rootmotion: "<bone>"}]`; `motionflags` is the clip
  record's flags as they are, Add Clip's 43008 = 0xA800 being position x, position z and yaw),
  `events` (`name`, `frame`, and `clip` (an id) or `animation` (a name), 0x1400a28dd; WE's Add
  Event created nothing in the capture), `attachments` (`[{bone, id, name, transform: "<the
  16 numbers of the MDAT matrix>"}]`) and `constraints` (`[{bone, config: {Puppet Warp's
  whole constraint key set, IK keys, layout, preset, presetresponsiveness}}]`). WE's importer
  writes `normals` and `tangentspace` as true; Import Model rewrites a default project's
  configuration that way (bars' `{"normals": true}`, pistols' `seconduvchannel`); a model
  without a configuration gets neither (the default projects' `techno/glow.mdl`, format 0x9).
- **Compiling the configuration** (capture 546): animations get their `animationmapping` ids
  and loop mode, flags 0; a clip record is flags `0x1 | 0x400` (Match loop) `| motionflags`
  (0xAC01), mode "" (WE's clips have no mode), the index of its source animation and the root
  bone. A bone's properties JSON is its constraint settings passed through with the tip `tp`
  (`"%.5f %.5f %.5f"`), `tm` 10 when it isn't above 0, and `lamin`/`lamax` replaced by their z
  angle on each simulated rotation axis (`rax`/`ray`/`raz`) and 0 on the others when both z
  angles are non-zero ("0 0 ±π/2" with every axis on becomes "±1.57080" thrice; 0x1400b0270).
  The attachment is `MDAT0001` with the transform as its matrix.
- **Materials.** Each mesh material becomes `materials/models/<model>/<material>.json` with
  WE's `generic4` pass (`wallpaperui.exe`'s template: depth test and write on, back faces
  culled) and its albedo texture named after the material
  (`models/<model>/<material>`; PaRappa's imported models: `materials/models/pj/pjberri_minion_body_d (Texture 0).json`).
  Advanced Texture Settings then edits the material: lighting, reflection, rim lighting, toon
  shading, tint mask, and the albedo, normal and PBR maps (metallic, roughness, reflection,
  emissive; `generic4`'s annotations).
- **The Model Editor** (Configure Model; `views/modals/editormodeleditormodal.html` and
  `EditorModelEditorModalCtrl` in `scripts.js`) has four tabs: **Animation** (the source's
  animations with Add Clip, the FBX files with Add FBX File, the clips and their options),
  **Attachments** (Add Attachment; bone, name, origin), **Events** (per animation or clip:
  Add Event, name, frame) and **Constraints** (the bones, each with the bone-physics settings
  Puppet Warp uses, presets, Reset, Copy and Paste). **Blend Layers and Transitions are
  commented out** in WE 2.8.0.42's template: their strings exist
  (`ui_editor_model_editor_tab_blend_layers`, `…_tab_transitions`) but the tabs are empty and
  hidden, so they have no storage format to follow. A model layer's own animation layers
  (`animationlayers` in scene.json, blended by `blend`, `blendin`, `blendout`) are the scene's,
  not the model's.

## What the Wallpaper Editor does

- **Reading** (`Packages/OWEEditor`, module `OWEModelImport`): ufbx (`Vendor/ufbx`, v0.23.1,
  MIT) reads FBX and OBJ (with its `.mtl`) in the file's own axes and units, as WE keeps an
  FBX's node transforms (Blender's 100× scale and −90° turn) in its nodes. `.blend`, `.dae`,
  `.3ds`, `.lxo` and `.gltf` aren't read.
- **Compiling** (`OWESceneEditing/Models/ModelCompiler`), Assimp's steps as WE runs them:
  a mesh's vertices are its polygons' corners, which the polygon's triangles share; polygons
  fan from their first corner (a quad from its concave corner, by Assimp's angle test); a
  static model's parts with one material are one mesh, in material order (Assimp's
  PreTransformVertices: an OBJ's in its `.mtl` order, an FBX's in first use), its vertices
  baked into model space; texture coordinates flip (v → 1 − v); a mesh without normals gets
  smooth ones (GenSmoothNormals); the tangent space is the file's own, else Assimp's
  CalcTangentSpace on the file's (unflipped) coordinates: per triangle, written over the
  vertices it shares with the triangle before, then smoothed over vertices within 1e-4 of the
  box diagonal whose normals agree to 0.9999 and tangents to 45°, with w the sign of
  (N × T) · B. Because WE 2.8 computes it before flipping v, its w is the opposite of the
  `MDLV0004`/`0014` files the default projects ship, except on faces whose coordinates span no
  area (Assimp's default direction). Vertices are joined when position and influences match
  and every other attribute, the tangent space and every texture coordinate set the source
  has (written or not) included, is within 1e-5. Normals are written with `normals`, tangents
  with `tangentspace`, and `seconduvchannel` packs both UV sets into `a_TexCoordVec4` (format
  0x27).
- **Ground truth:** `FBXImport546Tests` compiles capture 546's `skinned2.fbx` with the
  configuration WE wrote and compares every section with WE's `.mdl` (`Fixtures/FBXImport546`):
  meshes, bones, bind pose, boxes, the compiled constraint, the attachment, the ids, flags and
  every track sample. `WEDefaultProjectModelTests` compiles every source of WE's default
  projects (`OWE_WE_INSTALL`, the `wallpaper_engine` folder; skipped without it) and compares
  formats, vertices and indices with WE 2.8's output: the default projects' `MDLV0023` files
  and WE 2.8's own recompiles of `bars.obj`, `flow.obj` and `pistols.fbx` (`OWE_WE_RECOMPILED`,
  the capture's `recompiled` folder). 10 of their 14 meshes match (vertex values within 2e-6);
  pistols' other 4 have WE's vertices and triangles in another order (WE's Assimp reorders
  triangles for the vertex cache, ImproveCacheLocality, which isn't ported) and mesh 0 a
  pentagon Assimp's ear clipping splits along other diagonals. The older shipped files
  (`MDLV0004`, `MDLV0014`) are held to their formats and triangle counts; 18 of their 20 meshes
  match whole too. The seven divergences listed before capture 546 were the old compilers'
  output (bars, flow, dome, shadow and dna are `MDLV0004`/`0014` files) and the joining
  (pistols' two meshes split as WE 2.8 splits them once a polygon's corners are shared and every
  texture coordinate set is compared).
- **Skinned models** keep the nodes the skin needs (the root as "RootNode", every bone and its
  ancestors, and the node of each mesh without a skin), parents first by depth, at a depth the
  skeleton's nodes before the other meshes' (capture 546: RootNode, Rig, Plinth, root, arm;
  one sample, so the tie rule is ours), bone flag 1 on bones and those meshes' nodes, each bone's
  local matrix in the skin's bind pose (a skinned bone at its cluster's bind matrix, not where the
  file's current frame left it), and the mesh skinned in that pose (four influences, the
  largest, renormalised). A mesh without a skin keeps its model-space vertices and is bound to
  its own node with weight 1 (capture 546's Plinth). The `MDLS0004` per-bone block is each
  bone's box in its bind space (half size, then the centre as a translation), which PaRappa's
  `windows_front.mdl` and capture 546 match. Every animation stack becomes an `MDLA0006` record
  as WE turns Assimp's keys into tracks (0x14009fa53…): per node and property (translation,
  rotation, scaling) the keys of its x, y and z curves, each curve read linearly at them
  (Assimp ignores the curves' tangents), the rotation through a quaternion in the node's
  rotation order; each key at its time in frames truncated to a whole frame (Blender writes some
  frames' times a tick early, so their key lands on the frame before, over the key there, and
  the frame after is interpolated), per value a linear curve through those frames sampled at
  every frame, the last frame sampling the first. A node no curve animates keeps its rest pose;
  a node with pivots, offsets or pre/post rotations (which Assimp splits into helper nodes this
  importer doesn't make) is evaluated whole at each frame.
- **Files** (`EditorAssetStore+Models`, `EditorModelImporter`): the model's folder is
  `<name>-<hash of the source>`; the source (and an OBJ's `.mtl`), `<name>.json`, `<name>.mdl`,
  and `materials/models/<folder>/<material>.json` with its texture (PNG or JPEG as it is, other
  images as PNG; found where the model names it, then by name beside the model; missing ones
  draw WE's white and are reported). The store never overwrites, so a configuration the Model
  Editor compiles is `<name>-<hash>.json` and `.mdl`.

## The Model Editor here

`OWEEditor/ModelEditor/` (`ModelEditorView`, `ModelEditorModel`), opened from a model layer's
inspector (Configure Model…) when the model's source is with the edits' files. It edits the
configuration (`ModelImportConfig`) and compiles with it to fill its lists
(`EditorModelImporter.inspect`); OK keeps edited materials, compiles the model again
(`recompile`, a `<name>-<hash>.mdl`) and points every layer drawing the old model at it
(`SceneEditSession.replaceModel`), one undo step.

- **Animation, Attachments, Events, Constraints:** WE's tabs and options (above). Add Clip
  makes WE's clip: named "<animation> (Clip 0)" (counting that animation's clips from 0), the
  whole animation, Match loop on, position x and z and yaw flagged. WE's clip options have no
  frame rate or playback mode (a clip keeps its animation's rate and loops); this editor offers
  both because `MDLA` stores them per clip, and writes them (`fps`, `mode`) only when set. The
  configuration is written in WE's shape (above) and the shape the beta-7 editor wrote is still
  read (top-level `clips`, `events`, `attachments`, `constraints` by bone, clips naming their
  animation by id, `motionflags` as one byte). WE previews the model in the
  modal; here the play button plays a clip or animation on the layer itself, as WE's Skeletal
  animation › Add makes an animation layer (`animationlayers`: rate 1, blend 1).
- **Materials:** WE's Advanced Texture Settings, as a tab. The shader's combos, texture slots
  and constants come from its annotations (`ModelShaderSchema`, the `// [COMBO]` lines and the
  `uniform` comments of `shaders/<shader>.frag` and `.vert` read where the scene reads them), and
  the edited pass is kept as a new material file (`materials/models/<folder>/<material>-<hash>.json`)
  that the configuration's `materials` map names (ours: WE edits the material file in place,
  which the edits' files never do).
- **Blend Layers and Transitions:** not offered; WE 2.8.0.42 has them commented out, with no
  storage format.
- **Clean Project** keeps a used model's materials (the paths in the `.mdl`), configuration and
  sources (`ProjectCleaner.collectModelNames`).
## Adding a model from a file

Add Layer › Model… lists the wallpaper's models, the ones imported in the editor (Imported) and
WE's; **Import FBX or OBJ…** (and an FBX or OBJ dropped on the canvas or the asset browser)
imports the file (`EditorModelImporter.importModel`) and adds a model layer drawing it
(`LayerActions+Models`), at the scene's centre or the drop point in 2D, the camera's centre in
3D, with scale 1. WE's docs say its importer normalises a model's size; its rule isn't known.

## Guessed fields

What WE's own files didn't show, so the writer writes WE's common case:

| Field | Written | Why |
|---|---|---|
| `MDLS` version | `MDLS0004`, `MDLA0006`, `MDAT0001` | Capture 546. |
| Animation ids | `animationmapping`'s; an animation without one gets its position (1, 2, …), which the importer then saves in the mapping | WE's are its editor's counter (41, 42); scenes name them by id, so any stable number works. |
| Events | `{id, name, frame, clip: id}` or `{…, animation: name}` in `editor.events` | The compiler's keys (0x1400a28dd); WE's Add Event created nothing in capture 546. |
| Bone order at a depth | the skeleton's nodes, then other meshes' nodes, each in file order | One sample (capture 546). |
| Mesh flags | 0, or 1 for 32-bit indices | The library's imports. |
| `MDLV` 21/23 blobs and groups | none | Every imported model in the library. |
| Triangle order | the polygons' | WE's Assimp reorders triangles for the vertex cache (ImproveCacheLocality), not ported. |
| Scale on import | the layer's scale 1 | The docs say WE normalises the size on import; its rule isn't known. |

## Needs a capture in WE

- Add an event to a clip (select the clip first) and to an animation, to confirm the event
  record's layout.
- Import an FBX with two sibling chains and a static mesh between them (bone order at a depth),
  and one with pre-rotations (Mixamo), whose helper nodes Assimp makes.
- Import a large OBJ and FBX to see the scale WE gives the new layer.
