# Chromium web engine

Web wallpapers run in WKWebView unless the user installs the Chromium engine. Some Workshop web wallpapers expect Chromium (WE ships CEF), so the app can optionally install a Chromium engine: the Chromium Embedded Framework (CEF), downloaded on demand like SteamCMD. Nothing of CEF ships with the app.

- **Phase 1:** the installer and updater, the helper process and IOSurface frame sharing, with a debug harness that proves it end to end.
- **Phase 2:** web wallpapers in Chromium ([below](#phase-2-web-wallpapers-in-chromium)), and pointing out wallpapers that need it while it isn't installed ([below](#wallpapers-that-need-chromium)).

## Architecture

```
Open Wallpaper Engine.app                        (hardened runtime, library validation ON)
├── Settings › Plugins › Chromium web engine     ChromiumEngineSection
├── ChromiumEngineInstaller                      download → verify → unpack → rename
├── ChromiumEngineSession  ◄──── NSXPC ────┐     IOSurface → MTLTexture (no copy)
└── Contents/XPCServices/owe-chromium-helper.xpc (hardened runtime, allow-jit,
                                           │      disable-library-validation)
      main.swift / ChromiumHelperService ──┘     copies CEF's surface into its own ring
      OWECefBridge.m ── dlopen ──► ~/Library/Application Support/Open Wallpaper Engine/ChromiumEngine/
                                     <version>/OWE Chromium.app/Contents/Frameworks/
                                       Chromium Embedded Framework.framework
                                       OWE Chromium Helper{, (Renderer), (GPU), (Plugin)}.app
      CEF renderer / GPU / utility processes = those helper apps (same executable) with --type=…
```

| Piece | Where |
|---|---|
| Pins (version → SHA-256) | `OpenWallpaperEngine/Web/Chromium/ChromiumEnginePin.swift` |
| Verify and unpack | `ChromiumEnginePackage.swift` |
| Install, update, prune, remove | `ChromiumEngineInstaller.swift` |
| App end of the XPC connection | `ChromiumEngineSession.swift` |
| Debug harness | `ChromiumFrameCaptureCommand.swift` (Debug builds only) |
| XPC contract (both targets) | `OWEChromiumHelper/ChromiumHelperIPC.swift` |
| Helper | `OWEChromiumHelper/` (target `OWEChromiumHelper`, product `owe-chromium-helper.xpc`) |
| CEF C API headers | `Vendor/cef/include`, the subset the helper includes, copied from the pinned archive (BSD licence in `Vendor/cef/LICENSE.txt`) |

### Install layout

```
<Application Support>/Open Wallpaper Engine/ChromiumEngine/      (isolated copies: "Open Wallpaper Engine (isolated <tag>)")
  <version>/OWE Chromium.app/Contents/Info.plist
  <version>/OWE Chromium.app/Contents/Frameworks/Chromium Embedded Framework.framework
  <version>/OWE Chromium.app/Contents/Frameworks/OWE Chromium Helper*.app   copied from the app's Contents/Helpers
  <version>/LICENSE.txt
  <version>/.owe-chromium-engine.json   written last; a folder without it is not an install
  .state.json                           { active, previous }
  .profile/                             CEF's profile (root_cache_path)
  .staging-<uuid>/                      one install in progress, deleted on exit or next install
```

### Install and update

1. Download `cef_binary_<version>_<platform>_minimal.tar.bz2` from `https://cef-builds.spotifycdn.com/` over HTTPS into `.staging-<uuid>/<name>.partial`, with progress and cancel.
2. Compute its SHA-256 and compare with the pin. **On a mismatch nothing is unpacked** and the staging folder is deleted.
3. Rename `.partial` to the archive name, then clear the quarantine flag from the verified archive only (see below).
4. Unpack only `Release/Chromium Embedded Framework.framework` and `LICENSE.txt` into a scratch folder with `/usr/bin/tar` (bsdtar refuses absolute paths, `..` and writes through symlinks), then assemble `<version>/` inside staging and write the manifest last.
5. Rename into `ChromiumEngine/<version>`. A folder of the same version is set aside first and put back if the rename fails.
6. Record the version as active (the old active one becomes previous) and delete every other version folder. **Only the current and previous versions are kept.**

Updates follow the app: each release pins one build per architecture. When the pin differs from the active install, Settings shows *Update available*. There is no "latest" and no unpinned download. The app ships universal, so both `macosarm64` and `macosx64` are pinned and the host architecture's pin is used.

Pinned now: CEF `154.0.33+ga03e714+chromium-154.0.8037.94` (Chromium 154.0.8037.94).

| Platform | Download | Unpacked | SHA-256 |
|---|---|---|---|
| macosarm64 | 132.2 MB | 337.8 MB | `6de789c942ae948596b1b0c60d72503c0e126f368abdd4fee530e8eaa3776814` |
| macosx64 | 138.7 MB | 358.8 MB | `b1cf9e159b798323ffd17b457dfc410ea3ee192868eb73061f25447865d4fe1a` |

The SHA-1 of both archives matched the CDN's `index.json` when they were pinned.

**To pin a new build:** download both minimal archives, check their SHA-1 against `index.json`, compute `shasum -a 256`, update `ChromiumEnginePin.pinned`, copy the same version's headers into `Vendor/cef/include` (the files `OWECefBridge.m` includes, found with `clang -MD`), and set `CEF_API_VERSION` in the helper's build settings to the new `CEF_API_VERSION_LAST`. The helper checks at run time that `cef_api_hash` agrees with the headers and refuses to start otherwise.

### Frame sharing

- The helper creates windowless browsers (`windowless_rendering_enabled`, `shared_texture_enabled`), one per page, with an external message pump on its main run loop.
- CEF calls `OnAcceleratedPaint` with an IOSurface from its own pool, which goes back to the pool when the callback returns. The helper therefore blits it on the GPU into one of three IOSurfaces it owns, waits for the copy, and sends that surface.
- The message is `ChromiumFrameMessage` (an `IOSurface` plus a frame number) over NSXPC. XPC sends an IOSurface as a Mach port: the pixels are never copied between processes.
- The app wraps the surface with `device.makeTexture(descriptor:iosurface:plane:)`. Frames that aren't BGRA, are over 16384 px or have no frame number are dropped.

**Debug harness** (Debug builds):

```sh
"Open Wallpaper Engine.app/Contents/MacOS/Open Wallpaper Engine" \
  --chromium-capture https://example.com 30 /tmp/frame.png 1280x720
```

It starts the embedded helper on the installed engine, waits for 30 frames and writes the last one as a PNG. Set `OWE_CEF_NO_SANDBOX=1` (Debug builds only) to tell a sandbox problem from anything else. `--chromium-install` (Debug builds) installs the pinned build through the same installer Settings uses. If the helper exits, the harness fails at once with the reason.

## Security model

- **Integrity of the download:** HTTPS from Spotify's CEF CDN (the official CEF binary host) plus a SHA-256 pinned in the signed app. A changed or truncated file is refused before anything is unpacked. This is stronger than SteamCMD's trust (audit L9), which has no hash.
- **Quarantine:** files the app downloads with URLSession are not quarantined, so normally there is nothing to clear. If the archive does carry the flag, it is removed from **that verified archive only**, before unpacking, so tar has no flag to copy onto the files. Nothing is cleared wholesale, and no file that wasn't verified is touched.
- **CEF never loads into the app.** The app keeps hardened runtime with library validation. CEF runs only in `owe-chromium-helper`, an XPC service embedded in the app and signed with it. Only the containing app can connect to an embedded XPC service.
- **Helper entitlements** (`OWEChromiumHelper/OWEChromiumHelper.entitlements`), each needed:
  - `com.apple.security.cs.disable-library-validation`: the helper `dlopen`s the CEF framework the app downloaded. CEF's official build is not signed by our team (the arm64 binaries are linker-signed ad hoc, the x86_64 ones unsigned), so library validation would refuse it. The alternative, re-signing CEF with our Developer ID on the user's Mac, isn't possible, and shipping CEF in the app would add about 330 MB to every download for an optional feature. The exception is on the helper only, never the app, and the release workflow fails if the app ever carries it.
  - `com.apple.security.cs.allow-jit`: V8 generates code at run time (`MAP_JIT`). Chrome's own renderer helper has the same entitlement.
  - `com.apple.security.network.client`: wallpapers may load remote content.
- **One self-contained engine bundle.** Each installed version is assembled into `OWE Chromium.app`, CEF's standard macOS app layout: the framework and the helper apps in `Contents/Frameworks`. The helper apps (`OWE Chromium Helper.app` and its `(Renderer)`, `(GPU)` and `(Plugin)` variants, the names Chromium derives and launches) are built with the app into `Contents/Helpers`, signed with our team and the helper's entitlements, and copied whole into the engine bundle at install, and again when an app update changes them. The bundle itself has no executable; the XPC helper is CEF's browser process.
- **Signing, Gatekeeper and library validation:** nothing downloaded is re-signed. CEF's arm64 binaries keep their linker-signed ad-hoc signatures (`codesign` shows no team; AMFI logs "has no CMS blob" when loading them, which is informational). Our helper apps keep their team signature, hardened runtime and entitlements, and `codesign --verify --strict` passes on each copy. Only processes with `disable-library-validation` (the XPC helper and the helper apps) load the ad-hoc framework; the app never does and keeps library validation. Gatekeeper doesn't assess the engine bundle: files the app writes aren't quarantined, the downloaded archive's flag (if any) is cleared before unpacking, and the bundle is never opened through Launch Services. Its outer bundle is unsigned, which is fine because nothing executes it as an app. If a future CEF drops its linker signature, ad-hoc signing the verified framework after unpacking is the fallback.
- **CEF's sandbox stays on.** Subprocesses enter it through `libcef_sandbox.dylib` before CEF loads, the way `CefScopedSandboxContext` does. Chromium's subprocess profile only allows reading the browser's main bundle (`(allow file-read* (subpath (param bundle-path)))`, taken from `+[NSBundle mainBundle]`; CEF's `main_bundle_path` setting doesn't change it). The XPC helper exists only to host CEF, so just before `cef_initialize` its `+[NSBundle mainBundle]` becomes the engine bundle, and the framework, its resources and the helper apps are then readable inside the sandbox and nothing else is. Debug builds can turn the sandbox off for diagnosis with the harness's `OWE_CEF_NO_SANDBOX=1`, which travels to the helper over the XPC connection (an XPC service doesn't inherit the app's environment) and on to subprocesses as `--no-sandbox`.
- **On-disk trust after install:** the install folder is in the user's Application Support, writable by any process running as the user. Such a process could already change the user's login items or shell profile, so this adds no new privilege boundary. It is the same trust as SteamCMD's copy.
- **Profile:** cookies and caches stay in `ChromiumEngine/.profile`. Session cookies are not persisted, and Remove deletes the profile with the engine.

## Sizes

| | arm64 | x86_64 |
|---|---|---|
| Download | 132 MB | 139 MB |
| On disk, one version | 338 MB | 359 MB |
| On disk, during an update (current + previous) | up to ~680 MB | up to ~720 MB |
| Helper in the app bundle | well under 1 MB | |
| Vendored headers in the repo | under 1 MB | |

## Phase 2: web wallpapers in Chromium

**Routing** (`WebEngineRouting`, `WebEngineRouter`): one Chromium page costs about 550 MB, far more than WebKit, so WebKit plays web wallpapers by default. Chromium plays a wallpaper when the engine is installed and the wallpaper needs it: the static scan found a Chromium-only API, or WebKit's runtime probe saw it fail on one (stored per content key; the wallpaper switches on its next load). The **Web engine** choice in a wallpaper's details (Automatic, WebKit, Chromium; Chromium unavailable without the engine) overrides that. Installing, removing or overriding rebuilds the views.

```
WallpaperView ── web ──► ChromiumWebWallpaperView ─► WebWallpaperViewModel (the same one WebKit uses)
                                │                          │ WebWallpaperPage
                                ▼                          ▼
                        ChromiumPageView ◄─ frames ─ ChromiumBrowserPage ─► ChromiumBrowserHost.shared
                        (CAMetalLayer, mouse)                                   │ one NSXPC connection
                                                                                ▼
                                       owe-chromium-helper: one CEF, one windowless browser per page
```

| Piece | Where |
|---|---|
| Engine choice | `Web/WebEngineRouting.swift` |
| The page abstraction both engines implement | `Web/WebWallpaperPage.swift` |
| Shared connection, start scripts, `owe-wallpaper` serving | `Web/Chromium/ChromiumBrowserHost.swift` |
| One browser as a page | `Web/Chromium/ChromiumBrowserPage.swift` |
| Metal layer and mouse | `Web/Chromium/ChromiumPageView.swift` |
| Web / WebM views | `Web/Chromium/ChromiumWebWallpaperView.swift`, `Video/ChromiumVideoWallpaperView.swift` |
| Helper side | `OWECefBridge.m` (browsers, resource handler, render-process handler), `ChromiumHelperService.swift` |

How each part matches the WebKit path:

- **One browser per page, one helper for all.** Each display's page is its own CEF browser (`createBrowser`, numbered by the app); all of them live in the one helper process, as WebKit pages share a web content process. The helper exits 5 s after the last browser closes. If it crashes, each page reopens its browser (at most 3 times in a row).
- **Start scripts.** The browser carries WebKit's document-start scripts (`WebWallpaperViewModel.documentStartScripts`: WE's pause hooks, the property/audio/heartbeat bridge, the media bridge) in its extra info. The renderer runs them in `on_context_created` for the main frame, before the page's own scripts, after binding `__oweHostPost(name, json)`. `ChromiumPageScripts` points the scripts' `window.webkit.messageHandlers.X.postMessage` at that function; nothing named `webkit` is defined, so a page can't mistake Chromium for Safari. Whatever the bridge does (including the late-listener delivery of #109) is therefore the same in both engines.
- **User files.** A `file` property's file and a `directory` property's folder (`WebDirectoryProperty`, `WebDirectoryFeed`) lie outside the wallpaper. Pages open them as WE documents, `'file:///' + path`; a start script (`WebUserFiles.userFileScript`) points such URLs (element `src`/`href`, attributes, inline styles, `fetch`, XHR, `Audio`) at `owe-wallpaper://local/.owe-user-files/<path>`, which the scheme handler serves only for the chosen file or a matching file in a chosen folder, in both engines.
- **Local files.** `owe-wallpaper://local/…` is registered in every process (standard, secure, CORS and fetch enabled). Each request goes to the app over XPC, which answers with `WebWallpaperSchemeHandler.reply`: the same canonical-path containment (audit H1/H2), patches and ranges. A file body crosses XPC as a file descriptor, and the helper reads only the range asked for. A remote embed (YouTube/Vimeo) is served at `https://localhost/`, the origin WebKit gives it.
- **Properties, audio, media, FPS:** `WebWallpaperViewModel` runs unchanged against `ChromiumBrowserPage`: the full user property set on load, then changes; `applyGeneralProperties({fps})`; the 128-value spectrum 30 times a second while registered and visible; media listener events. The FPS setting also caps the browser's frame rate (`set_windowless_frame_rate`), which WebKit can't.
- **Pause, suspend, mute.** Paused: WE's `setPaused` and `___wpxPause`, and the browser is hidden (`was_hidden`), so Chromium stops drawing even a page that ignores `setPaused`. Covered or displays asleep: hidden (Chromium stops frames and throttles timers; sound plays on, as WebKit's throttled page keeps WE's covered-wallpaper sound). Mute: `set_audio_muted` on the browser (CEF has no per-browser volume; WebKit's path mutes too).
- **Frames:** the helper copies CEF's IOSurface into one of three of its own per browser and sends it; `ChromiumPageView` blits it into its `CAMetalLayer`'s drawable and presents. The page is sized to the view in points at the display's scale, or 1 with "Render web wallpapers at standard resolution".
- **Input:** wallpaper windows ignore the mouse, so `ChromiumMouseForwarder` watches global and local mouse events like `DesktopClickMonitor` and forwards moves, presses, drags, releases and wheel to the browser (`send_mouse_*_event`) only where they land on the wallpaper (`DesktopClickMonitor.landsOnWallpaper`).
- **Sound:** CEF plays the page's audio itself; media autoplays without a gesture (`--autoplay-policy=no-user-gesture-required`), as WebKit is configured. Popups are refused.

