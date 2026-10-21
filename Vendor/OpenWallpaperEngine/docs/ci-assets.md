# Wallpaper Engine assets for CI and tests

The asset-gated tests need Wallpaper Engine's built-in files. The repository ships none of them.
`Scripts/fetch-we-assets.sh` downloads them from Steam, logged in as a dedicated **CI Steam
account** that owns Wallpaper Engine (app 431960). CI and local test runs both use it.

It downloads only `assets/`, `locale/ui_*.json`, `projects/defaultprojects/`, the New Wallpaper
templates `projects/templates/` and the script editor's snippets `ui/dist/monaco/snippets/*.js` of
the Windows depot, with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) (MIT). The script pins
the release (3.4.0), verifies its SHA-256 and caches it in the tool folder (`OWE_TOOLS_DIR`).
.NET isn't needed. The output folder is laid out like a WE install, with `.build` (the Steam
build id) and `.owe-assets-info.json` (the format `WallpaperEngineAssetsCache` writes). Point
`OWE_ASSETS`, or `TEST_RUNNER_OWE_ASSETS` through `xcodebuild`, at it.

```sh
Scripts/fetch-we-assets.sh [--dry-run] [--force] [destination]
Scripts/fetch-we-assets.sh --build-id    # the current public build id; no login
```

The script first reads the current build id, without a key, from `api.steamcmd.net` (a mirror of
Steam's app info). It skips the download when the destination's `.build` matches and its
`.filelist` holds the script's current file list (a folder fetched by an older copy of the script
is downloaded again). If that
lookup fails, it downloads anyway. DepotDownloader keeps `.DepotDownloader/depot.config` in the
destination, so a later build downloads only the files that changed. `--dry-run` shows the plan
without logging in, and `--force` downloads even when the build matches.

Default destination: `$OWE_WE_ASSETS_DIR`, else `~/Library/Caches/owe-we-assets`.

## The CI account

1. Create a Steam account used only for CI. Buy or gift Wallpaper Engine to it.
2. Turn on the Steam Guard **mobile authenticator** and export its `shared_secret` (base64),
   for example from a Steam Desktop Authenticator `.maFile` or `steamguard-cli`. Keep the
   revocation code somewhere safe.
3. Add the repository secrets (*Settings → Secrets and variables → Actions*):

| Secret | What it is |
| --- | --- |
| `OWE_CI_STEAM_USER` | the account name |
| `OWE_CI_STEAM_PASSWORD` | its password |
| `OWE_CI_STEAM_SHARED_SECRET` | the authenticator's `shared_secret`, base64 |
| `OWE_CI_STEAM_WEB_API_KEY` | optional, currently unused |

```sh
gh secret set OWE_CI_STEAM_USER
gh secret set OWE_CI_STEAM_PASSWORD
gh secret set OWE_CI_STEAM_SHARED_SECRET
```

