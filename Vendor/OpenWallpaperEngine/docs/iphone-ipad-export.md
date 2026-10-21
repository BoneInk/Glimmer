# iPhone & iPad Export

**iPhone & iPad Export** is a tab of Scene Edit / Export (Wallpaper | Screen Saver |
iPhone & iPad Export | Android Export). It frames a scene or video wallpaper as an iPhone or iPad
lock screen and exports it as a Live Photo, which iOS and iPadOS 17 or later can set as a moving
lock screen. All exporting happens in Scene Edit / Export; the library has no export command.
Web wallpapers don't show the tab. How it is built: [`architecture.md`](architecture.md),
"Isolated edits" and "Live Photo export".

## Videos

A video wallpaper (an MP4, M4V or MOV file in the library) opens Scene Edit / Export on its
export and screen saver tabs; it has no Wallpaper tab. Its Live Photo is made the same way as a
scene's, from the video's own frames instead of a render: the crop (drag and zoom), the clip with
the most motion, the sharpest still and the blend at both ends all apply, and the clip loops back
to the video's start when it runs past its end. A video has no layers, properties or parallax, so
those sections aren't shown. A WebM or remote video shows the tab with why it can't be used.

## Your desktop doesn't change

The tab runs its own private copy of the wallpaper, started from the wallpaper's properties and
scene edits when it opens. Changing user properties, hiding, moving, resizing,
recolouring or fading layers, blending and effects there changes only the preview and the
export. The desktop, its properties and the Wallpaper Editor's edits stay as they were.

## Framing

- **Device**: any of 33 iPhones and 30 iPads with Live Photo lock screens. Type a name, family,
  year or resolution to find one; the last choice is kept. The photo has that device's exact
  pixels, in portrait; the movie is the same picture at most 1920 pixels tall, the largest the
  lock screen plays.
- **Show Lock Screen Guide** draws the clock and date where the device shows them. For an iPad,
  **Preview in Landscape** shows the part iPadOS keeps when the iPad is turned.
- Drag the preview to move the picture; pinch or **Zoom** to zoom in.
- **Parallax Position**: for a scene that follows the pointer (camera parallax, a depth parallax
  effect, or a shader that reads the pointer), a small pad shaped like the screen sets where the
  pointer rests in the Live Photo. **Reset to Center** puts it back. Other scenes say they don't
  follow the pointer.

## The clip

A Live Photo moves for up to 3 seconds. The scene's first seconds are measured, and the clip moves
to its 1–3 s with the most motion, avoiding a cut in the middle of a burst; the **Motion**
timeline shows it and can be dragged (**Clip Start**, **Clip Length**). **Preview Clip** plays it
in the frame; **Show Live Wallpaper** goes back.

The still photo is the sharpest frame near the middle of the clip (never in its first half
second, which the lock screen won't play from), at full resolution, and the movie blends in from
it and back into it, so the Live Photo never jumps. The movie is 8-bit HEVC at 30 fps, at most
1920 pixels tall, at a bitrate for its size (**Quality**). The clock, day and date layers are left
out, since the lock screen draws its own, and the export is silent.

## Motion on the lock screen

Photos takes any photo and movie that share a content identifier as a Live Photo, but the lock
screen of iOS and iPadOS 17 or later plays one as a moving wallpaper only when its movie looks
like the camera's; otherwise it says "Motion Not Available". Apple doesn't document what it
checks. The export writes what the camera writes and what others found the lock screen needs: a
`live-photo-info` metadata track with a sample at every frame, and the still's moment
(still-image-time with the still's transform) as a sample in the 600 timescale, both referring
to the video; HEVC; a movie at most 1920 pixels on its long side; and the still at least half a
second in. A clip of 1–3 s is within what the lock screen plays (up to about 5 s).

## Exporting

The tab's right-hand panel is the selected layer's **Layer Adjustments**, and the export's
progress while it renders. Everything above, the user properties and the exports are in
**Export Settings** (the toolbar's share button): **Send with AirDrop**, **Save…** and
**Export More with These Settings…**.

**Send with AirDrop** sends the Live Photo as one Live Photo bundle (a `.pvt` package with the
photo, the movie and a `metadata.plist`, as Photos sends one), which Photos on the iPhone or
iPad imports as a Live Photo; the photo and the movie sent as two files would arrive as a separate
photo and video. **Save…** writes the photo and the movie as two files; import both into Photos
together to get the Live Photo.

**Also Save to Photos Album** (off by default) also adds each export to an album in the Mac's
Photos library ("Open Wallpaper Engine" unless you name another; made when missing). With
iCloud Photos on, it reaches your iPhone and iPad. Photos access is asked for only when you turn
it on; if it's refused, the switch turns off and offers **Open Privacy Settings**. A save that
fails is reported without failing the export. Apps can't write iCloud Shared Albums, so this is a
regular album.

## Export More with These Settings

**Export More with These Settings…** (in Export Settings) makes Live Photos of other
wallpapers with the tab's device, quality and clip length. Pick them from the library (search, a
type filter, tick as many as you like; the wallpaper being edited starts ticked, and wallpapers that
can't be made into a Live Photo are shown with why), then where they go: **Save to Folder** (the
last folder is kept) and/or **Also Save to Photos Album**. Only the wallpaper being edited keeps
its crop, clip, parallax position, layer edits and properties; the others are centred at the
device's size, exported as authored, and, when the tab's clip is the automatic one, each starts at
its own window with the most motion.

The batch runs as a queue with overall and per-wallpaper progress, and can be cancelled. Scenes
render one at a time (they use the GPU) while videos are read beside them. Names are the
wallpapers' titles, made unique within the batch and the folder. **AirDrop All** sends every
finished Live Photo in one AirDrop share, each as its Live Photo bundle, so Photos on the iPhone
or iPad imports them as Live Photos; each finished one also has its own AirDrop button.

On the iPhone or iPad: touch and hold the Lock Screen, tap **+** (or Customise › Add New), choose
**Photos**, pick the Live Photo, check that the Live Photo button (the concentric circles, bottom
left) is on and not crossed out, and tap **Add**. Lock the device and wake it: the picture
moves once. From Photos: open the photo, Share › Use as Wallpaper.

MCP clients get `devices_list`, `export_settings_get` and `export_live_photo` ([`mcp.md`](mcp.md)).