### DevTools

Wallpaper Engine's *CEF devtools* row (Settings › Advanced, **Open Devtools**; its docs describe a devtools port whose `localhost` page lists the wallpapers) is **Settings › Optimizations › Developer Tools** here (`WebDevtools`, `WebDevtoolsSection`), for both engines:

- Off by default and kept for the session only: it is not a stored setting, so the port never opens on its own after a restart.
- WebKit: every wallpaper `WKWebView` is `isInspectable` while it is on, so Safari's Develop menu lists the pages under this Mac.
- Chromium: the helper starts CEF with `remote_debugging_port` 9222 (`--remote-debugging-address=127.0.0.1`, and `--remote-allow-origins` for that port's own origin only, so the frontend CEF serves there can connect). CEF opens the port only as it starts, so switching it lets the running helper go and its pages reopen in a new one (`ChromiumBrowserHost.remoteDebuggingPort`). Only processes on this Mac can reach it. Chrome's chrome://inspect lists 9222 without being told.
- **Open Devtools** opens `http://127.0.0.1:9222/` (the page list) while a Chromium page plays, else Safari while a WebKit page plays, else says "No web wallpaper active." as Wallpaper Engine does.

Still to do: drive frames from the display link (`send_external_begin_frame`), keyboard input, and installing a new pin in the background.

## Wallpapers that need Chromium

Without the engine, a web wallpaper that uses an API only Chromium has is pointed out (`ChromiumFeatureAdvisor`):

- **Static scan** (`ChromiumFeatureScanner`) when a web wallpaper loads or its details show: every `.html`, `.htm`, `.js`, `.mjs` in its folder (inline scripts and `on…=` handlers in HTML), with string, template and regular-expression literals and comments blanked first. A feature counts only when it is *used* (a method called, a member read, a constructor), not tested for: `navigator.serial.requestPort()` counts, `if (navigator.serial)` or `'serial' in navigator` doesn't. Cached by content key (the files' paths, sizes and dates).
- **Runtime detection** (`ChromiumFeatureProbe`, WebKit only): an early script reports TypeErrors and ReferenceErrors (uncaught, rejected promises, and errors logged with `console.error`). WebKit's message names the expression that came back undefined, e.g. *undefined is not an object (evaluating 'navigator.serial.requestPort')*, so the probe needs to define nothing the page could see.
- **Alert** when the user applies such a wallpaper: "This wallpaper uses features that need the Chromium web engine", listing the APIs, with **Open Plugins** (Settings › Plugins, the engine highlighted) and **Use Anyway** (plays on in WebKit; remembered for the wallpaper until its content key changes). It doesn't block: the wallpaper is already playing. The library's details show a "Some features only available on Chromium" badge.

