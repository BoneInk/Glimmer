# Theming

Settings › General › Theming lets macOS follow the colour of the wallpaper on the main display.
A master switch turns it on, and a checkbox per target says what follows. Everything is off by
default.

The code is the local package `Packages/OWETheming` (Foundation, Core Graphics and ImageIO only;
`swift test --package-path Packages/OWETheming`) and the app's side in `OpenWallpaperEngine/Theming/`
(`ThemingController`, `DesktopPictureTheming`) with the section in `Settings/ThemingSection.swift`.

## The colour

- **Scheme colour.** A Wallpaper Engine project can set `general.properties.schemecolor`, an
  "r g b" string of 0…1 floats (for example `"0.69 0.27 0.33"`). It is a user property, so the user
  can change it in the Details panel and presets can change it. The colour used is, in order: the
  running instance's value (live edits and presets), the value the user saved for that display's
  properties, then project.json's (`SchemeColorSource`).
- **Main colour.** With "Use the wallpaper's main color when it has no scheme color", a wallpaper
  without one uses the main colour of its picture, kept away from white, gray and black (a
  `schemecolor` is used as it is). K-means (k = 8, farthest-point seeds, 8 rounds) in OKLab over
  a 64×64 copy, off the main thread (`DominantColor`); each cluster scores its pixel share times a
  chroma preference in OKLCH: chroma below 0.04 (grays, white, black) and lightness below 0.22 or
  above 0.9 are strongly penalized, and clusters under 3% of the pixels or with chroma below 0.03
  aren't picked, so a small chromatic area beats a white or black majority. The pick is nudged
  into a usable range: lightness 0.40…0.78, chroma at least 0.08, the hue kept, the chroma
  reduced (and the lightness moved toward the middle) until it is inside sRGB. A monochrome
  picture (no cluster with chroma 0.03 or more) gets a neutral mid gray, Graphite as an accent.
  Results are cached per picture file and version (`DominantColorCache`). The picture is the
  scene's loading snapshot, else the desktop picture OWE made of a video or web wallpaper, else
  the Workshop preview. Without this option, such a wallpaper leaves everything as it is.
- **When.** The colour is worked out again when the main display's wallpaper changes, when its
  `schemecolor` changes (live or saved), when the screens change and when a setting changes,
  0.4 s after the last of a burst. The global preferences follow the main display's wallpaper.

## What each checkbox changes

All preferences are the current user's global domain (`NSGlobalDomain`). The keys were found by
reading this Mac's preferences (`defaults read -g`) and the strings of System Settings' Appearance
pane and of SkyLight on macOS 27; nothing was written while finding them.

| Checkbox | What it changes | Values |
|---|---|---|
| Menu Bar | The top of each wallpaper window and of the desktop picture OWE sets: the colour fades out downwards from the menu bar. No preference. | — |
| Accent Color | `AppleAccentColor` (Appearance › Color) | integer: −1 Graphite, 0 Red, 1 Orange, 2 Yellow, 3 Green, 4 Blue, 5 Purple, 6 Pink; absent is Multicolor (System Accent › Multicolor removes it) |
| | `AppleHighlightColor` (Appearance › Text highlight color) | `"r g b Other"`, a custom colour |
| Tinted Icon Color | `AppleIconAppearanceTheme` (Appearance › Icon & widget style) | `Tinted` + the current variant (`Automatic`, `Light`, `Dark`); the other styles are `Regular…` and `Clear…` |
| | `AppleIconAppearanceTintColor` | `Other` (the palette names Red … Graphite are the others; absent follows the accent colour) |
| | `AppleIconAppearanceCustomTintColor` | `"r g b a"` |
| Folder Color | `AppleIconAppearanceTintColor` and `AppleIconAppearanceCustomTintColor` only | as above |

### Menu Bar

macOS has no API for the menu bar's colour. On macOS 26 and later the bar is transparent with no
tint of its own: it shows whatever is directly behind it, which is OWE's wallpaper window (it covers
the desktop picture). The strip is the colour fading out downwards: 40% at the top, gone at 1.5
menu bar heights (`MenuBarStrip.fadeStops`): a tint over the bar that dissolves into the wallpaper. It is drawn twice:

- **The wallpaper window.** Each display's wallpaper window gets a gradient layer over its top
  (`WallpaperWindowContentView.menuBarStrip`). The
  compositor draws it; nothing renders again. This is what the menu bar shows.
- **The desktop picture**, which shows where no wallpaper window does (and on the lock screen). Each
  desktop picture OWE sets gets the same fade drawn over its top, based on the menu bar's height on that
  display (the frame's top minus the visible frame's top, or the safe area's top inset when taller),
  mapped into the picture as macOS's default "Fill Screen" shows it (`MenuBarStrip`). It is drawn by
  one hook in OWE's per-display desktop pictures (`DesktopPictureSync`): over each display's
  composed picture, before it is written and shown (`DesktopPictureTheming`). Each display gets its
  own strip, also when it shows its part of a stretch, a clone or split regions. The strip's colour
  and height are part of the picture's signature, so a new colour or a display change draws the
  pictures again; a Space change or a wake shows the same pictures, strip included.

Limits:

- The Menu Bar checkbox alone turns OWE's desktop pictures on (as "Show Wallpaper on Lock Screen"
  and "Adjust Menu Bar Color" do), so the pictures get the strip without either.
- A new colour is a new picture file: the two file names per display alternate, since macOS
  ignores setting the URL it already shows.
- On a macOS whose menu bar is translucent, the colour shows as a tint, not as the exact colour.
- A display whose menu bar hides itself has no strip.

### Accent Color

