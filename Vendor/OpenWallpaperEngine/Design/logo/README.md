# Logo

The artwork is a redesign of [Klaus Zhu](https://github.com/klauszhu1105)'s original Open Wallpaper Engine logo: one monitor on a stand, with a six-tooth gear and a round hole on its screen, in blue. The redesign by [Deepratna Awale](https://github.com/deepratna-awale) redraws it as vector layers for macOS 26's Liquid Glass icons.

## Files

| Path | What it is |
|---|---|
| `make_svgs.py` | The single source of the geometry and palettes. It writes every SVG in `svg/`. |
| `svg/monitor.svg`, `screen.svg`, `gear.svg`, `hole.svg` | App icon layers on the 1024 pt Icon Composer canvas. They use flat, solid fills only, with no gradient, baked shadow, glass or highlight. |
| `svg/logo-flat.svg` | The un-glassed logo on a clear background, used for the placeholder image and the docs. |
| `svg/menubar-template.svg` | The 18 × 18 pt menu bar silhouette: the monitor outline, a solid gear with its hole, and the stand. |
| `render.swift` | Rasterises the SVGs, puts a full-bleed icon on the pre-26 macOS icon grid (an 824/1024 body with a soft shadow), and centres the flat logo on a solid tile for the screen saver thumbnails. |
| `build.sh` | Regenerates every asset below. |

## Where the assets go

| Asset | Used by |
|---|---|
| `OpenWallpaperEngine/Resources/AppIcon.icon` | The Icon Composer bundle: `icon.json` plus the layer SVGs in `Assets/`. On macOS 26+ the system renders it with glass and its default, dark, clear and tinted looks. Its background is the solid `fill` in `icon.json`, which `build.sh` sets from the palette. |
| `Assets.xcassets/AppIcon.appiconset` | The macOS 14/15 fallback: `ictool`'s own rendering of `AppIcon.icon`, at 16–512 pt @1x/@2x. |
| `Assets.xcassets/OWEStatusIcon.imageset` | The menu bar icon: the template SVG, with preserved vector data and the template rendering intent, so macOS draws it white on dark bars and black on light ones. |
| `Assets.xcassets/we.placeholder.imageset`, `OpenWallpaperEngine.docc/.../OpenWallpaperEngine-icon@2x.png` | The flat logo. |
| `OpenWallpaperEngineSaver/thumbnail.png`, `thumbnail@2x.png` | The screen saver tile in System Settings: the flat logo on the palette's `background`, at 90 × 58 pt. The legacy `.saver` and the screen saver extension both bundle these files. |
| `OpenWallpaperEngineSaverExtension/Assets.xcassets/thumbnail.imageset` | The same tile at 107 × 65 pt, the size of the `thumbnail` image in Apple's own `com.apple.screensaver` extensions. |

Both icons use the name `AppIcon` (`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`). Xcode 26+ builds the `.icon` for macOS 26, and the asset catalog set for older systems.

## Regenerating

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer Design/logo/build.sh
```

You need Xcode 26 or newer. The script uses the `ictool` that ships inside Icon Composer (`Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`).

- To change a shape or colour, edit `make_svgs.py` and run the script. `LOGO_VARIANT=<key>` picks another entry of `PALETTES` for a one-off render.
- To change the glass, shadow or translucency, or the group order, open `AppIcon.icon` in Icon Composer. `build.sh` only replaces the layer SVGs in it and the `fill` in `icon.json`.

To preview any appearance, run:

```sh
ictool OpenWallpaperEngine/Resources/AppIcon.icon --export-image --output-file out.png \
  --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1
```

The renditions are `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and `TintedDark`.

## Light and dark looks

macOS 26 picks the look from the system appearance. The light look has a white
background, a black frame, a white screen and the blue gear. The dark look has a
graphite background, a light frame and a dark screen, with the same gear. The
light colours are `fill-specializations` in `AppIcon.icon/icon.json`; the dark
colours come from the palette in `make_svgs.py`. The macOS 14/15 fallback icon is
`ictool`'s Default rendering, which is the light look.

Tinted and Clear use Apple's standard mono glass: in the `tinted` appearance every
layer's fill is `automatic`, every layer is glass, and the groups use the default
translucency (0.5), neutral shadow and full opacity. The system supplies the colour.
