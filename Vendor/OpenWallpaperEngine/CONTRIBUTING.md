# Contributing

This is the one contributor guide; `.github/` links here. Read [`docs/architecture.md`](docs/architecture.md) first for the module layout. The goal is to run every Wallpaper Engine wallpaper except the `application` type, following WE's own behaviour. Comments that cite "… notes" (for example "editor-plan notes §3") refer to the maintainers' planning notes, which are kept outside the repository.

## Quick start

```sh
git clone https://github.com/deepratna-awale/open-wallpaper-engine-mac.git
cd open-wallpaper-engine-mac
open OpenWallpaperEngine.xcodeproj        # Xcode 26.3 or newer, scheme OpenWallpaperEngine
Scripts/fetch-we-assets.sh                # WE assets for scenes and the asset tests (see below)
xcodebuild test -project OpenWallpaperEngine.xcodeproj -scheme OpenWallpaperEngine -destination 'platform=macOS'
```

- **Before merging:** `Scripts/ci-local.sh`, the local gate (see [Tests](#tests)).
- **Quick tests:** the command above. Asset-dependent tests skip without assets.
- **Asset tests:** add `TEST_RUNNER_OWE_ASSETS=~/Library/Caches/owe-we-assets` (or any WE install).
- **Slow tests:** add `TEST_RUNNER_OWE_SLOW_TESTS=1`. The [nightly workflow](.github/workflows/nightly.yml) runs them with the assets every night (see [the slow tier](#tests)).

## Building

- Open `OpenWallpaperEngine.xcodeproj`, scheme **OpenWallpaperEngine**, macOS 14+ (Xcode 26.3 or newer; CI and release use 26.3).
- **Debug and Release builds sign with *Apple Development*** (automatic signing, the project's `DEVELOPMENT_TEAM`). macOS ties the audio-capture grant (System Audio Recording, or Screen Recording before macOS 14.2; needed for audio-reactive features) to the signature, and ad-hoc signing loses it on every rebuild. An ad-hoc ("-") Release build doesn't launch at all: the hardened runtime's library validation rejects the ad-hoc framework and Sparkle.
  - If you aren't on the project's team, set your own team in *Signing & Capabilities* (or pass `DEVELOPMENT_TEAM=<your team ID>` to `xcodebuild`) and don't commit that change.
  - The published release overrides this with manual Developer ID signing (docs/releasing.md); CI's test builds pass `CODE_SIGNING_ALLOWED=NO` and need no certificate.
- **Shaders:** WE shaders are translated by the glslang and SPIRV-Cross libraries linked into the app (`Vendor/ShaderToolchain`), run in a helper copy of the app (`--shader-compile-helper`, `HelperShaderCompiler`) so a compiler crash or hang can't take the app down; hosted tests translate in process. You don't need to install anything.
- **WE assets:** none are in the repository or the app. The app reads them from a WE install the user chose, or from the cache Settings › Assets fills from the user's Steam copy (`<Wallpaper Storage>/.owe-assets`). For development, `Scripts/fetch-we-assets.sh` downloads them from Steam with the CI account (credentials in your login Keychain, see [docs/ci-assets.md](docs/ci-assets.md)), or `Scripts/fill-assets-cache.sh <WE install> <folder>` copies them from a WE install on disk.

## Where code goes

| You are adding… | Put it in… |
|---|---|
| A new WE file format or field | `Scene/Format/`: plain `Decodable` models, no side effects |
| Anything that reads a value that can be user-, script- or animation-bound | resolve it through `Scene/Values`; never read the raw JSON |
| Shader translation, reflection, caching | `Scene/Shaders/` |
| Metal drawing, render passes, render targets | `Scene/Rendering/` |
| A SceneScript API member | `Scene/Scripting/` (JS-side code in a bundled `.js` resource, not a Swift string) |
| A settings control or Scene Edit / Export UI | `Settings/` or `Scene/UI/`; the view model sits next to its view |
| Anything used by several features (logging, settings, asset paths) | `Core/` |

There is **one type per file** unless the types are tiny and private to it. A file over about 600 lines, or a function over about 80 lines, needs a reason. Split along a real seam.

## Rules

1. **Implement WE's behaviour, not a look-alike.**
   - Don't add native approximations of WE effects, invented parameter names, or remapped ranges.
   - Don't add special cases keyed on a layer, effect, file or property *name* (`"cloud"`, `"clock"`, `"snow"`…). If a wallpaper renders wrong, find the missing general feature.
2. **Fail loudly.**
   - Don't use `try?` on file IO, decoding, shader translation or pipeline creation. Use `do/catch` and log the error once, with the wallpaper, layer, effect and reason.
   - `try?` is fine for genuinely optional lookups, and a comment should say so.
   - Decode collections element by element, so one bad entry doesn't drop its siblings.
3. **No new global state.**
   - Don't add a new `static let shared`, `AppDelegate.shared` lookups from engine code, or `UserDefaults.standard`. Defaults go through `UserDefaults.app` (`@AppStorage(…, store: .app)`) and files through `AppStorageLocation.current` (`supportDirectory`, `cachesDirectory`), so tests and development copies stay isolated from the user's data. The editor package can't see `.app`: its `@AppStorage` passes the store the app hands it (`WallpaperEditorServices.preferences`). `AppStorageIsolationTests` fails on an `@AppStorage` without a store.
   - Pass dependencies in. State belongs to a wallpaper instance.
4. **Typed keys.** Don't add new `"_owe_…"` string keys. Add a case to the typed settings or property identifiers instead.
5. **Logging** goes through `OWELog`: `.debug` for per-frame detail, `.info` for lifecycle, `.error` for failures. Don't use `print` or raw `NSLog`, and don't log anything every frame at `.info` or above.
6. **Caches are versioned.** Any on-disk cache is keyed on its inputs *and* a revision constant you bump whenever the producing code changes. `ShaderVariantTranslator.revision` is the example; `ShaderVariantCacheTests` fails when translated output changes without a bump. Shader and pipeline caches are keyed on that revision, the toolchain, the device and the OS build, never the app version. `ShaderRevisionGuardTests` hashes the translated MSL of the fixture shaders (and of every WE asset shader with `OWE_ASSETS`) against `Tests/Fixtures/ShaderRevision/expected.json`; after a bump, re-record the pair with `TEST_RUNNER_OWE_RECORD_SHADER_HASH=1 TEST_RUNNER_OWE_ASSETS=<assets folder> xcodebuild test -project OpenWallpaperEngine.xcodeproj -scheme OpenWallpaperEngine -destination 'platform=macOS' -only-testing:OpenWallpaperEngineTests/ShaderRevisionGuardTests` and commit the fixture. Adding or changing a fixture shader pair under `Tests/Fixtures` changes the base hash without changing the translator: re-record it then, without a bump (a bump discards every user's shader cache).
7. **Concurrency.** Mark UI types `@MainActor`. Don't share mutable state across threads without an owner: prefer actors, or one lock that is documented and owns specific fields. Don't add `nonisolated(unsafe)` without a comment explaining why it's safe.
   - **Thread guards.** Mark heavy work with `ThreadGuards.assertBackground` (or `assertNotMainThread` / `assertNotRenderThread`) and per-frame work with `assertRenderThread`. A guard never traps, in any build: every violation (thread, kind, what, call site, a trimmed call stack, time) is recorded in `ThreadGuards.store`. In tests, `ThreadGuardTestObserver` fails the test that caused it when the test ends, one issue per violation (`TEXParser.decode ran on the main thread`, then the top frames), and the other tests keep running; a test that expects violations takes them with `expectThreadGuardViolations { … }`, which keeps them from failing it. Dev builds (Debug, or no release update key, the ones with the Dev badge) also log each call site once at error level and show "Thread guard: N violations — see Diagnostics" in the main window, with the list in Settings › Diagnostics. Release builds only record.
8. **Keep dead code out.** Delete it; git has history. Don't comment code out, and don't keep an unused alternate render path.
9. **UI text goes through `Localizable.xcstrings`.**
   - Pass literals to localizing APIs (`Text`, `Button`, `Label`, `.help`…), or use `String(localized:)` / `LocalizedStringResource` where the text travels as a value (AppKit, errors, view models). A `String` handed to `Text` shows in English in every language.
   - Counts use the catalog's plural variations, not a hand-made "s"; numbers, sizes, durations and lists use the Foundation formatters.
   - Values that are stored or sent (tags, types, ratings) stay English; show them through `LocalizedLabels`.
   - The app ships in 15 languages besides English. A new string needs a translation in each, using the terms in [`docs/localization-glossary.md`](docs/localization-glossary.md). `LocalizationCatalogTests` and `LocalizationLintTests` fail otherwise.

## Debugging

- Read the app's logs with `/usr/bin/log` (a shell `log` alias or function may shadow it), e.g. `/usr/bin/log show --last 10m --predicate 'process == "Open Wallpaper Engine"'`.
- Shaders the translator rejects are written to `~/Library/Caches/app.openwallpaperengine/FailedShaders` for inspection (an isolated copy uses `~/Library/Caches/Open Wallpaper Engine (isolated <tag>)/app.openwallpaperengine/FailedShaders`). The folder is readable only by you (`0700`, files `0600`).

## Tests

- **Where tests go:** the `OpenWallpaperEngineTests` target (unit tests hosted in the app, which starts without its delegate under XCTest). Fixtures live in `Tests/Fixtures/`, outside the target, and are read with `Fixtures.url(_:)`.
- **Every fix or feature comes with a test.** Format and value tests decode fixtures. Rendering checks go in `RenderCheckTests`.
- **Known gaps** are asserted with `XCTExpectFailure("<snapshot id>: …")`. It's strict, so fixing a gap makes its test fail until you delete the expectation.
- **Tests never touch the user's state.** The test host is the app, so under XCTest `AppStorageLocation` switches to the defaults suite `app.openwallpaperengine.isolated.tests`, `Open Wallpaper Engine (isolated tests)` under Application Support and Caches, and isolated keychain services. `AppStorageIsolationTests` guards this. Tests never read the user's assets either: the asset-dependent tests use `OWE_ASSETS=<assets folder or WE install>` (`TEST_RUNNER_OWE_ASSETS` through `xcodebuild`) and skip without it, as on CI. A test that needs them starts with `_ = try Fixtures.assets()`.
- **Launch development copies isolated.** Every build shares the bundle id, so an agent or script that launches a copy of the app (screenshots, smoke runs) must set `OWE_ISOLATED_STATE=<tag>` in its environment or pass `-OWEIsolatedState <tag>`, e.g. `OWE_ISOLATED_STATE=shots "<build>/Open Wallpaper Engine.app/Contents/MacOS/Open Wallpaper Engine" -CustomWallpapersDirectory <library>`. Launch arguments (`-Key value`) still override defaults in the isolated suite. Never launch a dev copy against the real domain: it overwrites the user's playlists, per-screen wallpapers and safe-restart sentinel.
- **The local gate.** A PR should pass `Scripts/ci-local.sh` before it merges. It builds the test bundle and runs every test class the way CI does (parallel classes, then the serial ones, a failing test retried once), then prints each failure with its message and file:line. Run it with the assets and the slow tests: `OWE_ASSETS=~/Library/Caches/owe-we-assets OWE_SLOW_TESTS=1 Scripts/ci-local.sh` (after `Scripts/fetch-we-assets.sh`); `--no-build` reuses the last build. CI is the safety net, not the gate:
  - CI (`.github/workflows/ci.yml`) runs twice per change: on the PR once it has the **ready to merge** label, and on `main` after it merges. Label a PR only when it's done and up to date with `main`: the run fails straight away if the branch is behind `main`. Pushing to a labelled PR runs CI again; a PR without the label runs nothing. The CodeQL scan (`.github/workflows/codeql.yml`) follows the same rule, and also runs weekly. On the PR it runs the suite without assets, in three shards. On a PR it runs only the test classes the changed files select through [`.github/test-map.yml`](.github/test-map.yml); an unmapped file, a workflow or a project or package change runs everything. When you add a source folder or a test class that the map's patterns don't reach, add it to the map.
  - The asset tests run on CI only on `main` and nightly, with assets fetched from Steam and cached only as an encrypted archive whose key (`OWE_ASSET_CACHE_KEY`) lives in the `steam-ci` environment; a PR or fork can restore the file but can't read it ([docs/ci-assets.md](docs/ci-assets.md)), so run them locally with `OWE_ASSETS` before you open a PR.
  - **The slow tier.** Tests slower than about a minute skip unless `OWE_SLOW_TESTS=1`; the nightly workflow (`.github/workflows/nightly.yml`) and `OWE_SLOW_TESTS=1 Scripts/ci-local.sh` run them, pull requests and pushes to `main` don't. A slow test starts with `try SlowTests.require()`; a class whose every test is slow inherits from `SlowTestCase` (`OpenWallpaperEngineTests/Support/SlowTests.swift`). Move a test there only when the durations report shows it is slow and its phase breakdown shows the time can't be cut.
  - **Test durations.** Every CI test job, the nightly and `Scripts/ci-local.sh` list the 25 slowest tests with the phase their time went to (scene load, shader translate, pipeline, texture, particles/models, render with its frame count, GPU wait, scripts, readback, compare), and write every test to a CSV (`test-durations-*` artifacts on CI, `build/ci-local/results/durations.csv` locally; `Scripts/ci-test-durations.py`). The phases come from `OWEPhaseTiming` hooks in the loader and renderers, which `TestPhaseTimer` turns on when `OWE_TEST_PHASES` names a folder (`Scripts/ci-run-tests.sh` sets it); a phase's time is its own time summed over threads. Debug builds only, and a single Bool check when off.
  - **Optimised test builds.** CI, the nightly and `Scripts/ci-local.sh` build the tests as Debug with the settings in `Scripts/test-build-settings.txt` (`-O`, whole module, `ENABLE_TESTABILITY`). `#if DEBUG` code, signing and `@testable import` work as before, but Swift `assert` and `assertionFailure` don't run under `-O` (`precondition` does), and timing budgets tuned for `-Onone` under `#if DEBUG` are now looser than they need to be. A plain `xcodebuild test` from Xcode is unoptimised, as before.
  - **Shader caches.** CI saves the test runs' shader-variant translations and Metal pipeline archive (the isolated test copy's `shader-variants` and `pipeline-archives` caches) between runs, keyed on `ShaderVariantTranslator.revision`, `EffectPipelineArchive.revision`, Xcode, the macOS build and the shader sources. The asset jobs' cache holds MSL translated from Wallpaper Engine's shaders, so it is encrypted with `OWE_ASSET_CACHE_KEY` like the assets; the plain cache holds only the fixtures' shaders.
  - A test that fails and then passes on the retry doesn't fail CI, but the job summary lists it; fix it rather than relying on the retry. A class that flakes under parallel workers goes in the `serial` list of `.github/test-map.yml`.

## Commits and PRs

- Use [Conventional Commits](https://www.conventionalcommits.org/): `fix:`, `feat:`, `perf:`, `refactor:`, `build:`, `docs:`, `test:`.
- Keep commits small and single-purpose. File moves and renames go in their own commit with no logic changes, so review and `git log --follow` stay useful. Asset or vendor drops never share a commit with code.
- Branch from `main` as `<your-name>/<topic>` and open the PR against `main`.
- Performance work goes in one PR per wallpaper type (scene, video, web), and an optimisation stays only if it measurably wins.
- No per-wallpaper hacks: fixes must follow WE's behaviour for every wallpaper (rule 1).
- The PR description says what changed, why, and how it was verified ([template](.github/pull_request_template.md)).

## Reporting bugs

Use the [issue templates](https://github.com/deepratna-awale/open-wallpaper-engine-mac/issues/new/choose). A good report has the wallpaper's Workshop ID or link, its type, the macOS and Open Wallpaper Engine versions, and the logs from the time of the problem:

```sh
/usr/bin/log show --last 10m --predicate 'process == "Open Wallpaper Engine"' > owe.log
```

Security problems go privately through the repository's Security tab ([SECURITY.md](SECURITY.md)).

## Changing the project file

- New files: the project uses folder-synced groups, so putting a file in the right folder is enough. Everything in `OpenWallpaperEngine/` builds into the OpenWallpaperEngine framework, which both apps run ([architecture](docs/architecture.md#targets)); a resource the code reads goes there too and is read through `AppBundleLayout.framework`, not `Bundle.main`.
- Never add Wallpaper Engine files to the repository, the app or `Tests/Fixtures`: tests get them from `OWE_ASSETS`, and fixtures are written for the project.