macOS 27 still has a fixed accent palette: System Settings shows eight swatches and stores an
integer, and there is no custom accent. So Accent Color has two choices (`ThemingSettings`):

- **System Accent** (`systemAccent`), what the system-wide accent becomes:
  - **Nearest Apple Accent** (`nearestApple`, the default, as before): the colour maps to the
    nearest swatch by OKLab distance (`AccentPalette`). Every app matches, in one of the eight.
  - **Multicolor** (`multicolor`): `AppleAccentColor` is removed, which is System Settings'
    Multicolor, so each app uses its own accent (an app without one shows Blue).
- **Open Wallpaper Engine's Accent** (`appAccent`), the accent of the app's own windows:
  - **Exact Wallpaper Color** (`themeColor`, the default): the colour itself, which the palette
    can't show (`ThemingSettings.appTint`).
  - **Follow System Accent** (`system`): the system accent, as other apps show it.

The text highlight colour does take a custom colour (`Other`), so with either choice it is set to
the colour at 30% over white, which is how light macOS's own highlights are.

**The app's own windows.** AppKit has no API for an app's accent other than the static asset
colour in its Info.plist, so the tint is SwiftUI's: every window's root (the main window, Settings,
About, the legal documents, What's New, the safe restart notice, the Workshop preview, Send over
Wi-Fi, Scene Edit / Export and the Wallpaper Editor)
applies `appAccentTint()` (`AppAccentTint`), which sets `.tint` (buttons, switches, sliders, links,
progress) and `appAccentColor` (`OWEInspectorKit`), which the app's own selection marks, gizmos and
indicators draw with instead of `Color.accentColor`; `SelectionHighlight` reads the tint too.
Without a tint (Theming or Accent Color off, Follow System Accent, or no colour) they are the system
accent, as before. The Wallpaper Editor runs in its own process: the app keeps the tint in the
defaults both share (`ThemingAppTint`, "r g b") and posts `themeTintDidChange` on the process
channel after each change (`ThemeTintSync`); the editor reads it at launch and on each post. On
quit the app clears it, so an editor left open goes back to the system accent. Menus, the menu bar
and alerts are drawn by AppKit and keep the system accent. The keys go to the
global domain through CFPreferences (`kCFPreferencesAnyApplication`, the current user, any host,
then a synchronize), where System Settings keeps them. After writing, OWE posts the distributed
notifications System Settings' Appearance pane posts (names from its binaries), delivered at once:
`AppleAquaColorVariantChanged` (the accent), `AppleColorPreferencesChangedNotification` (the
highlight) and `AppleInterfaceThemeChangedNotification` (apps redraw their dynamic colours).
Posting only the second left running apps on the old accent until System Settings next opened.

### Tinted Icon Color

The icon and widget style of macOS 26 and later is `AppleIconAppearanceTheme`; its colour is
`AppleIconAppearanceTintColor`, with `Other` for a custom colour in
`AppleIconAppearanceCustomTintColor`. SkyLight reads them and the Dock and Finder draw the icons.
System Settings applies a change through a private SkyLight call, and there is no public
notification for it, so after OWE writes the keys the Dock shows the change when it starts again.
With **Restart the Dock automatically to apply icon and folder colors** (on by default),
`DockRestartScheduler` runs `killall Dock` (launchd starts it again at once; there is no public
relaunch API) 1.5 s after the last icon change, so dragging a colour picker, editing the scheme
colour or switching wallpapers restarts it once, after the colour settles. It compares the stored
icon keys with those the Dock last started with and skips the restart when they are equal. Quitting
with "Restore on Quit" restarts it once more when the restore changed the keys. Off, the section
shows **Restart Dock** while the Dock is out of date. If an icon still doesn't change, logging out
and in applies it.

### Folder Color

macOS 26 and later colour folders with the "Icon, widget & folder color" setting, the same
`AppleIconAppearanceTintColor` / `AppleIconAppearanceCustomTintColor` the tinted style uses; folders
use it with every icon style, and without it they follow the accent colour. So Folder Color writes
those two keys and leaves the icon style alone. Folder Color and Tinted Icon Color share them: the
keys are restored when both are off.

## Saving and restoring

- **Before the first change** of a key, its value (or its absence) is saved in a journal under the
  app's defaults (`ThemingJournal`, `UserDefaultsJournalStore`), on disk before the write happens.
- **Unchanged values aren't written**, and no notification is posted for them.
- **A removed key counts as a value.** Multicolor removes `AppleAccentColor`; the journal keeps the
  original from before the first change (a number, or absent when the user had Multicolor), and
  switching between Nearest Apple Accent and Multicolor never replaces it. Restoring writes the
  original back, or removes the key again when it was absent, as long as the key still holds what
  OWE last wrote (absent, after Multicolor).
- **Turning a checkbox off** restores its keys; **turning the master switch off** restores all of
  them. A key goes back only while it still holds what OWE wrote: if the user changed it in System
  Settings since, their choice stays.
- **Quitting** restores everything when "Restore on Quit" is on (the default). Off, the colours stay,
  and the originals are kept, so turning theming off later still restores them.
- **After a crash**, the journal still says a session was running, so the next launch restores the
  originals first; theming then applies again if it is on.
- **Isolated copies** (tests, development copies, `OWE_ISOLATED_STATE`) read the preferences but
  never write them (`ReadOnlyAppearanceWriter`), never restart the Dock, and don't change the
  desktop picture.

All writes go through the `SystemAppearanceWriter` protocol: `GlobalPreferencesWriter` uses
CFPreferences (`GlobalPreferencesStore`) and the distributed notification centre
(`DistributedNotificationPosting`), and the package's tests use fakes for each, and for the Dock
(`DockRestarting`) and the settle timer (`SettleTimer`).
