# Depth maps

The **Depth Map Generation** plugin makes a depth map on your Mac, for two jobs, in Scene Edit /
Export and in the Wallpaper Editor alike:

- **Scene › Depth Parallax** binds Wallpaper Engine's own **Depth Parallax** effect to a depth map
  of the whole scene, so a flat picture shifts in depth as the pointer moves, as in Wallpaper
  Engine.
- **Layer › Create Mask from Depth Map** turns a layer's depth map into the layer's opacity, so
  what is far fades out, or into the mask of one of its effects, so an effect (Shake, Water
  Ripple, Tint…) shows only on what is near, or only on what is far.

## The plugin

Settings › Plugins › **Depth Map Generation** (off until installed) downloads Depth Anything V2
Small, Apple's Core ML release of it (Apache-2.0), from Apple's Hugging Face repository at a
pinned commit. Every file is checked against its pinned SHA-256 before it is kept, then the model
is prepared for the Mac. **Update** and **Remove** are in the same place; the About window credits
the model.

The model runs only on the Mac, and only while generating: it is loaded for a generation and
released five minutes after the last one. Nothing is loaded while wallpapers just play.

## Making a depth map

Without the plugin, both sections offer **Install Depth Map Generation**. In both, **Generate**
makes the depth map, **Preview Depth Map** shows it and **Smoothing** softens it.

### Scene Depth Parallax

With nothing selected (the scene), **Scene Depth Parallax** generates a depth map of the whole
scene. **Apply Depth Parallax** adds a fullscreen layer with Wallpaper Engine's Depth Parallax
effect bound to the map on top of the scene; **Strength** sets how far it moves, and **Remove Depth
Parallax** takes it off.

The effect follows the pointer and the scene's parallax as in Wallpaper Engine. On a scene
without camera parallax, applying it turns parallax on, with the other layers' own movement at 0,
and removing the last depth parallax turns it off again.

### Create Mask from Depth Map

Select an image or text layer and open **Create Mask from Depth Map**. The preview shows the mask
as it will be: white where the effect shows, black where it doesn't.

- **Invert** swaps near and far, so the effect shows on the background instead.
- **Contrast** pushes the mask toward black and white (above 100%) or softens it (below).
- **Use as Mask for…** lists **Layer Opacity** first, then the layer's effects that have a grey
  mask (WE's `opacitymask` samplers; an effect with several lists each), and writes the depth map,
  shaped, as that effect's mask. Effects that already have a mask are listed under **Replaces the
  current mask**: the depth map replaces it, Undo brings it back, and its file stays.
- **Layer Opacity** makes the depth mask the layer's alpha through Wallpaper Engine's own
  **Opacity** effect (`effects/opacity`), whose shader multiplies the layer's alpha by its grey
  mask: near shows and far fades to transparent, and Invert swaps them. A layer without an Opacity
  effect gets one, added with the mask as one undo step (its files are copied in as Effects › Add
  Effect… copies them); a layer that has one has its mask filled (the first Opacity effect, when
  there are several), under **Replaces the current mask** when it has one already.
- Without Wallpaper Engine's assets or an effect with a grey mask, the section says to add one
  first (Effects › Add Effect…).

A layer section no longer applies depth parallax; the scene's does. Depth parallax an earlier
version put on a layer still shows **Remove Depth Parallax** there.

Where the depth comes from:

- An image layer: its own picture.
- Text, solid, composition and fullscreen layers, and animated images: the layer as it is drawn,
  at a still frame.
- The scene: one frame of the whole scene.

## Where depth maps are kept

Every action is one undo step. Depth maps and masks are kept with the wallpaper's edits, beside it,
never in its files, so both editors see the same ones. In the Wallpaper Editor they are part of its
draft, which only its canvas shows until File › Save. **Save as New Wallpaper** writes them into the
new wallpaper as normal effects and textures, which Wallpaper Engine reads as well.

A mask is stored as Wallpaper Engine's editor stores a painted effect mask in Workshop scenes:

- the file `materials/masks/<effect>_mask_<hash>.tex`, one 8-bit channel (`FORMAT_R8`, format 9),
  clamped, the size of the layer (at most 2048 pixels on its longer side, as a painted mask), one
  LZ4 mipmap in a `TEXB0003` container;
- named, without `materials/` and `.tex`, in the effect's first pass at the sampler's index:
  `"effects": [{"file": "effects/shake/effect.json", "passes": [{"textures": [null, null, null,
  "masks/shake_mask_…"]}]}]`, with the sampler's combo (`MASK`) on.

Layer Opacity is stored the same way, in the Opacity effect's `g_Texture1` slot (where Wallpaper
Engine's own Opacity preview names its `masks/opacity_mask_…`): `{"file":
"effects/opacity/effect.json", "passes": [{"textures": [null, "masks/opacity_mask_…"], "combos":
{"MASK": 1}}]}`, with `effects/opacity/effect.json`, its
material and its shaders copied into the wallpaper's edits as adding any built-in effect does.

Files are named by their content and never deleted, so a replaced mask is still there for Undo.

MCP clients get `depth_generate`, `depth_apply`, `depth_remove` and `use_depth_map_as_mask`
(`effect: "opacity"` for Layer Opacity; [`mcp.md`](mcp.md)).
