# Lighting, reflections, bloom and HDR: evidence and plan

**Note (2026-09-28):** `Vendor/we-assets` no longer exists. Wallpaper Engine's assets now come from the user's own Steam copy (Settings › Assets, cached in `<Wallpaper Storage>/.owe-assets`) or a chosen Wallpaper Engine folder, and tests read them from `OWE_ASSETS`. Mentions of `we-assets` below describe the tree as it was when this was written.

**Status: 2026-09-26. L0 (format, values, settings and seams) is done; the seams are in §4.4. A1 (the generated `LightingV1` and the light combos) is done. C1 (`_rt_MipMappedFrameBuffer` and the reflection setting) is done: a `REFLECTION` layer without effects draws through its material. B1 (WE's LDR bloom chain) is done: bloom scenes bloom through WE's own four util passes. D1 (volumetrics) is done: volumetric lights draw through WE's util passes, in 2D now and in 3D once the scene has depth. A2 (the light packer and the frame lighting) is done. A3 (lit image layers, direct path) and A4 (the prelighting path) are done: every library image layer that sets `LIGHTING` or `REFLECTION` draws through its material, with the packed lights, and `angles.z` now turns counter-clockwise as in WE. B2 (WE's HDR path) is done: with `bloom`, `hdr` and post-processing "ultra" a scene draws into float targets with `HDR=1` and blooms through WE's HDR mip chain. B3 (display HDR) is done: "displayhdr" on a display with EDR headroom outputs WE's display HDR combine as EDR. The test-risks findings LF2–LF10 are fixed (docs/test-risks.md, "Fixes (lighting)"): light fields are live, lights and volumetrics follow the camera shake, `bloomhdr*` are live, and per-frame settings no longer rebuild the content. D2 (shadows) is done with models-plan M8, and lit particles read the shadow atlas; §3 was brought up to date on 2026-10-16. The optimisation pass (test-risks, "Optimisation pass") removed two full-size copies: a layer whose effects read the scene reads the paused scene target, and the remaining snapshot shares `_rt_MipMappedFrameBuffer`'s level 0 where that is safe (Hinata −122 MB at 5K).** This covers roadmap notes area 5 (lighting and reflections) and the image-material part of area 1 item 3 that area 5 needs: 3 library image layers fall back to our native draw because their materials set `LIGHTING`/`REFLECTION`. It sets out:

- WE's format for lights and the `general` lighting, bloom and HDR settings, with a survey of the library;
- how `wallpaper64.exe` collects lights, generates `#require LightingV1`, reflects, blooms, tone-maps and shadows;
- where our implementation stands;
- work packages that parallel agents can take.

Where the ground truth comes from:

- **Binary:** `wallpaper64.exe` from the 2026-09 install. The disassembly is `we64.asm` in the session scratchpad; the helpers are `/Volumes/980Pro/dd-timeline/we.py` (`strva`, `xrefs`, `show`). Addresses below are VAs in that file.
- **Shaders:** WE's shipped shaders and `materials/util`, vendored in `Vendor/we-assets`. They are byte-identical to the install's, so the util materials can be run as they are.
- **Docs:** docs.wallpaperengine.io: scene/lighting introduction and lights, models/lighting, effects/bloom, models/introduction, IScene. The docs are tutorial-level. They don't mention `lightconfig`, `_rt_Reflection`, shadow atlases or the HDR feather and iterations, and give almost no defaults.
- **Library:** the Steam workshop folder, `/Volumes/980Pro/OpenWallpaperStorage` and WE's default projects, `scene.pkg` contents included. That is 106 scenes after de-duplicating by workshop id.

WE can't be run here. Where the binary leaves a value open, it is tagged **[?]** and listed in §5.

The extracted data is in `/Volumes/980Pro/dd-lighting`:

| File | Contents |
|---|---|
| `survey/survey.py`, `survey/load.py` | the library scanner (reads `.pkg`; delete `cache.pkl` to rescan) |
| `survey/summary.md` | every table of §1.5 in full, with key and value distributions |
| `survey/per_wallpaper.json`, `.csv` | one row per scene: lights by type, hdr, bloom, lit layers, models |
| `survey/examples.json` | all 11 light objects, general blocks, lit layers, lit effects, models |
| `survey/raw.json` | raw key→count tables, and the grep of the shipped shaders |
| `re-lights/lightingv1_gen.py` | a port of WE's `LightingV1` generator (0x140169140) |
| `re-lights/lightingv1_fragments.txt` | the 67 strings that generator emits, verbatim, with addresses |
| `re-lights/lightingv1_example.glsl` | one sample expansion |
| `light_parse.asm`, `light_ctor.asm`, `scene_update.asm`/`su.txt`, `lightingv1_gen.asm`, `combos_lights.asm`, `uniform_set.asm`, `render_scene.asm`, `volumetrics.asm` | annotated disassembly |

## 1. Format and library survey

### 1.1 Light objects (`scene.json` objects with a `light` key)

A light is a scene object with the usual `origin`, `angles`, `scale`, `parent`, `visible` and `parallaxDepth`, plus the fields below. The properties are registered at `0x14025da80`; the constructor defaults are at `0x140190457`…`0x1401904e4`. The Knight (2515150033) binds scripts to its legacy light's `intensity` and `origin` (y and z), and tube endpoints can be animated, as the docs describe. WE's packer reads the live properties every frame, so the app resolves them per frame too: a script's value, then the field's timeline, then the authored or user-bound one (`SceneLightObject.live`; `intensity`, `radius`, `exponent`, `innercone`, `outercone` and `controlpoint` are object-table fields that only a bound script sets, since `ILayer` has no light members).

| Key | Type (offset) | WE default | Meaning |
|---|---|---|---|
| `light` | enum (0x2c0) | legacy `point` | `lpoint`=0, `lspot`=1, `ltube`=2, `ldirectional`=3; `point`=5 is the **legacy** type (4 fixed slots, §2.2). No other names exist. An unknown name is taken to leave the constructor's 5 [?: the enum setter wasn't traced]; we log it. A `null` `light` is no light, as for `sound`. |
| `color` | vec3 (0x2cc) | 0 0 0 | |
| `intensity` | float (0x2e4) | 0 (the constructor zeroes 0x2e0…0x2e7 at 0x14019047f) | multiplies the colour (premultiplied) |
| `radius` | float (0x2e8) | 1 | falloff `saturate(1 − d/radius)^exponent` |
| `exponent` | float (0x2ec) | 2 | |
| `innercone`, `outercone` | float (0x2f0, 0x2f4) | 20, 30 | half-angles in degrees; the shader gets their cosines |
| `controlpoint` | vec3 (0x2d8) | 2 0 0 | tube end B, in the light's local space; end A is the origin |
| `castshadow`, `usecookie`, `castvolumetrics` | bits 0/1/2 of 0x2c4 | off | |
| `density`, `volumetricsexponent` | float (0x2f8, 0x2fc) | 2, 1 | volumetrics only |
| `cascadedistance0/1/2` | float (0x300…0x308) | 3, 10, 100 | directional shadow cascades |
| `lightsourcesize` | float (0x30c) | 0 | near plane of a point light's shadow |

A light points along its **local +X** axis. The world matrix is row-major, and row 0 is the direction.

### 1.2 `general` lighting, bloom and HDR settings

| Key | WE default (scene constructor offset) | Notes |
|---|---|---|
| `ambientcolor`, `skylightcolor` | constructor (0,0,0) (0x368…0x37c, zeroed at 0x140186f68…0x140186f7d). Every library scene authors both, mostly 0.3 grey. | Copied into the frame context at load (0x140187e4a) and on change (0x1401863f0). Model shaders mix them by `N.y·0.5+0.5`; `genericimage4` uses the ambient colour alone. |
| `lightconfig` | absent | `{"point":n,"spot":n,"tube":n,"directional":n,"spotshadow":n,"spotcookie":n,"spotshadowcookie":n,"directionalshadow":n,"pointshadow":n}`. **It is the light budget.** Without it, new-style lights have no effect (§2.2). Each count is its integer masked to the field width (4 bits base, 2 bits subset: 20 → 4); a value that isn't a number is skipped. |
| `bloom` | false (scene flag 0x2) | |
| `bloomstrength`, `bloomthreshold` | 2.0 (0x3bc), 0.65 (0x3c0) | LDR bloom |
| `bloomtint` | 1 1 1 (0x3d8) | both chains |
| `hdr` | false (scene flag 0x400) | needs `bloom` too, plus the user's post-processing setting at "ultra" (§2.6) |
| `bloomhdrstrength`, `bloomhdrthreshold`, `bloomhdrfeather`, `bloomhdrscatter` | 2.0, 1.0, 0.1, 1.619 (0x3c4…0x3d0) | HDR bloom |
| `bloomhdriterations` | 8 (0x3d4, an **int**) | |
| fog (`fog*`) | distances 1…5, heights 1…−3, densities 1 | no library scene has fog |

The docs' "Ultra HDR" and "HDR threshold smoothing" are `hdr` and `bloomhdrfeather`. The per-object "HDR brightness" is `brightness`: 185 image objects author it, and generic2 multiplies the albedo by it under `HDR`.

### 1.3 Reflection, shadows and volumetrics in the format

- **Reflection:** there are no `general` reflection keys. Image layers turn it on with material combos (`REFLECTION`, plus `NORMALMAP` for anything to show).
  - Model objects carry `reflected` (default true, `0x14019086d`), which puts them in the planar reflection pass (§2.5).
  - The user setting `reflection` (bool, default true) turns the screen-space copy off.
- **Shadows:** `castshadow` on a light and on objects (image, model, other).
  - 350 `castshadow` keys exist in the library, and **none is true**.
  - The caster shader is picked by a `// [PASS] shadow <shader>` header in the object's shader, otherwise `materials/util/shadowcaster.json`.
- **Volumetrics:** `castvolumetrics`, `density` and `volumetricsexponent` on point and spot lights.
- **Cookies:** a spot light with `usecookie` projects a texture (the docs: an image, a video or a layer). The texture is the light's `cookie` key, a path, and `cookie/flashlight1` when it names none (§2.8). The library's cookie spots: Hinata (no `cookie`, so the default) and 3233200129 (`cookie/flashlight1`).

### 1.4 Material side (`genericimage4`, and the same pattern in `genericimage2/3`, `generic4`, `chroma4`, `fur4`, `foliage4`)

- **Combos:** `LIGHTING` (default 0 on image shaders, 1 on `generic4`), `REFLECTION` (default 0) and `FOG` (default 1).
- **Normal map:** `g_Texture1`, `NORMALMAP`, rg88 with `formatcombo`.
- **PBR mask:** `g_Texture2`, `PBRMASKS`, whose r, g, b and a channels are the `METALLIC_MAP`, `ROUGHNESS_MAP`, `REFLECTION_MAP` and `EMISSIVE_MAP` components.
  - No material authors the component combos. WE defines component k when the bound texture's `.tex` flags have bit 20 + k (`0x14016c800`: `test [tex+0x1c], 0x100000 << k`, next to the sampler's own `#define <combo> 1`); the editor sets the bit for each channel painted. меч's mask has flags 0x400002 (only reflection, blue) and the Knight's 0x300002 (metallic and roughness): exactly the channels their PNGs paint.
- **Material constants:** `roughness` 0.7, `metallic` 0, `speculartint` 1 1 1, `emissivecolor` 1 1 1, `emissivebrightness` 1, `reflectivity` 1, `reflectivitydistance` 4 (hidden).
- **Engine textures:** `g_Texture3` = `_rt_MipMappedFrameBuffer` (with REFLECTION and NORMALMAP), `g_Texture4` = `_rt_FullFrameBuffer` (with BLENDMODE), `g_Texture6` = `_rt_shadowAtlas` (a comparison sampler, with `LIGHTS_SHADOW_MAPPING`, plus `g_Texture6Texel`), and `g_Texture7` = `_alias_lightCookie` (with `LIGHTS_COOKIE`).
- **Engine uniforms:** `g_LightAmbientColor`, `g_EyePosition`, `g_NormalModelMatrix`, `g_ViewProjectionMatrix`, `g_AltModelMatrix`/`g_AltNormalModelMatrix`/`g_AltViewProjectionMatrix` (PRELIGHTING), `g_Texture3MipMapInfo`, `g_Screen`, `g_Texture2Resolution`.
- **Lighting math:**
  - `genericimage4.frag` calls `PerformLighting_V1(v_WorldPos, albedo, N, V, g_SpecularTint, f0, roughness, metallic)`; **the 6th argument is f0**, not an ambient colour.
  - The result goes through `CombineLighting(light, g_LightAmbientColor·albedo)`, which is `ambient + light`. Under HDR it is `saturate(ambient + light) + light·saturate(|light|−2)·0.5/max(0.01,|light|)`.
  - `SCENE_ORTHO` fixes the view vector at (0,0,1).
  - The building blocks (GGX, Schlick, Smith, `PointSegmentDelta`, PCF, cascades, point-shadow cube faces) are in `common_pbr_2.h`.

### 1.5 Library survey (106 scenes)

**Lights: 13 lights in 6 scenes** at the survey (the Knight was missed then; LF2). The library has grown since: `LightingLibraryDecodeTests` now counts 112 scenes with 11 `lpoint`, 4 `lspot`, 4 `ltube`, 3 `ldirectional` and 9 legacy points, 9 `lightconfig`s and 9 `hdr: true`.

