# Android Export

**Android Export** is a tab of Scene Edit / Export (Details › Scene Edit / Export, ⌥⌘I). It
writes Wallpaper Engine's `.mpkg` packages for its Android app, as Wallpaper Engine's own "Export
.mpkg" does. All exporting happens in Scene Edit / Export; the library has no export command.
Copy the packages to the phone or tablet, or send them over Wi-Fi (below), and import them in the
Wallpaper Engine app.

The packages have the layout, files and JSON of Wallpaper Engine 2.8.42's own exports. How they
are built: [`architecture.md`](architecture.md), "Android export".

## What can be exported

| Type | Export |
|---|---|
| Scene | **Dynamic** or **Pre-Rendered** (below) |
| Video | The video file exactly as it is, byte for byte, with its preview and a minimal project.json, as Wallpaper Engine packs it. Videos over 4 GB can't be packed. |
| Web, application | The tab is shown but unavailable: "Wallpaper type not supported on Android devices", as in Wallpaper Engine. |

A video opens Scene Edit / Export on its export and screen saver tabs (it has no Wallpaper
tab). Its Android Export tab plays the video in the device's screen, filled as the phone fills
it; there is nothing to set, so it only has the export buttons.

## Output for scenes

Pick the performance rating that suits the device:

- **Dynamic, High Quality**: the scene itself, rendered live on the device. Everything a scene
  does keeps working there: animation, particles, effects, scripts, clocks and dates, audio
  response, touch and its user properties. Textures are converted to the compressed format
  phones read (ETC2), at full size (half for wallpapers over 1920×1080). Shaders get the same small GLSL ES edits Wallpaper Engine
  makes. **Pixel art optimization** keeps textures full-size, uncompressed and sharp-edged;
  **Texture Reduction** sets full, half or a quarter of the resolution.
- **Dynamic, Balanced**: as High Quality, with the textures at half their resolution (a quarter
  over 1920×1080; full size for pixel art). This is the
  tab's default.
