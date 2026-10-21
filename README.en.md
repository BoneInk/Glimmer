<p align="center">
  <img src="Resources/Glimmer.png" width="128" height="128" alt="Glimmer icon">
</p>

<h1 align="center">Glimmer</h1>

<p align="center">A live wallpaper app for macOS, built around Apple's Liquid Glass design language with an immersive, minimalist interface.</p>

<p align="center"><a href="README.md">简体中文</a> · English</p>

## Features

- Integrates with the Wallpaper Engine Workshop and supports most Wallpaper Engine features, with further compatibility work in progress.
- Supports multiple types of live wallpaper:
  - Video: full support.
  - Web: broad compatibility.
  - Scene: initial support.
  - Further compatibility improvements are in development.
- Supports native animated lock screens on macOS.
- Imports local live wallpapers.
- Smooth, pleasing transition animations.
- Additional wallpaper sources and features are in development.

## Installation

Requires an **Apple Silicon Mac (M-series chip) running macOS 26 or later**. The current build targets `arm64`; an Intel version is not available.

1. Download `Glimmer-<version>-arm64.dmg` from this repository's [Releases](https://github.com/BoneInk/Glimmer/releases) page.
2. Open the DMG and drag `Glimmer.app` into **Applications**.
3. Launch Glimmer from **Applications**.

The current development preview is **signed with Apple Development and has not been notarized by Apple**. macOS may block it when first opened on another Mac. Check the corresponding release notes and accompanying `manifest.json` for the package's signing status.

## Getting Started

### Using Local Files

1. Open the library and click the **+** import menu in the upper-right corner.
2. Choose **Video Files or Folder…**, **Web Wallpaper Project…**, or **Scene Wallpaper Project…**.
3. After importing, open the wallpaper's details, preview it, select a target display, and click **Set as Wallpaper**.

For Web and Scene wallpapers, select the complete project folder containing `project.json` and its associated resources. To import existing Steam content, choose **Import from Local Steam Library…**.

### Using the Workshop

Before using the Wallpaper Engine Workshop, sign in to your Steam account within Glimmer and make sure that the account owns Wallpaper Engine. Download and favorites records are stored locally and are not synced to the cloud.

## Wallpaper Compatibility

| Type | Current Support | Notes |
| --- | --- | --- |
| Video | Local import, looping playback, multiple displays, mute and volume controls | Decoding support depends on AVFoundation. Playability is checked during import; videos retain their source frame rate |
| Web | Complete project import, desktop playback, author-defined settings | Compatibility depends on the web capabilities used by the project; FPS settings rely on the wallpaper author's implementation of the relevant interface |
| Scene | Original projects and `scene.pkg`, images, text, particles, scripts, shaders, embedded video | Uses a community Metal backend; see the [compatibility matrix](docs/scene-backend-compatibility-matrix.md) for supported capabilities and limitations |

Scene background music is integrated and muted by default. Integration audits for 3D models and skeletons, lights, and camera objects are not yet complete. System audio spectrum response, left-click interaction, and some author-defined properties are not yet integrated. Playback of every Wallpaper Engine project, or an exact visual match with the Windows version, is not guaranteed.

The app displays diagnostics for missing resources, unsupported features, and runtime failures to help identify the cause.

### Experimental Lock Screen

Scene and Web lock screens default to **live rendering**, so clocks, dates and scripts continue updating. Settings → Lock Screen Export also offers recorded playback. HTTPS access for lock-screen Web content is optional and off by default; weather services still need the wallpaper’s own author settings, service permissions and compatible CORS rules. Existing renderer compatibility limits apply. Hidden/sleeping surfaces pause; Web documents are released while the last native frame is retained and are recreated on resume. Reapply the lock screen after changing settings or author properties.

The project includes a system wallpaper extension and a lock screen integration workflow. Web and Scene wallpapers can be recorded as **10-second videos without audio tracks**. Settings → Lock Screen Export offers original, 720p, 1080p, 1440p and 4K resolution limits and an output frame rate, or synchronization with the desktop render size and frame rate. Output preserves aspect ratio and never exceeds the source dimensions or frame rate. Videos use their actual track specifications; Scenes use their project canvas; responsive Web content without declared dimensions uses the display render size. Procedural Web/Scene content uses the current wallpaper FPS cap as its source frame rate. The cache includes source content, author-defined settings, effective output specifications and engine version. Changes apply on the next export. Re-export atomically replaces the wallpaper’s previous video and poster and removes its obsolete cache entries after validation; a failed export retains the previous files.

This functionality relies on undocumented macOS system interfaces and is still being validated. Successful video export does not establish that the system lock screen displays it correctly, nor does it imply support for animated wallpapers on the startup or FileVault login screen. See the [extension documentation](Extensions/GlimmerWallpaperExtension/README.md) for implementation details and the scope of validation.

## Building from Source

Requires an Apple Silicon Mac, macOS 26+, a full Xcode installation with the macOS 26+ SDK, and Python 3.

The complete Scene backend also requires a valid code-signing identity already present in your keychain; ad-hoc signing is not supported. The scripts automatically select the Apple Development identity if exactly one is available. If multiple identities are available, specify one using `GW_SIGNING_IDENTITY`.

Run the following commands from the project root:

```bash
# Prepare the project-local .NET SDK and pinned SteamKit2 source
./scripts/prepare-dependencies.sh

# Optional: run Swift type checking and strict concurrency checks for the main app
./scripts/build-app.sh --typecheck

# Build the complete app at build/Glimmer.app
./scripts/build-app.sh

# Package a development preview DMG in dist/
./scripts/package-release.sh

# Verify the packaged artifact
./scripts/package-release.sh --verify dist/Glimmer-0.16.0-arm64.dmg
```

Dependency preparation writes to the project's `.tools/` directory and verifies pinned versions and archive hashes. The root `Package.swift` supports IDE indexing and auxiliary development tasks; use the scripts above to build the complete app.

See the [development guide](docs/development.md) for environment variables, module tests, and directory details. See the [distribution and packaging guide](DISTRIBUTION.md) for Developer ID signing, Apple notarization, and release package verification.

## Data and Issue Reports

The library and settings are stored locally. Credentials used to resume Steam sessions are stored in the macOS Keychain; the app does not save Steam passwords. User wallpapers, account data, caches, and signing certificates are not distributed with the source code.

When reporting an issue, include your macOS version, chip model, Glimmer version, wallpaper type, steps to reproduce, and any error messages shown in the app. For Workshop content, you can provide a public link or item ID. Do not include passwords, verification codes, or session tokens.

## Acknowledgments and Licenses

Glimmer's Scene backend is based on the community project **OpenWallpaperEngine**. Steam content downloads use **SteamKit2**, and the system wallpaper extension draws on **Phosphene**'s interface implementation. Thanks to the authors of these projects and their dependencies.

Original source code in this project is licensed under the [MIT License](LICENSE). Third-party components retain their respective licenses, including GPL-3.0 for the Scene backend and LGPL-2.1 for SteamKit2; the root MIT license does not cover these components. See [NOTICE.md](NOTICE.md) for full provenance, version, and license information. The packaging scripts include the corresponding notices and source archives with the app.