The script makes the Steam Guard code itself (`Scripts/steam_totp.py`: HMAC-SHA1 over the 30 s
counter, written as 5 characters of Steam's alphabet). It passes the password and the code to
DepotDownloader on stdin, so neither shows up on a command line. It never prints either one, and
in Actions it masks them.

## CI

`.github/workflows/ci.yml` builds the test bundle once and runs it in shards, split by test
class (`Scripts/ci-test-plan.py`):

- **`build-and-test`** runs the suite without assets, for every push and PR, forks included, in
  three shards (`build-and-test (1/3)`…). The asset-gated tests skip. This is the fast signal. A
  final job named `build-and-test`, the required check, passes only when every shard passed. On
  a pull request only the test classes the changed files select run (`.github/test-map.yml`).
- **`asset-tests`** runs every test class with `TEST_RUNNER_OWE_ASSETS` set, in four shards,
  and a final `asset-tests` job passes only when all four passed. It runs on pushes to `main`
  and on manual runs from `main` only, never for pull requests. The Steam secrets live in the
  `steam-ci` environment, which only `main` can use. The nightly workflow uses the same
  environment. No job uploads the assets as artifacts.

The `asset-cache` job runs first and makes sure the encrypted cache (below) holds the current
build: on a miss it downloads the assets (three attempts, 30 s and 2 min apart), encrypts and
saves them, and then checks that the entry is there. It is the only job that logs in to Steam.
The four shards restore that build (`download: 'false'`) and fail with an error if they can't;
they never log in themselves, since concurrent logins of one account fail. Without
`OWE_ASSET_CACHE_KEY` the asset jobs fail: set the key. The steps live in
`.github/actions/we-assets`, shared with the nightly workflow, which downloads on a miss itself.

Failing tests are retried once, and a test that fails both times fails the job. On a failure the
job summary lists each failing test with its message and file:line, and the `.xcresult` bundles
and the log are uploaded for 7 days (`test-results-*`).

### Encrypted asset cache

The `steam-ci` jobs cache the assets only as ciphertext, keyed `we-assets-enc-r<revision>-<buildid>`
(the Steam build id, digits only, and `ASSET_CACHE_REVISION` in `.github/actions/we-assets`):

- **Hit:** `actions/cache/restore` fetches the one encrypted file, and the job decrypts it with
  `openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000` and untars it into the assets folder. If
  decryption fails (a wrong or rotated key), the nightly downloads the assets from Steam
  instead; an asset shard fails.
- **Miss:** the job downloads the assets, then streams `tar` straight into
  `openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt`. No plaintext archive is written. Only
  pushes and manual runs on `main` save the encrypted file with `actions/cache/save`. The cache
  paths are made absolute first: `actions/cache` refuses a path with `..` in it, and then only
  warns and saves nothing.
- **New files:** when `Scripts/fetch-we-assets.sh` downloads more (its `FILELIST`), bump
  `ASSET_CACHE_REVISION` in the same change. The next push to `main` then misses, downloads and
  saves the new set; without the bump the cache keeps serving the old one until Steam publishes a
  new build. Revision 2 added `projects/templates/` and `ui/dist/monaco/snippets/`, which
  `NewWallpaperWizardTests.testWEsTemplatesComeWithTheAssets` and
  `EditorScriptToolsTests.testWEsSnippetsComeWithTheAssets` read.
- **No key:** when `OWE_ASSET_CACHE_KEY` is empty, or the build id couldn't be read, the nightly
  skips the cache and downloads the assets; `asset-cache` and the asset shards fail.

The asset jobs and the nightly also keep their shader-variant translations and Metal pipeline
archive between runs (`.github/actions/shader-cache`). Those hold MSL translated from Wallpaper
Engine's shaders, so they are cached the same way: one archive, encrypted with
`OWE_ASSET_CACHE_KEY`, never plaintext.

The key is the `OWE_ASSET_CACHE_KEY` secret in the `steam-ci` environment. Only the steps that
decrypt or encrypt get it, through `-pass env:`, so it is never on a command line or in the log.
The cache itself holds nothing but ciphertext: a pull request or a fork can restore the file, but
without the key it can't read it. To set or rotate the key (a rotation just makes the next run
download and re-save):

```sh
openssl rand -base64 48 | gh secret set OWE_ASSET_CACHE_KEY --env steam-ci
```

Contributors run the asset tests locally with `OWE_ASSETS` (see Local use).

`OWE_LIBRARY` stays unset in both jobs, so the library-gated tests skip.

## Local use

Store the credentials in your login Keychain, service `owe-ci-steam`. Each command prompts for
the value, so it never lands in your shell history:

```sh
security add-generic-password -U -s owe-ci-steam -a user -w
security add-generic-password -U -s owe-ci-steam -a password -w
security add-generic-password -U -s owe-ci-steam -a shared-secret -w
```

The script reads them with `security find-generic-password -s owe-ci-steam -a <account> -w`.
Environment variables, when set, take precedence. Then:

```sh
Scripts/fetch-we-assets.sh                      # refreshes the default folder
TEST_RUNNER_OWE_ASSETS=~/Library/Caches/owe-we-assets \
  xcodebuild test -project OpenWallpaperEngine.xcodeproj -scheme OpenWallpaperEngine -destination 'platform=macOS'
```

`OWE_ASSETS=~/Library/Caches/owe-we-assets Scripts/ci-local.sh` runs the whole suite with them
the way CI does (CONTRIBUTING.md).

To refresh, run the script again. It does nothing until Steam publishes a new build. To start
over, use `--force` or delete the folder. To remove the credentials, run
`security delete-generic-password -s owe-ci-steam -a <account>`.

`Scripts/fill-assets-cache.sh` still copies the assets from a WE install on disk, when you have
one.

## Troubleshooting

| Exit | Meaning | What to do |
| --- | --- | --- |
| 2 | bad arguments | see `--help` |
| 3 | missing credentials, or a shared secret that isn't base64 | set the secrets or Keychain items above |
| 4 | login failed: wrong password, wrong shared secret, or a clock that's off by more than ~30 s | check the values; sync the clock; a changed authenticator means a new `shared_secret` |
| 5 | Steam is rate limiting logins (`RateLimitExceeded`, `AccountLoginDeniedThrottle`) | wait 30–60 minutes; don't retry in a loop |
| 6 | the account doesn't own Wallpaper Engine | add the licence to the account |
| 7 | the download failed, or the result has no `assets/shaders` | rerun; see DepotDownloader's log |
| 8 | DepotDownloader couldn't be downloaded, or its checksum didn't match | check the network; on a version bump, update the pinned hashes |
| 9 | `--build-id` couldn't read the build | `api.steamcmd.net` is down or returned something other than a number; the download still runs |
