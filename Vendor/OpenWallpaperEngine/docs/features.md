# Features

Everything Open Wallpaper Engine does, by area. The [README](../README.md) has the highlights.

## Supported wallpaper types

| Type | Status |
|------|--------|
| Video (.mp4, .mov, .m4v, .webm) | Working; HDR10 and HLG videos in HDR on the Metal video path |
| Web (HTML/WebGL) | Working (WebKit, or the optional Chromium engine) |
| Scene — image layers & timelines | Working (Metal) |
| Scene — DXT1/DXT3/DXT5 textures | Working (Metal GPU decode) |
| Scene — TEXS sprites / alpha timelines | Working |
| Scene — sprite particles | Working |
| Scene — advanced particles | Working |
| Scene — Wallpaper Engine and Workshop effects (WE's own shaders) | Working |
| Scene — SceneScript | Working |
| Scene — 3D models / rigging / puppet warp | Working |
| Application | Not supported |

## Using the features

### Edit Wallpapers

- **Scene Edit / Export** (Details › Scene Edit / Export, ⌥⌘I) has four tabs, and every export happens there. **Wallpaper** edits the running wallpaper: show, hide, move, resize, recolour and fade layers and change effects, live on the desktop. **Screen Saver** makes a version of the wallpaper your screen saver, drawn live ([docs/screen-saver.md](screen-saver.md)). **iPhone & iPad Export** turns it into a Live Photo lock screen ([docs/iphone-ipad-export.md](iphone-ipad-export.md)). **Android Export** writes it as a package for Wallpaper Engine's Android app ([docs/android-export.md](android-export.md)). A video wallpaper opens it on its screen saver and export tabs.
- **Wallpaper Editor** (Edit Wallpaper in the library's bottom bar, ⌥⌘E) is an editor in the spirit of Wallpaper Engine's, running as an app of its own: add, arrange and group layers; add effects and particle systems from Wallpaper Engine's catalogs, with previews the app renders in the background once its assets are installed; animate on a timeline; write SceneScript with autocomplete; author user properties; edit particle systems and Puppet Warp rigs (with their clipping masks). The editor works on a draft: edits show in its canvas and can all be undone, and nothing else runs them (the desktop, the screen saver, playlists) until **File › Save** (⌘S), which every display showing the wallpaper then shows; **Save as New Wallpaper** (⇧⌘S) adds a new wallpaper with them to the library instead, and **Revert to Saved** goes back to the last save. Closing or quitting with unsaved changes asks to save them, and a draft survives a crash: the editor offers to resume it. Edits are kept beside the wallpaper, never in its files. The **View** menu has Wallpaper Engine's Reset Camera, Preview Aspect Ratio, Show Grid, Show Selection Box, Show Debug (particle collision and control points), Show Desktop Preview, Show Phone Preview and Low FPS Simulation (the canvas at 22 frames a second); the grid, selection box, previews and Low FPS Simulation are also buttons beside the canvas's zoom. Several layers can be selected (Shift- or ⌘-click, or a marquee dragged from an empty place) and moved, nudged, deleted or duplicated together; Option-click picks the layer under the selected one. A layer's context menu has Wallpaper Engine's Center, Align with Background, Rotate CW and CCW, Copy and Paste Transforms, Move to Custom Position and Copy and Paste All Effects; an effect's menu has Copy, Paste, Paste Effect Settings and Duplicate. An effect open in the inspector shows Wallpaper Engine's gizmos on the canvas: Perspective's four corners, Spin's and Twirl's centre and ellipse, Swing's hinge and page, and Advanced Fluid Simulation's point and line emitters with their size and direction; a centre or other position setting is a point to drag, and a direction setting is a dial. The canvas's gizmo has Wallpaper Engine's **Multi** (2D scenes), **Translate**, **Rotate** and **Scale** modes in its upper left corner, with **World Space** and **Local Space** for Translate and Rotate; in a 3D scene it sits on the selected object, moves, turns and scales it along x, y and z, and clicking near an object picks it. The toolbar's **Thumbnail** menu makes the library thumbnail from the canvas as Wallpaper Engine's snapshot tool does: **Take Snapshot** draws the scene's centre square (up to 1024 pixels) into `preview.jpg`, and **Record GIF** records it into `preview.gif` in one of Wallpaper Engine's six GIF formats (256 pixels at 25 FPS for 2 seconds, 256 at 12 FPS for 4 seconds or 128 at 25 FPS for 8 seconds, each with or without dithering), made smaller until it fits Steam's 1 MB. The result shows with **Use** and **Discard**; Save as New Wallpaper gives the new wallpaper the one in use, and File › Save writes it into a wallpaper of your own (not a Workshop item). Without one, the wallpaper keeps its preview. With nothing selected, the inspector shows Wallpaper Engine's **Scene Options** (General, Bloom with HDR bloom, Camera with shake and parallax, Distance and Height Fog, Physics) and **Project Settings** (title, resolution). An image layer's inspector also has Wallpaper Engine's parallax depth, brightness, Miscellaneous (perspective rendering, click events and propagation, copy background, alignment), Clamp UVs, Lighting & Reflections (lighting, reflection, normal map, material values) and Variants (Wallpaper Engine's texture variant groups and options, Replace or Alpha blended, each on a checkbox or combo property, with a Preview on the canvas). A sound layer's inspector edits Wallpaper Engine's sound properties (mode, volume, random times, mute in editor, start silent, spatialization).
- **New Wallpaper…** (the library's **Add Wallpaper** menu) is Wallpaper Engine's editor welcome page and template wizard: **From a Picture** makes a scene the picture fills (and offers to resize a picture that isn't a display size to one of Wallpaper Engine's sizes), **From a Template** makes Wallpaper Engine's Empty scene or a copy of one of the 2D templates of your Wallpaper Engine copy, and **Import Folder** makes a web wallpaper of a folder with an `index.html`. A new scene opens in the Wallpaper Editor.
- **Adding to a scene** — **Add Layer** has Wallpaper Engine's Add Asset choices: image, text, particle system, sound, **Light** (point, spot, tube or directional), **Model**, **Camera**, **Full Composition Layer**, **Solid Placeholder** and **Preset**. Adding images asks for Wallpaper Engine's importer options first (texture format, Pixel Art Optimization, No Mip Maps, Clamp UVs). The asset browser lists the project's files in Wallpaper Engine's folders and has a Project menu with **New Material…** and **Clean Project…**.
- **3D models** — **Add Layer › Model › Import FBX or OBJ…** (or a drop on the canvas) compiles the file into Wallpaper Engine's `.mdl` with its materials, textures, bones, skin weights and animations, and **Configure Model…** opens Wallpaper Engine's Model Editor (animation clips, materials, attachments and the model's import options) ([docs/model-import.md](model-import.md)).
- **Your own effects and shaders** — **Add Effect** has Wallpaper Engine's **New**, **Duplicate** and **My Effects**. An editable effect lists its shaders in the inspector: **Edit** opens the **Shader Editor** under the canvas, with Wallpaper Engine's shader dialect highlighted and completed, its Snippets menu, **Apply** (⌘↩) and each translation error on its line; each material's **Shader Options** set its blending, culling, depth test and depth write.
- **Image Editing** (an image layer's context menu) — Wallpaper Engine's **Foreground Separation**, **Character Sheet Creation** and **Normal Map Generation** (the inspector's Normal Map section), run on your Mac ([docs/image-tools.md](image-tools.md)).
- **Scripts and properties** — the script editor has Wallpaper Engine's **Snippets** (Insert Function, Insert Property, Import Base Module) and Edit menus, **Run / Stop Preview** and the console's options; scripts see `engine.isRunningInEditor()` as true. User properties can be Wallpaper Engine's Texture, User Shortcut and Group types, with a folder's fetch mode and a file's type.
- **Show Stats** in the editor's toolbar (Never, Auto, Always) is Wallpaper Engine's "Stats per frame" overlay: FPS, GPU time, texture memory, lights, script time, expensive effects, draw calls and the rest, red past Wallpaper Engine's limits. Scene Edit / Export shows FPS, GPU time and texture memory under its preview.
- **Depth maps** — with the Depth Map Generation plugin, both editors make depth maps on your Mac: **Scene › Depth Parallax** applies Wallpaper Engine's Depth Parallax to the whole scene, and a layer's **Create Mask from Depth Map** turns its depth map into the layer's opacity (**Layer Opacity**) or the mask of one of its effects ([docs/depth-maps.md](depth-maps.md)).

### Several Displays

**Displays** in the toolbar sets Wallpaper Engine's display layouts: a wallpaper per display, one stretched across every display, or one cloned onto every display, plus stretch and clone groups of some displays, flipped clones, muted displays and displays split into regions, saved as profiles. A clone or stretch renders once. Each display has a miniature of what it shows. [docs/display-layouts.md](display-layouts.md)

### Export to iPhone, iPad and Android

- **iPhone & iPad** — Scene Edit / Export's iPhone & iPad Export tab frames a scene or a video as any of 63 iPhones' and iPads' lock screens and exports a Live Photo, with AirDrop, to a folder or into a Photos album, without changing your desktop. **Export More with These Settings…** makes Live Photos of other wallpapers from the library in one batch, with **AirDrop All**. [docs/iphone-ipad-export.md](iphone-ipad-export.md)
- **Android** — Scene Edit / Export's Android Export tab writes Wallpaper Engine's `.mpkg` packages for its Android app: scenes as live **Dynamic** scenes or a **Pre-Rendered** video, videos byte for byte as they are. **Export More with These Settings…** packs other wallpapers from the library in one batch, and **Send over Wi-Fi** lets the device download them from the Mac with a QR code. [docs/android-export.md](android-export.md)

### Theme macOS

Settings › General › **Theming** lets the menu bar (a tint that fades out below it), the accent and highlight colours, tinted icons and folders follow the scheme colour of the wallpaper on the main display, and restores your own colours when it's turned off. macOS has only eight accent colours, so you choose whether the system accent becomes the nearest of them or Multicolor; Open Wallpaper Engine's own windows can use the exact colour. [docs/theming.md](theming.md)

### Control from MCP Clients

Install the **MCP Server** plugin in *Settings › Plugins* and MCP clients (AI assistants and other tools that speak the Model Context Protocol) can do what the app's own controls do, through a local connection only your account can open: set wallpapers, playback, volume, user properties, playlists and settings; edit scenes through the Wallpaper Editor's edit model (in its draft, shown in an open editor window, with Undo, and on the displays once saved); export Live Photos; and set up the screen saver and the lock-screen picture. Setup, every tool and the security model: [docs/mcp.md](mcp.md).

## Everything that is supported

### Setup, library & updates
- **Setup assistant** — on first launch, a few skippable steps set the language, show the privacy notes, set up SteamCMD, the Steam login and an optional Steam Web API key, install the Wallpaper Engine assets and bring in your wallpapers.
- **SteamCMD sets itself up** — when none is found, the app downloads Valve's SteamCMD; Homebrew's or Steam's is used if present.
- **Wallpaper Engine assets from your own Steam copy** — installed through SteamCMD after you sign in, optionally with Wallpaper Engine's default wallpapers.
- **Imports** — your Workshop collections and subscriptions (read from Steam's Web API), the Workshop items of an existing Steam library, and wallpaper folders.
- **Wallpaper Engine favourites** — Wallpaper Engine keeps its favourites in your Steam account (they are your Workshop favourites), not in its folder. Once the assets are installed or a Wallpaper Engine folder is chosen, the setup assistant and Settings › Assets ask whether to add them to My Favourites, showing how many are new; your current favourites stay, and importing again adds only new ones. It needs your Steam Web API key and the account's SteamID, found in Steam's own files for the SteamCMD login or for the Steam folder the chosen Wallpaper Engine install is in. *Import Wallpaper Engine Favourites…* in Settings › Assets checks again.
- **The [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)** — guides, settings reference and troubleshooting; Support & FAQ in the app opens it.
- **Dock and menu bar** — Settings › General › macOS has *Show in Dock* and *Show in Menu Bar*; with both off, the app keeps running in the background once its windows close.
- **Automatic updates** — signed updates install by themselves (on quit, after 10 minutes away, or within a day, then a quick relaunch restores your wallpapers). Settings › Updates lets you only check, or turn checks off, and opt into beta updates. Check for Updates… is in the app menu and the menu bar menu.

### Scene rendering
- **Wallpaper Engine's own shaders** — layers, effects and materials now draw through each wallpaper's original shaders, translated to Metal, including effects that Workshop authors made themselves.
- Composition, fullscreen and solid layers, layers that sample other layers, all 33 blend modes, and more effect masks.
- **Faithful text layout** — text is sized, aligned and positioned as in Wallpaper Engine, with outline, blur and drop-shadow font effects, letter spacing and an opaque background, laid out again when a script changes it.
- Texture variants (Wallpaper Engine 2.6): textures with Replace and Alpha-blended options that a checkbox or combo property swaps in, composed as Wallpaper Engine loads them.
- Texture user properties (`scenetexture`): a picture or video you pick replaces an image layer's image.
- Scene gravity and wind (Physics options) and `clearenabled` (frames drawn over the last one), as in Wallpaper Engine.
- **Timelines** — keyframe and texture animations follow Wallpaper Engine's single, loop and mirror rules.
- Colour lookup tables, Wallpaper Engine's colour correction, and the image filter and colour options in a wallpaper's properties.
- **Puppet Warp** images posed by their animations, with blend rules (a bone pulled toward another by a keyed weight), bone physics (springs, gravity, limits), kinematic chains (limbs reaching for an IK target, ropes hanging and swinging in the scene's gravity and wind), clipping masks and objects attached to their bones.

### 3D & lighting
- **3D models** with skinning, animation layers, morph targets and root motion; every pass of a model's material, and every fur shell of Wallpaper Engine's fur shader.
- Cursor events on 3D models and named hit boxes on models and Puppet Warp images (`CursorEvent.hitBox`).
- Perspective scene cameras with camera paths, fades and shake; 2D layers sit in depth.
- **Scene lights** with light cookies, shadows, planar reflections, distance and height fog, and volumetric lights.
- **HDR** — HDR scenes render with Wallpaper Engine's HDR bloom, and the "Ultra (Display HDR)" quality outputs EDR on displays that can show it; with it, HDR10 (PQ) and HLG video wallpapers on the Metal video path reach the display in HDR too.

### Particles
- **GPU particles** — every particle system is simulated on the GPU, in 3D, with 3D control points (on the emitter, the cursor, a scene position or the parent system's point, raw or carried into the child's space).
- Child systems, placed by their links in 3D, including ones triggered by their parent's particles; emitter bursts, delays and periodic emission; emitting from a layer's image, sampled again every second while it changes (a video, a texture animation, a script's texture), its points following a Puppet Warp layer's bones and, as an option, launched with the layer's motion.
- Collision, including with a model's bones and a Puppet Warp image's rig, audio response, and rotation about every axis.
- Particle settings bound to a wallpaper's user properties.
- Every Wallpaper Engine initializer and operator, with its defaults; colour lists of any length.

### SceneScript & media
- A complete **SceneScript runtime** — modules, the scene/layer/effect/material object model, animation events, `localStorage`, and cursor hit testing, with each wallpaper's scripts on their own thread.
- Scripts can create layers, particle systems and sounds, move the fog, drive bloom, pose puppets and models, play animation layers' own timelines, and run an effect's functions (`executeMaterialFunction`).
- **Now Playing** — scenes and web wallpapers receive the current track and playback state (macOS 15.4 or later). The **Media blocklist** (Settings › Optimizations › Audio) hides chosen apps' media from wallpapers.
- **Web wallpaper devtools** (Settings › Optimizations › Developer Tools, off by default, for the session only): Safari's Web Inspector for WebKit pages, Chromium's DevTools on 127.0.0.1:9222 for Chromium ones.
- Web wallpapers receive their user properties and live audio. Dropdown values reach the page with the type their author gave them. Folder (`directory`) properties hand the page the folder's pictures or videos, all of them and each change (`fetchall`) or one at random on request (`ondemand`), and pages open chosen files as `'file:///' + path` in both web engines.

### Audio
- The audio spectrum is computed the way Wallpaper Engine computes it, in stereo.
- **Audio recording device** and **Recording volume** (Settings › Optimizations › Audio): audio-reactive wallpapers can hear a microphone or a loopback device instead of the sound the Mac plays (it asks for the Microphone permission).
- **Sound layers** play on the scene's clock, with **spatial sound** placed as in Wallpaper Engine.

### Displays & playback
- **Display layouts** — per display, stretch, clone, groups, flip, mute, splits and profiles, as in Wallpaper Engine ([docs/display-layouts.md](display-layouts.md)).
- **Copy to** and **Swap with** (right-click a display under *Wallpaper per display*) copy a display's wallpaper, with its properties and display options, to another display, or swap two displays' wallpapers.
- **Pause per Display** or **Pause All**, with the playback rules checked for each display, including Wallpaper Engine's maximized-window rule. Wallpapers pause while the screen is locked or another user is switched in.
- **Application Rules** — pause, stop or mute wallpapers, or load a wallpaper, playlist or display profile, while an app is running, focused, maximized, in full screen or playing audio.
- **Laptop on battery** — Keep Running, Pause or Stop while the Mac runs on battery, as in Wallpaper Engine (shown on Macs with a battery). **On battery: use a lower quality preset** (off by default) draws wallpapers with a Low, Medium or High preset and an optional 15, 20 or 30 FPS cap while the Mac is on battery or in Low Power Mode, and switches back to your own settings on power, live, without reloading the wallpaper. It never raises a setting you have lower, and the Preset control and saved settings stay yours.
- **Playlists** as in Wallpaper Engine: change wallpaper on a timer, at login, by time of day or by day of week; begin with the first wallpaper, an intro played at startup only, changing while paused; and Wallpaper Engine's 27 **transitions** between wallpapers (or a random one), drawn on the GPU, also for wallpapers chosen in the library ([docs/playlists.md](playlists.md)).
- **Hotkeys** for Wallpaper Engine's actions (including Stop wallpapers), for each playlist, for a wallpaper on a display (its context menu's Assign Hotkey…) and for each display profile (the Displays sheet's Profile › Hotkeys), system-wide, with no Accessibility permission; **Next and Previous Wallpaper** in the menu bar menu.
- **Stop Wallpapers** (menu bar menu, Playback menu, a hotkey): unloads every wallpaper, freeing its CPU, GPU and memory, and shows the macOS desktop picture until Resume.
- **Take Screenshot** of the wallpaper alone, at the display's size, 4K or 8K.
- **Play in Window** (a wallpaper's context menu): the wallpaper in a resizable window beside the desktop, as Wallpaper Engine's Full HD, Phone or Maximized Preview, taking the mouse and keyboard.
- **Command line**: Wallpaper Engine's `-control` commands (pause, stop, play, mute, open a wallpaper on a display or in a window, next, close, playlists, profiles, properties, desktop icons, get the wallpaper), in WE's spelling or as `--control open-wallpaper …` ([docs/command-line.md](command-line.md)).
- Per-wallpaper **position, zoom and flip** on each display, and a video's playback rate.
- **Video loading** (Settings › Optimizations › Video): From disk (the default) or In memory, Wallpaper Engine's `videoreadmode`, which stops a looping video from reading its file from the disk again on every loop.
- Per-display user properties, with "Sync properties across displays".
- A wallpaper shown on several displays renders once and is presented on each.
- Quality settings: Render Resolution (Your Display, 4K, Full) with Upscaling (Render Scale 50–75 %), Texture Resolution, Effect Detail (Match Display), reflections, shadows and volumetrics.
- **Safe restart** — a wallpaper that stalled or crashed the app is skipped on the next launch and marked in the library.
- **Caches** (Settings › Performance) — the app's caches clean up what has been unused for 60 days, and **Clear Caches…** deletes them except what the wallpapers on screen use.

### Screen saver, lock screen & theming
- **Screen saver** — a plugin installs a macOS screen saver that draws your wallpaper live while it runs, with nothing recorded: scenes, videos, and web and WebM wallpapers through the Chromium engine. With **Screen Saver Same as Wallpaper** (Settings › General, on by default) each display's screen saver shows that display's own wallpaper; **Set as Screen Saver** in a wallpaper's menu, or Scene Edit / Export's Screen Saver tab with your own layer and property choices, sets one instead. When the app isn't running, the screen saver starts it in the background ([docs/screen-saver.md](screen-saver.md)).
- **Lock screen** — each display's desktop picture, which the lock screen shows, is a picture of its wallpaper.
- **Theming** — the menu bar, accent, tinted icons and folders follow the wallpaper's colour, and the app's own windows can use the exact colour ([docs/theming.md](theming.md)).

### Workshop & library
- Wallpaper Engine's Workshop filters: Show Only, a resolution filter, genres combined with AND/OR, a Wallpaper/Preset category, and tags on every card.
- Wallpaper Engine's Workshop sorts: Top Rated, Most Popular (Year, Month, Week, Today), Most Recent, Most Up Votes and Most Subscriptions, Most Popular (Year) first. The sorts of the signed-in Steam account (My Favorites, Voted Up, Friends' Favorites, Created By Friends, Created By Followed Users) aren't offered: Wallpaper Engine reads them through the Steam client.
- Wallpaper Engine's Workshop search options: a "quoted phrase" is matched as a phrase by Steam, and **Exact phrase** (shown by the search field once the search has two words) quotes the whole search. **Hide Anime** (the filter sidebar's Filter Settings, Wallpaper Engine's Workshop Filter Settings) leaves out the Anime, MMD, Girls, Guys and Music genres, all but those you tick; Reset Filters keeps it. As in Wallpaper Engine, both are Workshop-only: the Installed search matches words anywhere, and Discover's lists have no search or filter.
- **Discover** — Wallpaper Engine's curated Workshop lists; Workshop items can be blocked (or their author), reported in Steam, and lead to related wallpapers.
- **Set as Wallpaper** and **Set as Screen Saver** in the Installed, Discover and Workshop context menus; a Workshop item downloads first.
- **Installed** is one scrolling grid of the whole library; Select All (⌘A) selects what the folder shown lists.
- **Downloads** are grouped into In Progress, Queued, Failed and Completed, with speed and time left; SteamCMD stays signed in between downloads, so a queue runs back to back.
- **Folders in Installed**, as in Wallpaper Engine: *Create Folder…* (the grid's context menu, or the bottom bar's button) makes a folder in the folder shown; folders nest, show first in the grid and open with a click, with breadcrumbs (and ⌘[) back to the top level. A folder's menu has Rename…, Change Icon, Change Color (Wallpaper Engine's 30 icons and 9 colours; an icon with an open variant, such as the rocket, shows it on the breadcrumb of the folder shown and while something is dragged over the folder), Move to Folder and Remove Folder…, which removes its subfolders too and puts their wallpapers back at the top level; no wallpaper is ever deleted. Drag wallpapers (the selection, when the dragged one is in it) or folders onto a folder or a breadcrumb, or use **Move to Folder** in a wallpaper's menu; its **Create Folder** makes a new folder with the wallpaper (or the selection) in it, as Finder's New Folder with Selection. A wallpaper is in one folder at most, and the top level lists the wallpapers in none. Search and filters apply within the folder shown, as in Wallpaper Engine; favourites and sorting work as before, and the Name sort's direction orders the folders too. Folders are kept in the settings by the favourites' keys (`workshop-<id>` for a Workshop item), so a wallpaper downloaded again is back in its folder, and they travel with *Export Settings…*; importing settings merges them. The setup assistant and Settings › Assets offer *Also import your Wallpaper Engine folders?* when the Wallpaper Engine folder chosen for the assets has folders in its `config.json`: they merge into yours, never replacing anything, and importing again adds nothing ([getting-started.md](getting-started.md#wallpaper-engine-folders)).
- **Workshop preset items** play their base wallpaper with the preset's values, as in Wallpaper Engine.
- **Library folders** — add folders of wallpapers beside Wallpaper Storage (Settings › Assets); they're watched and never written to.
- **Animated previews** — wallpaper tiles in the library play their Workshop preview animation (GIF), so you can see a wallpaper move before applying it. They play only while visible, and pause when the window is hidden or in Low Power Mode.
- Installed wallpapers show and filter by their Workshop tags; asset-only and dependency-only items stay out of Installed.
- Installed sorts, in Wallpaper Engine's order: Name, Rating, Favorite (favourites first, then by name), File Size, Date Downloaded and Last Updated (when the Workshop item last changed on Steam, else when its folder last changed; local wallpapers, which have no update date, come last). Wallpaper Engine's *Last Date Modified* belongs to its editor's Open Project list, not to the library.
- Missing Workshop dependencies download automatically, and unused ones are removed after a delete. Every download lands in the Wallpaper Storage folder.
- **Reset** in Details returns a wallpaper's properties, and its scene edits, to the defaults its author set.
- Property conditions, text rows and slider formats from the wallpaper's settings are honoured.
- **User shortcuts** (Wallpaper Engine 2.7's `usershortcut` property): a wallpaper's clickable element opens what you assign it in Details: a file in its default app (an app with its arguments), a folder in Finder, a website in your browser, or a command run in zsh with your login environment. Only you choose what it opens: the author's project.json, presets and Share JSON never bind one, and a binding copied from another Mac doesn't open until you assign it again. Scripts get `engine.openUserShortcut(name)` (true when something opened) and `{isbound, commandtype, file}` in their user properties, as in Wallpaper Engine; web wallpapers have no user shortcuts there either.
- **Author translations** (project.json `general.localization`): a wallpaper's property titles, text rows and combo choices written as `ui_` keys show in the app's language, from the author's own tables, as in Wallpaper Engine: Wallpaper Engine's own text first, then the author's, then English, then the key. In Details, Scene Edit / Export, the Wallpaper Editor's property choices and the MCP property listing.
- Steam passwords are never stored, and the Steam Web API key is kept in the Keychain.

### Interface & languages
- **Liquid Glass** on macOS 26 — a native split view, toolbar and inspector with glass controls. Earlier macOS versions keep the familiar look.
- **15 languages besides English**: German, French, Spanish, Brazilian Portuguese, Italian, Japanese, Korean, Simplified and Traditional Chinese, Russian, Polish, Turkish, Ukrainian, Arabic and Hindi, chosen from the Language picker in Settings.
- A new app icon, and a menu bar icon that follows the menu bar's appearance.
