# Security audit, September 2026

Scope: the whole repository at `main` (1fff9324): the app (Swift, Metal, JavaScriptCore, WKWebView), Workshop and asset downloads (SteamCMD, DepotDownloader), Sparkle updates, the GitHub Actions workflows, the vendored shader toolchain and the GitHub Pages site.

Threat model: every wallpaper (scene, web, pkg, loose files, imported folders) is untrusted input from anyone. The repository is public, and anyone can open pull requests from forks.

This is a review of the code, not a penetration test. Nothing here was run against real users.

## Disclosure policy for this document

The repository is public. For every **High** finding, and for Medium findings that would guide an attack, this document gives only a title; the details, locations and exploit scenarios are withheld and tracked privately. Fixes for them are made in ordinary pull requests without describing the attack.

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 6 |
| Medium | 11 |
| Low | 15 |
| Info | 4 |

All findings are confirmed from the code unless marked *suspected*.

## High

| ID | Area | Title |
|---|---|---|
| H1 | Web wallpapers | File-URL access from web wallpapers. *Details withheld.* |
| H2 | Web wallpapers | The web wallpaper scheme handler follows symlinks. *Details withheld.* |
| H3 | Package import | Symlink escape during `.pkg` extraction. *Details withheld.* |
| H4 | Texture parser | TEX width/height integer overflow crash. *Details withheld.* |
| H5 | Texture parser | LZ4 decompression bomb. *Details withheld.* |
| H6 | Model parser | Huge allocation from model index padding. *Details withheld.* |

## Medium

### Withheld

| ID | Area | Title |
|---|---|---|
| M1 | Web wallpapers | The navigation policy lets pages go anywhere. *Details withheld.* |
| M2 | Web wallpapers | Every web wallpaper shares one website data store. *Details withheld.* |
| M3 | Workshop dependencies | Dependency links let one wallpaper write into another. *Details withheld.* |
| M4 | Asset loading | `..` traversal in asset and shader include paths, and a world-readable failed-shader dump. *Details withheld.* |
| M5 | Puppet animation | Out-of-bounds GPU reads from puppet data. *Details withheld.* |
| M6 | CI | Fork pull requests can reach the Wallpaper Engine asset cache. *Details withheld.* |

### M7. Float-to-Int traps from particle JSON

- **Where:** particle loading (`OpenWallpaperEngine/Scene/` particle parsers).
- **Scenario:** a wallpaper puts non-finite or out-of-range numbers in particle JSON (counts, rates, sizes). The code converts them with `Int(_:)` on a `Double`, which traps. The app crashes whenever the wallpaper loads, and again at every launch while it is the active wallpaper.
- **Fix:** convert through one checked helper that rejects NaN and infinity and clamps to a sane range before `Int(exactly:)` / `Int(clamping:)`.

### M8. Releases can be signed from any tag, with no approval

- **Where:** `.github/workflows/release.yml:25-40`. Also repository settings: no tag rulesets; `main` allows force pushes; admins are not enforced; 0 required reviews.
- **Scenario:** anyone who can push a `v*` tag, or a stolen maintainer or `USER_PAT` token, can tag any commit. The workflow then builds it with the Developer ID certificate, notarizes it and signs it for Sparkle. Automatic updates are on (`SUAutomaticallyUpdate`), so that build reaches every user.
- **Fix:**
  - Put the signing, notarization and Sparkle secrets in a `release` environment that requires a reviewer and only allows `v*` tags.
  - Add a tag ruleset restricting who can create `v*` tags.
  - Turn off force pushes on `main` and enforce protection for admins.

### M9. A third-party action receives the publishing token, and actions are pinned by tag

- **Where:**
  - `.github/workflows/release.yml:425` (`softprops/action-gh-release@v3.0.3` with `GITHUB_TOKEN: secrets.USER_PAT`).
  - Every other `uses:`: `ci.yml:41,47,56,84,93,103,115,133,150,181,198,221`, `release.yml:89,414`, `appcast.yml:61`, `nightly.yml:19,31,64`, `pages.yml:27-33`.