| Scene | Lights | `lightconfig` | What they light |
|---|---|---|---|
| 3270035750 "One piece girls" | 4 `ltube` (intensity 10, radius 500, exponent 2, z = 250, `controlpoint` (1.9, 1131.8, 0): vertical tubes across the image) | `{"tube":4}` | image layer `f1` (genericimage4, `LIGHTING:1`, **no effects**); ambient 0.294 0.133 0.133 |
| 3352730400 "Hinata Uzumaki" | 1 `lspot` (cones 80/80, radius 1136, intensity 4.12, `usecookie`, `castvolumetrics`) | `{"spot":1,"spotcookie":1}` | no lit layer: only its volumetrics show. HDR and bloom are on. |
| 3453730450 "Moon" [3D] | 3 `lpoint` (all `castvolumetrics`; 2 parented and invisible) | `{"point":3}` | 5 `generic4` models (`LIGHTING:1`, mostly `REFLECTION:1`): area 6 |
| 2515150033 "Knight" | 2 legacy `point` (colours 0.72 0.35 0.15 and 1 0.85 0.77, radius 2048, z 588 and 331); light 29 has scripts on `intensity` (`1 + 0.3 sin 7.3t + 0.2 sin 9.8t`) and `origin` (y and z = 500 + 200 sin) | none | the genericimage2 `LIGHTING`/`REFLECTION` puppet `centurion 1080p_sheet` (reads `g_LightsPosition`/`g_LightsColorPremultiplied`): **the library's only layer lit by legacy lights** |
| arsenal (default project) | 2 legacy `point` | none | 1 model (`generic`, LIGHTMAP/NORMALMAP/REFLECTION); uses `_rt_Reflection` |
| demon_core (default project) | 1 legacy `point` | none | 2 models; custom `core` shader reading `g_Lights*` |

No `ldirectional` light exists. Nothing casts shadows. Of the 11 light objects, 8 author `castshadow` and all 8 are false.

**`general`:**

| Key | Scenes | Values |
|---|---|---|
| `bloom` | 106 | **true in 24** (4 user-bound) |
| `bloomstrength` / `bloomthreshold` | 98 | mostly 2.0 / 0.65. Strength is user-bound in 3 and script-bound in 2; threshold is user-bound in 2. |
| `bloomtint` | 48 | 46 white |
| `hdr` | 70 | **true in 5**: 3074485715, 3352730400, 3606529469, razer_bedroom, shimmering_particles. All 5 also have bloom on. |
| `bloomhdrstrength/threshold/feather/scatter` | 70 | mostly 2.0 / 1.0 / 0.1 / 1.619 |
| `bloomhdriterations` | 64 | always 8 |
| `ambientcolor` | 106 | not the default 0.3 grey in 8 scenes (e.g. witcher 1 1 1, One piece girls reddish) |
| `skylightcolor` | 106 | not the default grey in 3 (arsenal, fantasticcar, ricepod) |
| `lightconfig` | 3 | see above |
| fog, reflection or shadow keys | 0 | |

**Lit image layers** (`LIGHTING` or `REFLECTION` = 1). There are 4, and 3 of them are in OpenWallpaperStorage: those are the 3 fallbacks.

| Scene | Layer | Material, combos | Effects on the layer | What WE draws |
|---|---|---|---|---|
| 3270035750 One piece girls | `f1` | genericimage4, `LIGHTING:1` | none | full LightingV1 with 4 tubes: **the one visible direct-lighting user** |
| 3803167460 witcher (beta) | `ведьмак розбивpng` | genericimage4, `LIGHTING:1` | 9 | prelighting path (§2.3); no `lightconfig`, so ambient only (1 1 1): the albedo, unlit |
| 3803167460 witcher (beta) | `меч` | genericimage4, `LIGHTING:1 REFLECTION:1`, normal map + PBR mask, metallic 1, roughness 0.55, reflectivity 4 | 2 | prelighting; screen-space reflection off `_rt_MipMappedFrameBuffer` |
| 2370927443 Lofi Cafe (workshop only) | `Base Image` | genericimage2, `REFLECTION:1`, no normal map | 11 | prelighting; REFLECTION without NORMALMAP adds nothing |

No particle material turns on lighting. 17 passes in 9 scenes set `LIGHTING` and 12 in 7 set `REFLECTION`, but most set them to 0.

**Effects:**
- Two local copies of `fluidsimulation` (3244466773, 3245833232) have `#require LightingV1` and `_rt_shadowAtlas` behind a `LIGHTING` combo that stays 0.
- Light-looking 2D effects (shine 34 uses, godrays 26, lightshafts 4, reflection 2) don't use lighting at all; they are ordinary effects.

**Models:** 26 model objects in 8 scenes (Moon, and the default projects arsenal, demon_core, fantasticcar and others). All of them wait for area 6.

**Usage ranking:**
1. Bloom: **24 scenes**, the most used feature here.
2. HDR: 5.
3. Lit image layers: 3 in the library (1 with real lights).
4. Volumetrics: 2 (Hinata; Moon with area 6).
5. Planar reflection: 2 default projects (area 6).
6. Shadows: 0.

## 2. WE's runtime (`wallpaper64.exe`)

### 2.1 `#require LightingV1` is generated, not stored

- The preprocessor's `require` handler (`0x14016c0ec`) calls a generator at `0x140169140`. It emits **nothing** unless the name is exactly `LightingV1` and the combo `LIGHTING` exists and is non-zero. No other `#require` name exists.
- It emits:
  - uniform arrays sized by the engine's `LIGHTS_*` combos (§2.2);
  - then `vec3 PerformLighting_V1(vec3 worldPos, vec3 color, vec3 normal, vec3 viewVector, vec3 specularTint, vec3 ambient /*f0*/, float roughness, float metallic)`, unrolled as one `{ const uint i = Nu; … light += … }` block per light.
- The per-light code, in emission order (verbatim in `re-lights/lightingv1_example.glsl`):
  - **Points** (the first `LIGHTS_POINT_SHADOW` are shadowed): `lightDelta = g_LPoint_Origin[i].xyz − worldPos`, `ComputePBRLightShadow(N, lightDelta, V, color, g_LPoint_Color[i].rgb, g_LPoint_Color[i].w /*radius*/, g_LPoint_Origin[i].w /*exponent*/, …, shadow)`. A shadowed point gets its factor from `CalculateProjectedCoordsPoint` and `PerformPointShadowMapping`.
  - **Spots**, in four groups in this order:
    1. shadow+cookie;
    2. cookie only: the colour is multiplied by the cookie texture at the projected coordinates, and there is no cone;
    3. shadow only;
    4. plain.

    Without a cookie, the colour is multiplied by `smoothstep(Direction.w /*cos outer*/, Origin.w /*cos inner*/, −dot(normalize(delta), Direction.xyz))`; the exponent is `g_LSpot_Exponent[i].x`. The spot index also indexes `g_LFeature_ShadowProjection`.
  - **Tubes:** `lightDelta = PointSegmentDelta(worldPos, OriginA, OriginB)`, exponent `OriginA.w`, never shadowed.
  - **Directionals:** `ComputePBRLightShadowInfinite(N, Direction.xyz, …)`. The first `LIGHTS_DIRECTIONAL_SHADOW` blend 3 cascades `p1..p3` that follow the spot features.
    - **WE quirk [C]:** the generator advances the cascade base by 1 per light (`0x14016a9b4`/`0x14016ae36`) while the CPU writes 3 matrices per light (`0x1401929d4`). With 2 or more shadowed directionals, WE samples the wrong cascades. Reproduce it, don't fix it.
- `re-lights/lightingv1_gen.py` reproduces the generator exactly for any combo set. It is the oracle for WP A1.

### 2.2 Collection, budget, sort and packing

- **No per-object light list.** Every material with `LIGHTING` gets the same global arrays. There is no distance culling and no per-object maximum. The docs' "four lights per scene" is editor guidance; the real limit is the `lightconfig` budget, 4 bits per type (≤ 15). See "Light count" below for how the editor writes it.
- **Budget:** `general.lightconfig` is parsed at `0x140187695` into ctx+0x121c:
  - 4-bit `point`, `spot`, `tube` and `directional`;
  - 2-bit `spotshadow`, `spotcookie`, `spotshadowcookie`, `directionalshadow` and `pointshadow`.

  The word is point bits 0–3, spot 4–7, tube 8–11, directional 12–15, spotshadow 16–17, spotcookie 18–19, spotshadowcookie 20–21, directionalshadow 22–23, pointshadow 24–25. The base counts include their shadow and cookie subsets. With the user's shadows disabled (0x140187c39), `spotshadowcookie` is OR-ed (bitwise, not added) into `spotcookie`'s bits and the other shadow counts drop to 0. **Without `lightconfig`, the per-frame packer returns early (`0x140190cab`) and every `LIGHTS_*` combo is 0 [C].**
- **Per frame** (`0x140190c80`, called at `0x14018031a`):
  1. Sort all lights (`0x140186990`, comparator `0x14019f490`): by type ascending; then by cookie/shadow flags descending (shadow+cookie, cookie, shadow, none); then by `dot(position, cameraForward)` ascending (ctx+0x160 [L]).
  2. Walk the sorted list and drop any light past its type's budget. Sub-group overflow isn't checked: WE trusts `lightconfig`.
  3. Pack each light from its **live world transform**, so parents, scripts and timelines apply:

  | Type | Arrays |
  |---|---|
  | point | `LPoint_Color` = (c·I, radius), `LPoint_Origin` = (pos, exponent) |
  | spot | `LSpot_Color` = (c·I, radius), `LSpot_Origin` = (pos, cos inner), `LSpot_Direction` = (row0, cos outer) (not normalised; cosines at `0x140192e64`/`eaa`), `LSpot_Exponent.x` = exponent |
  | tube | `LTube_Color` = (c·I, radius), `LTube_OriginA` = (pos, exponent), `LTube_OriginB` = world(`controlpoint`) |
  | directional | `LDirectional_Color` = (c·I, 1), `LDirectional_Direction` = (−row0, 0), pointing toward the light |
  | shadow features | `LFeature_ShadowProjection` (mat4) and `…Transform` (atlas rect: xy offset, zw scale) × F, where F = SSC + SC + SS + 3·DS; `LFeature_ShadowPointProjection` and `…Transform` × PS |

  4. `_alias_lightCookie` is set to the **last** cookie spot's texture, so there is one cookie per scene. Precisely (0x140192ee5…0x140192f0b, 0x14019359b…0x1401935d8): each visible spot the walk packs within the spot budget, if it has `usecookie`, makes its cookie texture (+0x330) the candidate; after the walk the alias is set to the candidate when it changed, so it is empty when no cookie spot is packed. Here: `SceneLightPacker.cookieLight`, `SceneLightCookie` (each cookie light's texture, keyed as the volumetrics key it), `SceneFrameLighting.cookie`; model materials bind it as `g_Texture7` (a zero texel when empty, as D3D reads an empty slot).
- **Light count, and which lights light a surface** (2026-09-26; the editor is `bin/wallpaperui.exe`, and its addresses are marked `ui:`). This checks two things the user saw in WE's editor: a 2D scene "allows 15 lights", 256 point lights "all work" in a 3D scene, and an image was lit only once a light's **Cast shadow** was on.
  - **The editor writes `lightconfig`** on save (`ui:0x14041bf85`, the `general` writer) from `ui:0x14041cd30`. It walks every light in the scene, hidden ones included, and counts each type (type byte +0x380, flags +0x384: bit 0 `castshadow`, bit 1 `usecookie`; legacy `point` is skipped).
    - Each base count stops at **15**.
    - Shadowed lights are counted per group (each stops at 7). They then share **3 shadow maps** in this order: directional shadows (at most 3), spot shadow and cookie, spot shadow, point shadow.
    - `spotshadowcookie` is then cut to 1, and `spotcookie` gets what is left of **one cookie**.
    - Without lights it removes `lightconfig` from `general` (`ui:0x14041bf8e`).
  - **The editor's own preview** recomputes the same word every frame (`ui:0x14029fedc`). It keeps it at ctx+0x122c and recompiles the lit materials (object flag 0x10, a shader that reports feature 0x8; `ui:0x1402b9379`) when a base count grows or a shadow/cookie count changes (`ui:0x14029ff00`…`0x14029ff8b`). A base count never shrinks during a session.
  - **Adding a light past 15 isn't refused.** The add command (`ui:0x1400a37c6`) compares the scene's light count, all types, with 15. At 15 or more it attaches a notice ("Light Limit reached": "Total light limit of 15 has been reached. The wallpaper will only display the closest lights…", key `ui_editor_modal_limit_error_shadow_directional_message`, `errorkey` "lightlimit") and adds the light anyway. `ui_editor_light_limit_reached` ("Cannot add more than {{count}} lights") is in the locale but used nowhere. The check doesn't depend on 2D or 3D. A new light is `lpoint`: in a 2D scene radius 500, intensity 10, at the view centre with z 250; in a 3D scene radius 5, intensity 5 (`ui:0x1400a2efb`…`0x1400a3454`).
  - **The runtime** (`wallpaper64.exe`) has no counting of its own: it reads `lightconfig` as written. It doesn't look at 2D or 3D either. So **at most 15 lights of each type** light a surface, in 2D and 3D, and each frame they are the first 15 in sort order (§2.2 step 1): shadowed and cookie lights first, then the closest along the view. 256 point lights mean 15 lit ones. The rest are dropped only because the shader has no slot for them. The user's "all 256 appear to work" fits this: toggling a light makes it one of the closest 15. It doesn't show that more than 15 light a surface at once. A hand-written count above 15 is masked (256 → 0 point lights).
  - **`castshadow` doesn't choose lights.** No light-selection code reads it (the packer tests `flags & 3` only in the sort, the counter only for the shadow subsets), and every material whose `LIGHTING` ≠ 0 gets every packed light. An image is lit through its material's `LIGHTING` combo: the layer's "Lighting" option. WE's own help says so: "Only affects images with lighting enabled or 3D models" (`ui_editor_effects_modal_light_description`). Turning `castshadow` on only makes the light sort first and, with shadows on, adds a shadow slot (and a recompile in the editor). Nothing in `wallpaperui.exe` turns on an image's `LIGHTING` or changes its material when a light's `castshadow` changes (the `castshadow` references are the property, its visibility rule for `lpoint`/`lspot`/`ldirectional`, and the serialisers). The observation is therefore an **editor artefact or an unlit test setup** (for example a light out of range or level with the image), not an engine rule [?: which one; a Windows capture would settle it, §5 item 8].
  - **Ours:** `WELightConfig` masks the counts as the runtime does, `SceneLightPacker` keeps the first ones in WE's order, and the engine combos follow the material's `LIGHTING`. We have no light cap of our own, and nothing reads `castshadow` for selection. So nothing changed. Tests: `SceneLightPackerTests.testTwoHundredFiftySixPointLightsKeepTheFifteenClosest`, `testCastShadowSortsButDoesNotSelect`.
