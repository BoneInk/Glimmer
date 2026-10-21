# Getting started

Installing the app, the optional requirements, the Wallpaper Engine assets and bringing in wallpapers. The [README](../README.md) has the short version.

## Requirements

- **macOS 14.0 or later** (Sonoma).

### Optional — needed for specific features

| Feature | Requirement | Install |
|---------|-------------|---------|
| Browsing / downloading from Steam Workshop | `steamcmd` | Automatic (optional: `brew install steamcmd`) |
| Audio visualizers & audio-reactive SceneScript | System Audio Recording permission (Screen & System Audio Recording before macOS 14.2) | Settings → Permissions |
| A microphone or loopback device as the audio source | Microphone permission, asked when you choose the device | Settings → Optimizations › Audio |
| App Rules' "Is playing audio" condition | macOS 14.2 or later | — |
| Now Playing in wallpapers | macOS 15.4 or later for live updates | — |
| Web wallpapers that need Chromium | The optional Chromium web engine | Settings → Plugins |
| Depth maps in the editors | The Depth Map Generation plugin | Settings → Plugins |
| The screen saver | The Screen Saver plugin; web and WebM wallpapers in it need the Chromium web engine | Settings → Plugins |
| HDR output (scenes, HDR10 and HLG videos) | A display with HDR (EDR) headroom and Post-Processing set to Ultra (Display HDR) | Settings → Performance |
| New effects, Replace Shader snippets and templates in the Wallpaper Editor | The Wallpaper Engine assets | Settings → Assets |
| Control from MCP clients | The MCP Server plugin | Settings → Plugins |
| Live Photo lock screens | iPhone or iPad with iOS / iPadOS 17 or later | — |
| Android export | Wallpaper Engine's Android app on the device | — |

## Wallpaper Engine assets

Scenes use Wallpaper Engine's shared effects, materials, shaders, fonts and SceneScript runtime from your own Wallpaper Engine copy on Steam; the app doesn't ship them. Install them in *Settings → Assets*: the app downloads your copy with steamcmd (the account must own Wallpaper Engine), keeps only the assets and the default wallpapers, and deletes the rest. You can also choose an existing Wallpaper Engine folder. Video and web wallpapers work without them.

### Wallpaper Engine favourites

Wallpaper Engine's favourites are your Steam Workshop favourites: they live in your Steam account, not in Wallpaper Engine's folder or its `config.json`, so a fresh SteamCMD download has none of its own. When the assets are installed, or a Wallpaper Engine folder is chosen, the app asks Steam's Web API for them (with your Steam Web API key and the account's SteamID, found in the files of the SteamCMD login or of the Steam folder the chosen install sits in) and asks *Also import your Wallpaper Engine favourites?* when there are any that aren't in My Favourites yet. They are added to your favourites, never replacing them, and the count is shown. Without a key, or with no account found, there is nothing to import from and the question isn't asked; *Import Wallpaper Engine Favourites…* in *Settings → Assets* checks again later. An account that keeps its favourites private returns none.

### Wallpaper Engine folders

Wallpaper Engine keeps the folders of its Installed tab in its `config.json`, beside `wallpaper64.exe` (`<account>.general.browser.folders`: each folder's title, colour, icon, subfolders and the Workshop ids or file paths filed in it). When you choose a Wallpaper Engine folder for the assets (the install or its `assets` folder), the app reads them and asks *Also import your Wallpaper Engine folders?* when they would add a folder, or file a wallpaper that isn't in a folder yet. They merge into your folders: a folder with the same name at the same place is the same folder, a wallpaper already in a folder here stays there, and importing again adds nothing. A local wallpaper is matched by its folder's name. The SteamCMD download keeps no `config.json`, so there is nothing to import from it; *Import Wallpaper Engine Folders…* in *Settings → Assets* checks again later.

## Wallpapers

### Browse & Download from Steam Workshop

1. Nothing to install: the app downloads Valve's SteamCMD in the background the first time it's needed (from Valve, not bundled). Homebrew (`brew install steamcmd`) is optional; an existing steamcmd (Homebrew, Steam, or one you pick) is used if found
2. Switch to the **Workshop** tab and log in with your Steam account (must own Wallpaper Engine)
3. Enter a [Steam Web API key](https://steamcommunity.com/dev/apikey) when prompted, or in *Settings › Assets*. It is checked with Steam and kept in your keychain; your Steam password is never stored (steamcmd reuses its own cached session)
4. Search, filter, and click **Download** on any wallpaper

### Import from Local Files

- **Folder or zip:** File › Import Wallpaper from Folder… (⌘I) — select wallpaper folders containing `project.json`, or `.zip` files of wallpapers; you can also drop them onto the library
- **Manual:** Copy wallpaper folders directly into `~/Documents/Open Wallpaper Engine/` (the default Wallpaper Storage folder; Settings › Assets can move it)
- **New:** Add Wallpaper › New Wallpaper… makes a scene from a picture or one of Wallpaper Engine's templates, or a web wallpaper from a folder with an `index.html`

## What the app connects to

Everything Open Wallpaper Engine saves stays on your Mac: your settings, library, cache and SteamCMD's login. Open Wallpaper Engine has no server and collects no data or analytics. It contacts Valve (Steam when you use the Workshop or install assets, and Valve's server to download SteamCMD), openwallpaperengine.app to check for app updates (its appcast) and GitHub to download them from GitHub Releases, without sending any personal data. Update checks can be turned off in Settings › Updates. Optional plugins download only when you install them: the Chromium web engine from the Chromium Embedded Framework's builds, and the depth model from Apple's Hugging Face repository, each checked against the version the app expects. Send over Wi-Fi serves an Android export only to devices on your local network, and stops once 15 minutes pass without a request. Web wallpaper devtools, while you turn them on for a session, listen on this Mac only (127.0.0.1). Web wallpapers may load their own online content. Your Steam password and Steam Guard code go straight to SteamCMD and are never stored, logged or sent anywhere else; only your account name is remembered, to reuse SteamCMD's saved login.