- **Scenario:** a moved or compromised tag in an action (as in the 2025 `tj-actions/changed-files` incident) runs attacker code in the release job. From there it can take `USER_PAT`, push to `main` (including `site/appcast.xml`) and edit releases. The repository allows all actions and does not require SHA pinning.
- **Fix:**
  - Pin every action to a full commit SHA, and add Dependabot for `github-actions`.
  - Replace the release action with `gh release create`.
  - Make `USER_PAT` a fine-grained token for this repository only, with `contents: write`.
  - In repository settings, allow only GitHub-owned and verified actions and require SHA pinning.

### M10. The CI Steam password and Steam Guard secret reach any same-repository branch

- **Where:** `.github/workflows/ci.yml:142-195` and `nightly.yml:37-45` run `Scripts/fetch-we-assets.sh` with `OWE_CI_STEAM_PASSWORD` and `OWE_CI_STEAM_SHARED_SECRET`.
- **Scenario:** `asset-tests` runs the pull request branch's own copy of the script with these secrets. Anyone who can push a branch here, or who controls a token that can, can send them anywhere; `::add-mask::` only hides them in logs. The shared secret is the full Steam Guard authenticator seed, so the account is taken over.
- **Done well:** DepotDownloader is pinned and its SHA-256 checked, the password and code go in on stdin, and `steam_totp.py` is correct.
- **Fix:**
  - Move the three secrets to an environment limited to `main` and the scheduled nightly. Let pull requests use the cached assets only, and skip the tests when the cache misses.
  - Keep the CI account worth nothing beyond owning Wallpaper Engine.

### M11. Untrusted content is parsed in an unsandboxed process with JIT, and the shader compilers run with asserts compiled out

- **Where:**
  - `OpenWallpaperEngine/OpenWallpaperEngine.entitlements:5-14`: `app-sandbox` false, `cs.allow-jit`, `network.client`. The `files.*` entitlements there have no effect without the sandbox.
  - `Vendor/ShaderToolchain/Package.swift:26-27,41-42`: glslang and SPIRV-Cross are built with `-DNDEBUG -w`.
  - `Vendor/ShaderToolchain/Sources/ShaderToolchain/ShaderToolchain.cpp:95`: glslang parse has no `try`/`catch`.
- **Scenario:**
  - Any memory-safety bug in the TEX, MDL, PKG and particle parsers, or in glslang or SPIRV-Cross, runs attacker code as the user, with full file and network access. The shaders come straight from wallpapers.
  - The compilers used to run in separate processes and now run inside the app.
  - With asserts disabled, invariants upstream relies on turn into undefined behaviour instead of an abort. An uncaught `std::bad_alloc` from glslang ends the app.
- **Fix:**
  - Move parsing and shader translation into a sandboxed XPC service with no network access and no file access beyond the wallpaper folder it is handed.
  - Catch every C++ exception in the shim, and cap shader source size and nesting.

## Low

### L1. SceneScript storage is keyed by the ID the wallpaper claims

- **Where:** the SceneScript host (`OpenWallpaperEngine/Scene/Scripting/Host/`).
- **Scenario:** a wallpaper claims another wallpaper's Workshop ID in its project and reads or overwrites that wallpaper's saved script storage.
- **Fix:** key storage by the folder the wallpaper was installed from, and cap its size.

### L2. `createLayer` asset paths are not confined to the wallpaper

- **Where:** `OpenWallpaperEngine/Scene/Loading/SceneScriptSceneDescriber.swift:87-111`, `SceneContentLoader.swift:814-834`.
- **Scenario:** a script asks for a layer whose asset path points outside the wallpaper and assets folders. JSON files there are read and parsed.
- **Fix:** resolve paths with the same confined resolver as the loader (see M4) and reject anything outside the allowed roots.

### L3. Web bridge messages have no size or rate limit

- **Where:** the `WKScriptMessageHandler` bridges in `OpenWallpaperEngine/Web/WebWallpaperViewModel.swift`.
- **Scenario:** a page posts very large or very frequent messages, costing the app memory and main-thread time.
- **Fix:** reject messages over a size cap, check types before use, and rate-limit each handler.

