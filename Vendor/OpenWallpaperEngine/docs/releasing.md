# Releasing

`.github/workflows/release.yml` builds the app, signs it with **Developer ID** under the
**hardened runtime**, **notarizes** and **staples** it, and attaches a zip, a DMG, SHA-256
sums and the zip's Sparkle signature to a **draft** GitHub release. Downloads open on any Mac
without a Gatekeeper warning.

Publishing the draft runs `.github/workflows/appcast.yml`, which adds the release to the
**Sparkle** update feed, `site/appcast.xml`, served by GitHub Pages at
<https://openwallpaperengine.app/appcast.xml> (the app's `SUFeedURL`, which `release.yml`
checks). Installed copies update themselves from it (Settings › Updates).

## The domain: openwallpaperengine.app

The site (`site/`: the download page, the privacy policy, the terms and the appcast) is served
at **<https://openwallpaperengine.app/>**, and the app's bundle ids are its reverse DNS
(`app.openwallpaperengine`, see [Bundle ids](#bundle-ids)). The source, releases, issues and
wiki stay on GitHub.

**Pages.** `.github/workflows/pages.yml` deploys `site/` with GitHub Actions, so the repository
has no `CNAME` file: the custom domain is a repository setting. Under *Settings → Pages*, the
source is *GitHub Actions* and *Custom domain* is `openwallpaperengine.app`; once the
certificate is issued, turn on *Enforce HTTPS*. Verify the domain for the account first
(*Settings → Pages → Verified domains*, at the user or organisation level), so no other
repository can claim it.

**DNS records** at the registrar:

| Name | Type | Value |
| --- | --- | --- |
| `@` (apex) | `A` | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` |
| `@` (apex) | `AAAA` | `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153` |
| `www` | `CNAME` | `deepratna-awale.github.io` |
| `_github-pages-challenge-deepratna-awale` | `TXT` | the verification code GitHub shows when you add the verified domain |

These are GitHub Pages' published addresses; check them against GitHub's *Managing a custom
domain for your GitHub Pages site* before changing anything. `.app` is on the HSTS preload
list, so browsers only ever load it over HTTPS: the site is unreachable until GitHub has issued
its certificate (usually within an hour of the DNS records resolving).

**The feed.** The app reads `https://openwallpaperengine.app/appcast.xml`. Copies released
before the move read `https://deepratna-awale.github.io/open-wallpaper-engine-mac/appcast.xml`,
which GitHub Pages redirects to the custom domain once it is set, so they still find the update
that moves them over. Don't merge a change of `SUFeedURL` (or release a build carrying it) until
`curl -I https://openwallpaperengine.app/appcast.xml` answers `200` over HTTPS with a valid
certificate.

### Bundle ids

| Bundle | Bundle id |
| --- | --- |
| Open Wallpaper Engine.app | `app.openwallpaperengine` |
| Wallpaper Editor.app (`Contents/Helpers`) | `app.openwallpaperengine.editor` |
| Open Wallpaper Engine.saver | `app.openwallpaperengine.saver` |
| OpenWallpaperEngine.framework | `app.openwallpaperengine.framework` |
| owe-mcp | `app.openwallpaperengine.mcp` |
| owe-chromium-helper.xpc (the XPC service) | `app.openwallpaperengine.chromium.helper` |
| The Chromium engine bundle (OWE Chromium.app) | `app.openwallpaperengine.chromium` |
| CEF's helper apps | `app.openwallpaperengine.chromium.helper[.renderer\|.gpu\|.plugin].app` |
| The unit tests | `app.openwallpaperengine.tests` |
| An isolated copy's defaults and (in-memory) keychain services | `app.openwallpaperengine.isolated.<tag>` |

The log subsystem (`OWELog`, `OWESignpost`) is `app.openwallpaperengine` too:
`/usr/bin/log show --predicate 'subsystem == "app.openwallpaperengine"'`. `AppIdentityLintTests`
checks the project's ids against this table and that the old id is left only in the migration.

## One-time setup: repository secrets

CI's asset tests use their own Steam secrets (`OWE_CI_STEAM_*`); see [ci-assets.md](ci-assets.md).

Add these under *Settings → Secrets and variables → Actions → New repository secret*, or with
`gh secret set` as shown below. Each workflow's first step fails with a list of whatever is
missing.

| Secret | What it is |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | *Developer ID Application* certificate + private key, `.p12`, base64 |
| `P12_PASSWORD` | the password you gave the `.p12` on export |
| `KEYCHAIN_PASSWORD` | any random string; locks the runner's throwaway keychain |
| `DEVELOPMENT_TEAM` | your 10-character Team ID (developer.apple.com → Membership) |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID (UUID) |
| `ASC_KEY_P8_BASE64` | the key's `AuthKey_<ID>.p8`, base64 |
| `USER_PAT` | GitHub token with `contents: write` on this repo: publishes the release, uploads the update deltas and pushes `site/appcast.xml` to `main` |
| `SPARKLE_PRIVATE_KEY` | Sparkle's EdDSA private key (`generate_keys -x`); signs every update |
| `SPARKLE_PUBLIC_ED_KEY` | its public key; built into the app as `SUPublicEDKey` |

Fallback instead of the three `ASC_*` secrets: `APPLE_ID` (Apple ID email) and
`APPLE_APP_PASSWORD` (app-specific password from appleid.apple.com → Sign-In and Security).
The API key is preferred: it does not depend on a person's Apple ID or 2FA.

`USER_PAT` pushes the appcast commit: a push made with the workflow's own `GITHUB_TOKEN` would
not start the Pages workflow. If `main` is protected, the token's owner must be allowed to push
to it (or add the appcast commit by hand, see *Appcast* below).

### Developer ID certificate (.p12)

Needs a paid Apple Developer Program membership; only the Account Holder can create a
Developer ID certificate. An *Apple Development* certificate is **not** enough.

1. Xcode → Settings → Accounts → your team → *Manage Certificates…* → **+** →
   *Developer ID Application*. (Or developer.apple.com → Certificates → **+** →
   *Developer ID Application* with a CSR from Keychain Access.)
2. Keychain Access → *login* → *My Certificates* → right-click
   “Developer ID Application: *Name* (*TEAMID*)” → *Export…* → `.p12`, set a password.
   Export from *My Certificates* so the private key is included.
3. `base64 -i DeveloperID.p12 | pbcopy` → paste as `BUILD_CERTIFICATE_BASE64`.
   Store the password as `P12_PASSWORD`. Delete the `.p12` file afterwards.

Check locally: `security find-identity -v -p codesigning` lists
`Developer ID Application: … (TEAMID)`.

### App Store Connect API key

1. appstoreconnect.apple.com → Users and Access → *Integrations* → *App Store Connect API* →
   *Team Keys* → **+**. Name it (e.g. “OWE notarization”), access **Developer**.
2. Download `AuthKey_<KEYID>.p8` (only once). Note the **Key ID** and the **Issuer ID**
   shown above the table.
3. `base64 -i AuthKey_<KEYID>.p8 | pbcopy` → `ASC_KEY_P8_BASE64`; Key ID → `ASC_KEY_ID`;
   Issuer ID → `ASC_ISSUER_ID`.

### Sparkle update keys

Updates are signed with an EdDSA (ed25519) key pair. The app carries the public key and
rejects any update the private key didn't sign, so **keep the private key safe and never lose
it**: a new key pair can't update copies that carry the old public key. Create it once, on your
Mac, with the tools from the Sparkle release the app links (2.10.0, see
`Scripts/release/fetch-sparkle-tools.sh`):

```sh
set -euo pipefail
cd "$(mktemp -d)"
curl -fsSLO https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  Sparkle-2.10.0.tar.xz" | shasum -a 256 -c -
tar -xf Sparkle-2.10.0.tar.xz ./bin

# 1. Creates the key pair (the private key goes into your login Keychain, item
#    "Private key for signing Sparkle updates") and prints the public key.
./bin/generate_keys

# 2. The public key → SPARKLE_PUBLIC_ED_KEY.
./bin/generate_keys -p | gh secret set SPARKLE_PUBLIC_ED_KEY --repo deepratna-awale/open-wallpaper-engine-mac

# 3. The private key → SPARKLE_PRIVATE_KEY, through a file that you trash right after.
./bin/generate_keys -x private.key
gh secret set SPARKLE_PRIVATE_KEY --repo deepratna-awale/open-wallpaper-engine-mac < private.key
trash private.key        # or: rm -P private.key
```

The login Keychain keeps the private key; back it up (e.g. export it to a password manager).
`release.yml` checks that `SPARKLE_PUBLIC_ED_KEY` is the public key of `SPARKLE_PRIVATE_KEY`
before building, so a mismatched pair fails the run instead of shipping an app that rejects its
own updates. The private key only ever reaches `sign_update` and `generate_appcast` on stdin
(`--ed-key-file -`); it is never written to disk or printed.

**Where the public key goes:** `OpenWallpaperEngine-Info.plist` has
`SUPublicEDKey = $(SPARKLE_PUBLIC_ED_KEY)`, a build setting that is empty in the project and
set on the `xcodebuild archive` command line by `release.yml`. Debug and local builds therefore
have no key, and `AppUpdateConfiguration.isConfigured` is false: the updater never starts, the
menu items are disabled and Settings says updates are off in this build. `OWEVersionLabel`
works the same way (`$(OWE_VERSION_LABEL)`, defaulting to `$(MARKETING_VERSION)`).

## Cutting a release

Tags decide everything:

| Tag | `CFBundleShortVersionString` | Label (`OWEVersionLabel`, appcast `shortVersionString`) | GitHub release | Update channel |
| --- | --- | --- | --- | --- |
| `v1.2.0` | 1.2.0 | 1.2.0 | draft | everyone |
| `v1.2.0-beta.1` | 1.2.0 | 1.2.0-beta.1 | draft, **pre-release** | `beta` only |
| `v1.2.0-rc.1` | 1.2.0 | 1.2.0-rc.1 | draft, **pre-release** | `beta` only |
| `v1.2.0-alpha.1` | 1.2.0 | 1.2.0-alpha.1 | draft, **pre-release** | `beta` only |

`CFBundleVersion` is the workflow run number, so it always increases; Sparkle compares
builds by it. Anything else (`v1.2`, `v1.2.0-preview.1`, leading zeros) fails the run
(`Scripts/release/release-version.sh`, tested by `Scripts/release/test-release-version.sh`).

```sh
# A beta, then a release candidate, then the release, all from main:
git tag v1.1.0-beta.1 && git push origin v1.1.0-beta.1
git tag v1.1.0-rc.1   && git push origin v1.1.0-rc.1
git tag v1.1.0        && git push origin v1.1.0
```

Or *Actions → Release → Run workflow* with `tag` = an **existing** tag (the workflow checks
out that tag).

The run: check secrets → check out → parse the tag → check the Sparkle key pair → import the
certificate into a temporary keychain → archive (manual signing, hardened runtime,
`--timestamp`, no `get-task-allow`, `SPARKLE_PUBLIC_ED_KEY` and `OWE_VERSION_LABEL` set) →
export (`developer-id`) → verify every Mach-O is Developer ID + runtime + timestamp, the
version, label, `SUPublicEDKey` and `SUFeedURL`, and that the only executables besides the app
are the known ones (Sparkle's, the framework, the Wallpaper Editor, `owe-mcp`, the Chromium
helpers and the screen saver) → notarize the app (`notarytool submit --wait`; on failure it prints
`notarytool log`) → staple → zip → DMG (signed, notarized, stapled) → verify with
`codesign`, `spctl` and `stapler validate` → sign the zip with `sign_update` into
`<zip>.sparkle.json` → draft release named *Open Wallpaper Engine 1.1.0 Beta 1* (for
`v1.1.0-beta.1`). The keychain and the API key file are deleted in an `always()` step.

Review the draft on GitHub, edit the notes (they become the update's release notes), then
*Publish*. **Draft + pre-release** is deliberate: GitHub lets a draft carry the pre-release
flag, it stays a pre-release when published, `releases/latest` and the stable update channel
skip it, and the `release: published` event that runs the appcast fires for pre-releases too.
Nothing reaches users until you publish.

The site's Download button shows the newest *published* release, pre-releases included
(labelled e.g. “Download 1.1.0 Beta 1 (beta)”), falling back to `releases/latest` and then to
the static releases link.

## Appcast (updates)

`appcast.yml` runs when a release is published (or by hand with its tag, to redo it):

1. Downloads the release's zip and `<zip>.sparkle.json`, and the full zips of the three newest
   items already in `site/appcast.xml` (`Scripts/release/appcast.py previous`).
2. Runs Sparkle's `generate_appcast` on them with `SPARKLE_PRIVATE_KEY`: it signs the new zip
   and makes **binary deltas** (`.delta`) from each older build to the new one, keeping a
   delta only when it is clearly smaller than the zip.
3. Checks that its signature and length for the new zip equal the release job's.
4. Converts the release notes (Markdown) to HTML through GitHub's API.
5. `appcast.py merge` takes the new item, points its enclosure and deltas at the release's
   assets (the deltas are renamed `OpenWallpaperEngine-<label>-from-<build>.delta` and
   uploaded to the release), sets `sparkle:shortVersionString` to the label,
   `sparkle:minimumSystemVersion` 14.0, `sparkle:channel` `beta` for a pre-release, the notes
   as the item's `description`, and the release page as `sparkle:fullReleaseNotesLink`, and
   puts it first in `site/appcast.xml` (replacing an item of the same build).
6. Commits `site/appcast.xml` to `main` as `chore(appcast): <label>`; the push deploys Pages.

A copy that finds the update downloads the smallest thing that applies: a delta from its own
build when there is one, otherwise the full zip. Deltas are made from the stapled, notarized
apps inside the published zips, so the patched app is byte-for-byte the notarized one, and
Sparkle checks its signature before installing it. Older releases stay in the feed; only the
newest release gets deltas.

**Channels:** pre-release items carry `<sparkle:channel>beta</sparkle:channel>`. The app asks
for the `beta` channel only when *Receive beta updates* is on, which it is by default on a
pre-release build (`AppUpdateConfiguration.allowedChannels`). Items without a channel reach
everyone.

**Fixing the feed by hand:** edit `site/appcast.xml` on `main` (keep each item's
`sparkle:edSignature` and `length`; they sign the archive, not the XML) and push, or re-run
*Actions → Appcast* with the tag.

## Updating installed copies

- **Update automatically** (on by default) checks every four hours, downloads in the background and
  installs: on quit, or once the Mac has been idle for 10 minutes, or at the latest a day after
  the download (`PendingUpdateInstallPolicy`). The relaunch takes a few seconds and restores
  the wallpapers, and the windows, tab and Settings page that were open
  (`UpdateRelaunchState`); a copy running only in the menu bar comes back without a window.
- With it off, *Automatically check for updates* makes Sparkle ask before installing, and
  *Check for Updates…* is in the app menu and the menu bar menu.
- The first time the main window opens after an update, *What's New* shows the notes of every
  version since the last one seen, cached from the appcast when the update was found (so it
  works offline) or taken from the bundled `CHANGELOG.md`. A first install shows nothing.
  *Don't show release notes* turns it off.

**What an update keeps.** Sparkle replaces only the app bundle, and the app writes nothing
inside its bundle (`UpdatePreservesUserStateTests` checks the sources): the defaults
(settings, per-display wallpapers, playlists, first-launch and setup-assistant flags), the
keychain items (Steam Web API key), Application Support (SteamCMD and its login, SceneScript
storage, the safe-restart ledger), the Wallpaper Storage with its `.owe-assets` cache, and
the caches under `~/Library/Caches` all stay. No store is keyed on the app version.

**The update that changed the bundle id.** Versions before the move to
`openwallpaperengine.app` used another bundle id. The first launch under the new one moves
that identity's state over once (`AppIdentityMigration`, before anything reads the defaults):
the defaults (and the Wallpaper Editor's), the caches under `~/Library/Caches/<id>` (shader
variants and pipeline archives included), the web views' data (`~/Library/WebKit/<id>`,
`~/Library/HTTPStorages/<id>`) and the Steam keychain items, which may show one keychain prompt
to read. It reinstalls the screen saver under the new id and registers launch at login again.
The Application Support folder is named after the app, not its id, and stays as it is. Each
step is recorded in `IdentityMigration.json` in that folder as it finishes, so an interrupted
migration resumes where it stopped; the old copy of anything is removed only after the new one
is verified. Afterwards the app says once that macOS will ask again for its permissions.

- **Downgrading isn't supported** past this update: the old identity's defaults, caches and
  keychain items are moved, not copied, so an older version starts as a new install.
- **Privacy permissions (TCC) can't be migrated.** macOS grants System Audio Recording (or
  Screen Recording), Local Network, Photos and the other privacy permissions to an app's
  identity, so the renamed app asks for each again the first time it needs it. The old
  identity's entries stay in System Settings › Privacy & Security until removed there.
- **Launch at login:** the old identity's Login Items entry can't be removed by the new app;
  remove it in System Settings › General › Login Items if it is still listed.

**Shader caches across updates.** The translated-shader cache is keyed on
`ShaderVariantTranslator.revision` and the toolchain fingerprint, and the Metal pipeline
archive on the device, the OS build, that revision and toolchain, and its own revision; neither
includes the app version, so an update that doesn't change translated output keeps both.
`ShaderRevisionGuardTests` fails when translated output changes without a revision bump.

**Keychain across signatures.** Keychain items are generic passwords under the bundle
identifier's service prefix, this-device-only. The data protection keychain needs an
application-identifier entitlement, which Developer ID builds without a provisioning profile
don't have, so items live in the login keychain, whose access list names the app that created
them by its designated requirement (bundle identifier + Developer ID + team). Every release is
signed by the same team, so updates read them without a prompt. A copy signed differently
(an *Apple Development* Debug build, an ad-hoc build) has a different requirement: the first
time the release reads an item such a build created, macOS asks to allow access once
(*Always Allow* ends it); or re-enter the Steam Web API key in Settings.

## Verifying a download

```sh
shasum -a 256 -c OpenWallpaperEngine-1.0.0.sha256     # in the download folder
ditto -x -k OpenWallpaperEngine-1.0.0.zip /tmp/owe-check
APP="/tmp/owe-check/Open Wallpaper Engine.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'Authority=Developer ID|flags=|Timestamp'
spctl -a -t exec -vv "$APP"        # accepted, source=Notarized Developer ID
xcrun stapler validate "$APP"      # The validate action worked!

spctl -a -t open --context context:primary-signature -vv OpenWallpaperEngine-1.0.0.dmg
xcrun stapler validate OpenWallpaperEngine-1.0.0.dmg
```

A pre-release's files carry its label: `OpenWallpaperEngine-1.1.0-beta.1.zip`.

## Local Release builds

The Release configuration signs every target (the app, `OpenWallpaperEngine.framework`, the
Wallpaper Editor, `owe-mcp`, the Chromium helper and the screen saver) with **Apple
Development**, automatic style, under the project's `DEVELOPMENT_TEAM`, as Debug does. An
ad-hoc ("-") signature can't be used: with the hardened runtime, library validation only loads
code signed by the same team (or Apple), so an ad-hoc app refuses its own framework and Sparkle
and doesn't launch. To build one locally:

```sh
xcodebuild -project OpenWallpaperEngine.xcodeproj -scheme OpenWallpaperEngine \
  -configuration Release -derivedDataPath build/Release build
```

Off the project's team, add `DEVELOPMENT_TEAM=<your team ID>` (an Apple Development certificate
for that team must be in your keychain; `security find-identity -v -p codesigning` lists them).
Such a build runs on your Mac only; it isn't notarized.