- **Buffer order** (HLSL `g_bufLights`, generator `0x1400f74db`): the order of the table above. On Metal, our translated shaders see the arrays as ordinary uniform members, found by reflection by name.
- **Legacy uniforms** (the `genericimage2`, `generic`, `generic2` and custom shaders). Ids are registered at `0x140003d56`; the per-draw setter is `0x1400d8300`:
  - `g_LightsColorRadius[4]` = (c·I, radius), or (0,0,0,1) when invisible.
  - `g_LightsPosition[4]` = the translation.
  - Both are filled only by **legacy `point`** lights, in a fixed slot 0–3 taken at construction (first free; a fifth light collides on slot 0; `0x14025d1f0`).
  - `g_LightsColorPremultiplied[3]`: `out[k].xyz = L_k.rgb·r_k²`, `out[k].w = L_3.rgb[k]·r_3²` [C].
  - `g_LightAmbientColor` and `g_LightSkylightColor` come from `general`.
- **Engine combos** (`0x1401a5c40`):
  - The engine never forces `LIGHTING`.
  - When a material's `LIGHTING` ≠ 0, it sets `LIGHTS_POINT`, `_SPOT`, `_TUBE`, `_DIRECTIONAL`, `_SPOT_SHADOW_COOKIE`, `_SPOT_SHADOW`, `_SPOT_COOKIE`, `_DIRECTIONAL_SHADOW` and `_POINT_SHADOW` from the budget.
  - Any shadow count > 0 sets `LIGHTS_SHADOW_MAPPING=1` and `LIGHTS_SHADOW_MAPPING_QUALITY` = the shadow quality (1–4).
  - A cookie count > 0 sets `LIGHTS_COOKIE=1`.
  - The same routine sets `SCENE_ORTHO`, `FOG_DIST`/`FOG_HEIGHT`, `BACKBUFFER_MS`, `HDR`, `REVERSEDEPTH` and `TEX<n>FORMAT` for every material.
- **User settings** (`0x14010ed80`):
  - `shadows`: disabled, low, medium (default), high, ultra = 0…4.
  - `volumetrics`: the same scale.
  - `reflection`: bool, default true.
  - `postprocessing`: see §2.6.

### 2.3 Lit image layers and the prelighting path

At `0x140206eaf` an image layer without effects or a puppet compiles its material with `LIGHTING` = the layer's lighting flag and `REFLECTION` = its reflection flag. Both flags come from the material's combos.

A lit or reflective layer **with effects**, a puppet, or one whose albedo is a sprite sheet (`.tex` flag 4) takes the **prelighting path** (`0x140209540`, resolved for A4):
1. The **prepass**: the layer's own material (its path, `material+0x200`), loaded with the overrides `cullmode: nocull` and `combos: {LIGHTING, REFLECTION` as authored, `PRELIGHTING: 1}` (plus `SKINNING`, `BONECOUNT`, `PRELIGHTINGDUALVERTEX` and `MORPHING` for a puppet), is kept at object+0x4a0. It becomes the object's material (the getters at `0x1401fa2a0`… prefer +0x4a0), so it is what draws the layer image into the buffer its effects start from. Under `PRELIGHTING` the vertex shader places the vertex with `g_ModelViewProjectionMatrix` (the buffer's) but lights it, and takes `v_ScreenPos`, through `g_AltModelMatrix`, `g_AltNormalModelMatrix` and `g_AltViewProjectionMatrix`: the object's own world matrix (vt+0x80, `0x140207dc3`) and the scene's view-projection (ctx+0x930, copied at `0x14020656b` before the object draws). So each texel is lit, and reflects, where it lies in the scene.
2. The layer's effects run on the lit image.
3. The effect chain composites it as usual.

`_rt_imageLayerAlbedo_<id>` (image size, RGBA8 or RGBA16F in HDR) and a `fullscreenlayer` copy of the albedo (with `SPRITESHEET` for a sprite sheet) exist only for puppets: the mesh is drawn into it (`0x140207740`), and the prepass reads it. `g_AltNormalModelMatrix` (`0x1400d8aab`), like `g_NormalModelMatrix` (`0x1400d8840`), is the model's upper 3×3 with each axis normalised.

Witcher's two layers and Lofi Cafe take this path; One piece girls' `f1` and the Knight puppet (no effects) don't in the app (below).

### 2.4 Screen-space reflection (`_rt_MipMappedFrameBuffer`)

All modern shaders (generic4, genericimage2/3/4, chroma4, fur4, foliage4) reflect in screen space; `_rt_Reflection` is not involved.

- **Creating the target** (`0x140181c8b`…`0x140181dc5`): while the scene reports an object that samples it, `_rt_MipMappedFrameBuffer` is created at full resolution (divisor 1) in the frame-buffer format (the argument read earlier as "15 in HDR, 1 otherwise" is the format: 0xf RGBA16F, 1 RGBA8), with the mipmap flag 0x10.
- **Mip count** (the render-target constructor, `0x1400d2dde`…`0x1400d2e76`): for each side, log2 of half the smallest power of two not below it; the smaller of the two, minus 2, at least 1. 1920×1080 has 8 levels. The texture is created with that many levels and `GENERATE_MIPS` when it is more than 1.
- **`g_TextureNMipMapInfo`** (uniform ids 0x52…0x5b, setter `0x1400d98f4`) is the bound texture's level count as a float (1 without a texture), so `roughness · g_Texture3MipMapInfo` reaches one level past the last; the sampler clamps it.
- **Filling it** (`0x140180a8c`): after the main pass, while render flag 0x80 (the user's reflection setting) is set, the frame is copied in (the target's vt+0x8: `CopyResource` of the bound target, or `ResolveSubresource` from MSAA) and its mips generated (vt+0x20, `GenerateMips`). Materials drawn in the main pass therefore read the **previous** frame. With the setting off it is cleared once, at creation, to (0,0,0,1) (`0x140181d2b`) and never filled.
- **The reflection itself** (genericimage4):
  - The tangent-space normal is projected to screen: `normal.xy · (0.15, 0.15·g_Screen.z)`.
  - `screenUV += normal.xy · fresnel⁴ · g_ReflectivityDistance`, where `fresnel = max(0.001, dot(N, V))`.
  - The sample is `texSample2DLod(g_Texture3, screenUV, roughness · g_Texture3MipMapInfo)`.
  - `refl = pow(max(0.001, refl·(1−fresnel)·reflectivity), 2 − metallic)`.
  - `color.rgb += saturate(refl) · fresnel`.
  - The mask's b channel scales `reflectivity`.
- It needs `NORMALMAP`. Without it, REFLECTION only computes normals.

### 2.5 Planar reflection (`_rt_Reflection`)

Only `generic2.frag` samples it. It is created when an object reports feature bit 0x8 (`0x140181c65`): full resolution, the frame-buffer format. At the start of the frame (`0x140180357`…`0x14018089a`, before the main scene) the engine:
- multiplies the view by `diag(1, −1, 1, 1)`, a mirror across the world plane y = 0;
- mirrors the eye and the camera basis;
- flips the culling;
- draws the "reflected list": model, particle, image, sprite and text objects whose `reflected` is true and which are not reflective themselves (models-plan §2.11), each through its own draw.

This is 3D-only in practice (arsenal, fantasticcar), so it belongs with area 6.

### 2.6 Bloom and HDR

**Enabling:**
- **Post-processing:** render flag 0x40 is set when the user's `postprocessing` setting is anything but "disabled" (`0x14010edab`). The engine writes "disabled" when the key is missing [?: the settings UI's default is unknown].
- **HDR:** decided at scene load (`0x14010e612`…`e6da`), only if **both** `general.bloom` and `general.hdr` are true. Then `postprocessing` = "ultra" sets HDR (0x2000), and "displayhdr" sets HDR plus display HDR (0x6000). Display HDR without an HDR swapchain falls back to plain HDR (`0x1401109be`).
- **HDR combo:** HDR compiles **every** material with `HDR=1` (`0x1401a6721`). That turns on CombineLighting's overbright, emissive overbright, `g_Brightness` in generic2, and the ccsimple LUT's overbright.
- **Per frame** (`0x140180a41`), bloom runs only if flag 0x40, `scene.bloom` (live; scripts and user properties can toggle it) and a non-empty scene list (`[scene+0x158]` [?]) all hold.
- **Constants** are recomputed on load and whenever the scene is dirty (`0x140184020`), so user and script changes apply live.

**Formats:** every frame-buffer-class target (`_rt_FullFrameBuffer`, MSAA, mip-mapped, bloom) is **RGBA8 in LDR and RGBA16F in HDR**: `rgb_backbuffer` resolves to 1 or 0xf (`0x1401e75ae`), mapped at `0x1400d2a20`.

**LDR chain** (setup `0x14017f1b0`, run `0x140183949`). Constants go only to pass 1.

| # | Material (shader) | In → out | Size | Math |
|---|---|---|---|---|
| 1 | `downsample_quarter_bloom` | `_rt_FullFrameBuffer` → `_rt_4FrameBuffer` | 1/4 | 4 diagonal taps at `uv ± g_TexelSize`, averaged; `c *= saturate(max(r,g,b) − g_BloomThreshold)`; `c = 2c − dot(c, (.2989,.587,.114))`; `out = max(0, c · strength · tint)` |
| 2 | `downsample_eighth_blur_v` | `_rt_4FrameBuffer` → `_rt_8FrameBuffer` | 1/8 | 13 taps along **x**, step 8·`g_TexelSize.x`; weights .006299 .017298 .039533 .075189 .119007 .156756 .171834 (centre), symmetric |
| 3 | `blur_h_bloom` | `_rt_8FrameBuffer` → `_rt_Bloom` | 1/8 | the same along **y**; the file names have the axes swapped |
| 4 | `combine_ldr` (`combine`) | [`_rt_FullFrameBuffer`, `_rt_Bloom`] → output | 1 | `vec4(scene.rgb + bloom.rgb, 1)` |

`g_TexelSize` is 1 / full render size [I]; that is the only size under which pass 1 is an exact 4×4 box.

**HDR chain** (targets `0x14017f346`…`f544`, run `0x140183610`). Up to 8 levels, `_rt_2FrameBuffer` (1/2) down to `_rt_256FrameBuffer`, all RGBA16F; the count is how many times `min(w,h)` halves, capped at 8. `_rt_Bloom` isn't created.

```
n        = max(1, min(levels, bloomhdriterations))
strength = bloomhdrstrength / (1 + bloomhdrscatter^(max(n,2) − 2))      // default 2/(1+1.619^6) ≈ 0.105
t = bloomhdrthreshold; k = t · bloomhdrfeather
blend    = (t, t − k, 2k, 0.25 / (k + 1e−5))                             // g_BloomBlendParams, default (1, .9, .2, 2.5)
D0: hdr_downsample_bloom  _rt_FullFrameBuffer → RT0 (1/2), g_RenderVar0 = (1/w, 1/h, −1/w, −1/h)
    c = box4; b = max(c.rgb); soft = clamp(b − blend.y, 0, blend.z)² · blend.w
    c *= max(soft, b − blend.x) / max(b, 1e−5) · strength · tint
Di: hdr_downsample        RT[i−1] → RT[i], box4, RenderVar0 × 2^i            i = 1…n−1
Uk: hdr_upsample(_cubic)  RT[k] → RT[k−1], additive: += 0.25 · scatter · Σ4 taps, RenderVar0 × 2^k
                          k = n−1…1; bicubic (B-spline) for k ≥ n−2
combine_hdr_upsample:     bloom = tent4(RT0);
    ultra      out = saturate(srgbToLinear(scene + bloom)) · RV.x
    displayhdr a = saturate(scene) + bloom; out = srgbToLinear(max(0,a)) · (RV.x + RV.y · smoothstep(1, 5, luma(a)))
```

