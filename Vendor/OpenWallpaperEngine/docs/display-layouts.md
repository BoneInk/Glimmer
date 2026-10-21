# Display layouts

With more than one display, **Displays** in the main window's toolbar opens Display Settings:
each display drawn with its own shape and a miniature of what it shows. The layouts follow
Wallpaper Engine 2.8's multi-monitor model, and their names are Wallpaper Engine's. How it is
built: [`architecture.md`](architecture.md), "Display layouts".

Click a display to select it; hold Shift to select several. Setting a wallpaper sets it on the
selected displays.

## Layout

The **Layout** menu sets how the displays share wallpapers:

- **Wallpaper per display** (the default): each display has its own wallpaper. Wallpapers chosen
  before layouts existed stay as they were.
- **Stretch single wallpaper**: one wallpaper spans every display (the main display's choice).
- **Clone single wallpaper**: one wallpaper is shown on every display.

Under Wallpaper per display, some displays can be grouped while the others keep their own
wallpapers. Right-click a display (with the others to group selected):

- **Add Stretch Group** / **Add Clone Group**: the displays stretch or clone one wallpaper.
- **Remove from Group**, **Remove Group**.

A group outline is solid for a stretch and dashed for a clone. A group with fewer than two
connected displays is kept and comes back when its displays reconnect.

## Clone

A clone runs the wallpaper once: a scene renders one frame (at the largest size its displays
need) and each display shows it at its own size and placement; a video decodes once. In the
Chromium web engine a web page or WebM video loads once on the main clone display and the other
displays show it, covering them; the pointer and clicks on any display reach the page, and its
sound plays once. In WebKit each display loads its own page.

- **Set as Main Clone Display** picks the display whose wallpaper and properties the clone shows.
  Setting a wallpaper on any member sets it on the whole clone.
- **Flip Clone Display** mirrors a member left to right, without rendering again. The main clone
  display can't be flipped.

## Stretch

The canvas is the rectangle around the displays as they are arranged in System Settings ›
Displays, gaps included; each display shows its own part. A scene renders one canvas-sized frame
and reads the pointer on the canvas, so parallax and cursor effects line up across displays. A
video plays once. In the Chromium web engine a web page (or WebM video) is laid out on the whole
canvas once and each display shows its part. In WebKit it is laid out on the whole canvas once per
display, so pages that keep their own random state may not line up.

## Splits

**Add Split** divides a display into two regions, side by side or one above the other, each
with its own wallpaper and properties, as if it were a display of its own. Regions can be split
again. **Edit Split** moves the divider, **Remove Split** and **Remove All Splits** undo them. A
stretch group removes its displays' splits.

## Copy to and Swap with

Under **Wallpaper per display**, right-click a display (or a split display's region) that shows
a wallpaper:

- **Copy to** puts its wallpaper on the display you pick, with the wallpaper's properties and
  display options as they are on this display.
- **Swap with** exchanges the two displays' wallpapers, each with its properties and display
  options. When both show the same wallpaper, its two sets of settings change places; a display
  without a wallpaper leaves the other without one.

The displays you can pick are the others that show a wallpaper of their own: not the members of
a clone or stretch group. With *Sync properties across displays* on, every display has the same
properties, so only the wallpaper and its display options move.

## Mute

**Mute** silences one display. A wallpaper's sound comes from a display that shows it unmuted,
and stops when none does. Audio-reactive wallpapers still react.

## Profiles

The **Profile** menu saves the whole layout (groups, splits, flips, mutes) with each display's
and region's wallpaper under a name, loads it, or deletes it. **Import Wallpaper Engine
Profile…** reads Wallpaper Engine's `config.json`. An application rule can load a profile while
an application runs (Settings › Performance › Application Rules).

**Profile › Hotkeys** lists the profiles: choose one to give it a system-wide shortcut that
loads it, or to change or remove the one it has, as Wallpaper Engine's profile hotkeys. The
command line loads a profile too (`--control open-profile --profile <name>`,
[command-line.md](command-line.md)).

## Screen saver layout

**Screen saver layout** is **Same as wallpaper** by default: the screen saver follows the
displays' layout and groups. It can also be its own: a loop per display, **Stretch single screen
saver** (one loop recorded at the canvas's size, each display playing its part) or **Clone single
screen saver**. See [`screen-saver.md`](screen-saver.md).

## Per-wallpaper display options

The Details panel's display options move (horizontal, vertical), zoom and flip one wallpaper on
one display, and set a video's playback rate. They are kept per wallpaper and display and are
applied when the frame is shown, so nothing renders again.
