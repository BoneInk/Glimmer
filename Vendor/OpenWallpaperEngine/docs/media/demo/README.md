# Demo clips

Short looping clips of the app for the README, the docs and the wiki. Each clip comes as:

- `<name>.webm`: VP9, 1280 × 720, 30 fps, no sound, the end crossfaded into the start so it loops;
- `<name>.mp4`: H.264 of the same, for players without VP9;
- `<name>.webp`: an animated WebP preview (720 px wide, 12 fps), which GitHub shows inline;
- `<name>.png`: a still (poster) from the clip.

GitHub strips `<video>` from Markdown unless the file was uploaded as a GitHub attachment, and the
repository's own `.webm`/`.mp4` don't play inline. The READMEs therefore show the animated WebP and
link it to the `.webm`:

```markdown
[![Scene Edit / Export](docs/media/demo/scene-edit.webp)](docs/media/demo/scene-edit.webm)
```

Pages that can play video (the website) can use the `.webm` with the `.mp4` as a fallback and the
`.png` as `poster`.

## Clips

| Clip | Length | Shows | Wallpapers (Workshop id) |
| --- | --- | --- | --- |
| `hero` | 13.4 s | The Installed tab, a wallpaper picked and set with **Set as Wallpaper**, the desktop changing. | Verdant (3292333890) to PaRappa the Rapper (3159348391) |
| `wallpapers-in-motion` | 12.0 s | Four scenes running on the desktop: a particle sky, a 3D room with a real-time clock and day cycle, an animated 3D scene, a 3D solar system. | Meteors at Dawn (3413921910), Chill Japanese Room (3074485715), PaRappa the Rapper (3159348391), Solar system (3455121165) |
| `scene-edit` | 15.6 s | Scene Edit / Export's Wallpaper tab: the wallpaper's versions (background, matrix code, clock) and a layer switched while the desktop follows live. | Katana Girl with Hologram (3238423642) |
| `wallpaper-editor` | 14.4 s | The Wallpaper Editor: a text layer moved with the gizmo and undone, an image layer's inspector and its effect. | Chill Japanese Room (3074485715) |
| `live-photo-export` | 11.6 s | The iPhone & iPad Export tab rendering the Live Photo, with the element moved in the preview. | Katana Girl with Hologram (3238423642) |
| `android-export` | 10.6 s | The Android Export tab and its Export Settings: zoom, Pre-Rendered and Dynamic output. | Katana Girl with Hologram (3238423642) |
| `play-in-window` | 9.0 s | A scene in a Play in Window window over a live desktop wallpaper. | PaRappa the Rapper (3159348391) over Meteors at Dawn (3413921910) |

Every wallpaper shown is rated Everyone in its `project.json`.

## How they were made

- A Debug build (`SWIFT_OPTIMIZATION_LEVEL=-O`, whole-module) run as an isolated copy
  (`OWE_ISOLATED_STATE=demo`), so none of the user's own state was used, with a Wallpaper Storage
  folder holding only Everyone-rated wallpapers and their Workshop dependencies.
- Wallpapers were set from the UI or with `--control open-wallpaper` ([command-line.md](../../command-line.md)).
- Recorded on a 1920 × 1080 display with `screencapture -v -C -D <display>`, the pointer moved by a
  small CGEvent script with eased motion. The Dock stayed hidden.
- Cut with ffmpeg: trim, an eased zoom and pan (`zoompan`) on the part of the screen in use, a 0.6 to
  1 s crossfade of the end into the start, then VP9 (two-pass, constant quality) and H.264; the WebP
  previews with `img2webp`.

Not recorded: the screen saver (starting it on this Mac would lock the session), Workshop browsing
and downloads (they need a Steam login and a Steam Web API key), model import and the Shader Editor.