### L4. SceneScript has no CPU or memory limit

- **Where:** the JavaScriptCore context setup (`OpenWallpaperEngine/Scene/Scripting/`).
- **Scenario:** a script loops forever or allocates without bound. The script thread stalls or the process grows until the system kills it.
- **Fix:** add a per-call execution time limit (`JSContextGroupSetExecutionTimeLimit`) and a heap watermark that disables the wallpaper's scripts.

### L5. The converter follows project.json `file` outside the wallpaper

- **Where:** `OpenWallpaperEngine/Library/Import/WallpaperPackageConverter.swift:47-57,108-116`.
- **Scenario:** the `.pkg` name is derived from project.json `file`. A crafted value points at a `.pkg` outside the wallpaper, which is then read and moved into the wallpaper's `.owe-source/`.
- **Fix:** accept only a bare file name for `file`, and check that the resolved path stays inside the folder.

### L6. Child particles can fan out exponentially

- **Where:** particle children (`OpenWallpaperEngine/Scene/` particle system).
- **Scenario:** nested child emitters multiply per level, so a small JSON file asks for a huge particle count and denies service to the GPU and memory.
- **Fix:** cap the child depth and the total spawned per system. This is a safety limit, separate from the performance budget.

### L7. `/tmp/owe-failed-shaders` is a fixed shared path

- **Where:** `OpenWallpaperEngine/Scene/Shaders/ShaderVariant.swift:70` (`defaultFailureDirectory`).
- **Scenario:** another local user can create the folder or a symlink there first and receive or redirect the dump. Wallpaper shader source lands in a world-readable location.
- **Fix:** write to a per-user folder under the app's caches, created with mode 0700, and only in Debug builds.

### L8. Remote content in release notes reaches every client

- **Where:** `release.yml:433` (`generate_release_notes`), `appcast.yml:133-142`, `OpenWallpaperEngine/Core/Updates/AppUpdater.swift:169-192`.
- **Scenario:** the notes are built from pull request titles, rendered as GitHub-sanitized HTML (which still allows images) and placed in the appcast. Clients parse them with `NSAttributedString`'s HTML importer every four hours, and Sparkle shows them in its release notes view. A merged title with an image makes every client fetch a third-party URL, revealing their IP addresses.
- **Fix:** strip `<img>` and external links from the notes in `appcast.py`, or publish plain-text notes.

### L9. SteamCMD is not pinned, and its quarantine flag is cleared

- **Where:** `OpenWallpaperEngine/Workshop/SteamCmdPackage.swift:6,60-76`, `SteamCmdLocator.swift:90-94`.
- **Scenario:** the archive is fetched over HTTPS from Valve's CDN without a hash or signature check, and the quarantine flag is then removed. A `steamcmd` found on the login shell's `PATH` is trusted as is. Both depend on Valve's CDN and the user's own environment.
- **Fix:** document this trust. Optionally check that `steamcmd` is signed by Valve's Team ID before running it.

### L10. Workshop IDs are checked with Unicode `isNumber`

- **Where:**
  - `OpenWallpaperEngine/Workshop/WorkshopDependencyResolver.swift:57`.
  - `OpenWallpaperEngine/Library/Import/SteamLibraryImport.swift:163`. Line 142 of the same file also requires ASCII.
- **Scenario:** non-ASCII digits pass the check. They cannot form a path, so there is no traversal, but the IDs reach steamcmd and file names.
- **Fix:** one shared validator that accepts ASCII digits only, 1 to 20 characters.

### L11. The build ID goes into `GITHUB_OUTPUT` unchecked

- **Where:** `ci.yml:171-176`, `nightly.yml:23-27`.
- **Scenario:** the value comes from `api.steamcmd.net`. A newline in the reply would add extra step outputs; today it only feeds a cache key.
- **Fix:** accept `^[0-9]+$` only.

### L12. `main` protection is weak

- **Where:** repository settings.
- **Scenario:** force pushes are allowed, admins are exempt and no review is required. A stolen maintainer token can rewrite history silently.
- **Fix:** covered by M8.

