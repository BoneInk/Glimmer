Open Wallpaper Engine
=========

**English** | [Deutsch](resources/readme/README.de.md) | [Français](resources/readme/README.fr.md) | [Español](resources/readme/README.es.md) | [Português (Brasil)](resources/readme/README.pt-BR.md) | [Italiano](resources/readme/README.it.md) | [日本語](resources/readme/README.ja.md) | [한국어](resources/readme/README.ko.md) | [简体中文](resources/readme/README.zh-Hans.md) | [繁體中文](resources/readme/README.zh-Hant.md) | [Русский](resources/readme/README.ru.md) | [Polski](resources/readme/README.pl.md) | [Türkçe](resources/readme/README.tr.md) | [Українська](resources/readme/README.uk.md) | [العربية](resources/readme/README.ar.md) | [हिन्दी](resources/readme/README.hi.md)

[![GitHub license](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Open Wallpaper Engine is a free, open-source macOS app that plays and edits Wallpaper Engine wallpapers: scene, video and web. Scenes draw with a native Metal renderer, with effects, particles, 3D models, lighting, SceneScript and audio-reactive visuals, and the Steam Workshop is built in. It began as a fork of Haren Chen's and MrWindDog's [Open Wallpaper Engine](https://github.com/MrWindDog) and has since been largely rewritten.

> **Note:** This is NOT affiliated with the commercial Wallpaper Engine on Steam. This is an open-source macOS app that can display wallpaper assets from Wallpaper Engine's Steam Workshop. → [ATTRIBUTION.txt](ATTRIBUTION.txt)

**Website:** [openwallpaperengine.app](https://openwallpaperengine.app/) · **Wiki:** [guides and troubleshooting](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki)

<!-- demo: desktop -->

[![Open Wallpaper Engine: set a wallpaper from the library](docs/media/demo/hero.webp)](docs/media/demo/hero.webm)

[![Scene wallpapers running live](docs/media/demo/wallpapers-in-motion.webp)](docs/media/demo/wallpapers-in-motion.webm)

![The library](docs/images/library.jpg)

## What sets it apart

- **The only macOS app that edits Wallpaper Engine scenes.** The Wallpaper Editor opens a scene's layers, effects, particles, timeline and scripts, and saves it as a Wallpaper Engine wallpaper.
- **Live Photo and Wallpaper Engine Android export.** Any scene or video becomes a moving lock screen for iPhone and iPad, or a package for Wallpaper Engine's Android app.
- **Wallpaper Engine's own shaders, translated.** Every layer, effect and material draws through the wallpaper's original shaders, translated to Metal, including effects Workshop authors wrote themselves.
- **A fully live screen saver.** The screen saver draws each display's wallpaper as it runs, so clocks, scripts and audio-reactive parts keep moving. Nothing is recorded.

## Highlights

- **Scene, video and web wallpapers**: scenes with effects, particles, 3D models, lights, timelines, SceneScript and audio-reactive visuals, and HDR output for scenes and HDR10 or HLG videos on displays that can show it. Web wallpapers run in WebKit or the optional Chromium engine, with their folder properties, live audio and Now Playing.
- **Steam Workshop**: browse with Wallpaper Engine's sorts and filters, download through SteamCMD with your own Steam account, or import wallpaper folders and zips. The Installed tab has Wallpaper Engine's folders and sorts.
- **Wallpaper Editor**: an editor in the spirit of Wallpaper Engine's. Add and arrange layers with gizmos, add effects with previews, write and edit your own effects in the Shader Editor, import FBX and OBJ models, animate on a timeline, write SceneScript, author user properties, edit particle systems and Puppet Warp rigs, and use Wallpaper Engine's image tools (Foreground Separation, Character Sheet Creation, Normal Map Generation). **New Wallpaper…** starts one from a picture or one of Wallpaper Engine's templates. You edit a draft: **Save** applies it, **Save as New Wallpaper** adds a copy to the library, and the wallpaper's own files are never changed.

  <!-- demo: wallpaper-editor -->

  [![Wallpaper Editor: layers, gizmo and effects](docs/media/demo/wallpaper-editor.webp)](docs/media/demo/wallpaper-editor.webm)

  ![Wallpaper Editor](docs/images/wallpaper-editor.jpg)

  <!-- demo: model-import -->

  <!-- demo: shader-editor -->

- **Scene Edit / Export**: change the running wallpaper's layers and effects live on the desktop, choose what the screen saver shows, or export the wallpaper as a Live Photo or an Android package.

  [![Scene Edit / Export: versions and layers changed live on the desktop](docs/media/demo/scene-edit.webp)](docs/media/demo/scene-edit.webm)

  ![Scene Edit / Export](docs/images/scene-editor-live.jpg)

- **Screen saver and lock screen**: the screen saver shows each display's wallpaper live (*Screen Saver Same as Wallpaper*), or one you choose, and the lock screen shows a picture of it.

  <!-- demo: screen-saver -->

- **Export**: Live Photo lock screens for iPhone and iPad, sent with AirDrop or saved to Photos, and Wallpaper Engine's Android packages, sent to the device over Wi-Fi with a QR code.

  <!-- demo: live-photo-export -->

  [![iPhone & iPad Export: Live Photo preview](docs/media/demo/live-photo-export.webp)](docs/media/demo/live-photo-export.webm)

  <!-- demo: android-export -->

  [![Android Export settings](docs/media/demo/android-export.webp)](docs/media/demo/android-export.webm)

  ![Send over Wi-Fi](docs/images/send-over-wifi.png)

- **Displays**: a wallpaper per display, one stretched across them or cloned onto each, groups, splits and profiles, as in Wallpaper Engine. **Play in Window** plays a wallpaper in a window of its own.

  ![Displays](docs/images/displays.png)

- **Playlists**: change wallpapers on a timer, at login, by time of day or day of week, with Wallpaper Engine's transitions.

  ![Playlist settings](docs/images/playlists.png)

- **Control**: hotkeys for actions, playlists, wallpapers and display profiles; Wallpaper Engine's `-control` [command line](docs/command-line.md); and the **MCP Server** plugin, through which MCP clients set wallpapers, playlists and settings and edit scenes, over a local connection only your account can open.

  ![MCP Server plugin](docs/images/mcp-plugin.png)

- **Power**: wallpapers pause while the screen is locked, follow Wallpaper Engine's *Laptop on battery* rule, and can drop to a lower quality preset and frame rate on battery or in Low Power Mode.
- **Theming**: the menu bar, the accent colour and tinted icons and folders follow the wallpaper's colour; Open Wallpaper Engine's own windows can use the exact colour.

  ![Theming](docs/images/theming.png)

Everything else, area by area: [docs/features.md](docs/features.md).

## Install

1. Download the latest release from [openwallpaperengine.app](https://openwallpaperengine.app/) or [GitHub Releases](https://github.com/deepratna-awale/open-wallpaper-engine-mac/releases). It's signed and notarized, and updates itself.
2. Open the DMG and drag **Open Wallpaper Engine** to Applications.

You need **macOS 14.0 (Sonoma) or later**. Scene wallpapers need the Wallpaper Engine assets from your own copy of Wallpaper Engine on Steam; video and web wallpapers don't. Some features need a later macOS, a permission or a plugin: see [Getting started](docs/getting-started.md#requirements).

## Quick start

1. Open the app. The setup assistant sets the language, SteamCMD, your Steam login and the Wallpaper Engine assets, and can import your Wallpaper Engine favourites and folders; every step can be skipped.
2. Install the Wallpaper Engine assets (*Settings › Assets*) if you want scene wallpapers. They come from your own copy of Wallpaper Engine on Steam; video and web wallpapers work without them.
3. Find wallpapers in the **Discover** and **Workshop** tabs, import a wallpaper folder or zip (*File › Import Wallpaper from Folder…*, ⌘I), or make one with **Add Wallpaper › New Wallpaper…**.
4. Click a wallpaper in the library, then **Set Wallpaper** in its details (or right-click it and choose **Set as Wallpaper**). Its properties are listed below it.

More: [Getting started](docs/getting-started.md) and the [wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki).

## Privacy

Everything the app saves stays on your Mac, and it collects no data or analytics. It contacts Steam (for the Workshop and the assets), openwallpaperengine.app (to check for updates) and GitHub (to download them), and plugins download only when you install them. Details: [what the app connects to](docs/getting-started.md#what-the-app-connects-to) and the [Privacy Policy](docs/legal/privacy-policy.md).

## Documentation

- [Getting started](docs/getting-started.md) — requirements, assets, the Workshop and importing
- [Features](docs/features.md) — everything the app supports, and how to use it
- Guides: [display layouts](docs/display-layouts.md) · [playlists](docs/playlists.md) · [screen saver](docs/screen-saver.md) · [iPhone & iPad export](docs/iphone-ipad-export.md) · [Android export](docs/android-export.md) · [depth maps](docs/depth-maps.md) · [theming](docs/theming.md) · [model import](docs/model-import.md) · [image tools](docs/image-tools.md) · [MCP Server](docs/mcp.md) · [command line](docs/command-line.md) · [Chromium web engine](docs/chromium-engine.md)
- [Development](docs/development.md) — building from source and the project layout; [CONTRIBUTING.md](CONTRIBUTING.md) and [architecture](docs/architecture.md)
- [Wiki](https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki) — guides, settings reference and troubleshooting

## Related Projects

- **[Open Wallpaper Engine for Linux](https://github.com/Unayung/simple-linux-wallpaperengine-gui)** — A PyQt6 GUI for [linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine), with Steam Workshop integration and UI design ported from this macOS version.

## Credits

This project is built on top of the work of:

- **[MrWindDog](https://github.com/MrWindDog)** — Maintainer of the upstream [wallpaper-engine-mac](https://github.com/MrWindDog) fork, added new features and UI refinements
- **[Haren Chen](https://github.com/haren724)** — Original creator of [open-wallpaper-engine-mac](https://github.com/haren724/open-wallpaper-engine-mac), built the core app architecture (SwiftUI, video wallpaper playback, import system, playlist UI)
- **1ris_W** — Chinese i18n translation
- **LivePaper** (MIT, Yuyang Zeng) — Measured the lock screen's Live Photo wallpaper metadata, which the iPhone & iPad Export writes
- **[Klaus Zhu](https://github.com/klauszhu1105)** — Original app logo design
- **[Chen Chia Yang](https://github.com/Unayung)** — Scene wallpaper rendering, web wallpaper fixes, Steam Workshop integration, multi-display support, zip import
- **[Deepratna Awale](https://github.com/deepratna-awale)** — Metal scene renderer and effect pipeline, GLSL→MSL shader translation and caching, SceneScript runtime, audio-reactive rendering, Workshop/Downloads overhaul, placement and performance settings, logo redesign

Licensed under [GPL-3.0](LICENSE), same as the original project.

## Legal

[Terms of Use](docs/legal/terms-of-use.md) · [Privacy Policy](docs/legal/privacy-policy.md) · [Security Policy](SECURITY.md)

- **English:** Please read the Terms of Use and the Privacy Policy.
- **Deutsch:** Bitte lesen Sie die Nutzungsbedingungen und die Datenschutzrichtlinie.
- **Français :** Veuillez lire les conditions d’utilisation et la politique de confidentialité.
- **Español:** Lee las condiciones de uso y la política de privacidad.
- **Português (Brasil):** Leia os Termos de Uso e a Política de Privacidade.
- **Italiano:** Leggi le condizioni d’uso e l’informativa sulla privacy.
- **日本語：** 利用規約とプライバシーポリシーをお読みください。
- **한국어:** 이용 약관과 개인정보 처리방침을 읽어 주십시오.
- **简体中文：** 请阅读使用条款和隐私政策。
- **繁體中文：** 請閱讀使用條款和隱私權政策。
- **Русский:** Прочитайте условия использования и политику конфиденциальности.
- **Polski:** Przeczytaj warunki korzystania i politykę prywatności.
- **Türkçe:** Lütfen Kullanım Koşulları’nı ve Gizlilik Politikası’nı okuyun.
- **Українська:** Прочитайте умови використання та політику приватності.
- **العربية:** يُرجى قراءة شروط الاستخدام وسياسة الخصوصية.
- **हिन्दी:** कृपया उपयोग की शर्तें और गोपनीयता नीति पढ़ें।