### The API list (19)

Only APIs WebKit on macOS 26 lacks, from WebKit's feature status and standards positions and caniuse/MDN browser-compat data (Safari through 26):

| Id | API | Source |
|---|---|---|
| chrome-apis | `window.chrome.*` (`runtime`, `app`, `loadTimes`, …) | Chrome-only global; MDN: non-standard |
| css-paint | `CSS.paintWorklet`, `registerPaint` | caniuse css-paint-api: Safari behind a flag only |
| ua-client-hints | `navigator.userAgentData` | WebKit position: oppose; caniuse |
| web-serial | `navigator.serial` | WebKit position: oppose; caniuse web-serial |
| webusb | `navigator.usb` | WebKit position: oppose; caniuse webusb |
| webhid | `navigator.hid` | WebKit position: oppose; caniuse webhid |
| web-bluetooth | `navigator.bluetooth` | WebKit position: oppose; caniuse web-bluetooth |
| feature-policy | `document.featurePolicy` | Chrome-only; MDN |
| file-system-access | `showOpenFilePicker`, `showSaveFilePicker`, `showDirectoryPicker` | caniuse native-filesystem-api: Safari has only the origin private file system |
| battery | `navigator.getBattery()` | caniuse battery-status: removed from WebKit |
| eyedropper | `EyeDropper` | caniuse/MDN |
| keyboard-map | `navigator.keyboard` | WebKit position: oppose |
| local-fonts | `queryLocalFonts()` | WebKit position: oppose |
| document-pip | `documentPictureInPicture` | caniuse/MDN |
| performance-memory | `performance.memory` | Chrome-only; MDN |
| chrome-file-system | `webkitRequestFileSystem()` | Chrome-only; MDN |
| idle-detection | `IdleDetector` | WebKit position: oppose |
| window-management | `getScreenDetails()` | Chromium only; MDN |
| compute-pressure | `PressureObserver` | Chromium only; MDN |

Left out:

- **Present in Safari 26:** WebGPU, OffscreenCanvas, CompressionStream, Screen Wake Lock, `requestVideoFrameCallback`, `CSS.registerProperty`, prefixed speech recognition.
- **Uncertain for Safari 26, so not counted:** `requestIdleCallback`, `scheduler.postTask`, Trusted Types, `BarcodeDetector`, `AudioContext.setSinkId`. Add one to `ChromiumFeatureCatalog` once WebKit's status confirms it is missing.
- **Missing but harmless:** `navigator.deviceMemory` and `navigator.connection`; pages fall back.
- **`-webkit-app-region`:** it does nothing in any browser tab, Chromium's included, so a wallpaper doesn't need Chromium for it.