### L13. Paths from project.json and `libraryfolders.vdf` escape their folders

- **Where:** `OpenWallpaperEngine/Library/Import/SteamLibraryImport.swift:182-186`, `SteamLibraryImport.swift:125-133`.
- **Scenario:**
  - The Steam library import resolves project.json `preview` with `appending(path:)`, so a `../` value points the preview at any image file the user can read. The preview is only shown locally.
  - A bottle's `libraryfolders.vdf` can name `C:\..\..` paths that leave the bottle's `drive_c`, making the import scan arbitrary folders.
- **Fix:** standardize and resolve both paths, and require them to stay inside the item folder and `drive_c`.

### L14. Steam library import copies symlinks as they are

- **Where:** `OpenWallpaperEngine/Library/Import/SteamLibraryImport.swift:217`.
- **Scenario:** `FileManager.copyItem` keeps symlinks, so symlinks inside an imported item land in the Wallpaper Storage folder. That feeds H2, H3 and M3.
- **Fix:** refuse, or drop, symlinks whose target resolves outside the item during import (the same for `ZipImporter`).

### L15. The VDF parser recurses without a depth limit

- **Where:** `OpenWallpaperEngine/Library/Import/ValveKeyValues.swift:74-101`.
- **Scenario:** `entries(closedBy:)` recurses once per `{`. A deeply nested `.acf` or `.vdf` file overflows the stack and crashes the app. These files are normally written by Steam, so the input is only semi-trusted.
- **Fix:** cap the nesting depth (for example 64) and throw a parse error beyond it.

## Info

- **I1.** `OpenWallpaperEngine-Info.plist:19-31` keeps Xcode's placeholder ATS exception ("New Exception Domain", insecure loads allowed). It matches no real host; remove it.
- **I2.** There is no Dependabot configuration for Swift packages or GitHub Actions.
- **I3.** The site (`site/index.html:391-465`) sets text only through `textContent`, and its links come from GitHub API URL fields, so there is no XSS from release names or notes. It has no Content-Security-Policy; a `<meta http-equiv>` CSP limited to `api.github.com` would harden it.
- **I4.** The update shader prewarm runs the downloaded update only after `UpdateBundleVerifier` (`OpenWallpaperEngine/Core/Updates/Prewarm/UpdateBundleVerifier.swift:46-53`) checks it against the running app's designated requirement. A time-of-check/time-of-use window exists, but only a process already running as the user can use it.

## Checked and found sound

- **CI:** `ci.yml` uses `pull_request`, never `pull_request_target`.
  - Default token permissions are read-only, and workflow permissions default to read.
  - Fork PRs get no secrets and skip the asset job.
  - PR cache writes are scoped to the PR, so main's cache cannot be poisoned.
- **Release inputs:** release tags are validated by a strict regex (`Scripts/release/release-version.sh`) before any use. The manual-dispatch input reaches the shell through `env`.
- **Sparkle:**
  - Version 2.10.0 is newer than every published Sparkle advisory's fix (the latest fixed in 2.9.6).
  - The updater is off unless the EdDSA key decodes to 32 bytes and the feed is https (`AppUpdateConfiguration.swift:36-40`).
  - The release job checks that the key pair matches, and the Sparkle tools' SHA-256 is pinned.
- **Release checks:** every Mach-O in the bundle must be Developer ID signed with the hardened runtime and a secure timestamp; `get-task-allow` and unexpected executables are rejected.
- **Keychain:** items are this-device-only, `AfterFirstUnlockThisDeviceOnly` and not synchronizable. Older builds' UserDefaults copies are moved into the keychain and deleted.
- **Steam credentials:** the password and Steam Guard code go to steamcmd on stdin and are redacted from logged output. The Web API key goes in a header, and transport errors are redacted.
- **steamcmd commands:** `SteamCmdScript` quotes every argument and rejects `"` and line breaks, so account names, IDs and paths cannot inject commands.
- **Appcast:** `appcast.py` builds the feed with ElementTree, which escapes the notes.
