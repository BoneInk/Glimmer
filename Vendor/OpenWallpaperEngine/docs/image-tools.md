# Image tools

The Wallpaper Editor's image preparation tools, as Wallpaper Engine's editor has them
([Image Preparation](https://docs.wallpaperengine.io/en/scene/image-preparation/foreground-separation.html),
[Real-Time Lighting](https://docs.wallpaperengine.io/en/scene/lighting/introduction.html)). Their
algorithms follow WE's editor (`wallpaperui.exe`, which runs OpenCV 4.4 on the picture), read from
its UI (`ui/dist/scripts/scripts.js`, `EditorCharacterSeparationModalCtrl`) and its binary. The
pieces live in `Packages/OWEEditor`: the image work in `OWESceneEditing/ImageTools`
(`ImagePlane`, `DistanceTransform`, `Inpainting`), the windows in `OWEEditor/ImageTools`.
Everything runs on the Mac, off the main thread, with no downloads.

## Normal Map Generation

An image layer's inspector has a **Normal Map** section: the layer's normal map (its material's
`g_Texture1`, WE's genericimage shaders' `NORMALMAP`), **Generate…** and **Remove**.
Generate opens WE's Normal Map Generation window with WE's options and defaults:

| Option | Range | Default |
|---|---|---|
| Shape › Blur | 1–63, odd | 63 |
| Shape › Depth | 0–1 | 1 |
| Shape › Exponent | 1–8 | 4 |
| Shape › Threshold | 0–1 | 1 |
| Details › Blur | 1–255, odd | 21 |
| Details › Depth | 0–1 | 1 |
| Details › Invert | | off |

WE's hidden "Filter size" (the Sobel kernel) stays at its default, 13. The options are remembered
per material while the window is open, as WE's editor does.

How the map is made (`NormalMapGenerator`, WE's `performGenerateNormalMap`):

- **Shape**, worked out with the long side at 512 pixels: the picture's alpha above 250, bordered
  with `64 / min(scale, 1)` transparent pixels, gives an inside distance (cut at Threshold of its
  range, normalised, rounded by Exponent as `1 − (1 − d)^e`) and an outside distance (the same,
  scaled by the ratio of the two ranges) whose difference, normalised and blurred by Blur, is the
  height. Its 13-tap Sobel gradients, normalised to −1…1, become normals with Depth. An opaque
  picture has a flat shape.
- **Details**, at the picture's size: the transparent part filled from the opaque one (Telea), the
  mean of red, green and blue normalised, blurred by Details › Blur; its gradients, divided by
  their largest magnitude, become normals with Details › Depth (Invert flips them), faded out
  towards the outline (the inside distance clamped to 1–7 % of its range, blurred).
- The details are turned onto the shape (the rotation taking straight up onto the shape's normal),
  kept facing forward and written as `n × 0.5 + 0.5` in red, green and blue (x right, y up), with
  the picture's alpha.
- Checked against WE 2.8.0.42 (capture 544, the bars picture at the defaults): red and green, what
  the texture keeps, agree to 0.2 and 0.65 of a step on average over the opaque pixels, flat at
  (127, 126, 254) as WE's; what differs is a 2–3 px line where a colour meets black (the details'
  edge, up to 19 in red and 43 in green) [?: WE's details there are smoother; not found].

OK writes the map as WE writes a generated one (RG88, its `.tex-json` `"format": "rg88"`, clamped, three mipmaps down to 64 px; the image importer's `EditorTEXEncoder.normalMap`)
named after the picture's texture with `_normal`, as WE does (`<texture>_normal`, plus the
content hash the editor's files carry), and makes it the layer's normal map in one undo step. The
layer's material and model are copied into the edits' files with the map as `g_Texture1`, and the
layer's `image` names the copy, so the wallpaper's files never change. WE draws a normal map only
with Lighting or Reflection on (its Generate button shows after one is turned on), so when neither
is, the copy turns Lighting on (`LIGHTING: 1`).

## Foreground Separation

An image layer's context menu has **Image Editing › Foreground Separation** (WE runs it only on
an image layer without effects, and says so otherwise). The window is WE's:

- **Editing**: **Polygon** (the default) or **Brush**. The brush marks foreground (white),
  background (black) or erases; Brush size is WE's 1–100 % (a diameter of up to 200 pixels per 400
  of the picture's long side, at least 200, growing as `((size − 1) / 99)^1.5`), and ⌃-dragging
  sideways changes it. The polygon tool adds a point per click, closes an outline on its first
  point, inserts a point when a side is clicked, moves a dragged point, and removes a point on
  ⌥-click or Delete (WE: the middle button); overlapping outlines cancel out, as WE fills them with
  xor, and Smoothing curves them through their points. **Reset Mask** clears the marks; Undo and
  Redo keep 30 steps.
- **Fine-tuning**: Fill gaps (0–100, 100 is off), Mask tolerance (−20–20, default −1), Smoothing
  (0–5, default 1) and Quality level (0–2, default 1).
- **View**: Original, Foreground & Original (the original faded under it when *Improve visibility*
  is on), Foreground, Background; the Mask (M) over it at Mask opacity (10–100 %, default 50);
  Reset View. **Recalculate** (R) and **Auto Recalculate**, on by default.

How the mask is made (`ForegroundSeparator`, WE's `performGrabCut`):

- With polygons, the mask is their inside, as WE's polygon tool (no GrabCut).
- With the brush, the marks are GrabCut's sure foreground and background (OpenCV's `grabCut`:
  five-component colour mixtures, gamma 50, the min cut of `MaxFlowGraph`), at the Quality
  level's size: 512 pixels on the long side, 1024, or the picture's own.
- **The automatic part.** WE's GrabCut starts from the strokes alone. Here it starts from the
  objects macOS's Vision finds in front of the picture's background
  (`VNGenerateForegroundInstanceMaskRequest`, on the Mac, nothing downloaded): the unmarked
  pixels are probably foreground where the objects the foreground strokes touch are (all of them
  before there are strokes), so a picture is separated before anything is drawn, and the brush or
  the polygons correct it.
- Smoothing blurs the mask at that size; Mask tolerance grows (or shrinks) it by as many pixels at
  that size; the edge is softened by a pixel.

OK asks WE's question and then, in one undo step, gives the layer the **background** (the picture
with the foreground's area filled from around it, as WE's "blurred area": Telea at a fifth of the
working size, radius 5 % of that picture's long side, 4–32 pixels) and adds the **foreground** (the
picture with the mask as its alpha) as a new image layer just above it, with the layer's place,
size, parent and look. Both pictures are PNGs with the editor's files; the layer's material is
copied for each.

## Character Sheet Creation

**Image Editing › Character Sheet Creation** (WE's Puppet Sheet Creation window) splits a
cut-out character into limbs for Puppet Warp
([character sheets](https://docs.wallpaperengine.io/en/scene/puppet-warp/charactersheet.html)):

- The **hierarchy** starts with the **Body**, which always exists. **Add Limb** asks for a name and
  adds the limb under the selected one; a limb's × removes it, its own limbs moving up under its
  parent. Each limb is a Foreground Separation (the same tools, Fill gaps at WE's 15) of the
  picture it is cut from, as WE's hierarchy works it out (`CharacterSheet.sources`): the first limb
  under another is cut from that limb, a later one from what the limb before it left, so a limb
  already cut away is ignored. With Fill gaps on, what a limb leaves is filled only within Fill
  gaps' reach (256 pixels at 100 %, at the working size) of the opaque picture left, so a limb
  sticking out of the body leaves transparency, not a smear.
- **OK** asks WE's question and collects WE's pieces (`CharacterSheet.pieces`): what is left of
  each limb that has limbs under it (after its last one), and every limb without. Each is cut to
  its opaque pixels and laid out on one transparent texture with WE's spacing (an eighth of the
  pieces' mean side, 30–200 pixels), the tallest first, in rows as wide as gives the squarest
  sheet ("place them into a square", WE's guide). The sheet, `<texture>_sheet`, replaces the
  layer (WE: "The existing layer will be removed along with any effects or settings") as a new
  image layer in its place (at the scene's centre, without the old image's `cropoffset`, as WE 2.8.0.42 puts it; capture 545 also checked the layout: a 512 × 512 picture gives a 64 px margin and gaps), in one undo step, and the Puppet Warp editor opens on it, where WE's
  guide continues (mesh, skeleton, weights, then the reference pose).