There is **no tone-mapping operator**. The scene is drawn gamma-encoded into float targets with overbright allowed, and it is linearised only at the combine. So the output is linear (scRGB). `RV` = `g_RenderVar0`, whose xy the device writes (vt+0x158 is `0x14009b790`, zw keep the chain's last pass): on an output whose colour space is HDR10 (`0xc`, `0x14012af44`) it is (SDR white, max luminance − SDR white) / 80 nits (`0x14012b5d9`), SDR white being the display's `SDR_WHITE_LEVEL` × 80 / 1000 (200 nits when the query fails, a user value ≥ 80 overriding it) clamped to [80, max luminance]; on an SDR output it keeps its initial value [?: (1, 0), which alone shows an SDR frame unchanged]. The swap chain is R8G8B8A8_UNORM, or R16G16B16A16_FLOAT with display HDR (`0x14012b656`); "ultra" writing linear values to it only looks right through an sRGB view [?]. An HDR scene without bloom running draws `combine_srgb` (`out = srgbToLinear(scene)`) instead.

**Frame order** (`0x14017fa70`):
1. The planar reflection pass (§2.5).
2. The main scene: every object, its effects and composite layers, into MSAA if enabled, then resolved.
3. `_rt_FullFrameBuffer` ← the frame.
4. `_rt_MipMappedFrameBuffer` copy and mips, if flag 0x80.
5. The bloom chain and combine; or, in HDR without bloom, `combine_srgb`.
6. `ccsimple` (colour correction), if present.
7. The camera fade (`fade.json`, alpha = the fade).
8. Present.

Bloom therefore sees the fully composited frame exactly once.

### 2.7 Shadows

- **Casters:**
  - Lights: point, spot and directional (never tubes) with `castshadow`, the shadows setting on, and room in the budget.
  - Objects: those with `castshadow`, drawn with their `[PASS] shadow` shader or `shadowcaster.json`. Translucent casters get `ALPHATOCOVERAGE`.
- **Map size per light** (`0x14025d3e0`): 256 at quality 1–2, 512 at 3, 1024 at 4.
- **Spot:** perspective with fov 2·outercone, near 0.05, far `max(radius, 0.06)`.
- **Point** (`0x14025d9c1`):
  - Six cube faces with fov 94°/92°/91.2° (quality 1–2 / 3 / 4), which matches the shader's 0.47/0.48/0.49 compensation.
  - near = `max(0.05, lightsourcesize)` (1.0 in ortho scenes); far = `max(radius, near + 0.01)`.
  - The faces are packed as a 2×3 block.
- **Directional:** 3 cascades (`0x14025d370`) of (distance, size) = (c0, 4c1), (c1, 4c1), (c2, max(1.5c2, 4c1)), each halved and centred at `eye + forward · distance/2` [L].
- **`_rt_shadowAtlas`** (`0x1401938d1`): rectangle-packed, grown on demand, sampled with a comparison sampler [?: depth format]. Filtering is 1 tap at quality 1, otherwise 9-tap PCF.

### 2.8 Volumetrics

The disassembly is `volumetrics.asm` (the per-light function `0x140196ce0`, a method of the scene reached through the light's draw, vt+0x50 at `0x14025d300`) and the finish at `0x140198d00`.

- **Trigger:** the volumetrics setting (ctx+0x1ad) isn't disabled. A light draws its volume when it casts volumetrics and it and its ancestors are visible (vt+0x68, `0x14025d330`). Type 0 (`lpoint`) takes the point path; every other type takes the spot path.
- **Targets**, made on the first light (`0x140196d63`…`0x140196f52`; arguments: divisor, colour format, depth format, flags):
  - `_rt_volumetricsBack`: full size, depth only (colour 0x1b, depth 0x19).
  - `_rt_volumetricsSingle`: 1/4 from quality 3, else 1/8; depth only (0x19 from quality 3, 0x17 below).
  - `_rt_volumetricsLightBuffer`: the same size; RGBA8, or RGBA16F in HDR (`0x14017e750`).
  - Below quality 3, `_rt_volumetricsLightBufferB` of the same kind, with `volumetrics_blur_h`/`_v`. `volumetrics_combine` always.
- **Per light**, in the scene's object loop:
  1. `_rt_volumetricsBack` ← the bound target's depth (vt+0x8, the copy of §5.3).
  2. `_rt_volumetricsSingle` is bound and its depth cleared; `volumetrics_back` draws the volume's mesh into it. The shader reads it as the far faces' depth (the fullscreen variant starts at the near plane and marches to it), so it holds the far faces [I: the culling state wasn't traced].
  3. `_rt_volumetricsLightBuffer` is bound; the first light since the last finish clears it to (0, 0, 0, 1) (flag bits 1 and 2 of scene+0x418).
  4. `volumetrics_fullscreen` when the camera is inside the volume, else `volumetrics_front`, ray-marches from the near faces to the nearer of the scene's depth and the far faces, additively.
- **Meshes** (made once per light, `0x140197004`…`0x140197560`), placed by `g_AltViewProjectionMatrix`:
  - A spot with a cookie or a shadow (`0x140185940`): the box of its clip volume, x and y ±1, z from the near depth to the far one, 12 triangles.
  - Any other spot: a 32-segment cone, the circle inscribed in that square with a fan cap at each end. The caps' centres are at (0.5, 0.5), as WE writes them.
  - A point: a sphere of radius 1 (`0x14025c660`): the poles and 23 rings of 25 vertices.
  - The fullscreen triangle (−1, 1), (−1, −3), (3, 1).
- **The camera inside** (`0x1401979c3`…`0x1401980e5`), at a point just ahead of the eye (ctx+0x68 + ctx+0x160 · d):
  - box: d = 0.1, inside the six planes of the light's projection (`0x1401849e0`);
  - cone: d = 0.2; the distance t along the light's axis is in (0, radius], and the distance from the axis is at most t / radius times the far plane's radius (the unprojected far centre to the far top edge);
  - sphere: d = 0.2, nearer than the radius.
- **The light's projection** (+0x338, `0x14025d420`): a view down the light's local +X with its +Y up (+x is its +Z), then a square perspective of twice the outer cone from 0.05 (1 in an orthographic scene) to `max(radius, near + 0.01)`. A point's is its shadow cube (§2.7).
- **Matrices and uniforms** (`0x1401977b4`, `0x140198568`…`0x1401987f5`; the uniform ids follow their names at `0x140002b60`):

  | Uniform | ctx | Contents |
  |---|---|---|
  | `g_ViewProjectionMatrix` | +0x930 | the camera's |
  | `g_EffectModelMatrix` | +0x970 | its inverse: clip to world |
  | `g_AltModelMatrix` | +0xa70 | the light's projection (+0x338) |
  | `g_AltViewProjectionMatrix` | +0xab0 | the mesh into the world: the projection's inverse for a spot; the radius and position for a point |
  | `g_RenderVar0` | +0xa8 | shadow transform (+0x310) |
  | `g_RenderVar1` | +0xb8 | (radius·0.99, cos inner, cos outer, intensity) |
  | `g_RenderVar2` | +0xc8 | (world position, density) |
  | `g_RenderVar3` | +0xd8 | a spot's world row 0 as it stands (scale included), or a point's projection info (+0x320) |
  | `g_RenderVar4` | +0xe8 | (colour **without** intensity, volumetricsexponent) |

  A cookie light's front passes get its cookie as `g_Texture2` (`0x140198815`). The cookie is the light's `cookie` key, a texture path read only with `usecookie` (`0x14025d0a5`), and `cookie/flashlight1` when it names none (`0x14025d1b7`).
- **Combos** of the front and fullscreen passes (`0x14019817e`…`0x140198440`): `COOKIE` with `usecookie`; `SHADOW` with `castshadow` while the shadows setting is on; `QUALITY` = the volumetrics setting; for a point, `POINTLIGHT` and `LIGHTS_SHADOW_MAPPING_QUALITY` = the shadows setting.
- **Finish** (`0x140198d00`): below quality 3, `volumetrics_blur_h` (the light buffer into B) and `_v` (B back); then `volumetrics_combine` adds the light buffer to the frame. The object loop (`0x14018ade4`…`0x14018b21e`) finishes a run of lights before the next object that isn't a light, and at its end. So the volumetrics sit in the object order, and the `_rt_MipMappedFrameBuffer` copy (§2.6 step 4) sees them.
- **The camera** (`0x140183a70`): an orthographic scene's projection is `ortho(0, width, 0, height)` from −2000 to 2000, whatever `nearz`/`farz` say.

### 2.9 Fog

`general.fogdistance` and `fogheight` turn on WE's distance and height fog. Only 3378346807 uses it in the library (distance fog, 1 to 48, its colour bound to the `backgroundcolor` property).

- **Fields** (the scene's property table, 0x14019a274…0x14019a8c4): `fogdistance` and `fogheight` are flags (+0xe0 bits 0x4000 and 0x8000); `fogdistancecolor` (+0x380) and `fogheightcolor` (+0x38c); `fogdistancestart`, `end`, `startdensity`, `enddensity` (+0x398…+0x3a4); `fogheightstart`, `end`, `startdensity`, `enddensity` (+0x3a8…+0x3b4). The constructor's defaults (0x140187063…0x1401870a1): colours black, distance 1 to 5, height 1 to −3, densities 0 to 1.
- **Scripts** (`thisScene.fog…`): every field's entry in that table has the fog's writer 0x140186440 as its change handler, and scenescript64.dll finds `thisScene` members by name through the table (it holds no member names), so scripts read and write them although `IScene` doesn't declare them. The app has them as scene fields (`SceneScriptSceneField`) and lays a script's (or a timeline's) values over the authored fog every frame (`SceneFogSettings.live`), so the colours, ranges and densities follow at once. Turning a fog on or off from a script changes WE's render flags and so the `FOG_DIST`/`FOG_HEIGHT` combos of the next draws; the app builds those combos with the content, so such a switch is logged once and only the uniforms follow. Tests: `SceneScriptFogTests`.
- **Uniforms** (0x140186440…0x1401865ad, each frame): `g_FogDistanceColor`, `g_FogHeightColor`, `g_FogDistanceParams` = (start, end − start, start density, end density − start density), `g_FogHeightParams` likewise. The flags set render flags bits 23 and 24.
- **Combos** (0x1401a64ae…0x1401a666a, the engine combos every material gets): with bit 23 or 24 set, a material whose `FOG` combo resolves to a value other than 0 gets `FOG_DIST` (bit 23) and `FOG_HEIGHT` (bit 24). `generic4`, `genericimage4`, `genericparticle`, `volumetricsfront` and a few others default `FOG` to 1.
- **In the volumetrics** (`volumetricsfront.frag`): `shadowSample *= ApplyFogAlpha(shadowSample, …)`, and `ApplyFogAlpha` returns `alpha · (1 − fog²)`. So under fog each sample of the march is **squared**, then faded. This is what made 3378346807's glow about twice WE's before the fog was implemented (docs/models-plan.md, M8's open points).
- **Here:** `SceneFogSettings` (resolved with the lighting settings), `SceneEngineCombos.fogCombos`, the four uniforms in `BuiltinUniforms` from `SceneFrameLighting.fog`. Models no longer force `FOG` to 0. Scripts can't change the fog here yet (WE registers the fields; no library script sets them).

## 3. Where we stand

Code references are to `OpenWallpaperEngine/Scene/…`.

| Feature | WE semantics (§) | Our status | Library users |
|---|---|---|---|
| Light objects | typed lights, WE defaults (1.1) | ✅ A2: `WESceneObject.light` (`WESceneLight`) decodes point, spot, tube and directional lights with WE's defaults; the editor adds them (Add Layer › Light) | 11 lights / 5 scenes |
| `lightconfig` budget | gates everything (2.2) | ✅ decoded in `general` (`SceneGeneralSettings.lightConfig`) and handed to the engine combos as the light budget, as the user's shadows setting leaves it (`SceneEngineCombos.lightBudget`) | 3 |
| `ambientcolor`/`skylightcolor` | general → `g_LightAmbientColor`/`g_LightSkylightColor` (1.2) | ✅ A2: from `general` (a script's colour wins) through `BuiltinFrameContext.lighting`, written every frame; the invented 0.2 / 0.3 are gone | all 106 author them; 8 non-default |
| `#require LightingV1` | generated per `LIGHTS_*` combo set (2.1) | ✅ A1: `Shaders/LightingV1Require.swift`, expanded per variant (`ShaderSource.text(combos:)`); text-equal to `Scripts/lightingv1-reference.py`. The old stub's `color * f0` is gone | every LIGHTING material |
| `LIGHTS_*`, `HDR`, `SCENE_ORTHO` engine combos | set per material (2.2) | ✅ A1: `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*`, `LIGHTS_COOKIE` and `SCENE_ORTHO` (`SceneEngineCombos+Lighting.swift`); B2: `HDR` (`SceneEngineCombos+HDR.swift`) | — |
| `g_L*` light arrays, legacy `g_Lights*` | packed per frame from live transforms (2.2) | ✅ A2: `Rendering/SceneLightPacker.swift`; the `g_LFeature_*` values since D2 | One piece girls (tubes); legacy: default projects |
| Lit image layers (`LIGHTING`/`REFLECTION`) | direct path, or prelighting with effects (2.3) | ✅ A3: through the material with the engine's `LIGHTS_*` combos and the packed lights | f1, witcher ×2, Knight (2515150033), Lofi Cafe |
| Prelighting (`PRELIGHTING`, `g_Alt*`) | 2.3 | ✅ A4: `ImageMaterialPlan.prelighting`, `ImageMaterialRenderer.prelight`; puppets are prelit too (`ScenePuppet`) | witcher ×2, Lofi Cafe |
| Normal map / PBR mask on images | rg88 with `formatcombo`, `TEX1FORMAT`; components from the `.tex` flags (1.4) | ✅ A3: `TEX<n>FORMAT` for `formatcombo` samplers, the component combos from the mask's flags | меч, Knight |
| Screen-space reflection `_rt_MipMappedFrameBuffer` | copied after the main pass, mipmapped, `g_Texture3MipMapInfo` (2.4) | ✅ C1: `SceneMipMappedFrameBuffer`, the first frame stage; REFLECTION draws on layers without effects (LIGHTING and prelit layers still fall back) | меч (+ 4 materials per test-risks) |
| Planar `_rt_Reflection` | mirrored pass of the `reflected` list (2.5) | ✅ models-plan M9 (`ScenePlanarReflection`): models, images, texts and particle systems | arsenal, fantasticcar, audiophile (area 6) |
| LDR bloom | 4 util passes on the composited frame (2.6) | ✅ B1: WE's passes through the translator and the effect graph (`Rendering/SceneBloomChain.swift`), run by `ScenePostProcess` on the finished frame, gated by `postprocessing` | **24 scenes** |
| HDR (float targets, `HDR=1`, mip-chain bloom, combine) | 2.6 | ✅ B2: RGBA16F scene target and layer buffers, `HDR=1`, WE's mip chain and combines (`Rendering/SceneHDRChain.swift`); and B3's display HDR: EDR output with WE's `combine_dhdr_upsample` on a display with headroom ("displayhdr" draws as "ultra" without) | 5 scenes + 4 of the HDR test set |
| `postprocessing` / `shadows` / `volumetrics` / `reflection` user settings | 2.2, 2.6 | ✅ Settings › Performance: `postprocessing` gates bloom and HDR (B1–B3), and the shadows, volumetrics and reflection settings are in place beside it | all bloom/HDR scenes |
| Shadows (`_rt_shadowAtlas`, casters) | 2.7 | ✅ D2 (models-plan M8): WE's atlas, views and casters; lit models, images and particles read it | 0 (no `castshadow` true) |
| Volumetrics | 2.8 | ✅ D1: WE's util passes as a frame stage (`Rendering/SceneVolumetrics.swift`); shadow casters read their map (D2) | Hinata (2D), Moon and the test set (3D) |
| Distance and height fog | 2.9 | ✅ `SceneFogSettings`, `FOG_DIST`/`FOG_HEIGHT`, `g_Fog*` | 3378346807 |
| Light cookie (`_alias_lightCookie`) | one per scene (2.2) | ✅ for models (gaps pass): the last packed cookie spot's texture per frame (`SceneLightCookie`); the volumetrics bind each light's own; image layers bind it too (`ImageMaterialPlan`, `ImageMaterialRenderer`: a zero texel without a packed cookie spot) | 3233200129 |
| Depth buffer, perspective models | area 6 | ✅ models-plan M4, M5 | Moon, default projects |

Tests that pin today's gaps:
- `ImageMaterialSweepTests`, which tallies `unsupported[reason]`;
- `WEAuthoredValuesTests`:196-218 (bloom defaults);
- `BuiltinUniformTests`:117-125 (ambient and skylight pass through; the invented defaults are untested).

## 4. Plan

### 4.1 Principles

- **Run WE's own code.** The LightingV1 source comes from a port of WE's generator. Bloom and HDR run WE's `materials/util` passes through our shader translator, not hand-written Metal. The native `sceneFragment` bloom and the invented ambient defaults are deleted.
- **Keep app extras identity at their defaults.** `_owe_bloom` becomes a multiplier on WE's strength, with 1 = WE.
- **Per-scene state.** The light list, budget and targets belong to the wallpaper instance.
- **Bump `ShaderVariantTranslator.revision`** whenever translated output changes (A1, B2).

### 4.2 Order and ownership

Files are listed per package. Each file has one owner; a later package touches an earlier one's file only after it has landed.

```
L0 ─┬─ A1 ─┐
    ├─ A2 ─┼─ A3 ── A4
    ├─ B1 ── B2
    ├─ C1 ─┘ (A3's REFLECTION test needs C1)
    └─ D1 (after A2)            C2, D2 → with area 6
T (tester, lighting sweep) after A3/B2
```

Most-used first: **B1 (bloom, 24 scenes)** and **A1–A3 (lighting)** are the critical path; B2 (HDR, 5 scenes) next. C1 is small and unblocks меч. D1, C2 and D2 come last.

### 4.3 Work packages

**L0 — Format, values and seams (one agent, first, small). Done; what landed is in §4.4.**
- **Files:** new `Scene/Format/SceneLight.swift` (`WESceneLight`: kind enum with legacy `point`, every field of §1.1 with WE's defaults, bound values through `SceneRawValue`); `Scene/Format/SceneObject.swift` (the `light` key); `Scene/Format/SceneDocument.swift` and `Scene/Format/SceneValueFields.swift` (`hdr`, `bloomhdr*`, `lightconfig` as `WELightConfig`); `Scene/Values/SceneGeneralSettings.swift` (the HDR defaults of §1.2; `SceneBloomSettings` gains the HDR fields).
- **Seams, with no output change:**
  - new `Scene/Shaders/SceneEngineCombos.swift`: a value type {hdr, sceneOrtho, lightBudget, shadowQuality, cookie} and one function that turns it into combos, threaded through `ImageMaterialPlan`, `SceneEffectPlan` and `ParticleMaterialPlanBuilder`. For now it returns nothing, so there is no revision bump.
  - new `Scene/Rendering/SceneFrameLighting.swift`: the per-frame lighting value (ambient, skylight, packed arrays, all empty for now) that `SceneMetalRenderer` builds once per frame and passes to the uniform writers.
  - new `Scene/Rendering/ScenePostProcess.swift`: the post-process stage that `SceneMetalRenderer` calls after the scene pass. For now it wraps today's composite unchanged.
- **Tests:**
  - `SceneLightDecodeTests`: fixtures for each light type with defaults and bindings.
  - A library decode check: 11 lights (4 tube, 3 lpoint, 3 legacy point, 1 spot), 3 `lightconfig`s, 5 `hdr: true`, 70 `bloomhdr*`.
  - `WEAuthoredValuesTests`: the HDR defaults.

**A1 — The LightingV1 generator and light combos. Done** (revision 7). Shadow budgets translate since D2 (revision 9: the prelude's `sampler2DComparison`/`texSample2DCompare`, `LightingV1RequireTests.testShadowBudgetsNeedTheShadowAtlas`).
- **Files:** new `Scene/Shaders/LightingV1Require.swift`, a port of `re-lights/lightingv1_gen.py` (strings verbatim from `lightingv1_fragments.txt`, the cascade quirk included); `Shaders/ShaderSource.swift` (`stubRequires` → the generator, given the variant's combos; an unknown `#require` stays a logged comment); the `lightBudget` → `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*` and `LIGHTS_COOKIE` mapping, and `SCENE_ORTHO`, in `SceneEngineCombos+Lighting.swift` (§4.4). Bump the revision.
- **Tests:**
  - A text oracle: our output equals `lightingv1_gen.py`'s for a matrix of budgets (0/1/4/15 per type, with shadow and cookie subsets). Check the Python outputs in as fixtures.
  - `genericimage4`, `generic4`, `genericparticle` and the fluid-simulation combine translate and build pipelines under each budget.
  - `LIGHTING=0` emits nothing.
  - `ShaderVariantCacheTests` sees the revision bump.

**A2 — The light packer and frame lighting. Done.** `SceneLightPacker` reproduces the packer at 0x140190c80 on one flat buffer, cursors and all, and the legacy setter; `SceneFrameLighting.frame` feeds it each light's world matrix (`SceneFrameLighting.world`), and `BuiltinUniforms` serves the arrays by name (zero-padded to the shader's length) and the scene colours. They are frame-varying uniforms (`UniformProgram.timeVarying`). What the binary showed beyond §2.2:
- **Sort key:** the depth is `dot(object+0x128, ctx+0x160)`, and +0x128 is the light's **own `origin`** (relative to its parent; the world matrix is cached at +0xe0, 0x1401850a0), not its world position. The flags key is `flags & 3` (shadow 1, cookie 2). Ties keep scene order here; WE's `std::sort` leaves them unordered [?].
- **Visibility:** a light is packed only if it and every ancestor are visible (0x140185010), checked before the budget, so a hidden light doesn't use it.
- **Groups:** each group's cursor starts at its budget offset (points: shadowed at 0, plain at PS; spots: SSC 0, SC SSC, SS SSC+SC, plain SSC+SC+SS; directionals: shadowed at 0, plain at DS) and is never checked, so an overfull group writes over the next group or array. The spot group is `flags & (shadows ? 3 : 2)`. `g_LSpot_Exponent` gets only `.x`. The buffer is zeroed each frame.
- **Unused directional slots** get the direction (0, 1, 0, 0) (0x1401931bb, 0x140193530).
- **Legacy slots:** the constructor gives **every** light, whatever its type, the first slot 0–3 no earlier light holds, and slot 0 after that (0x1401903c4), so a legacy point's slot counts the lights before it in scene order. Each frame (0x14025d1f0) a legacy point writes (c·I, radius), or (0,0,0,1) when it or an ancestor is hidden, and its world position either way. The context starts with all slots zero. `g_LightsPosition` is `vec3[4]` in the shaders.
- **Rotation:** WE builds an object's rotation as `Rz(z)·Ry(y)·Rx(x)` (0x1401dd630). The 2D hierarchy carries no depth or tilt, so each light keeps its authored `origin.z`, `angles.x/y` and `scale.z` (`SceneLightDepth`); the z rotation is the 2D hierarchy's, which A3 made WE's (+X toward +Y, counter-clockwise on screen), so a light turns with the layers it lights. Parents contribute their 2D transform only. Camera parallax isn't applied to lights: WE's object loop translates only the draws' model matrices by it (0x14018b062…0x14018b14e), while the packer reads the world matrices (0x1401850a0). Camera shake moves WE's camera; the renderer moves the objects by −shake instead, so the lights move with them. The rotation order `Rz·Ry·Rx` is confirmed against WE's own frames of Hinata (test-risks LR4).
- **Not done:** `_alias_lightCookie`, whose source key is unknown (§5.6). The `g_LFeature_*` projections, transforms and point projection infos are D2's (models-plan §4.3 M8), a cookie spot's projection included.
- **Files:** new `Scene/Rendering/SceneLightPacker.swift` (sort, budget and pack as in §2.2, from live world transforms after scripts and timelines; legacy `point` slots; `g_LightsColorPremultiplied`; the cookie alias); `SceneFrameLighting.swift` (filled); `Rendering/BuiltinUniforms.swift` (`g_LightAmbientColor`/`g_LightSkylightColor` from `general`, deleting the 0.2/0.3 defaults; the `g_L*` and `g_Lights*` arrays by reflection name). Light objects stay out of the draw list but take part in parenting and in the script object table, as `thisScene.getLayer` proxies with `origin`/`angles`/`visible`.
- **Tests:** packer unit tests with hand-derived arrays (the sort order across types, flags and camera depth; budget truncation; no `lightconfig` → empty; spot cosines and the −row0 direction; the tube's world `controlpoint`; a parented light following its parent; `visible: false` legacy slots = (0,0,0,1)); One piece girls' 4 tubes packed against values computed by hand from its `scene.json`.

**A3 — Lit image materials, direct path. Done.**

What landed:
- `ImageMaterialPlanBuilder` no longer refuses `LIGHTING`: a lit layer without effects draws through its material with the engine's `LIGHTS_*` and `SCENE_ORTHO` combos (A1) and the frame's packed lights (A2). Samplers a variant declares but never reads (`genericimage4`'s normal map and mask without their combos) need nothing bound. `TEX<n>FORMAT` is set for `formatcombo` samplers as for effects, and a mask's component combos follow its `.tex` flags (`ShaderVariantTranslator.resolveCombos(textureFlags:)`, §1.4).
- `g_NormalModelMatrix` is WE's (the model's axes normalised, not the inverse transpose), and `BuiltinPassContext` carries the `g_Alt*` matrices (A4).
- **Rotation:** `angles.z` turns counter-clockwise on screen, as WE's `Rz` does (`SceneAffineTransform`): WE's preview of 2764281221 (a lens-flare rainbow turned −0.744 rad) matches only this way, and WE's clock scripts turn hands clockwise with negative angles. Layers, parents, emitters and lights all use it, so a spot's cone points along its turned +X in the same frame the layers are drawn in (`ImageMaterialLightingTests.testSpotConePointsAlongItsTurnedAxis`, and through the renderer `testRendererLightsTheLayerFromTheContentsLights`).
- Tests: `LightingReference`, a float32 CPU model of `genericimage4`'s `LIGHTING` path written from WE's shader text (a point, a spot, a tube and a directional; the normal map through the layer's tangent space; metallic and roughness from constants or the mask); `ImageMaterialLightingTests` draws into an RGBA16F target and matches it within 0.002 (0.0003 without a normal map), ambient only gives albedo·ambient, and the mask's flags set exactly the painted components. Cost: a 1920×1080 layer lit by 4 tubes takes 0.6 ms of GPU against 0.05 ms for the same layer unlit (median of 30; 0.85 against 0.65 while other work shared the GPU). `testLightingNeedsSceneLightsAndFallsBack` is gone; the image material sweep draws `LIGHTING` materials with no budget.
- Library (`LitLayerLibraryTests`): the 5 lit layers of 4 scenes (f1, witcher ×2, the Knight puppet, Lofi Cafe) draw through their material every frame with no fallback; One piece girls' `f1` is 5.2–5.6× its ambient-only frame at the tubes (x = 641, 1282) and unchanged halfway between them (WE's preview shows the same bright bands).
- Not done: the Knight is a puppet; its atlas is lit as a still image (its mesh isn't drawn, area 1).

The plan as written:
- **Files:** `Loading/ImageMaterialPlan.swift` (drop `unsupportedCombos`; `NORMALMAP`/`PBRMASKS`/`*_MAP` from bound textures; `TEX1FORMAT` for rg88 normals; the `_rt_shadowAtlas`/`_alias_lightCookie` slots bound only under their combos); `Rendering/ImageMaterialUniforms.swift` and `Rendering/ImageMaterialRenderer.swift` (`g_NormalModelMatrix`, `g_EyePosition`, `g_ViewProjectionMatrix`, `g_Texture2Resolution`, the frame lighting from A2).
- **Tests:**
  - `ImageMaterialRenderTests`: a lit fixture with one point, one spot and one tube light against a CPU reference of `ComputePBRLightShadow` (Swift, float32) at chosen pixels; ambient-only gives `albedo · ambient`.
  - `testLightingNeedsSceneLightsAndFallsBack` is deleted.
  - `ImageMaterialSweepTests`: no "needs scene lights" reason is left.
  - A headless render of One piece girls (the `TimelineLibraryRenderTests` harness): `f1` is drawn through the WE path, with the brightness bands at the 4 tube x positions.

**A4 — The prelighting path (lit layers with effects). Done.**

What landed (the binary's order is §2.3; it differs from the plan below, which had the lighting after the effects):
- A lit or reflective layer with effects plans two variants (`ImageMaterialPlan`): `prelighting`, its material with `LIGHTING`/`REFLECTION` as authored and `PRELIGHTING` = 1, unblended and without the object's blend mode; and `pass`, the layer's own draw after its effects, with both combos off.
- `ImageMaterialRenderer.prelight` draws the layer image texel for texel into a texture of its size, in the frame-buffer format (RGBA8, or RGBA16F in HDR), before `SceneMetalRenderer.runEffects` hands the image to the effect graph: `g_ModelViewProjectionMatrix` maps the image quad onto the texture, the `g_Alt*` matrices are the layer's place in the scene, and `g_Color4` is white (the layer's colour, alpha and brightness are applied once, by its own draw, which the app does after the effects). A reflective prepass reads `_rt_MipMappedFrameBuffer`, which is made for it. Until its pipeline is ready the effects take the image unlit; when the chain renders nothing (every effect hidden, or compiling) the layer draws the prelit image.
- Puppets aren't prelit: WE prelights their mesh, which isn't drawn here, so their atlas is lit where it is drawn (`SceneContentLoader`). Sprite-sheet albedos, which WE also prelights, keep the direct path (no library user).
- Tests (`ImageMaterialPrelightingTests`): the two variants; with a white ambient and no lights the prepass gives a padded image back within 1/255 (witcher's `ведьмак` layer: ambient 1 1 1, no `lightconfig`); each texel matches `LightingReference` at its scene position within 1.5/255 (a turned layer, normal map, mask, all four light types); through the renderer, a lit layer behind an identity effect matches the same layer lit directly within 3/255. The library sweep above covers witcher and Lofi Cafe.

The plan as written:
- **First, pin down the pass order at `0x140209540` in the binary.**
- **Files:** the image-layer build in `Loading/SceneContentLoader.swift` (the unlit albedo target `_rt_imageLayerAlbedo_<id>`, the effect chain, the final `fullscreenlayer`/genericimage pass with `PRELIGHTING`/`PRELIGHTINGDUALVERTEX` and the `g_Alt*` matrices) and `Rendering/EffectGraphRenderer.swift` (the final lit pass).
- **Tests:** witcher's two layers and Lofi Cafe draw through WE's path with no fallback. With ambient 1 1 1 and no `lightconfig`, witcher's first layer matches today's unlit output within 1/255. A fixture layer with an effect and a light matches the direct path where the effect is the identity.

**B1 — WE's LDR bloom chain. Done.**

What landed:
- `SceneBloomChain` states WE's hard-coded chain as an effect.json (`engine:bloom_ldr.json`: the 4 `materials/util` passes, and `_rt_4FrameBuffer`/`_rt_8FrameBuffer`/`_rt_Bloom` as RGBA8 FBOs at 1/4, 1/8, 1/8) and plans it with `SceneEffectPlanBuilder`, so WE's shaders go through the translator unchanged. `SceneContentLoader` plans it for every scene (`SceneMetalContent.bloomChain`): a script or user property can turn `bloom` on.
- The effect graph runs it, holding its targets like a layer's (state `engine:bloom`), not `SceneRenderTargetPool`. The scene target is `_rt_FullFrameBuffer`; the combine writes an RGBA8 frame of its size. `EffectGraphRenderer.Context.texelSizeReference` makes `g_TexelSize` 1 / the frame's size in every pass.
- The live strength, threshold and tint (scripts, then timelines, then the content) go to pass 1 as constant writes each frame; strength is multiplied by the app's `_owe_bloom` (1 = WE's).
- `ScenePostProcess.encode`: step 5 (the bloom, when `allowsBloom` and the live `bloom` hold), then the composite, which now carries only the app's saturation, hue and blur. The HDR chain (B2) takes step 5's place; WE's `ccsimple` follows it for the user's image filter and colour options (`SceneColorCorrection`, we-values-audit notes §7.8), and the camera fade (step 7) isn't drawn yet. `sceneFragment`'s 3×3 bloom and `userBloom × 1.2` are deleted.
- Tests: `SceneBloomChainTests` (the plan; the chain against `BloomReference`, a Swift CPU model of the 4 passes, on an impulse, a step, a gradient and an odd size under 4 constant sets: within 2/255; the threshold; stability; the GPU cost), `SceneBloomRenderTests` (a fixture through the real renderer; `disabled` → no bloom), `ScenePostProcessTests` (the gate, the slider, the composite), and `BloomLibrarySweepTests`: every library bloom scene rendered headless for 45 frames, with no fallback, finite constants, bloom only adding, and each checked frame equal to the CPU model on that frame's own scene target (worst 1/255). 2 of the 24 (arsenal, fantasticcar) draw only their preview until area 6. The library now has a 25th bloom scene (2868563343).
- Cost (GPU, the chain alone, M-series, other work on the GPU): 0.3 ms fastest and 0.5–0.9 ms median at 1920×1080; 1.7–4.6 ms fastest and 4–7 ms median at 5120×2880 (runs differ with the load). At 5K the full-size combine and the composite's read of its output are most of it.
- Not done: the Python reference (the Swift model is the only one); a "before and after" image diff of non-bloom scenes (their composite is unchanged: its bloom term was 0 there). Left over: the layer uniform's `effects.w`, `colorEffects.w` and `bloomTint` (`SceneMaterialEffects.bloom`/`bloomThreshold`) are now read by no shader.

The plan as written:
- **Files:** new `Scene/Rendering/SceneBloomChain.swift` (the 4 passes of §2.6 run from `materials/util` through the effect-pass machinery, with RGBA8 targets from `SceneRenderTargetPool`); `ScenePostProcess.swift` (`_rt_FullFrameBuffer` ← the frame, bloom, combine; then the existing colour/fade steps in WE's order); `Rendering/SceneShaders.metal`, `SceneComposite.swift` and the composite section of `SceneMetalRenderer.swift` (delete the 3×3 bloom and `userBloom × 1.2`; `_owe_bloom` multiplies strength); the typed `postprocessing` setting is in place since L0 (§4.4): B1 only reads `ScenePostProcess.Frame.settings.postProcessing.allowsBloom`.
  - The app's default is "enabled", which keeps today's behaviour. WE's own UI default is unknown [?] (§5.1); the user can change the setting under *Settings → Performance → Post-Processing*.
  - `g_TexelSize` = 1 / render size.
- **Tests:**
  - A Python and Swift reference of the 4 passes on synthetic frames (an impulse, a step, a gradient); the rendered chain matches it within 2/255.
  - Threshold, strength and tint respond live to user, script and timeline values.
  - `postprocessing = disabled` → no bloom.
  - A bloom sweep renders the 24 bloom scenes headless: finite, no fallback, and a frame-time budget.
  - Compare before and after to confirm that non-bloom scenes are unchanged.

**B2 — HDR. Done.**

What landed:
- **The gate.** HDR is decided when the content is built, as WE decides it at load: `bloom` and `hdr` on and post-processing "ultra" or "displayhdr" (`SceneEngineCombos.hdr`, unchanged since L0). The content then carries `hdrChain`, `ScenePostProcess.drawsHDR` is set, and every material gets `HDR=1` (`SceneEngineCombos+HDR.swift`; nothing otherwise, as `common_blending.h` tests `#ifdef HDR`). Combos key the translation cache, so the translated output of a given variant is unchanged and there is no revision bump.
- **Float targets.** In HDR the scene target is RGBA16F (`SceneMetalRenderer`), and so is what follows its format: the native layer pipelines (`SceneLayerPipelines`, made for the drawable's format and RGBA16F), the image and particle material pipelines, region copies, snapshots and `_rt_MipMappedFrameBuffer`. The effect graph's layer buffers are WE's frame-buffer class (`0x1401ea642`: `_rt_imageLayerComposite_` and the ping-pong targets are format 0 in LDR, 0xe in HDR; `rgba_backbuffer`/`rgb_backbuffer` FBOs likewise, `0x1401e7572`): `EffectGraphRenderer.Context.frameBufferFormat`. An effect's explicit `rgba8888` FBO stays 8-bit.
- **The chain** (`SceneHDRChain`) states WE's passes as one effect.json (`engine:bloom_hdr.json`: D0, D1…7, both upsample materials at every level, both combines; `_rt_2FrameBuffer`…`_rt_256FrameBuffer` as RGBA16F FBOs) planned once per content; each frame picks its passes (`plan(levels:)`): n = max(1, min(levels, `bloomhdriterations`)) levels, bicubic for *k* ≥ n − 2, or `combine_srgb` alone when bloom doesn't run (scripts can turn `bloom` off). The constants (`0x140184020`) go to D0 (`bloomstrength` / (1 + scatter^(max(n,2)−2)), `blend`, `bloomtint`) and to every upsample material (`scatter`) as constant writes; `g_RenderVar0` per pass through `Context.passRenderVars` (D0 (1/w, 1/h, −1/w, −1/h), then × 2^level; the combine (RV.x, RV.y, the last pass's zw)). `_owe_bloom` scales the strength (1 = WE's). The effect graph holds the chain's targets (state `engine:bloom-hdr`) and releases whichever chain stops running.
- **Output.** The combines write linear values into an sRGB target (`rgba8Unorm_srgb`, the ping-pong format of the chain, `Context.outputFormat`), and the composite reads it through an `rgba8Unorm` view: the bytes an sRGB swap-chain view shows. RV is (1, 0), so an SDR frame shows as it does in LDR (0.85 stays 217). There is no tone map, as in WE.
- **Display HDR.** B3 below adds the EDR output. Without EDR headroom (neither display here has any: both report a potential EDR of 1.0) "displayhdr" draws as "ultra", which is WE's own fallback without an HDR swap chain (`0x1401109be`). *Settings → Performance → Post-Processing* offers "Ultra (Display HDR)" only when a display has EDR headroom, and keeps a saved "displayhdr" as "ultra" where none has, as WE's settings do (`runtime.displayhdrsupport`; `DisplayHDRSupport`). The warning icon shows for both ultra settings.
- **Tests:** `SceneHDRChainTests` (WE's levels, constants and `g_RenderVar0`; the plan; the chain against `HDRReference`, a Swift CPU model of every pass at half-float precision, on an overbright impulse, a step, a gradient and two odd sizes under 5 constant sets from 2 to 8 levels: within 2/255; the knee; stability; `combine_srgb`; the GPU cost), `SceneHDRMaterialTests` (every shipped shader with an `HDR` branch translates with `HDR=1`; a probe material's `CombineLighting` computes WE's overbright on a float target, and `ambient + light` without HDR), `SceneHDRRenderTests` (the fixture `Scenes/hdr` through the real renderer: HDR only with ultra and displayhdr; the float frame keeps 1.6; only the overbright square blooms; the output equals the CPU model; displayhdr = ultra; enabled stays LDR with WE's LDR bloom), `ScenePostProcessTests` (the levels follow the bloom gate and the iterations), `DisplayHDRSupportTests`, and `HDRLibrarySweepTests`: the 5 library HDR scenes and the HDR test set (2321732083, 3657770939, 3734636606, 2350874185) rendered headless for 45 frames with ultra (the chain runs every frame, RGBA16F, finite frames and constants, each checked frame equal to the CPU model on its own scene target: worst 1/255) and again with enabled (LDR bloom, no HDR). 3657770939 and 3734636606 author `bloomhdrstrength` 0: their chain runs and adds nothing.
- **Cost** (GPU, the chain alone, 8 levels, M-series, other work on the GPU): 1.8 ms fastest and 2.8–4.5 ms median at 1920×1080; 5.4–14 ms fastest and 8–21 ms median at 5120×2880. Level 0's half-size RGBA16F reads and the full-size combine are most of it. Whole frames in the sweep (a 384×216 drawable; the scene targets are 1920×1080 to 5760×1080): 6–29 ms of GPU in ultra against 1.5–17.5 ms in enabled.
- **Not done:** the camera fade (step 7): WE makes it only for scenes with camera paths (0x140181bae). `ccsimple` (step 6) is drawn since: WE makes it only for colour-correction settings away from identity (0x1401826a2…0x1401826f3), the user's image filter and colour options (we-values-audit notes §7.8). Done since: scripts and timelines drive `bloomhdr*` (bound-only scene fields, `69f9530`), and the prelit image is RGBA16F in HDR (`961c6f4`).

The plan as written:
- **Files:** new `Scene/Rendering/SceneHDRChain.swift` (§2.6 HDR: up to 8 RGBA16F levels, the constants, D0/Di/Uk with bicubic, `combine_hdr_upsample`/`combine_dhdr_upsample`/`combine_srgb`); `ScenePostProcess.swift`; the scene-target format in `SceneMetalRenderer.swift` (RGBA16F when HDR is on); `SceneEngineCombos+HDR.swift` (`HDR=1` everywhere; bump the revision; §4.4); effect FBO and ping-pong formats in `EffectGraphRenderer.swift` (the frame-buffer class follows the scene format).
- **Output on macOS:** "ultra" writes linear values, so the final pass goes to an sRGB drawable view (`bgra8Unorm_srgb`) with `RV.x` = 1. "displayhdr" uses an `rgba16Float` `CAMetalLayer` with `wantsExtendedDynamicRangeContent` and a linear extended colour space, with `RV.x` = 1 and `RV.y` from the screen's EDR headroom. RV is our choice here [?], so name it in test-risks.
- **Tests:**
  - A reference of the mip chain (levels, strength normalisation, soft knee) on synthetic float frames.
  - The 5 HDR scenes render with `ultra` and fall back to LDR bloom with `enabled`.
  - An overbright fixture (emissive or `brightness` > 1) blooms only in HDR.
  - The LDR output is unchanged by B2.

**B3 — Display HDR output. Done.**

WE's behaviour (`wallpaper64.exe`):
- **The gate.** At load, "displayhdr" sets display HDR (0x4000) with HDR (0x2000), only for a scene drawn in HDR (`bloom` and `hdr`, 0x14010e6da). The device then looks at every output (IDXGIOutput6::GetDesc1, 0x14012af26): on the one showing the wallpaper, a colour space of 12 (DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020, the monitor in HDR mode, 0x14012af44) keeps display HDR and computes RV; any other clears the support byte (0x14012b5e7), and after the device is made display HDR is dropped (0x1401109be), so the scene draws as "ultra".
- **The swap chain** is R16G16B16A16_FLOAT with display HDR, R8G8B8A8_UNORM otherwise (0x14012b656). No `SetColorSpace1` call exists near it, so DXGI shows the float swap chain as scRGB: linear, BT.709 primaries, 1.0 = 80 nits.
- **RV** (`g_RenderVar0.xy`, 0x14012b5d9): SDR white = the display's `SDR_WHITE_LEVEL` × 80 / 1000 (200 nits when the query fails), clamped to [80, max luminance], max luminance = max(DXGI MaxLuminance, 80); RV = (SDR white, max luminance − SDR white) / 80. At Windows' default SDR white level (1000 → 80 nits) RV.x is 1: scRGB 1.0 is SDR white.
- **The combine** is `combine_dhdr_upsample` (`combine_hdr` with `DISPLAYHDR` 1, 0x14017fb49): the scene saturated, the bloom added, linearised and scaled by RV.x + RV.y · smoothstep(1, 5, luma) (the formula in §2.6). No tone map and no clamp to the display's maximum: the scene stays at SDR white and only the bloomed luma above 1 rises towards the maximum. A frame without bloom running takes `combine_srgb` unscaled (0x140180b9c).

What landed:
- `Rendering/SceneDisplayOutput.swift`: `SceneDisplayHeadroom` (a screen's potential and current `maximum…ExtendedDynamicRangeColorComponentValue`) and `SceneDisplayOutput` (`.standard` or `.extendedRange(headroom:)`): EDR only for "displayhdr", a content drawn in HDR and a screen whose potential headroom is above 1, the macOS counterpart of WE's HDR10 test. The EDR drawable is `rgba16Float` in extended linear sRGB with `wantsExtendedDynamicRangeContent` (`apply(to:standard:)`; the standard output restores a view only where EDR changed it). macOS's EDR is WE's scRGB model with SDR white as the unit, so WE's RV over its SDR white is RV = (1, current headroom − 1) (`renderVar`).
- `SceneHDRChain`: `combine_dhdr_upsample` is pass 24 of the chain's document; `plan(levels:displayHDR:)` and `encode(…displayHDR:)` take it with that RV and write RGBA16F linear values; `combine_srgb` also writes RGBA16F then. `ScenePostProcess.Frame.display` carries the output; the composite has a pipeline per drawable format; `ccsimple` keeps float targets in EDR.
- `SceneMetalRenderer`: `selectDisplayOutput` per frame (a view's screen, or for a shared frame the least headroom of the views it was shown on), `displayHeadroom` (tests), `displayOutput`; `present(in:)` shows an EDR shared frame on an EDR-configured view.
- Tests: `SceneDisplayOutputTests` (the selection over every quality, HDR or not and headroom; RV; the view set up and restored; the chain's display combine; the HDR fixture on a view with headroom 4: an `rgba16Float` extended-linear-sRGB drawable, the combine equal to a CPU model of the `DISPLAYHDR` branch within 2 % relative, the overbright square above 1 on the drawable, black at 0; "ultra" byte-identical with and without headroom; "displayhdr" without headroom byte-identical to "ultra"; a shared frame in EDR once shown on EDR views), with `SceneHDRRenderTests`, `SceneHDRChainTests`, `ScenePostProcessTests` and `DisplayHDRSupportTests` unchanged and passing.
- **Not verified:** neither display here has EDR headroom (potential 1.0), so the EDR output was checked only headlessly. RV follows the current headroom, which rises only once the layer asks for EDR; the first frames after switching show SDR levels.
- **Deviations** [?]: RV.x = 1 takes macOS's SDR white as WE's (WE's own RV.x is 1 only at Windows' default white level); `combine_srgb` in EDR writes its values unscaled, as WE's does. `ccsimple` runs on the linear EDR frame (WE's order, step 6, after the combine; its targets there are the swap chain's format [I]).


**B3b — HDR video (WE 2.8's "Scene DX11 (HDR Support)" video framework). Done.**

WE's behaviour: the scene video framework plays a video through the scene renderer (`scenes/videoplayer`). For a HDR video the float frame holds linear light (scRGB) instead of sRGB-encoded colour, and render flag 0x10000 swaps the no-bloom combine `combine_srgb` for `materials/util/combine_video_hdr.json` (0x14017fb82; the bloom combine is unchanged). That shader does no linearisation: `rgb = saturate(rgb / (2 · g_HDRParams.y)) · 2 · g_HDRParams.y`. `g_HDRParams` (uniform id 0x8b) is a device value; `passthroughlinear` divides by its `.x` to get back to SDR, which with the single HDR pair the device computes (0x14012b5d9) reads as RV, (SDR white, max luminance − SDR white) / 80 nits. Where the flag is set wasn't found (the setter takes computed masks); it is taken as "HDR video on a HDR swap chain", the only case the shader's clamp makes sense in.

What landed:
- `Video/VideoDynamicRange.swift` reads the first video track's transfer function (PQ, HLG or SDR).
- The Metal video path (`SceneContentLoader.videoContent()`) decodes a PQ or HLG video as HDR only under "Ultra (Display HDR)": `VideoTextureStream` asks AVFoundation for linear half floats in BT.2020 (`kCVPixelFormatType_64RGBAHalf`, 1.0 = 100 nits; asked for BT.709 it tone maps into 0…1), and `VideoHDRConversion` (one compute pass per new video frame, on the frame's command buffer) converts them to linear BT.709. The content draws in HDR with `videoHDR`, so `SceneHDRChain` combines with `combine_video_hdr` (pass 25) and `g_HDRParams` = (1, headroom − 1) on the EDR output. A frame of it on a display without headroom gets (1, 0.5), SDR white, rather than WE's (1, 0), which would be black. Every SDR video, and every video under the other settings, keeps the 8-bit BGRA path unchanged. Embedded video textures in scenes stay SDR: the flag is a whole-frame switch, so it fits only a frame that is the video.
- The AVKit path already shows HDR video as EDR: `AVPlayerView` does it on its own on a display with headroom.
- Tests: `VideoHDRTextureTests` (PQ/HLG clips written with AVFoundation; linear values 1, 2.03, 10 for 100/203/1000 nits; BT.2020 red converted; the end-to-end EDR drawable with injected headroom 4), `SceneHDRChainTests.testAHDRVideoCombinesWithCombineVideoHDR`.
**C1 — The mip-mapped frame buffer and the reflection setting. Done.**
- **What landed:**
  - `Rendering/SceneMipMappedFrameBuffer.swift`, the first `SceneFrameStage`. It exists only while the content samples the target (`samples(_:)`: an image material, effect pass or particle stage). It keeps one target at the scene target's size and format with WE's mip count (§2.4), and it isn't pooled, since it lives across frames. After the scene pass it copies the frame and generates the mips while `renderSettings.reflection` is on. With the setting off it clears the target once to (0,0,0,1).
  - `SceneEffectTextureInput.mipMappedFrameBuffer` replaces the alias to `.sceneSnapshot` in the image, effect and particle plan builders. The renderers bind the stage's target, which `SceneMetalRenderer` fetches before the scene pass, so draws read the previous frame as in WE. Reading it doesn't pause the scene pass, and an effect that reads it isn't cached.
  - `g_Texture3MipMapInfo` is the level count (`EffectGraphRenderer.textureInfo`), not the count − 1.
  - `ImageMaterialPlanBuilder` accepts `REFLECTION` without `LIGHTING` on a layer without effects or a puppet (`prelit` false). A prelit layer still falls back (A4), and so does `LIGHTING` (A3).
- **Tests** (`SceneMipMappedFrameBufferTests`, `ImageMaterialReflectionTests`): WE's mip count; level 0 is the frame and each level is the box average of the one before; `g_Texture3MipMapInfo`; nothing is made while nothing samples the target; the setting off clears every level to (0,0,0,1); a `genericimage4` `REFLECTION` layer with a normal map and a PBR mask (fixture `ImageMaterials/materials/reflection.json`) matches a CPU reference of §2.4 at mip 0 and at the roughest mip, within 3/255; with the setting off it draws its albedo; through `SceneMetalRenderer`, the layer reflects the last frame and stops when the setting is turned off.
- **Left for A3:** меч itself (LIGHTING, prelit); whether WE sets the `*_MAP` component combos from the mask by itself (the fixture authors them; меч's material doesn't). Both done by A3 and A4: WE sets them from the mask's `.tex` flags (§1.4).

**D1 — Volumetrics. Done.** Hinata's cookie spot draws its volume through WE's own passes.

What landed:
- `SceneVolumetricsPlan` (planned with the content, like the bloom chain) resolves WE's six util materials through the translator with WE's combos, per light that casts volumetrics, and loads each cookie. It is nil while the setting is disabled or no light casts volumetrics.
- `SceneVolumetrics`, the stage, does §2.8 per visible light: the far faces into `_rt_volumetricsSingle`, the ray march into the light buffer, then the blur below quality 3 and the combine. `SceneVolumetricLight` holds the per-frame values (projection, mesh placement, `g_RenderVar*`, the inside test), `SceneVolumeMesh` the meshes, `SceneVolumetricsPipelines` the pipelines. The cookie key is decoded (`WESceneLight.cookie`, `SceneLight.cookie`).
- The translator's prelude gained HLSL's `clip`, and `texLoad2D`/`texSample2DBackBuffer`/`sampler2DBackBuffer` (an unfiltered texel read). Only shaders that use them get them, so no translated output that existed changes and the revision stays.
- *Settings → Performance → Volumetrics* (disabled…ultra; the app's default stays medium, §5.1).

How it maps to Metal:
- **Depth.** The shaders compare their clip depth with the depth targets, which D3D stores as they are. Here the translator maps clip z to Metal's depth as (z + w) / 2, and the shader reads rows mirrored from how it draws them (D3D's screen UV against the translator's y flip). So each depth target is converted after it is drawn (`volumetricsClipDepth`: 2d − 1, rows swapped) into the R32F texture the shader reads. The front pass keeps the near faces and the back pass the far ones by culling, with the winding taken from the sign of the mesh's full transform: the meshes are wound outward.
- **Where it runs.** WE composites volumetrics within its object loop (§2.8, finish); here the stage runs once the scene pass has ended. That is WE's result when the volumetric lights come after every drawn object, as Hinata's does; otherwise the objects after a light's run draw under its volumetrics here [deviation]. The stage runs before the `_rt_MipMappedFrameBuffer` copy, which in WE follows the loop: `SceneFrameStages.make` lists it first.
- **Depth for 3D scenes.** The scene pass has no depth buffer yet, so `_rt_volumetricsBack` is the far depth (one texel). `SceneFrameStageContext.sceneDepth` takes the scene's depth once area 6 has one; each light then copies it through the same conversion, as WE copies it per light.
- **The camera** is `SceneCamera`'s perspective, or in an orthographic scene WE's reset camera (eye 0, looking down −z, +y up; 0x14018866b) through the projection above. Shake moves WE's eye and centre (0x140199580); the renderer moves every object by −shake instead, the lights included (`SceneFrameLightingInput.cameraShake`), so the volumes follow it. Parallax moves only the draws' model matrices (0x14018b062…0x14018b14e), not the lights nor this camera. Its y is mirrored for the scene target (whose first row is the scene's top), and `g_EffectModelMatrix` is that matrix's inverse.

Not done:
- (Done with D2) a light that casts both a shadow and volumetrics while shadows are on draws with `SHADOW`, reading its map in `_rt_shadowAtlas`; with shadows off WE compiles it without `SHADOW`, and so does the app.
- Tube, directional and legacy lights with `castvolumetrics` take WE's spot path, with a projection WE never computes for them; they aren't drawn [?]. The library has none.
- A point's `g_AltViewProjectionMatrix` drops the light's rotation [?: a sphere doesn't show it], and the sphere's own triangle order wasn't traced.

Tests:
- `SceneVolumetricsTests`: the plan (materials, combos, passes and blur per quality, the cookie); the setting gates the plan and the stage; shadow casters plan with `SHADOW` with shadows on and without it with them off; the meshes are WE's and wound outward; the light values against hand-derived ones; the inside tests; the blur and combine against `VolumetricsReference` (a Swift model of `blur_k3` and the additive `passthrough`) within 1/255, with and without the blur; the stage on a synthetic frame against the model of `volumetrics_front` along every pixel's ray (the model rasterises the meshes itself) within 2/255, for a cone spot at ultra and a point at high; the cost.
- `VolumetricsLibraryTests`: Hinata through the real loader and renderer (every lit texel lies in the light's projected frustum, the volume follows the light when it moves, and the setting turns it off); the test set's and Moon's lights (which WE draws, with shadows on and off); and the root lights of 3233200129 (a cookie spot) and Moon (a point, with the camera inside its volume) drawn through the scene's own camera onto an empty frame.
- Cost (GPU, the stage alone, 1920×1080, two spots and a point, M-series with other work on the GPU): 0.4–2 ms fastest, 4–10 ms median over runs, at every quality. The light buffers are small; most of it is the ray march over the volumes' screen area.

**C2 — Planar `_rt_Reflection`** and **D2 — shadows (atlas, casters, the cascade quirk):** with area 6 (depth buffer, models). There are no 2D library users.

**D2 — Shadows. Done** as models-plan §4.3 M8 (the atlas and its packer, the spot, point and cascade views, the casters' shadow variants, the `g_LFeature_*` values, lit models, images and volumes reading the atlas; §2.7 is corrected by models-plan §2.10). Lit particles don't get the atlas yet. Lights in perspective scenes now take their world matrix from M3's 3D hierarchy (parents' depth and 3D rotation included); A2's 2D parent chain stays for orthographic scenes.

**T — Tester (after A3 and B2).**
- A `LightingLibrarySweepTests` over the library (`OWE_LIBRARY`), listing every scene with lights, lit layers, bloom or HDR. For each it:
  - asserts there is no lighting or bloom fallback;
  - logs the packed light arrays and the chosen combos;
  - checks every frame for NaN and inf;
  - records the frame time.
- Adversarial fixtures: a budget exceeded, 5 legacy points, a light without `lightconfig`, a script moving a tube's `controlpoint`, bloom toggled by a user property mid-run.
- New "needs WE ground truth" entries in `docs/test-risks.md`: One piece girls, Hinata, the 2B HDR scene, and one plain bloom scene, captured at `postprocessing` ultra and enabled.

### 4.4 Seams (landed with L0)

L0 decoded the format and added the files, types and hook points below without changing what is drawn: the engine combos are empty, nothing is packed, no uniform reads the frame lighting, and the composite is the old one. A1, A2, B1, C1 and D1 can now start in parallel, and A3, A4 and B2 as their prerequisites land. Each file below has one owner.

**Decoded and resolved.** L0 owns these; the other packages read them and don't edit them.

| What | Where |
|---|---|
| `WESceneObject.light: WESceneLight?`: the kind (`WELightKind`, with WE's raw values) and every field of §1.1 as a `SceneRawValue`, keyed by `SceneLightValueField` | `Scene/Format/SceneLight.swift`, `SceneObject.swift`, `SceneValueFields.swift` |
| `WESceneGeneral.lightconfig: WELightConfig?`, with masked counts and `withShadowsDisabled` | `Scene/Format/SceneLightConfig.swift`, `SceneDocument.swift` |
| `hdr` and `bloomhdr*` as bindable `general` fields | `SceneValueFields.swift` |
| `SceneLight(_:in:)`: the fields resolved against the user properties, defaulting to `SceneLightDefaults` (the constructor's values) | `Scene/Values/SceneLightValues.swift` |
| `SceneBloomSettings.hdr: SceneHDRBloomSettings` and `SceneLightingSettings` (ambient, skylight, `lightConfig`), with their defaults in `SceneGeneralDefaults` | `Scene/Values/SceneGeneralSettings.swift`, `Rendering/SceneRenderContent.swift` |
| `SceneMetalContent.lighting: SceneLightingContent` (the settings, plus every `SceneLightObject` in scene order: object id, authored light and resolved light) and `SceneMetalContent.engineCombos`. Light objects aren't layers. Their transforms are in `content.transforms` and `content.motions`, like any other object's. | `SceneContentLoader.lights(in:context:)` |

**User settings.** L0 added all of these, so no later package needs to touch the settings store.
- `GlobalSettings` has WE's four quality settings:
  - `postProcessing`: disabled, enabled, **ultra** or **displayhdr**; default "enabled".
  - `reflections`: default on, as in WE.
  - `shadows` and `volumetrics`: `GSLightingQuality`, disabled…ultra = 0…4; default medium.
- Post-processing and reflection are stored under new keys (`postProcessingQuality`, `reflection`). The old keys hold values saved while the settings had no effect, when post-processing defaulted to "disabled".
- Settings now decode key by key, so adding a key no longer resets every setting.
- The engine sees them as `SceneRenderSettings` (`Rendering/SceneRenderSettings.swift`, with `allowsBloom` and `allowsHDR`):
  - `SceneMetalRenderer.renderSettings` is read per frame;
  - `SceneContentLoader.setRenderSettings` rebuilds the content;
  - `SceneWallpaperView` passes them in and follows changes.
- UI: *Settings → Performance* already has Post-Processing (disabled, enabled, ultra) and Reflections. In `Settings/PerformancePage.swift`, B2 adds a "Display HDR" entry and D1 a volumetrics picker. Each touches only its own control.

**Hook points and their owners.**

| Seam | File (owner) | How it is called now | What the owner adds |
|---|---|---|---|
| Engine combos | `Scene/Shaders/SceneEngineCombos.swift` (L0). `SceneEngineCombos(bloom:lighting:orthographic:settings:)` sets `hdr` (bloom, hdr and ultra or displayhdr), `sceneOrtho`, `lightBudget` (folded when shadows are off) and `shadowQuality`. | `SceneContentLoader.metalContent` makes one per content build and passes it to every `ImageMaterialPlanBuilder`, `SceneEffectPlanBuilder` and `ParticleMaterialPlanBuilder` (`sceneEngineCombos`). They lay `applied(to:)` over the resolved combos. | — |
| Light combos | `SceneEngineCombos+Lighting.swift` (**A1**, done) | called from `combos(for:)` | done: all nine `LIGHTS_*` counts when `material["LIGHTING"]` ≠ 0 (0 without `lightconfig`), `LIGHTS_SHADOW_MAPPING` and `_QUALITY` for a shadowed count, `LIGHTS_COOKIE` for a cookie count, and `SCENE_ORTHO` on every material of an orthographic scene |
| HDR combo | `SceneEngineCombos+HDR.swift` (**B2**, done): `hdrCombos(for:)` returns `HDR=1` while the content draws in HDR | called from `combos(for:)` | done (no revision bump: combos key the cache) |
| Frame lighting | `Scene/Rendering/SceneFrameLighting.swift` and `SceneLightPacker.swift` (**A2**, done). `SceneFrameLighting.frame(_:input:)` returns the ambient and skylight colours (a script's `thisScene.ambientcolor` or `skylightcolor` wins) and the packed `arrays` by uniform name. | `SceneMetalRenderer` calls it once per frame, after scripts and timelines, and stores the result in `BuiltinFrameContext.lighting`, which `BuiltinUniforms` reads. `SceneFrameLightingInput` provides each object's live own transform (`local(id)`) and its parents' (`parentWorld(id)`), `isVisible(id)` (ancestors included), the scripts' scene colours, the user's shadows setting, the eye and the view forward. | done |
| Post-process | `Scene/Rendering/ScenePostProcess.swift` (**B1** done, then **B2**). `encode(Frame)` runs `bloomed(_:)` (step 5, WE's LDR chain) and then `composite(_:_:)` with the app's extras; B2's HDR chain replaces step 5 in HDR. It owns the composite pipeline. | `SceneMetalRenderer` calls it after the scene pass and the frame stages. `Frame` holds the scene target, the drawable's pass, the placement uniform, `Bloom` (live values: scripts, then timelines, then the content; `hdr` included), `AppExtras` (`_owe_bloom`, `_owe_saturation`, `_owe_hue`, `_owe_blur`) and `settings`. | B1: `_rt_FullFrameBuffer`, `SceneBloomChain.swift` and the combine; honour `allowsBloom`; make `_owe_bloom` a strength multiplier; then the composite. Delete `sceneFragment`'s 3×3 bloom (`SceneShaders.metal`, `SceneComposite.swift`). B2 (done): `SceneHDRChain.swift`, `drawsHDR`, and the float scene target in `SceneMetalRenderer.swift` and `EffectGraphRenderer.swift`. |
| Frame stages | `Scene/Rendering/SceneFrameStage.swift`: `protocol SceneFrameStage` (`encode(SceneFrameStageContext)`, `setContent`) and `SceneFrameStages.make(device:)`, which returns C1's `SceneMipMappedFrameBuffer` | `SceneMetalRenderer` runs the stages in order between the scene pass and the post-process. Each gets the scene target, the command buffer, the scene size, the frame's `BuiltinFrameContext` (lighting included) and the settings, and `setContent` on every content change. | **C1** added the `_rt_MipMappedFrameBuffer` copy and **D1** `SceneVolumetrics` (done), which runs first since WE combines volumetrics within its object loop. D1 added `sceneDepth` (for area 6) and `assetTexture` (the cookies) to the context. |
| Lit image materials | `Loading/ImageMaterialPlan.swift`, `Rendering/ImageMaterialUniforms.swift`, `ImageMaterialRenderer.swift` (**A3**, done) | a lit layer draws through its material with the packed lights | done |
| Prelighting | `ImageMaterialPlan.prelighting`, `ImageMaterialRenderer.prelight`, called from `SceneMetalRenderer.runEffects` (**A4**, done; `EffectGraphRenderer` untouched) | a lit layer with effects is lit into the image its effects start from | done |
| Reflection copy | `SceneMipMappedFrameBuffer.swift` (**C1**, done); the setting is `renderSettings.reflection` | the first stage in `SceneFrameStages.make`; `SceneMetalRenderer` binds `target(matching:commandBuffer:)` to every draw | — |

**Tests that pin the seams:**
- `SceneLightDecodeTests`: each light type from the survey objects in `Tests/Fixtures/Scenes/lights`, WE's defaults, bindings, `lightconfig` masking and folding, and the HDR and lighting settings.
- `LightingLibraryDecodeTests`: the library decodes to 106 scenes, 4 tube, 3 lpoint, 3 legacy point and 1 spot light, 3 `lightconfig`s, 5 `hdr: true` and 70 scenes with `bloomhdr*`.
- `SceneLightingSeamTests`: no combos, no arrays, and the lights in the built content; `ScenePostProcessTests`: the old composite uniform. Each owner replaces its "nothing yet" assertions as it fills its seam.
- `QualitySettingsTests`: the settings' defaults and the migration of saved settings.
- `WEAuthoredValuesTests.testGeneralDefaultsAreWEs`: the HDR and colour defaults.

## 5. Open points (all need the binary or WE ground truth)

1. The default for `postprocessing` in WE's settings UI (the engine writes "disabled" when the key is missing). The app defaults to "enabled" (today's look) and the user can change it; revisit once WE's UI default is known. The default of the `volumetrics` setting is also unconfirmed: the app takes shadows' "medium".
2. `g_TexelSize` for the bloom passes and the HDR combine (inferred as 1 / render size), and `g_RenderVar0.xy` on an SDR output (taken as (1, 0); on an HDR10 output it is found, §2.6). Whether "ultra" reaches the screen through an sRGB view of WE's 8-bit swap chain.
3. What `[scene+0x158]` is. (`vt+0x8` of WE's render targets, `0x1400d3310`, is the frame copy: `CopyResource` of the bound target, or `ResolveSubresource` from MSAA; found for C1.)
4. ~~`_rt_MipMappedFrameBuffer`'s mip count in LDR and `g_Texture3MipMapInfo`~~: resolved by C1 (§2.4). The "1 or 15" was the format.
5. ~~The prelighting pass order for lit layers with effects (`0x140209540`)~~: resolved for A4 (§2.3). Still open: the view-projection WE gives the prepass (its effect buffer's), which only the reflection's screen offset reads (`normal · g_ViewProjectionMatrix`, normalised); the app uses the buffer's orthographic projection in the scene target's convention, z range −1…1 as for the scene (C1). The size of that offset depends on WE's orthographic z range, which isn't traced [?].
6. ~~The cookie texture's source key~~: `cookie`, resolved by D1 (§2.8). (The default `intensity` is 0: §1.1.) Still open for D1: the 2D camera's eye, and the culling of `volumetrics_back`.
7. The shadow atlas depth format and the exact cascade fit.
8. The user's editor observation that an image was lit only once a light cast shadows (§2.2, "Light count"). The binaries show no such rule, so it is an editor artefact or the test setup. To settle it, the Windows session could capture a 2D scene with one image whose **Lighting** is on, and one `lpoint` added from the editor (radius 500, intensity 10). Screenshot and save `scene.json` at each step: after the add, after Cast shadow on, and after Cast shadow off again. Then the same with the image's Lighting off. The saved `lightconfig`, the image's material combos and the pictures show whether the first add didn't recompile, or the image simply wasn't lit.