The release workflow doesn't use these settings: its archive passes `CODE_SIGN_STYLE=Manual`,
`CODE_SIGN_IDENTITY="Developer ID Application: …"`, `DEVELOPMENT_TEAM` and an empty
`PROVISIONING_PROFILE_SPECIFIER` on the command line, which override the project's
(conditional) identity for every target, and the `developer-id` export re-signs the bundle.
CI's test builds are Debug with `CODE_SIGNING_ALLOWED=NO`. Hardened runtime and library
validation are unchanged.

## Entitlements and nested code

`OpenWallpaperEngine/OpenWallpaperEngine.entitlements`: not sandboxed,
`cs.allow-jit` (JavaScriptCore in SceneScript), network client, user-selected files,
Downloads read-only, Photos library (for "Also Save to Photos Album"), `device.audio-input` (the audio recording device in Settings › Optimizations › Audio, under the hardened runtime). Metal, WebKit (out of process), system audio capture (a TCC prompt,
not an entitlement) and running `/usr/bin/perl` with the bundled `nowPlayingAdapter.pl`
(a resource, not an executable) need nothing more under the hardened runtime.

The nested code is the app's own (`OpenWallpaperEngine.framework`, `Wallpaper Editor.app` and
`owe-mcp` in `Contents/Helpers`, the `owe-chromium-helper` XPC service and its four
`OWE Chromium Helper` apps, and `Open Wallpaper Engine.saver` in `Contents/Resources`) and
`Sparkle.framework` (Swift package, embedded by Xcode) with its `Autoupdate` tool, `Updater.app`
and two XPC services. The app isn't sandboxed, so it doesn't use Sparkle's XPC services; they
ship inside the framework, signed. Xcode's `developer-id` export re-signs all of it with the
Developer ID identity, hardened runtime and a timestamp; the verify step checks every Mach-O for
that, checks the Sparkle components, the framework and the saver with
`codesign --verify --strict`, and fails on any other executable. No `--deep` signing is used
(Apple advises against it); `codesign --verify --deep --strict` checks the whole bundle.