- **Pre-Rendered** (Wallpaper Engine's High Performance): the scene recorded as a seamless H.264
  video loop, which any device plays cheaply, framed as the preview shows it: the device's screen
  (or a custom size), the crop you drag and zoom, the parallax position, **Video Size**, **FPS**
  (24, 30 or 60) and **Length** (30 s by default). As Wallpaper Engine warns, the scene's dynamic
  parts are baked in: clocks and dates show the time of the recording, and touch, audio response
  and properties no longer change anything.

The tab runs a private copy of the wallpaper, so nothing on your desktop changes. Its layer edits
and user properties are the export's own: a pre-render records them, and Dynamic bakes them into
the package's scene.json and project.json.

The tab's right-hand panel is the selected layer's **Layer Adjustments**, and the export's
progress and results. The output settings, the user properties and the exports are in
**Export Settings** (the toolbar's share button): **Send over Wi-Fi…**, **Save .mpkg…** and
**Export More with These Settings…**.

## Export More with These Settings

**Export More with These Settings…** (in Export Settings) exports other wallpapers with the
tab's settings. The main window switches to the Installed tab to pick them, under a tinted banner,
**Choose wallpapers to export to Android**, with the settings the batch uses:

- The grid works as usual for finding and selecting: the search, the filters, folders and
  breadcrumbs, the sort, ⌘-click, ⇧-click and **Edit › Select All** (⌘A). A click picks or
  unpicks a wallpaper; picks stay picked across folders and searches. The wallpaper being edited
  starts picked.
- Wallpapers Android can't play (web and application wallpapers, videos over 4 GB) are dimmed and
  can't be picked; their tooltip says why.
- Everything else is off until you finish: context menus, the Details panel (and its Set as
  Wallpaper), dragging into folders, adding or deleting wallpapers, the other tabs.
- The bar under the grid shows how many are picked, **Export as .mpkg** and **Cancel**. **Export
  as .mpkg** starts the batch and returns to Scene Edit / Export; **Cancel** or Esc returns
  without exporting. Leaving the Android Export tab or closing Scene Edit / Export ends the
  selection too.

Every scene gets the tab's output, quality, frame rate, video size and length; a pre-render is framed
for the tab's device, centred. Only the wallpaper being edited keeps its edits (hidden layers,
properties, crop, parallax position); the others export as authored. Videos are packed as they
are.

The batch runs as a queue, shown in the Android Export tab's right-hand panel with overall and
per-wallpaper progress, and can be cancelled there.
Pre-rendered videos render one at a time (they use the GPU) while the other packages are written
beside them. Each package is named `<title>.mpkg`, made unique within the batch, and goes into the
Android exports list, ready for **Send over Wi-Fi…**.

## Send over Wi-Fi

Every Android export (from Scene Edit / Export's Android Export tab, its batches or MCP) is
also added to the **Android exports** list, with its title, type, size, the device it was framed
for, the date and a copy of the wallpaper's preview. The list is kept in
`~/Library/Application Support/Open Wallpaper Engine/Android Exports/`; entries whose file is gone
are dropped.

**Send over Wi-Fi…** (after an export, in the export sheets, after a batch, or **File › Send Android Exports over
Wi-Fi…** and the menu bar icon's menu) opens a window with the whole list as a grid of previews.
Everything not downloaded yet starts selected. **Add .mpkg Files…** adds packages exported
earlier; each tile's menu has **Show in Finder** and **Remove from List**. **Start Sharing** lets
the phone or tablet download the selected packages from the Mac over the local network, with no
cable:

1. Scan the QR code with the device, or type the link it shows,
   `http://owe-fileshare.<mac>.local:<port>/<token>/`. With several networks, pick the one the
   device is on.
2. The page shows the import steps, **Download All**, and a card per package with its preview
   (animated when the wallpaper's is a GIF), title, type, device and size. Tap **Download** for
   one, or **Download All** (Chrome asks once to allow several downloads). Downloaded cards are
   marked.
3. Import each file in the Wallpaper Engine app, as with a copied file.

While it shares, each tile shows its progress and which devices downloaded it; selecting,
adding or removing packages updates the page within a few seconds. The link lasts until 15
minutes pass without the page or a download being opened; **Send Again** makes a new one.
Without a local network address on the Mac, the window explains why and offers **Save to
Folder…** instead.

If the page doesn't open on the device:

- The sheet also shows the link with the Mac's IP address. **Use IP address in QR code** puts it
  in the QR code, for devices that can't look up `.local` names.
- macOS may ask whether Open Wallpaper Engine may accept incoming network connections. Allow it.
- macOS may ask whether Open Wallpaper Engine may find devices on local networks. Allow it: until
  then the link and the QR code use the IP address, and they switch to the name once it's allowed.
- Some networks (guest networks, many public ones) keep devices from reaching each other
  ("client isolation" or "AP isolation"). Use a network that doesn't, or copy the files.
- If a download stops, keep the window open and tap **Download** again: it resumes.

### Security

- The server is started only while the window shares, until 15 minutes pass without a request,
  and serves only the selected packages. Closing the window ends it.
- It listens on one private or link-local IPv4 address of the Mac's local network, and only
  answers devices on that network. VPN, public and cellular addresses are never used.
- While it runs, the Mac advertises the name `owe-fileshare.<mac>.local` (`<mac>` is its
  LocalHostName, the Bonjour name, as a DNS label) for that address over multicast DNS, with an
  `_http._tcp` service on it and no TXT record, so the token is never advertised. When the name is
  taken (another Mac sharing), it uses `owe-fileshare-2.<mac>.local`, and so on. The name is
  withdrawn when the share stops.
- The link carries a random token: 10 base32 characters (50 bits), short enough to type and far
  beyond guessing in a 15-minute share that limits requests and refuses a device after 20 wrong
  paths. A wrong or expired token, and any other path, previews included, get the
  same "not found". Files are addressed by number, never by a path, so nothing else on the Mac
  can be reached.
- Only downloads are accepted. Connections and requests per device are limited, and a device that
  keeps guessing paths is refused until the session ends.
- The page loads nothing from the internet.
- It is plain HTTP on purpose: public certificate authorities don't issue certificates for
  `.local` names and a self-signed one shows a full-page browser warning, while the packages
  only cross the local network, for 15 minutes, behind the random token.

MCP clients get `export_android` and `android_send_wifi` ([`mcp.md`](mcp.md)).
