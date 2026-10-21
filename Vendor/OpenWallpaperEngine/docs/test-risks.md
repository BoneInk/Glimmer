# Test risks: renderer (A), shaders M9 (B), recent `git log -25`

**Note (2026-09-28):** `Vendor/we-assets` no longer exists. Wallpaper Engine's assets now come from the user's own Steam copy (Settings › Assets, cached in `<Wallpaper Storage>/.owe-assets`) or a chosen Wallpaper Engine folder, and tests read them from `OWE_ASSETS`. Mentions of `we-assets` below describe the tree as it was when this was written.

Status: 2026-09-25, branch `deepratna/feature-work`. Adversarial list; ranked by severity × likelihood.
Paths are relative to `OpenWallpaperEngine/`. **A** = renderer agent, **B** = shaders agent, **R** = already landed.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| 1 | Critical | B | Stale disk variants after the M9 switch |
| 2 | Critical | B | glslang global state is not thread-safe in-process |
| 3 | Critical | B | Static-lib symbol clashes (glslang / SPIRV-Cross / others) |
| 4 | High | B | Corrupt or foreign `MTLBinaryArchive` |
| 5 | High | B | Binary archive keyed to one GPU; GPU switch / eGPU / multi-display |
| 6 | High | B | Async pipeline compile races with `releaseLayer` |
| 7 | High | B | In-process crash/hang replaces a recoverable subprocess failure |
| 8 | High | B/R | Release/CI packaging still expects `shader-tools`; hardened runtime |
| 9 | High | R | Render-target pool evicts targets whose contents must survive |
| 10 | High | A | Screen-space scene snapshot sized/oriented wrong |
| 11 | High | R/A | Retina target on 5K / multi-display / display change |
| 12 | High | A | `.center` placement in points vs pixels |
| 13 | Med | A | `.tex` content size vs allocated (power-of-two) size |
| 14 | Med | A | Freeing effect state for removed clones: use-after-free / leak |
| 15 | Med | A | Particle velocity/gravity under parent rotation |
| 16 | Med | A/B | Pointer and parallax uniforms: coordinate space, multi-display |
| 17 | Med | R | Scene clock after sleep/wake, pause, speed 0 |
| 18 | Med | R | Static-chain cache key reuse (`ObjectIdentifier`) |
| 19 | Med | R | Bundled WE assets on first launch / read-only / translocated bundle |
| 20 | Med | R | Pool byte accounting and budget under memory pressure |
| 21 | Med | R | Per-wallpaper property store key collisions / migration |
| 22 | Med | R | Music-sync on effect overrides |
| 23 | Low | R | LRU caches: not thread-safe, clock wrap, capacity churn |
| 24 | Low | B | Cache dir: bundle id, disk-full, concurrent instances |
| 25 | Low | B/CI | CI runner with older Xcode / SDK |

---

## 1. Stale disk variants after the M9 switch — Critical, B
**Scenario.** The disk cache key includes `revision` and a toolchain fingerprint (`Scene/Shaders/ShaderVariant.swift:54`, `:67-69`, `:123-126`). The fingerprint is built from the *executables'* path/size/mtime (`:75-80`) and is `""` when no process toolchain is used (`:69`). After M9, if the in-process path yields `""` (or any constant), a user who upgrades keeps MSL produced by the old Homebrew glslang/spirv-cross. If in-process SPIRV-Cross options differ (MSL version, argument buffers, `--msl-decoration-binding`, reflection JSON shape), the cached reflection no longer matches what the new binder expects: wrong buffer indices, black layers, or a Metal validation failure. Also: the reverse (downgrade) and a user who still has Homebrew installed.
**Test.**
- Unit: assert `cacheKey(...)` differs between the process toolchain and the in-process toolchain for the same inputs; assert the in-process fingerprint includes glslang + SPIRV-Cross *library* versions (e.g. `glslang::GetVersion()`, `SPIRV_CROSS_C_API_VERSION`) and the option set.
- Unit: seed `~/Library/Caches/app.openwallpaperengine/shader-variants` with a v4 JSON for a known key, run the new build, assert it is not read (or is re-translated).
- CONTRIBUTING.md rule: bump `ShaderVariantTranslator.revision` in the same commit; add a test that fails when the translator output hash for a fixed corpus changes without a revision bump (golden-file test).

**Status (R2, 2026-09-25).** Fixed 8cd197b. The key already held the revision and the library versions and options (1231087). Variants now also live in a directory per revision and compiler, so an upgrade never reads old ones. Verified by `ShaderVariantCacheTests.testVariantsOfAnotherCompilerAreNotReused` and `testTranslatedOutputMatchesItsRevision`: a golden hash of every bundled effect pair's output, keyed by `revision`, fails when output changes without a bump. Also by `InProcessShaderCompilerTests.testFingerprintNamesLibraryVersionsAndOptions`. Update (2026-09-27): the command-line compiler is gone, and `testCacheKeyDiffersBetweenBackends` with it; the golden corpus test is the guard on translated output.

## 2. glslang global state is not thread-safe in-process — Critical, B
**Scenario.** `glslang::InitializeProcess()`/`FinalizeProcess()` are process-global and ref-counted; older glslang has a global pool allocator and symbol-table init that races. Today each translate is an isolated process (`Scene/Shaders/ShaderCompiler.swift:76`), so parallel loads (multi-display, each display's scene loading at once; preloading many effects) were safe. In-process, two `variant(...)` calls run concurrently (`ShaderVariant.swift:109-121` only locks the memory map, not translation) → heap corruption, sporadic wrong SPIR-V, or crashes that are not reproducible. Calling `FinalizeProcess` per compile while another thread compiles is a use-after-free.
**Test.**
- Stress unit test: 64 concurrent `translate` calls over 16 different WE shaders on `DispatchQueue.concurrentPerform`, run under Thread Sanitizer and Address Sanitizer, 50 iterations; compare every output byte-for-byte to a serial run.
- Assert `InitializeProcess` is called exactly once (e.g. `static let` / `dispatch_once`) and `FinalizeProcess` never while the app lives.
- Manual: two displays, two different heavy scene wallpapers, launch with an empty cache.

**Status (R2, 2026-09-25).** Fixed 1231087: `InitializeProcess` runs once (`std::call_once`), is never finalized, and one mutex serializes every library call. Verified by `InProcessShaderCompilerTests.testParallelTranslationMatchesSerial` (24 pairs × 4 rounds concurrent, byte-equal to serial), which also passes under Thread Sanitizer with no reports. Open: two displays loading heavy scenes with an empty cache is manual. ASan was not run.

## 3. Static-lib symbol clashes — Critical, B
**Scenario.** glslang ships its own `spv::` headers and SPIRV-Tools; SPIRV-Cross embeds `spirv.hpp` (`spv::` namespace too). Linking both statically can give ODR violations (different `spv::Op` enum sizes, duplicated inline functions) — the linker silently picks one; crashes only on specific opcodes. Also clashes with any other C++ in the process (MoltenVK-like libs, a future `.mdl` loader). Duplicate `-lc++` / different C++ standard libraries between prebuilt libs and Xcode.
**Test.**
- Build step: `nm -gU` the app binary, grep for duplicate weak `spv::` symbols; fail CI if the linker emits "duplicate symbol" or ODR warnings (`-Wl,-warn_commons`, `-Wodr` with LTO).
- Round-trip test: translate the whole bundled `we-assets/shaders` corpus in-process and compare to the process path (golden). Any difference that is not whitespace is a bug.
- Build Release with LTO and with `-dead_strip`; run the same corpus test on the Release binary.

**Status (R2, 2026-09-25).** Verified. SPIRV-Cross's `spv::` is renamed `spvc_spv` (f28027d). `Scripts/check-toolchain-symbols.sh` (2a11bc6, run in CI) finds no symbol defined by both libraries in Debug or Release objects; the only shared definitions are libc++ instantiations and the libraries' own header inlines in the shim. `testMatchesProcessCompilerOverBundledCorpus` is byte-identical to the Homebrew tools. The Release archive links with dead stripping. Open: LTO is off, and the corpus test runs on the Debug build.

## 4. Corrupt or foreign `MTLBinaryArchive` — High, B
**Scenario.** App killed mid-`serialize(to:)`; disk full; the file written by a newer macOS/driver and read by an older one after a downgrade; two app instances (or login-item + manually launched) writing the same archive. `makeBinaryArchive(descriptor:)` with a corrupt URL throws — or succeeds and `makeRenderPipelineState` crashes deep in the driver.
**Test.**
- Unit: write random bytes / a truncated real archive to the archive path, launch the loader, assert it deletes the file and falls back to an empty archive without crashing.
- Serialize to a temp file then atomically rename; unit test that no partial file exists at the final path after a simulated failure.
- Manual: `kill -9` the app during first-launch warmup, relaunch.

**Status (R2, 2026-09-25).** Fixed a040708 and bdd0b48: writes go to a pid-named temporary file that is renamed into place, and an archive Metal can't open is deleted. Verified by `EffectPipelineArchiveTests`: `testCorruptArchiveIsDiscardedAndReplaced`, `testTruncatedArchiveIsDiscarded` (b68e85f), `testCompiledPipelinesArePersistedAndHitOnTheNextLaunch` (no `.tmp` left behind) and `testConcurrentCompilesSerializeCleanly` (also clean under TSan). With two instances, the last writer wins. Open: `kill -9` during warmup is manual (QA 3).

## 5. Binary archive tied to one GPU; GPU switch — High, B
**Scenario.** Archives contain GPU-specific binaries. MacBook Pro with dGPU/iGPU switching, eGPU hot-plug, or two displays on different GPUs (Intel Mac Pro): a pipeline looked up in an archive from another device silently recompiles (fine) — or code passes the archive to a device other than the one it was created with (error). Also an OS update invalidates everything; archive grows unbounded as keys accumulate.
**Test.**
- Key the archive file by `device.registryID` + OS build + app version; unit test the path function.
- Manual: Intel MBP, toggle "Automatic graphics switching", plug an external display, confirm no errors in `/usr/bin/log stream --predicate 'subsystem CONTAINS "wallpaper"'`.
- Check archive size after 44-wallpaper library sweep, then again after 3 sweeps (should not grow).

**Status (R2, 2026-09-25).** Fixed a040708: there is one file per GPU (name and registry ID), OS build, app build and revision, and this GPU's stale files are deleted. Each write holds only the pipelines of the last session that compiled something, which bounds the size. Verified by `testEachGPUHasItsOwnArchive` (b68e85f), `testArchivesForAnotherBuildOfThisGPUAreDeleted`, `testRenderersOfADeviceShareOneArchive` and `testBuiltinEffectPipelinesSurviveRepeatedWritesAndLaunches`. Open: a real GPU switch or eGPU is manual; no dual-GPU Mac was available.

## 6. Async pipeline compile races with `releaseLayer` — High, B
**Scenario.** A layer requests a pipeline asynchronously, then the wallpaper is switched (or a clone is removed, see #14) and `releaseLayer` runs before the completion handler; the handler writes into freed state or re-inserts a pipeline for a dead layer (leak). Two layers requesting the same key concurrently compile twice and one overwrites the other's cache entry while a frame is encoding with it.
**Test.**
- Unit: fake compiler with a controllable delay; request → `releaseLayer` → complete; assert no entry remains and no crash (TSan).
- Unit: two concurrent requests for one key produce one compile (in-flight dedupe).
- Manual: rapidly switch wallpapers (arrow keys in library) 30× with an empty cache.

**Status (R2, 2026-09-25).** Fixed 96a746b: the check for a pending compile and marking it pending were two separate locked steps, so two callers could both start one. Pipelines are keyed by variant, not by layer, and a completion only writes the shared cache under the lock. Verified by `EffectGraphTests.testReleaseLayerWhileItsPipelinesCompile` (no state comes back, and the next layer reuses the compiles) and `testConcurrentRequestsCompileEachPipelineOnce` (clean under TSan). Open: switching wallpapers 30× with an empty cache is manual.

## 7. In-process failure modes replace a recoverable subprocess — High, B
**Scenario.** The spawn path has a 30 s timeout and isolates crashes (`ShaderCompiler.swift:73`, `:76-100`). In-process, a glslang `assert`/`abort` on a malformed WE shader, an infinite loop in the preprocessor, or a stack overflow on deeply nested macros kills the whole app — and the menu-bar/login-item app then crash-loops on relaunch with the same wallpaper. `~/Library/Caches/app.openwallpaperengine/FailedShaders` dumping may also be lost.
**Test.**
- Fuzz: feed the translator truncated/garbled versions of 50 WE shaders; the app must return an error, not abort. Build glslang with `NDEBUG` in Release.
- Test that a failed shader still lands in `~/Library/Caches/app.openwallpaperengine/FailedShaders`.
- Crash-loop guard: if the app crashed during translation last launch, start without restoring the wallpaper (manual: inject a crash).

**Status (R2, 2026-09-25).** Fixed 0be8b90 and earlier. glslang builds with `NDEBUG`. `InProcessCompileCrashGuard` turns in-process compiling off after 2 deaths mid-compile, and safe restart skips the wallpaper. Fixed d9b00ee and 0418de2: the `~/Library/Caches/app.openwallpaperengine/FailedShaders` dump had been lost with the process translator. Verified by `ShaderVariantCacheTests.testGarbledSourcesFailWithoutCrashing` (truncated and garbled WE shaders, 20 000 parentheses, 2 000 nested `#if`), `testRejectedSourceIsWrittenForInspection` and `testFactoryFallsBackOnlyAfterRepeatedCrashes`, plus the crash-guard tests in `InProcessShaderCompilerTests`. Fixed e671ff6: in-process compiles run on a dedicated thread (16 MB stack) under a 20 s watchdog on the job's run time. A hung compile fails its variant, counts as a death for the crash guard (so a hang that recurs turns in-process compiling off on the next launch), and routes every later compile this session to the process compiler, since the stuck thread keeps glslang's lock. Verified by `InProcessShaderCompilerTests.testCompileThreadTimesOutAndFailsQueuedJobs`, `testTimeoutCountsRunTimeNotQueueTime`, `testHungCompileFailsItsVariantAndHandsOverToTheFallback` and `testHungCompileWithoutFallbackFailsFast`. Open: without Homebrew's tools, compiles after a hang fail for the rest of the session.
**Update (2026-09-27).** The command-line fallback compiler was removed at the user's request, and the crash guard now quarantines per shader instead of turning in-process compiling off. The marker names the shader in flight (a hash of the step, stage and full input, combos included). Two deaths compiling the same shader, or one hang, quarantine it for that library build: later launches skip it (its variant fails, logged, source dumped to `~/Library/Caches/app.openwallpaperengine/FailedShaders`) and every other shader compiles. After a hang the rest of that session's compiles fail at once, since the hung thread holds glslang's lock; the next launch compiles normally. Verified by `InProcessShaderCompilerTests` (`testShaderThatKilledTheAppTwiceIsQuarantined`, `testDeathsCountPerShader`, `testDeathWithoutAShaderQuarantinesNothing`, `testCrashGuardIgnoresLiveProcessesAndCleansUp`, `testShaderKeyCoversStepStageAndVariant`, `testQuarantinedShaderIsSkippedAndOthersCompile`, `testHungCompileQuarantinesItsShaderAndFailsFast`) and `ShaderVariantCacheTests.testFactoryQuarantinesAShaderThatKilledTheAppRepeatedly`.
**Update (2026-09-29).** Rejected sources moved from a shared `/tmp` folder to `FailedShaderDump.defaultDirectory` (`<AppStorageLocation.cachesDirectory>/app.openwallpaperengine/FailedShaders`): the folder is `0700`, each file is created `0600` and never written through a symbolic link. Verified by `FailedShaderDumpTests`.

## 8. Packaging still expects `shader-tools`; hardened runtime — High, B / CI
**Scenario.** The release workflow asserts `Contents/Resources/shader-tools/glslangValidator` and `spirv-cross` exist and are executable, and CI `brew install`s them (`.github/workflows/*` "Verify bundle before notarizing"; `brew install glslang spirv-cross`). M9 removes them → release fails, or the tools are kept and unsigned binaries are notarized needlessly. If glslang is instead linked as a *dylib*, it must be signed with the same team, embedded under `Frameworks`, and library validation (hardened runtime) rejects an unsigned/ad-hoc dylib at launch — works in Debug, crashes in the notarized build. `SceneShaderTranslator.swift:18-19` still searches `/opt/homebrew/bin` and `/usr/local/bin`: a stale Homebrew toolchain could be preferred over the in-process one.
**Test.**
- Update the verify step: assert no `shader-tools`, run `codesign --verify --deep --strict` and `otool -L` shows no `/opt/homebrew` paths.
- Manual on a clean Mac/VM with no Homebrew: install the notarized DMG, open a scene with effects.
- Unit: the translator factory returns the in-process backend even when `/opt/homebrew/bin/glslangValidator` exists.

**Status (R2, 2026-09-25).** Fixed 9dda345: removed the Vendor Shader Tools build phase and its script, the bundle path from the fallback search and Homebrew from the release workflow. The release check now asserts that there is no `shader-tools`, that the WE assets are bundled, a Developer ID signature, the hardened runtime, only `/usr/lib` and `/System` libraries, and no extra executables. The linked libraries are static, so library validation has no dylib to reject. Verified locally on a Release archive: `codesign --verify --deep --strict` passes, `flags=0x10002(adhoc,runtime)`, `otool -L` lists system libraries only, and the verify step's checks pass. Also by `ShaderVariantCacheTests.testFactoryPrefersTheLinkedCompiler` with Homebrew installed (2026-09-27: the fallback search is removed; `testFactoryMakesTheGuardedLinkedCompiler`). Tests translate in-process, so they need no Homebrew (1da4ae8). Open: Developer ID signing and notarization run only in the workflow, which hasn't run yet. QA 1 (a clean Mac) is manual.

## 9. Pool evicts targets whose contents must survive — High, R (9cccfe2, d05e689)
**Scenario.** `SceneRenderTargetPool.endFrame()` drops any bucket untouched for 600 frames (`Scene/Rendering/SceneRenderTargetPool.swift:64-67`) and `evictOverBudget` drops the LRU bucket over 256 MB (`:73-80`). Anything that relies on *previous-frame content* (ping-pong feedback effects, `_rt_` persistent targets, cached static-chain results from #18) gets a fresh uninitialised texture: trails reset, or garbage because `.private` storage is not cleared. 600 frames = 5 s at 120 Hz, 10 s at 60 Hz, so a layer hidden by a script for a few seconds loses its state; behaviour depends on refresh rate. Also: `texture(...)` returns `buckets[key]!.textures.first` (`:46-48`) — two consumers of the same size in one frame get the *same* texture unless `avoiding` is passed.
**Test.**
- Unit: request A, then `endFrame()` 601× without touching A, request again → assert the caller that holds a persistent target is notified/re-seeded (or persistent targets are excluded from the pool).
- Unit: two requests of the same key within a frame without `avoiding` → assert distinct textures (or document the contract).
- Headless: render a feedback-effect wallpaper 120 frames, hide the layer for 700 frames, show it → compare to reference.

**Status (R2, 2026-09-25).** Fixed 7272f67: frame leases, persistent leases that are never evicted or shared, and idle eviction by wall time instead of frames. Verified by `SceneRenderTargetPoolTests` (distinct textures within a frame, `avoiding`, idle by time at 240 Hz, persistent targets and LRU over budget). Effect ping-pong and FBO targets are per layer in `EffectGraphRenderer`, not pooled, so a hidden layer keeps them. Memory pressure trims free targets (#20).

## 10. Screen-space scene snapshot — High, A
**Scenario.** Rotated or partly off-screen layers whose effect reads the scene (`_rt_FullFrameBuffer`, refraction). Edge cases: rotation 90°/180° (width/height swap), negative scale (mirrored), layer entirely off-screen (zero-size rect: `pixelRect` returns nil at `Scene/Rendering/SceneRenderResolution.swift:33-`), snapshot taken before vs after the layer's own draw (feedback into itself), Retina scale (#11) applied twice or not at all, y-flip between scene y-up and texture y-down.
**Test.**
- Headless render check: synthetic scene with a checkerboard background and a 45°-rotated layer running a pass-through "sample framebuffer" effect; the output inside the layer must equal the background pixels under it (tolerance 1/255). Repeat for 90°, 180°, mirrored, half off-screen, fully off-screen.
- Unit: `pixelRect` for a box beyond every edge returns nil; for NaN/inf returns nil.
**Status (R1, 2026-09-25).** Verified by `SceneRegionResampleTests` (e3cb90f): a headless round trip through `sceneCopyFragment` and `sceneVertex` gives back the scene beneath for quads at 0/45/90/180/270°, mirrored on x or y, sheared, and half or fully off-screen. Zero, NaN and infinite quads cover no pixels. `pixelRect` no longer exists (bd8ceba). Since 221bed9 a blend-mode material or scene-input layer copies only its quad's padded bounding rect into one per-frame snapshot target, and a copy that still matches is shared (`SceneSnapshotTracker`); effects that read the scene still get all of it. Verified by `SceneSnapshotTrackerTests` (rect maths, sharing, and three `BLENDMODE` layers over each other reading the right scene from partial copies).

## 11. Retina target on 5K / multi-display / display change — High, R/A
**Scenario.** `pixelsPerUnit` caps at 8192 px and `maximumPixelCount` (`SceneRenderResolution.swift:10-23`). A 1920×1080 scene on a 5K (5120×2880) display → ~2.67 ppu → 5120×2880 targets × every effect pass × rgba16Float = hundreds of MB, immediately over the pool's 256 MB budget (#20) → eviction thrash every frame. Dragging a window between a 1× and 2× display, or `didChangeScreenParametersNotification` (`App/AppDelegate.swift:107`), must re-size targets; `g_Screen` is set from `drawableSize` (`Scene/Rendering/SceneMetalRenderer.swift:356`) — check effects that divide by `g_Screen` still line up with a target that is not the drawable size. Ultrawide 32:9 or portrait scenes on a landscape display.
**Test.**
- Unit: table test of `pixelsPerUnit`/`targetSize` for 5K, 6K XDR, 32:9, portrait, 0-size drawable, scene 1×1, scene 20000×20000.
- Manual: 5K or 6K display + laptop panel, move a scene between them, watch memory in Activity Monitor and `/usr/bin/log` for pool churn.
**Status (R1, 2026-09-25).** Fixed 79223dc: the scene target follows the drawable's density with no 5K or 8192 px cap, as WE draws at the display's resolution. Only a target past Metal's 16384 px limit is scaled to fit; before, it failed to allocate every frame. Verified by `SceneRenderPrimitivesTests.testTargetSizeTable` (5K, 6K, 32:9, portrait, no drawable, 1×1, 20000², NaN) and `testTargetIsLimitedOnlyByTheLargestTexture`. `g_Screen` is the target size (053cb7d). Open: effect-target memory at 6K against the pool's 256 MB budget is unmeasured (the pool is B's). Moving between displays is manual (QA 4).

## 12. `.center` placement in points — High, A
**Scenario.** `WallpaperPlacement.center` (`Core/Wallpaper/WallpaperPlacement.swift:7`) now in points: on a 2× display a 1920×1080 image is drawn at 3840×2160 pixels (larger than a 1440p-point screen → cropped) — is that what WE does? Mixed-DPI setups; scaled resolutions ("Looks like 1680×1050" on a 2880×1800 panel, backing scale 2 but not integer mapping); video and web wallpapers using the same enum.
**Test.**
- Unit: placement rect for (image 1920×1080, screen 1440×900 pt, scale 2) and scale 1; compare to WE on Windows at 100%/200% (screenshots).
- Manual: System Settings → Displays → switch between scaled modes while a centered scene/video runs.
**Status (R1, 2026-09-25).** Verified by `SceneRendererPlacementTests.testCenterPlacementIsOnePointPerSceneUnit` and `testCursorMapsThroughThePlacement` (070eafd). Open: whether WE's own centre placement is one point or one pixel per unit at 200 % needs WE-on-Windows captures at 100 % and 200 % scaling.

## 13. `.tex` content size vs texture size — Medium, A
**Scenario.** WE `.tex` files store an allocated (often power-of-two) size and a content size. Passing the content size to effects (`g_Texture0Resolution`, `g_TexelSize`) wrong way round → UVs off by the padding; sprite sheets (animated `.tex`) where each frame has its own size; mipmapped `.tex` where only mip 0 has the content size; content size 0 in old files.
**Test.**
- Unit on `Scene/Format/TEXParser.swift`: fixtures with padding (e.g. 1000×600 in 1024×1024), sprite sheet, content size 0 → assert fallback to texture size and `xy/zw` components of `g_Texture0Resolution` are (texture, content) as WE expects.
- Headless: an image layer with a padded `.tex` + a pass-through effect → no visible border strip.
**Status (R1, 2026-09-25).** Fixed 6fb64b5: unsized layers and sprite frames were sized by `NSImage.size`, which is in points and depends on DPI, instead of pixels. Verified by `TexContentCropTests` (including `testLayerSizeIsInPixelsWhateverTheImageDPI`), `SceneRendererPlacementTests.testCompressedTextureCarriesContentSize`, `EffectGraphCachingTests.testTextureResolutionReportsAllocatedThenContentSize` and `ImageMaterialRenderTests.testPaddedContentCropMatchesTheNativeDraw`.

## 14. Freeing effect state for removed clones — Medium, A
**Scenario.** Script `destroyLayer`/clone removal while the frame is encoding: freeing the effect state (targets returned to the pool) while the GPU still reads them from an in-flight command buffer → next frame hands the same texture to another layer while GPU still writes it (flicker). Removing a clone that shares a static-chain cache entry with its original (#18). Clone removed and re-created in the same frame gets the old state.
**Test.**
- Unit: create 100 clones, remove all, run `endFrame()` → assert state count back to baseline (leak check).
- Headless: script that creates/destroys a clone every frame for 1000 frames; memory flat, no Metal validation errors (`MTL_DEBUG_LAYER=1`).
**Status (R1, 2026-09-25).** Verified by `SceneDeferredReleasesTests` (6e51f34): state waits for the command buffer that last drew it, and a re-created id keeps its new state. Also by `ImageMaterialRenderTests.testRemovedClonesFreeTheirUniformState` (100 clones leave 0 programs) and `EffectGraphTests.testReleaseLayerFreesItsStateAndTargetsAreReused`. Open: a 1000-frame create/destroy run under `MTL_DEBUG_LAYER=1` is manual.

## 15. Particle velocity/gravity under parent rotation — Medium, A
**Scenario.** Emitters in world vs local space (`Scene/Loading/SceneParticleEmitterSpace.swift`). Rotating the parent should rotate emitted velocity but *not* gravity (gravity is world-space in WE) — or the reverse depending on flags. Double application when both parent and emitter are rotated; non-uniform parent scale; negative scale; animated parent rotation (already-emitted particles must not swing with the parent in world-space mode).
**Test.**
- Unit: emitter with velocity (0,100) and gravity (0,-10), parent rotated 90°: assert after 1 s the particle position in both space modes matches hand-computed values.
- Manual: compare with WE on Windows for a snow/rain wallpaper with a rotated emitter.
**Status (R1, 2026-09-25).** Unchanged, because particle code is the particle agent's. Verified by `SceneRendererPlacementTests.testEmitterDirectionsFollowParentRotationNotScale` and `SceneReviewFixTests.testEmitterSpaceIncludesParentScaleAndRotation`. Open: bd8ceba turns gravity with the emitter; whether WE does needs a WE capture of a rotated snow or rain emitter.
**Status (particles, 2026-09-25).** The emitter's transform is now live (animated and scripted parents), and gravity follows WE's `movement` flag 1: without it gravity turns with the emitter, with it gravity is scene space. Particles live in the emitter's space and move, turn and scale with it unless the system's `worldspace` flag (bit 0) is set (WE's docs: worldspace particles "ignore the position and rotation of the particle system after they have been created"). Verified by `ParticleEmitterMotionTests` (local particles follow a moved, turned and scaled emitter; worldspace ones stay), `ParticleSimulationParityTests.testParticlesFollowAMovingEmitter` and `testWorldSpaceParticlesIgnoreAMovingEmitter` (CPU and GPU agree under a moving emitter), and `SceneRendererParticleFamilyTests.testGPUParticlesFollowTheirAnimatedParent`. Open: sprite sizes under a non-uniform scale take the area scale; WE's model matrix would squash them.
**Status (particles, 2026-09-25, later).** Sprites are drawn through the emitter's transform, as WE's `genericparticle` expands a sprite in the system's space before `g_ModelViewProjectionMatrix` (linux-wallpaperengine and wallpaper-scene-renderer build the same model matrix, scale included): sizes and rotations stay local, the material path passes the emitter's linear as `g_OrientationRight/Up`, the built-in draw as the quad's axes, and trail and rope widths take its area scale. A non-uniform scale squashes and skews sprites; the emitter's first transform counts, not only its moves; a `worldspace` particle takes the area scale and turn when it spawns. Verified by `ParticleEmitterMotionTests.testANonUniformScaleSquashesSprites`, `testWorldSpaceParticlesTakeTheEmitterScaleWhenTheySpawn`, `ParticleMaterialRenderTests.testANonUniformEmitterScaleSquashesTheSprite` (both stages) and `ParticleSimulationParityTests.testBuiltInSpritesTakeTheEmitterTransform`. Open: WE simulates in the system's units, so velocities, gravity and operator distances would scale with the object as well; ours turn with it but stay scene units. Worldspace sprites under a non-uniform scale take the area scale. Both need a WE capture to settle.

## 16. Pointer and parallax uniforms — Medium, A/B
**Scenario.** `g_PointerPosition`, `g_PointerPositionLast`, `g_PointerState`, `g_ParallaxPosition` (`Scene/Rendering/BuiltinUniforms.swift:67-68`, `:110-113`). Pitfalls: y-up vs y-down; normalised to the display vs to the scene (cropped with `cover` placement); multi-display (cursor on display 2 while display 1 renders — clamp or freeze?); desktop covered by windows (no mouse events delivered to the desktop-level window; must poll `NSEvent.mouseLocation`); `pointerLast == pointer` on first frame (no velocity spike); parallax influence 0 and the `0.5 + (mouse − 0.5)·influence` formula (`:15`); uniforms stay constant when "pause on fullscreen app".
**Test.**
- Unit: frame context builder with mouse at each display corner, display origin negative (display left of main), scene cropped → expected values.
- Manual: a parallax wallpaper, move cursor across two displays arranged vertically.
**Status (R1, 2026-09-25).** Verified by `SceneRendererPlacementTests.testCursorMapsThroughThePlacement` (070eafd: fill, fit, center and stretch, clamped to 0…1), `BuiltinUniformTests.testPointerParallaxAndScreen` and `SceneCursorTrackerTests` (the pointer stays put while on another display; on the first frame `pointerLast == pointer`). y points up (0 at the bottom), which matches the flip WE's own `cursorripple` and `xray` shaders apply ("Flip pointer screen space Y to match texture space Y"). Open: confirming the on-screen ripple position needs a WE capture. Under `fill` cropping, the pointer is normalised to the scene, not the display.

## 17. Scene clock after sleep/wake, pause, speed 0 — Medium, R (d75c0b0)
**Scenario.** `SceneClock.advance` clamps a frame delta to 0.25 s (`Scene/Rendering/SceneClock.swift:9`, `:22`), good for sleep. But `g_Time` is sent as `Float(frame.time)` (`BuiltinUniforms.swift:107`); after days of uptime without re-load precision drops (at 2^17 s ≈ 36 h resolution is ~8 ms; at ~1 week 60 ms) → jittery animations. Speed 0 stops time: any code that divides by `delta` gets NaN. Is `g_Daytime` wall-clock (should be) and not the scene clock?
**Test.**
- Unit: advance with speed 0, NaN, negative, inf, backwards wall time, 1-hour gap.
- Unit: set time to 7 days and assert that effects use a wrapped time (or doc the limitation).
- Manual: close the lid 10 min, open: no jump, no burst of particles.
**Status (R1, 2026-09-25).** Fixed 19e6ec7: a non-finite wall time made the clock NaN permanently. Verified by `SceneRenderPrimitivesTests.testClockSurvivesDegenerateSpeedsAndWallTimes` (speed 0, −1, NaN and ±∞, a backwards clock, an hour-long gap), `testSpeedChangeDoesNotJump` and `BuiltinUniformTests.testTimeIsNotWrappedOverLongRuns` (`g_Time` is not wrapped, as in WE; debcb9f). `g_Daytime` reads the wall clock.

## 18. Static-chain cache key — Medium, R (30836fa)
**Scenario.** The cache compares textures by identity because an `ObjectIdentifier` can be reused after free (`Scene/Rendering/EffectGraphRenderer.swift:52`). Remaining holes: a *reused* pool texture (#9) is the same object with new content → stale cache hit; scripted `g_Color`/`g_Alpha` or user-property changes that are not in the key (roadmap notes area 8 item 5); music-sync override (#22) changes a constant every frame yet the chain is cached as static.
**Test.**
- Unit: build a chain, change only a user property bound to an effect constant → assert the chain re-renders.
- Unit: return a texture to the pool, have another layer write into it, assert the cache misses.
**Status (R1, 2026-09-25).** `EffectGraphRenderer` is B's. Verified by `EffectGraphReuseTests.testStaticChainRerendersWhenColorAlphaOrInputVersionChange` and `EffectGraphTests.testStaticChainIsReusedAndAnimatedChainIsNot`. User-bound and music-synced constants are dynamic, so their chains are never cached as static (`UniformProgram.isStatic`).

## 19. Bundled WE assets: first launch, read-only, translocation — Medium, R (0916434, f2abfb8)
**Scenario.** `WallpaperEngineAssets.directory` = configured ?? bundled (`Core/WallpaperEngineAssets.swift:28-30`). First launch on a Mac with no WE install and no Homebrew: effects must work purely from `we-assets` + in-process translation. The app bundle is read-only (DMG, `/Applications` owned by root, App Translocation from Downloads): any code that writes derived files next to `we-assets` fails. A stale `WallpaperEngineAssetsDirectory` default pointing at an unmounted external drive → `configured` returns nil (good) but is it re-evaluated after the drive mounts? The tests now use the bundled copy (f2abfb8): tests may pass with the bundle but miss regressions in a real WE install with newer shaders.
**Test.**
- Manual: fresh macOS user, no Homebrew (`PATH` without `/opt/homebrew`), download the notarized zip, open it from Downloads (translocated), pick an effect-heavy scene.
- Unit: `chmod -R a-w` a copy of the bundle resources, run a load; assert no writes.
- CI: keep one optional job that runs the WE-asset tests against a real install when present.
**Status (R1, 2026-09-25).** Fixed cd4e7e6: shared assets came from either the configured install or the bundled copy, never both. A file an older install lacks now resolves from the bundled copy. Verified by `WallpaperEngineAssetsTests`: the bundled copy ships and is used with no install, an install on a drive that mounts later is picked up, and the lookup order holds. Open: a read-only or translocated bundle and a Mac without Homebrew are manual (QA 1).
**Update (2026-09-27).** The assets-folder setting was removed at the user's request: the app always uses the bundled copy, and a saved `WallpaperEngineAssetsDirectory` is ignored. Tests can still point the test host at a WE install with `OWE_WE_ASSETS` (`WallpaperEngineAssets.testInstall`, nil outside XCTest). `WallpaperEngineAssetsTests.testBundledAssetsAreShippedAndUsed` checks a saved value is ignored.

**Update (2026-09-28).** No WE assets ship any more (`Vendor/we-assets` is gone). The app resolves them from a chosen WE install (`WallpaperEngineAssetsDirectory`, reinstated), else the cache in the Wallpaper Storage folder (`.owe-assets`, filled from the user's Steam copy by Settings › Assets), else none. Tests read only `OWE_ASSETS` and skip without it (`Fixtures.assets()`); `WallpaperEngineAssetsTests` and `WallpaperEngineAssetsInstallTests` cover the order, the cache subset, the SteamCMD script and the missing state.

## 20. Pool byte accounting under memory pressure — Medium, R
**Scenario.** `bytes(of:)` ignores mip levels, array layers, MSAA sample count, and compressed/depth formats default to 4 bpp (`SceneRenderTargetPool.swift:82-92`), so resident memory is under-counted. No reaction to `DispatchSource.makeMemoryPressureSource` or `MTLDevice.currentAllocatedSize`; `evictOverBudget` never evicts the protected key, so one giant bucket (5K rgba16Float with many layers) exceeds the budget forever. 8 GB Macs with shared memory under pressure → system swapping.
**Test.**
- Unit: pool with 1 MB budget, request a 4 MB texture → assert it's served and a later small request evicts it.
- Manual: 8 GB Mac, two 4K displays with heavy scenes + Xcode open; `memory_pressure -l warn`; watch the app's footprint.
**Status (R1, 2026-09-25).** The pool is B's. Fixed by 7272f67: it counts `allocatedSize`, never evicts leased targets, and ages targets out by wall time. Verified by `SceneRenderTargetPoolTests`. Fixed d73bf75: each renderer observes `DispatchSource.makeMemoryPressureSource`; a warning drops the pool's free targets, cached text beyond the current strings, spare effect targets and free uniform chunks, and a critical event also drops effect asset textures and pipelines idle since the last critical trim. Leased, persistent and layer-owned targets stay. Verified by `SceneMemoryPressureTests` (a blend layer still draws through its material on the frame after a critical trim) and `EffectGraphReuseTests.testMemoryPressureDropsSpareTargetsAndIdlePipelinesOnly`. Open: particle material pipelines aren't trimmed, and the manual 8 GB check is not done.

## 21. Per-wallpaper property store — Medium, R (0ba2720, 286158d)
**Scenario.** Keys per wallpaper instance: same wallpaper on two displays (one store or two?), workshop id vs folder path (a moved library changes keys → user settings lost), a property named with dots/slashes, deleting a wallpaper leaves orphans, a property changing type after a workshop update (bool → combo) → decode fails and crashes or silently resets.
**Test.**
- Unit on `Scene/Scripting/SceneUserPropertyStores.swift`: type change on stored value, two displays same wallpaper, key containing `.`.
- Manual: set a colour on display 1, check display 2; move the library folder; relaunch.
**Status (R1, 2026-09-25).** Verified by `SceneUserPropertyStoreTests` (1011bf9): a bool that becomes a combo, keys with dots and slashes, and one wallpaper on two displays sharing one entry. Open: it's unknown whether WE keeps properties per monitor. Fixed 23db937: stored settings are keyed by the Workshop id (or Steam's numeric folder), else a hash of `project.json` plus the folder name. Verified by `WallpaperSettingsIdentityTests`. Since 2026-10-05 a local wallpaper's identity is an id the app keeps per folder (`LocalWallpaperIdentities`: follows a move or rename by the folder's node, a copy gets its own), so title, tag and rating edits no longer orphan its settings; an old hash that still holds settings becomes the id. Open: scene music and video music-sync settings are still keyed by path.

## 22. Music sync on effect overrides — Medium, R (3ca15ea)
**Scenario.** Inspector override of an audio-bound constant: when audio capture is denied or stops (sleep/wake, device switch to AirPods), does the override freeze at the last value or fall back to the authored one? Override removed while music is playing. Interaction with #18 (static-chain cached). Audio buffers from two scenes on two displays.
**Test.**
- Manual: enable an override on an audio-reactive effect, deny screen/audio recording permission, then grant; switch output device mid-song.
- Unit: override resolution with a nil audio snapshot returns the authored value.
**Status (R1, 2026-09-25).** Verified by `SceneReviewFixTests.testSyncedOverrideFallsBackToItsValueWithoutAudio` (1011bf9). When capture stops or is denied, `resetAudioLevels` sets the level to 0, so a synced override reads the user's value. `testSyncedOverrideBindsToItsProperty` makes it a dynamic `.user` binding, so #18 never caches it. Open: switching the output device mid-song is manual (QA 14).

## 23. LRU caches — Low, R (d75c0b0)
**Scenario.** `SceneLRUCache` is a struct with no lock (`Scene/Rendering/SceneLRUCache.swift:3-21`); fine only if every access is on the render thread — any access from a load/background queue (text layout preparation, font registry) is a data race. Eviction is O(n) per insert past capacity; text layers whose string changes each frame (clock wallpapers) churn the 128-entry text cache (`SceneMetalRenderer.swift:128`) and re-rasterise every frame.
**Test.**
- TSan run of a clock-text wallpaper for 60 s.
- Unit: capacity 2, insert 3, assert the least recently *read* entry goes.
**Status (R1, 2026-09-25).** Verified by `SceneRenderPrimitivesTests.testLRUEvictsLeastRecentlyUsed`: the least recently *read* entry goes. The text cache is touched only on the main (render) thread, and content loads hand off to main before touching it. The `UInt64` clock doesn't wrap in practice. Open: a TSan run of a clock wallpaper is manual.

## 24. Cache directory hygiene — Low, B
**Scenario.** Variants live under `Caches/app.openwallpaperengine/shader-variants` (`ShaderVariant.swift:86-88`) — hard-coded id that doesn't match the renamed app; sandboxed builds get a container path. Disk full → `write(.atomic)` (`:190`) throws: must not crash. Two app instances writing the same key (atomic rename makes this safe) but the binary archive (#4) is not. Unbounded growth over library sweeps.
**Test.**
- Unit: point the cache dir at a read-only folder → translation still succeeds (no persist).
- Manual: check cache size after 44-wallpaper sweep; add a size cap or document.

**Status (R2, 2026-09-25).** Fixed 8cd197b: variants are stored per generation (`r<revision>-<compiler hash>`). Other generations and the old flat files are deleted after a week unused. The path's bundle id still matches the app's (`app.openwallpaperengine`). Verified by `ShaderVariantCacheTests`: `testVariantsLiveInTheirGeneration`, `testStaleGenerationsArePruned`, `testUnwritableCacheStillTranslates` and `testCorruptCachedVariantIsRetranslated`. Tests no longer write the user's pipeline archive (1da4ae8). Open: within one generation the cache grows with the variants used, which is bounded by the library.

## 25. CI with older Xcode / SDK — Low, B/CI
**Scenario.** CI uses `macos-15` and picks the latest Xcode; a runner with an older Xcode lacks newer `MTLBinaryArchive`/Metal 3 APIs or C++20 features glslang needs; prebuilt static libs compiled with a newer clang (`-fcoroutines`, newer libc++ ABI) fail to link on older Xcode; deployment target mismatch warnings ("built for macOS 15 newer than 14"). Building glslang from source in CI adds minutes and may time out.
**Test.**
- Add a CI matrix leg with the oldest supported Xcode; `-Werror` on "was built for newer macOS version".
- Guard new Metal APIs with `if #available` and a unit test that the fallback path (no archive) still compiles pipelines.

**Status (R2, 2026-09-25).** Fixed 2a11bc6. CI and release pin Xcode 16.4, the oldest supported version, instead of the newest on the image, so development on the newest Xcode and CI on the oldest cover both. CI fails on "built for newer macOS version" link warnings and on toolchain symbol clashes. The Metal APIs used (`MTLBinaryArchive`, `.failOnBinaryArchiveMiss`) need macOS 11, below the 14.0 deployment target, so no `#available` is needed. The no-archive path runs in `ImageMaterialRenderTests` (`archive: nil`). Open: nothing was built with Xcode 16.4 locally (only Xcode 27 is installed); CI is the check.

---

## Manual QA checklist (on screen)

1. Fresh macOS user, no Homebrew, no WE install: open the notarized app from Downloads, pick an effect-heavy scene; effects render, `Console` shows no shader errors, `~/Library/Caches/app.openwallpaperengine/FailedShaders` stays empty.
2. Delete `~/Library/Caches/app.openwallpaperengine`, launch, time the first load of a heavy scene (should be seconds, not minutes); relaunch, second load near-instant.
3. `kill -9` the app during that first load; relaunch: no crash, no crash loop.
4. Two displays (one Retina, one not), two different scenes; drag/rearrange displays in System Settings; change a scaled resolution. Text stays sharp, nothing misaligned, memory stable.
5. 5K/6K display: check Activity Monitor memory after 5 minutes; should plateau.
6. Move the cursor across both displays on a parallax and a pointer-reactive wallpaper; no jumps at the display border, correct y direction.
7. Rotated-layer wallpaper with a refraction/framebuffer effect: no offset or mirrored background.
8. A `.center` placed wallpaper on 1× and 2× displays: same apparent size as WE on Windows at 100%/200%.
9. Particle wallpaper with a rotated parent: gravity still points down.
10. Speed slider 0 → 1 → 3 and back: no jump in time; pause/resume.
11. Sleep 10 min, wake: animations continue smoothly, audio-reactive effects resume, no particle burst.
12. Hide a feedback/trail layer via script or property for >10 s, show it: no garbage frame.
13. Set user properties on one wallpaper, switch away and back, relaunch: values kept; other wallpapers unaffected.
14. Enable a music-synced effect override, play music, switch output to headphones, deny then grant audio permission.
15. Rapidly switch wallpapers 30× in the library: no crash, memory returns to baseline.
16. Intel MBP only: toggle automatic graphics switching / plug external display: no blank frames.

---

# Area 1: image materials and geometry emulation

Status: 2026-09-25, branch `deepratna/feature-work`, base `4154ccd`. Roadmap area 1 items 3 and 4.
**E** = image-material agent (genericimage/2/3/4 and custom image-layer materials drawn through WE shaders).
**F** = geometry-emulation agent (`genericparticle.geom`, `genericropeparticle.geom`, `flatpoint.geom`, workshop `.geom`, particles through WE particle materials).
Paths are relative to `OpenWallpaperEngine/` unless they start with `Vendor/`. Library numbers come from `/Volumes/980Pro/OpenWallpaperStorage` (43 scenes): 243 image objects; 133 `genericimage*` material passes (101 of them `genericimage4`); 79 `genericparticle` passes; 33 objects with `colorBlendMode`, 21 with `copybackground`, 18 with `clampuvs`, 17 with `perspective`, 24 with `solid`; 25 models with `cropoffset`; combos seen: `VERSION` (16), `REFRACT` (13), `LIGHTING` (7), `REFLECTION` (4), and lowercase `version` and `spritesheet`.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| I1 | Critical | E | Premultiplied vs straight alpha; opacity applied twice |
| I2 | Critical | E | The base material's output fed into effect chains (world transform or alpha applied twice) |
| I3 | Critical | F | Particle attribute layout does not match what the shader expects |
| I4 | Critical | F | Vertex counts, `maxvertexcount`, strips and restarts in emulated geometry |
| I5 | High | E | Blend-mode table parity (`normal` / `translucent` / `additive`) and scene-target alpha |
| I6 | High | E | `colorBlendMode` → `BLENDMODE` reads `_rt_FullFrameBuffer`: y flip, alpha and cost |
| I7 | High | E/F | sRGB vs linear, and the scene target format vs the effect target format |
| I8 | High | E | UV flips, `.tex` padding, `cropoffset`, `clampuvs` / repeat |
| I9 | High | E | Spritesheet frames (`SPRITESHEET`, `g_Texture0Rotation/Translation`) |
| I10 | High | E/F | Combos triggered by bound textures, combo case, `TEXnFORMAT` vs TEXParser's expansion |
| I11 | High | E | Per-layer pipeline and uniform explosion; hundreds of layers; pop-in |
| I12 | High | E | World transform, MVP and matrix convention built-ins |
| I13 | High | E | Scene-input layers (`copybackground`, composition, fullscreen) |
| I14 | High | F | Rope and trail ordering, connectivity, shader choice by renderer |
| I15 | High | F | Custom workshop `.geom`: loops, HLSL-isms, other input primitives |
| I16 | High | E/F | Fallbacks: silent blank layers vs loud native fallback |
| I17 | High | E/F | Library sweep does not cover base materials or particles |
| I18 | Med | E | Text layers: font shader vs genericimage, baked colour |
| I19 | Med | E | Solid layers (`solidlayer*.json` = genericimage + `util/white` + `VERSION`) |
| I20 | Med | E | `g_Color4` / `g_UserAlpha` / `g_Brightness` vs object colour/alpha/brightness |
| I21 | Med | F | Particle built-ins left at zero (orientation, eye, `g_RenderVar*`, `g_Screen`) |
| I22 | Med | E/F | `#define HLSL 0` makes `#ifdef HLSL` and `#if HLSL` disagree |
| I23 | Med | E/F | Material render state: depth test without a depth attachment, cull mode, `culling` typo |
| I24 | Med | F | Particle blending, overbright and draw order between layers |

---

## I1. Premultiplied vs straight alpha; opacity applied twice (Critical, E)
**Scenario.** WE textures are straight alpha, and WE's `translucent` is `SrcAlpha, InvSrcAlpha`, with `g_UserAlpha` scaling **only** `albedo.a` (`Vendor/we-assets/shaders/genericimage2.frag`). Today's native fragment returns `color * layer.opacity * layer.color` (`Scene/Rendering/SceneShaders.metal:199`) into a `sourceAlpha` blend (`SceneMetalRenderer.swift:172-175`), so RGB is scaled by opacity² at partial alpha. Moving to genericimage changes every layer with alpha < 1. That is the fix, but any golden image calibrated on the native path will flag it, and someone may "fix" it back. Inputs that are premultiplied break under straight-alpha blending: CoreText output is `premultipliedLast` (`Scene/Rendering/TextLayout.swift:102`), CGImage-decoded PNGs may be premultiplied, and AVFoundation video frames are premultiplied BGRA. They get dark fringes and darker semi-transparent areas. Effect outputs fed back in (I2) must stay straight.
**Test.**
- Headless unit: 1×1 texture straight `(1,0,0,0.5)` over a white clear through `genericimage2` `translucent` with `g_UserAlpha=1` → `(1,0.5,0.5)` ±1/255; with `g_UserAlpha=0.5` → `(1,0.75,0.75)`.
- A PNG fixture with a 50%-alpha pure-colour region, loaded through the production texture path: the sampled RGB equals the file's straight RGB (not RGB·α).
- A white text glyph over black: an edge pixel with 50% coverage reads 0.5 (not 0.25). Test the same for a video frame with alpha, if supported.
**Status (R1, 2026-09-25).** Fixed 5aa4e95 and 22f8798. `MTKTextureLoader` copies a CGImage's bytes as they are, so premultiplied images (CoreText output, AppKit drawing) are now unpremultiplied on upload (5aa4e95). `sceneFragment` returned colour × opacity into a `SrcAlpha` blend, which applied opacity twice on native draws (22f8798). Verified by `TextureUploadTests` (straight images unchanged, premultiplied ones made straight, a decoded PNG keeps its straight colour, text edges keep the text colour), `ImageMaterialRenderTests.testLayerAlphaIsAppliedOnceLikeWE` and `testNativeDrawAppliesLayerAlphaOnce`. Open: video frames with alpha (AVFoundation BGRA) are untested.

## I2. Base material output feeding effect chains (Critical, E)
**Scenario.** In WE, a layer with effects first renders its image through its material into the layer's own FBO, **without** the world transform. The effects then run on that FBO, and the final composite applies the transform and blending. Failure modes:
- (a) The base pass uses the world MVP into the FBO, so the image is rotated or offset inside its FBO and cropped.
- (b) `g_UserAlpha`, `g_Brightness`, `g_Color4` or `BLENDMODE` are applied both in the base pass and in the composite: alpha², brightness², or the blend mode applied twice.
- (c) The FBO is sized to the allocated `.tex` size instead of the content size, so `g_Texture0Resolution` seen by the effects is wrong (see #13 above).
- (d) The static-chain cache (`EffectGraphRenderer`, #18 above) does not key on base-material constants that scripts animate (alpha, brightness, spritesheet frame), so the chain freezes.
**Test.**
- Headless: a layer rotated 45°, scaled 2×, alpha 0.5, with a pass-through effect vs the same layer without the effect → pixel-identical output (tolerance 1/255).
- Animate alpha by script while the effect is static: the output changes every frame. A spritesheet layer with an effect animates (I9).
- Assert the first effect pass's `g_Texture0Resolution.zw` equals the `.tex` content size.
**Status (R1, 2026-09-25).** Verified by `ImageMaterialRenderTests.testPassThroughEffectLeavesTheMaterialDrawUnchanged` (1dd7380): a layer rotated 45°, scaled, at α 0.5, tinted and at brightness 1.2 draws the same through a pass-through `tint`. Also by `EffectGraphReuseTests.testStaticChainRerendersWhenColorAlphaOrInputVersionChange` and `EffectGraphCachingTests.testTextureResolutionReportsAllocatedThenContentSize`. Effects run in texture space, and the material applies the transform, alpha and brightness once.

## I3. Particle attribute layout mismatch (Critical, F)
**Scenario.** WE particle shaders expect specific vertex attributes:
- `genericparticle.vert` with GS: `a_Position` vec3, `a_TexCoordVec4` = rotation xyz + size w, `a_TexCoordVec4C1` = velocity xyz + lifetime w (**only with `THICKFORMAT`**), `a_Color` vec4 in 0..1.
- Without GS: rotation is split into `a_TexCoordC2.xy` + `a_TexCoordVec4.z`, and `a_TexCoordVec4.xy` becomes the corner UV.
- Rope: `a_PositionVec4`, end point in `a_TexCoordVec4`, CP0 + trail position in C1, and `a_TexCoordVec3C2` or `Vec4C2/C3` (thick).

Our particles are 2D with a separate alpha: `Particle.position/velocity: SIMD2`, `alpha`, `color` (`SceneMetalRenderer.swift:48-73`). Failure modes:
- `z` left uninitialised.
- Rotation in degrees instead of radians.
- Size as radius instead of full width (`ComputeParticlePosition` uses `size*(uv-0.5)`).
- Lifetime not normalised (`frac(age/lifetime)` feeds `ComputeSpriteFrame`).
- `a_Color.a` missing the fade and `opacityMultiplier` (`particleOpacity`, `:1656`).
- Swift `SIMD3<Float>` is 16 bytes while an MSL `packed_float3` attribute is 12, so every attribute after it is shifted.
- An `MTLVertexDescriptor` built by hand instead of from the variant's reflection, which breaks as soon as combos add or remove attributes.
- `SPRITESHEET` or `TRAILRENDERER` enabled without `THICKFORMAT`: `genericparticle.geom` reads `IN[0].v_VelocityLifetime`, which only exists with `THICKFORMAT`, so it fails to compile.
**Test.**
- Unit: for GS × `THICKFORMAT` × `SPRITESHEET` × `TRAILRENDERER`, build the vertex descriptor from reflection. Assert that every declared attribute is bound with the right format and offset, and that invalid combos (SPRITESHEET without THICKFORMAT) are never requested.
- Golden: one particle at (100,100), size 50, rotation 0, colour `(1,0,0,0.5)`, square white texture → covered box exactly 50×50 scene units centred at (100,100), pixel `(1,0,0)` at 50%. Rotation π/4 gives a diamond.
- A non-square texture (e.g. 64×128) → height = size × `g_Texture0Resolution.y/x`. With a spritesheet, the ratio comes from `g_RenderVar1.w`.
**Status (particles, H).** Verified by `ParticleMaterialRenderTests.testEveryAttributeTheStageReadsComesFromTheRecord` (every renderer form × both stages: no attribute reads the zero buffer) and `testColourAndAlphaReachThePixel` (`bc63f2d`), with `testSpriteThroughEmulatedGeometryStage` (size), `testBothPathsDrawTheSameRotatedSprite` (radians) and `testClampUVsKeepsTheOppositeEdgeOut` (non-square aspect). The GPU simulation writes the same records (`ParticleSimulationParityTests.testSwiftAndMetalLayoutsAgree`, `testSpriteRecordsMatchTheCPUWriter`). Sizes follow linux-wallpaperengine (quad width = size/2, `0591466`); a WE capture is still Open.

## I4. Emulated geometry: vertex counts, `maxvertexcount`, strips (Critical, F)
**Scenario.**
- **Output layouts.** `genericparticle.geom` and `flatpoint.geom` emit one 4-vertex strip. `genericropeparticle.geom` emits `4 + TRAILSUBDIVISION*2`. A custom `.geom` can emit fewer than `maxvertexcount` (conditional `Append`), or several strips (`RestartStrip`).
- **Vertex pulling.** Emulating with `vertexCount = N` per instance must turn the extra slots into degenerate vertices. NaN positions are undefined behaviour, so they must collapse onto the last emitted vertex. Strip-to-list conversion must not bridge across a restart. Metal only has primitive restart for indexed strips.
- **The count itself.** The `[maxvertexcount(...)]` expression must be evaluated after combos are resolved.
- **Scale.** N × max particles (e.g. 10 × 10 000) blows up vertex counts and buffers. Mesh shaders cap a threadgroup at 256 vertices / 512 primitives.
- **Winding.** The strip's corner order (0,0),(0,1),(1,0),(1,1) gives alternating winding; that matters if a material's `cullmode` is not `nocull`.
**Test.**
- Parser unit: `[maxvertexcount(4 + TRAILSUBDIVISION * 2)]` → 4 / 10 for TRAILSUBDIVISION 0 / 3.
- A synthetic `.geom` emitting 3 of a max of 6 vertices draws exactly one triangle (count the covered pixels).
- A `RestartStrip` fixture with two disjoint quads leaves the pixel between them at background.
- 10 000 sprite particles: vertex buffer ≤ 4 × 10 000 vertices, no per-frame allocation (buffer identity stable over 100 frames).
**Status (particles, H).** Verified by `testRestartedStripsLeaveTheGapsBetweenThem`, `testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles`, `testStripTrianglesKeepOneWinding` (`329a12d`), `GeometryShaderEmulationTests.testMaxVertexCountExpressions`, and `ParticleGPURenderTests.testTenThousandSpritesReuseTheirBuffers` (`bc63f2d`: 10 000 sprites keep one record and one particle buffer over 99 frames).

## I5. Blend-mode table parity and scene-target alpha (High, E)
**Scenario.** WE material `blending` values seen are `normal`, `translucent`, `additive` (and `disabled` in some workshop content). `EffectGraphRenderer.blendMode` (`Scene/Rendering/EffectGraphRenderer.swift:534-539`) maps `additive` to `(srcAlpha, one)` for **alpha as well**, and anything else to "no blending". The native additive path uses `(one, one)` for alpha (`SceneMetalRenderer.swift:180-183`). A `normal` (overwrite) image layer with transparent texels writes alpha 0 into the scene target. The final composite then blends the scene target with `sourceAlpha` (`SceneMetalRenderer.swift:~575`, `renderPipeline`), which WE never does at present, so holes show the clear colour. Unknown blending strings silently become overwrite.
**Test.**
- Table test over every blending string found in library + we-assets materials: expected Metal factors per RGB and alpha; an unknown string logs once.
- Headless: red opaque background + a `normal` layer whose texture has a transparent quadrant → the final drawable shows the texture's RGB there (or matches a WE reference screenshot), never the clear colour.
- An additive layer over a transparent area: final pixel equals WE's.
**Status (R1, 2026-09-25).** Fixed 320b7ec (opaque composite). Verified by `testNormalBlendingOverwritesTheScene`, `testCompositeIgnoresTheSceneAlpha` and `testAdditiveBlendingMatchesTheNativeAdditiveDraw`. Open: an unknown `blending` string silently overwrites (`EffectGraphRenderer.blendMode`, which is B's); fixing it needs WE's full list of blending values.

**Status (R2, 2026-09-25).** Fixed d03f50e: an unknown `blending` value still overwrites, as `normal` does, and is now logged once. `normal`, `disabled`, `translucent` and `additive` are known; the bundled assets and the 49-wallpaper library use only `normal` (416), `translucent` (213) and `additive` (56). Verified by `EffectGraphCachingTests.testBlendingTable`. Open: WE's full list of values.

## I6. `colorBlendMode` / `BLENDMODE` and `_rt_FullFrameBuffer` (High, E)
**Scenario.** 33 library objects set `colorBlendMode`. `genericimage2/3/4` then sample `g_Texture4 = _rt_FullFrameBuffer` at `v_ScreenPos` and write `gl_FragColor.a = screen.a`:
- **Snapshots.** Each such layer needs the snapshot taken *just before it*, as `readsScene` layers do (`SceneMetalRenderer.swift:~520`, end encoder + blit). At 5K with 10+ blend-mode layers, that is 10+ full-screen blits per frame (a performance risk).
- **y flip.** It depends on `#ifdef HLSL` being taken (I22).
- **Snapshot alpha.** Where the snapshot's alpha is 0 (clear colour alpha 0, nothing drawn yet), a translucent pass with `a = screen.a` makes the layer vanish.
- **Unused sampler.** `BLENDMODE 0` must *not* bind the sampler; `resolveCombos` must not turn it on because of the hidden default texture.
**Test.**
- Headless: vertical gradient background + a white layer with `BLENDMODE=2` (multiply) → output equals the background exactly (no vertical flip).
- The same over a region the background leaves transparent: the layer stays visible if WE shows it.
- Perf: 20 blend-mode layers at 5120×2880 → CPU+GPU frame time budget (e.g. < 8 ms on M1 Pro) recorded via `OWEFrameMetrics`.
**Status (R1, 2026-09-25).** Verified by `testBlendModeMultipliesWithTheSceneBeneath`, `testBlendModeReadsTheScenePixelBeneath` (fixed by 9d8c262 and 6bc5732) and `testObjectBlendModeReadsTheScene`. `BLENDMODE` 0 samples no snapshot (`testPlainMaterialsPlanWithTheLayerImageInSlotZero`). `a = screen.a` is WE's own shader code. Open: the cost of one snapshot per blend-mode layer at 5K is unmeasured.

## I7. sRGB vs linear; target formats (High, E/F)
**Scenario.** WE blends in gamma space: `rgba8` UNORM targets and non-sRGB textures (HDR scenes use `rgba16f` + `HDR` combo). Today every load passes `SRGB: false` (`SceneMetalRenderer.swift:924`, `:993`, `:1009`), and the scene target inherits the drawable's `bgra8Unorm` (`:878`), while effect targets are `rgba8Unorm` (`EffectGraphRenderer.swift:522-531`). Risks:
- New loading code uses `MTKTextureLoader` defaults (sRGB for tagged PNGs, so midtones get darker).
- BC blocks are uploaded as `_srgb`.
- The view switches to `bgra8Unorm_srgb`.
- A base-material pipeline compiled for `rgba8Unorm` is used in the scene pass (`bgra8Unorm`), which is a Metal validation error or a silent failure. The pipeline key must include the attachment format (it does for effects: `EffectGraphRenderer.swift:273`).
- `g_Power` (`genericimage.frag`) and MSDF math assume gamma values.
**Test.**
- Headless: a 1×1 `0x80` grey texture through genericimage2 into the scene target → reads back `0x80` ±1. Repeat for BC1/BC7 and a PNG with an sRGB ICC profile.
- Source test: grep asserts every `newTexture(` in `Scene/` passes `SRGB: false`.
- Unit: the base-material pipeline's colour format equals `sceneTexture.pixelFormat`. Run with `MTL_DEBUG_LAYER=1` and no validation errors.
**Status (R1, 2026-09-25).** Fixed 5aa4e95: AppKit converted solid-layer colours into the display's colour space (P3). Verified by `TextureUploadTests.testStraightAlphaImagesUploadAsStored` (Display P3 and sRGB tags are ignored) and `testSolidLayerImageHoldsTheAuthoredColour`. The pipeline key includes the target format, every upload passes `SRGB: false` through `SceneTextureUpload`, and BC formats upload as non-sRGB.
**Status (particles, H).** Verified for particles by `ParticleMaterialRenderTests.testGreyStaysGreyInTheSceneFormat` (`bc63f2d`: 0x80 stays 0x80 in rgba8 and bgra8 targets); the particle pipeline key includes the target format. BC and ICC-tagged inputs and the `MTL_DEBUG_LAYER` run: Open (texture loading is E's).
**Status (HDR, B2, 2026-09-26).** With `bloom`, `hdr` and post-processing "ultra" the scene target and the layers' effect buffers are RGBA16F and every material gets `HDR=1` (docs/lighting-plan.md §4.3 B2); the native, image and particle pipelines are keyed or made per target format. Verified by `SceneHDRRenderTests` and `HDRLibrarySweepTests` (the chain against the CPU model on each scene's own float frame). Needs WE ground truth: a capture of an HDR scene (2321732083 or 3606529469) at "ultra" and at "enabled" on an SDR display, to confirm that WE's "ultra" output reaches the screen sRGB-encoded with `g_RenderVar0.xy` = (1, 0) (§5.2 of the plan), and one at "displayhdr" on an HDR display for the EDR output the app doesn't have yet.

**Status (display HDR, B3, 2026-09-27).** "displayhdr" on a display with EDR headroom outputs WE's `combine_dhdr_upsample` onto an `rgba16Float` extended-linear-sRGB layer (docs/lighting-plan.md §4.3 B3). Verified headlessly only (`SceneDisplayOutputTests`: the combine against a CPU model, values above 1 on the drawable, "ultra" byte-identical). Risks: RV = (1, headroom − 1) is our mapping of WE's (SDR white, max − SDR white) / 80 nits onto EDR's unit of SDR white [?]; WE doesn't clamp at the display's maximum, so bright bloom clips on the display; `ccsimple` runs on the linear EDR frame [I]. Needs an EDR display (a MacBook Pro XDR or an HDR monitor with HDR on) and a WE capture at "displayhdr" on an HDR monitor to compare brightness.

## I8. UV flips, `.tex` padding, `cropoffset`, `clampuvs` (High, E)
**Scenario.**
- **Padding.** Native crops the padded allocation via `contentUVExtent` (`SceneMetalRenderer.swift:1028-1034`). `genericimage*` uses raw `a_TexCoord`, so the generated quad's texcoords must span content/allocated, or the padding shows.
- **Flips.** The effect quad relies on the translator's GL-style y flip (`EffectGraphRenderer.swift:93-96`), while the scene pass uses a y-down `sceneVertex` (`SceneShaders.metal:135-160`). Moving the scene pass to a WE MVP (y-up world) can flip the image only when effects are present, or only when they are absent.
- **Model options.** `cropoffset` (25 models) and `nopadding` change the mesh.
- **Sampler mode.** WE uses repeat unless `clampuvs` (18 objects) or the `.tex` clamp flag. With repeat plus bilinear, the opposite edge bleeds a 1-px line into the border, and padded POT textures bleed padding. `genericimage` `g_ScrollX/Y` needs repeat. Native's constexpr sampler is clamp.
**Test.**
- A `.tex` fixture: 1000×600 content in 1024×1024 with a 1-px red border inside the content and green padding. Render it: no green pixel anywhere, red on all four edges. Repeat with `clampuvs` on/off.
- An asymmetric "F" texture: render with and without a pass-through effect and with rotation 0/90/180 → identical orientation to the native oracle.
- A `cropoffset` model fixture vs a WE screenshot.
**Status (R1, 2026-09-25).** Verified by `testPaddedContentCropMatchesTheNativeDraw`, `testScrollingImageWrapsUnlessClamped`, `testTexFlagsAreReadFromTheHeader` and the rotated native-oracle tests. Open: `cropoffset` and `nopadding` aren't decoded; their semantics need WE ground truth, such as a model with `cropoffset` captured in WE.

## I9. Spritesheet frames (High, E)
**Scenario.**
- **Combo.** Animated `.tex` needs `SPRITESHEET=1`, which the engine sets from the texture (library materials rarely set it, and one uses lowercase `spritesheet`).
- **Frame UVs.** `g_Texture0Rotation = (width, widthY, heightX, height)/atlas` and `g_Texture0Translation = (x, y)/atlas`, where atlas must be the **allocated** pixel size. Native divides by `NSImage.size` (`SceneMetalRenderer.swift:~1017`), which is in points and may be the content size.
- **Atlas binding.** Frames can live in different images (`frame.imageIndex`), so `g_Texture0` must be rebound per frame.
- **Default.** The fallback rotation `(1,0,0,1)` (`Scene/Rendering/BuiltinUniforms.swift:186`) is correct only when `SPRITESHEET` is 0.
- **Caching.** A static-chain cache that doesn't key on the frame freezes it (I2).
**Test.**
- A synthetic 4-frame 2×2 atlas (distinct colours, 0.1 s per frame, atlas padded to POT, 3 frames in a 512² texture with 480² content) → at t = 0.05/0.15/0.25/0.35 the centre colour is the expected one.
- The same with a material lacking the combo, with a lowercase combo, with a multi-image `.tex`, and with an effect on the layer.
**Status (R1, 2026-09-25).** Fixed 6fb64b5: frame rects are now divided by the atlas texture's pixels rather than `NSImage.size`. Verified by `testSpriteSheetFrameMatchesTheNativeDraw`, with and without `SPRITESHEET`. Each frame binds its own atlas image. Open: the repo has no real animated `.tex` fixture with padding.

## I10. Combos from bound textures, combo case, `TEXnFORMAT` (High, E/F)
**Scenario.** `resolveCombos` (`Scene/Shaders/ShaderVariant.swift:75-89`) turns a sampler's `combo` on when its slot is bound and upper-cases overrides, but declaration defaults are keyed by their declared name. Risks:
- **Material slots.** A material `textures` array with `""`/`null` slots; `require`/`requireany` annotations not honoured.
- **Hidden defaults.** `_rt_MipMappedFrameBuffer` (REFLECTION, 4 library materials), `_rt_shadowAtlas` (`sampler2DComparison`), `_alias_lightCookie` and `util/white` go through `textureInput`, which rejects `_rt_*` with an error (`Scene/Plans/SceneEffectPlan.swift` `textureInput`).
- **`TEXnFORMAT`.** TEXParser already expands R8 to `(1,1,1,r)` and RG88 to `(l,l,l,a)` (`Scene/Format/TEXParser.swift:434-455`). So `ConvertTexture0Format` must see `TEX0FORMAT=0`; setting `TEX0FORMAT=9` yields `vec4(1,1,1,1)` (opaque squares). RG88 **normal maps** lose G from RGB, so `DecompressNormal`/`WithMask` (`Vendor/we-assets/shaders/common_fragment.h:19-48`) read swapped or duplicated channels. That affects `REFRACT` particles (13 in library) and `LIGHTING`.
**Test.**
- Table test: (material, bound slots, object combos) → expected combo dictionary for all 133 image and 79 particle passes in the library; lowercase keys normalise.
- An R8 particle sprite: alpha = r, RGB = 1.
- An RG88 normal map with constant (+1,0) under REFRACT over a vertical-stripe background → displacement only along x.
**Status (R1, 2026-09-25).** Combo resolution and TEXParser's channel expansion are B's. On the image side, `testAMissingTextureOnlyUnbindsItsSlot` covers it. Still open on B's side: `TEXnFORMAT` against RG88 normal maps.
**Status (particles, H).** Verified for particles by `testCoverageMaskSpriteTakesTheParticlesColour` (`bc63f2d`: TEXParser's white-plus-alpha R8 expansion takes the particle's colour; `TEX0FORMAT` stays unset and genericparticle doesn't read it). REFRACT particles draw through their material (`a0d6c15`). Block-compressed textures after the first set `TEX<n>FORMAT` (`187e2b3`, `testBlockCompressedTexturesAfterTheFirstSetTheirFormatCombo`), so a DXT normal map decompresses as in WE. RG88 normal maps: Open (none in the library; TEXParser's `(l,l,l,a)` expansion puts R in the mask).
**Status (particles, 2026-09-25, later).** RG88 loads as (r, g, 0, 1), as the GPU samples a two-channel texture, and particle materials set `TEX<n>FORMAT=8` for RG88 slots (texture 0 included): `ConvertTexture0Format` reads an albedo as `.rrrg` and `DecompressNormalWithMask` a normal map as `.gr`. The built-in draw gets a luminance-alpha copy (`ParticleFallbackTexture`). Consumers of the old expansion: only particle albedos (51 bundled textures), now converted by the combo; the library's other RG88 textures are `shake`/`waterflow`/`psyhue` flow maps, which read `.rg` and were losing their y, and two normal maps for `genericimage4` lighting (area 5). Verified by `TextureRG88Tests`, `ParticleMaterialRenderTests.testRG88NormalMapRefractsThroughItsFormatCombo` (green is x) and `testRG88AlbedoReadsAsLuminanceAndAlpha`. Image and effect materials set `TEX<n>FORMAT` for their `formatcombo` samplers since `55fdd33`.

## I11. Pipeline and uniform explosion, hundreds of layers (High, E)
**Scenario.**
- **Variants.** 243 image objects; `BLENDMODE` has 33 values × `LIGHTING` × `REFLECTION` × `SPRITESHEET` × `VERSION` × `FOG` × `HDR`. Translation is keyed per variant (fine), but a pipeline per *layer*, or a uniform program per layer rebuilt each frame, costs CPU.
- **Uniform size.** `setVertexBytes` is limited to 4 KB, and `genericimage4`'s light arrays can approach that.
- **Async compile.** Pipelines compile asynchronously (`failedPipelines`, `pipelineLock` in `EffectGraphRenderer`), so layers pop in out of order over the first frames.
- **Clones.** `createLayer` script clones (hundreds) each get a uniform program.
**Test.**
- Synthetic scene with 500 layers on one material → 1 translated variant, 1 pipeline (expose counters), CPU frame time < 4 ms on M1 via `OWEFrameMetrics`.
- 500 layers over 33 `BLENDMODE`s → ≤ 33 pipelines.
- With a warm cache, frame 1 draws every layer (or loading holds until pipelines are ready); memory is flat over 1 000 frames.
**Status (R1, 2026-09-25).** Verified by `testRemovedClonesFreeTheirUniformState` (ac3b667: 100 layers on one material compile one pipeline and hold 100 programs, all freed on release) and `testStillLayerRewritesNoPlacementUniforms`. Fixed 87b58cf: uniforms over 4 KB come from `SceneUniformArena` (256-aligned slices of reused chunks, recycled once their command buffers complete). Verified by `SceneUniformArenaTests` and `ImageMaterialRenderTests.testLargeUniformBlocksComeFromTheArena`. Open: `ParticleMaterialRenderer` still makes a buffer per draw, and frame time for 500 layers is unmeasured.

## I12. World transform, MVP and matrix convention (High, E)
**Scenario.** `g_ModelViewProjectionMatrix` must carry parents, alignment, parallax, shake, `cropoffset` and `perspective` (`angles.x/y`, 17 objects, needing a perspective camera). It must **not** include placement, which the composite applies (`SceneMetalRenderer.swift:~570`). `mul(x, y)` is `(y) * (x)` (`Scene/Shaders/ShaderPrelude.swift:86`), so WE matrices are row-vector; uploading a Swift column-major `simd_float4x4` without the matching transpose mirrors or shears. `LIGHTING`/`REFLECTION` also need `g_ModelMatrix`, `g_NormalModelMatrix`, `g_ViewProjectionMatrix`, `g_EyePosition` and `g_AltModelMatrix` (PRELIGHTING).
**Test.**
- Unit with native as the oracle: a layer at (100,200), scale 2, angle 30°, a parent offset and shear → MVP·corners in NDC equal `sceneVertex`'s corners (1e-4).
- A non-symmetric matrix transposition test.
- A `perspective` layer with `angles.y = 30°` vs a WE screenshot.
**Status (R1, 2026-09-25).** Verified by the native-oracle tests (`testGenericImage4MatchesTheNativeDraw`, `testVersionedGenericImage2MatchesTheNativeDrawWithColourAndBrightness`) and by the mirrored quads in the I23 test. Open: `perspective` (`angles.x/y`) and `cropoffset` aren't implemented and need WE captures. LIGHTING and REFLECTION are refused and logged.

## I13. Scene-input layers (High, E)
**Scenario.** `copybackground` (21), composition and fullscreen layers: native resamples the snapshot through the quad (`sceneRegion`, `SceneMetalRenderer.swift:819-851`). WE's `composelayer` samples `_rt_FullFrameBuffer` at `v_ScreenCoord` (and `CLEARALPHA`). Risks:
- Doing both (region resample *and* screen coordinates) double-offsets the image.
- Retina: the snapshot is at render px/unit, not scene units.
- The layer includes its own previous frame (feedback).
- `sceneInput` with no effects must still draw.
**Test.**
- Extend risk #10: a checkerboard + composition layer + pass-through effect → identical to the background; repeat for a 90°-rotated `copybackground` layer and a half-off-screen one.
- A scene-input layer with `BLENDMODE` combined.
**Status (R1, 2026-09-25).** Verified by `SceneRegionResampleTests` (see #10). A scene-input layer without effects is skipped, as in WE (`buildMetalLayer`). Open: `composelayer`'s own shader (`CLEARALPHA`) isn't used.

## I14. Rope and trail ordering and connectivity (High, F)
**Scenario.**
- **Shader choice.** Library rope/trail materials name `genericparticle`, so the engine must pick `genericropeparticle` from the renderer (`rope`, `ropetrail`) and set `TRAILRENDERER`, `THICKFORMAT` and `TRAILSUBDIVISION=renderer.subdivision`. Otherwise ropes draw as sprites.
- **Segment data.** Segment *i* needs particle *i+1* as its end point, spline control points, and `a_TexCoordVec4C1.w` trail position with `g_RenderVar0` (x unscaled max count, z UV time offset, w max count).
- **Particle order.** Swap-remove compaction would scramble ropes; today it is `removeAll` (order-preserving, `SceneMetalRenderer.swift:1519`). `ropetrail` uses a history ring buffer (`orderedHistory`), and translucent segments must draw oldest→newest.
- **Spline shape.** WE uses a cubic Bezier with CPs ×0.15 and `smoothstep` spacing; native uses Catmull-Rom (`:1605-1655`). Tests pinned to native will fail.
- **Shipped shader bugs.**
  - `genericropeparticle.geom` redeclares the loop variable (`for (int s…){ float s = …}`), which GLSL forbids: `TRAILSUBDIVISION > 0` won't compile without a rewrite.
  - The non-GS `genericropeparticle.vert` writes `sizeStart.w` on a float under `TRAILSCROLLALPHA && TRAILFADESIZE`, so that fallback won't compile.
**Test.**
- Translate `genericropeparticle` for TRAILSUBDIVISION 0..4 × each TRAIL* combo × GS on/off; list failures (expect the two above unless rewritten).
- A rope fixture with 5 particles on a line → one continuous strip: sample the midpoint of every joint (non-background). Kill the middle particle → no crossing segment.
**Status (particles, H).** Verified by `testRopeThroughEmulatedGeometryStage` (shader swap), `testSubdividedRopeCurvesThroughItsPoints`, and `testRopeJoinsParticlesInOrder` and `testRopeShaderBuildsForEverySubdivisionAndTrailCombo` (`bc63f2d`: subdivision 0–4 × trail combos; the geometry stage builds everywhere, the no-GS stream everywhere except `TRAILSCROLLALPHA` + `TRAILFADESIZE`, WE's own `sizeStart.w` bug, which the test asserts). The GPU simulation keeps spawn order with an order-preserving compaction (`c6f6fbc`), checked by `ParticleSimulationParityTests` (spawn order, rope and rope-trail records, `testRopeTrailHistory`). Spline shape against WE: Open, needs a WE capture.
**Status (particles, 2026-09-25, later).** A rope on an instanced system (a child) draws one strand per instance: record `i` joins particle `i` to the next particle of its instance, with the strand's own point count and index for the UVs, and the last of each strand gets an empty record; the built-in draw likewise. Verified by `ParticleChildrenTests.testAnInstancedRopeDrawsOneStrandPerInstance` (CPU records and the GPU's agree; no segment joins two instances). The GPU finds a strand's neighbours with a scan over the system's particles, O(n) per particle for an instanced rope (child ropes are small; WE's thunderbolt beam is 8 a strand).

## I15. Custom workshop `.geom` (High, F)
**Scenario.** WE's `.geom` dialect is pseudo-HLSL:
- `[maxvertexcount(n)]`, `in`/`out` redeclaring `gl_Position`, `IN[0].x`, `OUT.Append(v)`.
- `PS_INPUT`/`VS_OUTPUT` structs synthesised from varyings, possibly `OUT.RestartStrip()`.
- Line or triangle inputs (`IN[1]`, `IN[2]`).

Loops can be bounded by combos (unrollable) or by **uniforms** (runtime), which breaks translate-time unrolling. With `Append` inside a loop, vertex pulling must re-run the body per output vertex (O(N²)), or a compute pre-pass is needed. Shadowed loop variables (I14) and int literals in `smoothstep(0, 1, x)` also occur.
**Test.** Fixtures:
- (a) `for (int i = 0; i < COUNT; ++i)` emitting quads, COUNT combo = 3 → 3 quads.
- (b) A loop bound by uniform `g_Count` = 2 of max 8 → 2 quads; set it to 5 at runtime → 5 quads.
- (c) A line-input geom using `IN[1]`.
- Each case must render correctly or fail loudly: log once, a dump in `~/Library/Caches/app.openwallpaperengine/FailedShaders`, and the layer on its fallback (I16). Never draw nothing silently.
**Status (particles, H).** Verified by `testRestartedStripsLeaveTheGapsBetweenThem` and `testEmittingFewerVerticesThanTheBoundDrawsOnlyThoseTriangles` (a loop bounded at runtime in `stripquads.geom`), `GeometryShaderEmulationTests.testLoopBodyRedeclaringTheLoopVariableGetsItsOwnScope` and `testNonPointInputIsReported`; a failed stage falls back (I16).

## I16. Fallbacks (High, E/F)
**Scenario.** When the WE path fails, the layer must fall back to the native draw, log once with the wallpaper, layer and reason (architecture "loud failure"), and not retry every frame. Failure causes include:
- A translate error or missing include.
- `sampler2DComparison` (`LIGHTS_SHADOW_MAPPING` in `genericimage4`/`genericparticle`).
- An unknown `_rt_*` target.
- A pipeline compile failure.
- An unparsable `.geom`.
- An attribute the emulator can't supply.

Risks:
- Everything silently falls back, for example after a prelude regression, and nothing notices because the picture looks "fine".
- The async-compile window shows native first and then WE: a visible colour/alpha jump due to I1.
- A fallback for particles doesn't exist and the system is dropped.
**Test.**
- Inject a bad shader name → the layer is still visible, exactly one log line, `failedPipelineCount == 1` after 100 frames.
- Expose "layers on WE path / fallback" counters and assert ≥ 95% WE-path in the sweep (I17).
- The same for a particle system with a broken custom `.geom`.
**Status (R1, 2026-09-25).** Verified by `testLightingNeedsSceneLightsAndFallsBack` and `testMissingShaderFailsLoudly` (1dd7380). A failed pipeline is remembered and logged once (`ImageMaterialRenderer.compile`). Open: the sweep has no counter of WE-path versus fallback layers.
**Status (particles, H).** Verified for particles by `testFailedPipelineFallsBackToTheBuiltInDraw` and `testAFallbackIsReportedOnce` (`bc63f2d`: one report over 100 frames, `ParticleMaterialRenderer.fallbacksReported`). Only a material none of whose stages builds falls back; refraction no longer does (`a0d6c15`), and a compiling pipeline draws nothing instead of the built-in look-alike (`207b700`, `testCompilingPipelineDrawsNothingRatherThanTheBuiltInDraw`). The built-in draw also works from GPU-simulated particles (`ParticleSimulationParityTests.testBuiltInDrawInstances`, `SceneRendererParticleTests`).

## I17. Library sweep regressions (High, E/F)
**Scenario.** `LibrarySweepTests` (`OpenWallpaperEngineTests/LibrarySweepTests.swift:21`) only plans, translates and runs **effects**. Base image materials (133 passes), particle materials (79), rope variants and geometry emulation are not covered, and it uses `ProcessShaderCompiler` rather than the in-process compiler. "44 wallpapers, 0 failures" (roadmap notes) would stay green while every image layer quietly falls back.
**Test.**
- Extend the sweep:
  - For every image object, plan its material with object combos and `colorBlendMode`, translate it, and build the pipeline for the scene-target format.
  - For every particle system, choose the shader by renderer, then translate and build the emulated variant.
  - Assert 0 failures and the fallback ratio from I16.
- Render one frame per wallpaper headless: not blank (not all clear colour), and mean colour within tolerance of a stored baseline. Update the baselines deliberately when I1 changes appearance.
- Run with both compilers.
**Status (R1, 2026-09-25).** Verified by `ImageMaterialSweepTests`: every library image material builds a bgra8 pipeline with the in-process compiler. Open: rendering one frame per library wallpaper against a baseline. `SceneRendererParticleTests` (5336d12) shows whole frames now run headless.
**Status (particles, H).** Verified for particles by `ParticleMaterialSweepTests` (89 systems, 356 pipelines of which 32 refracting, 0 failures, 0 systems left on the built-in draw; in-process compiler, shader chosen by renderer) and `ParticleSimulationSweepTests` (`d3ff7e9`: 74 loaded systems through the CPU and GPU simulations, 0 failures). A rendered frame per wallpaper against a baseline: Open.

## I18. Text layers (Med, E)
**Scenario.** WE draws text with `font` (`Vendor/we-assets/materials/fonts/basefont*.json`: `g_Color4`, `MSDF`, `COLORFONT`, `g_RenderVar0..3` outline/shadow), not genericimage. Our text is CoreText-rasterised with its colour baked in (`SceneMetalRenderer.swift:921`) and is premultiplied. Routing it through genericimage2 `VERSION` with `g_Color4 = (colour, alpha)` squares the colour. Leaving it native makes text blend differently from images (I1), so a text layer next to an image with the same alpha looks different.
**Test.**
- Red `(1,0,0)` text, alpha 0.5, over white → glyph interior `(1,0.5,0.5)`; an edge pixel is no darker than the interior blend.
- The same text with a shake effect has the same colour.
**Status (R1, 2026-09-25).** Fixed 5aa4e95 (premultiplied glyph edges) and 22f8798 (alpha applied once). Verified by `TextureUploadTests.testTextEdgesKeepTheTextColour` and `testNativeDrawAppliesLayerAlphaOnce`. Fixed e277d74: text is rasterised white, uploaded as an R8 coverage texture, and drawn through `materials/fonts/basefont.json` (the `font` shader) with `g_Color4` as its colour, brightness and alpha. Verified by `ImageMaterialRenderTests.testTextFontMaterialTintsItsCoverageOnce` (red at alpha 0.5 over white, half-coverage edge, equal to the native draw), `TextureUploadTests.testWhiteTextGivesItsCoverage` and `RenderCheckTests`. Open: text with effects or a blend mode, and colour glyphs (emoji), draw natively; MSDF, outline and drop shadow need WE's MSDF atlas, which isn't generated.

## I19. Solid layers (Med, E)
**Scenario.** `solidlayer` models (3) and `solid` objects (24) are WE `util/solidlayer*.json`: genericimage2/3/4 + `util/white` + `VERSION: 2` → `g_Color4`. The `_depthtest` variants enable depth (I23), and the `_instance` variants use `INSTANCECOUNT`. Risks: `util/white` is not found in a workshop-only root; the colour is applied twice (I20); a fullscreen solid is not resized with the scene.
**Test.** Solid `(0.2,0.4,0.6)`, alpha 0.5, over black → `(0.1,0.2,0.3)`; with an effect → same; at a changed scene size it covers the full target.
**Status (R1, 2026-09-25).** WE's bundled `util/solidlayer.json` uses the `flat` shader, which has no image, so solid layers draw their baked colour natively. Fixed 5aa4e95 (the colour was converted to P3) and 22f8798. Verified by `testSolidLayerImageHoldsTheAuthoredColour`, `testNativeDrawAppliesLayerAlphaOnce` and `testBlendModeOnAFlatMaterialIsReported`. Open: E-5.

## I20. `g_Color4`, `g_UserAlpha`, `g_Brightness` vs object colour/alpha/brightness (Med, E)
**Scenario.** Without `VERSION`, genericimage2 takes `g_Brightness`/`g_UserAlpha` from `constantshadervalues` (`Brightness`, `Alpha`); with `VERSION`, it takes `g_Color4`. Objects also carry `color`, `alpha` and `brightness`, with scripts and timelines on top (`layerDraw`, `SceneMetalRenderer.swift:635-677`). Effects get `g_Color`/`g_Alpha` via `EffectGraphRenderer.Context.layerColor/layerAlpha`. If the object alpha is fed to `g_UserAlpha` **and** the composite still multiplies `opacity`, the result is alpha². If `VERSION` materials ignore the object colour, tint is lost.
**Test.** A matrix of `VERSION` on/off × object alpha 0.5 × material `Alpha` 0.5 × script alpha → expected final alpha per WE (take the expectations from WE screenshots, not from the native path).
**Status (R1, 2026-09-25).** Verified by `testLegacyGenericImage2TakesAlphaFromTheMaterialAndTheLayer`, `testVersionedGenericImage2MatchesTheNativeDrawWithColourAndBrightness`, `testMaterialBrightnessIsAppliedOnce` and `testLayerAlphaIsAppliedOnceLikeWE`. Open: the full matrix of `VERSION`, object α, material α and script α needs WE screenshots.

## I21. Particle built-ins left at zero (Med, F)
**Scenario.** Particle shaders read built-ins nothing sets today. If they stay zero, particles become degenerate and **invisible with no error**:
- `g_OrientationUp/Right/Forward`, `g_ViewUp/Right`, `g_EyePosition`, `g_ModelMatrixInverse` (`common_particles.h`).
- `g_RenderVar0` (trail length min/max, UV offset) and `g_RenderVar1` (frame width/height/count, ratio).
- `g_Texture0Resolution`.

`flatpoint.geom` divides by w and offsets in NDC by `0.002 * size`, with `g_Screen.z` as aspect and `1080/g_Screen.y`. `effectFrame.screenSize` is the Retina scene target (`SceneMetalRenderer.swift:~404`), so points shrink on 5K (the formula in fact expects that); check it against WE.
**Test.**
- Unit: for each particle variant, every reflected uniform is written by the builtin table or has a material/annotation default; fail on an "unset builtin" list.
- A `flatpoint` point at a 1080p vs a 2160p target keeps the same size in scene units, or matches WE.
**Status (particles, H).** Verified by `testEveryParticleUniformHasASource` (`bc63f2d`: every uniform of every particle stage is a built-in, a material or annotation constant, or one `ParticleMaterialUniforms` writes); the rope's `g_RenderVar0` point count comes from the GPU step (`ParticleGPURenderTests.testRopeRenderVarHoldsTheGPUsPointCount`). `flatpoint` size at 1080p vs 2160p against WE: Open, needs a WE capture.

## I22. `#define HLSL 0` semantics (Med, E/F)
**Scenario.** The prelude defines `GLSL 1` and `HLSL 0` (`Scene/Shaders/ShaderPrelude.swift:81-82`). So `#ifdef HLSL` blocks are **taken**: 17 in the assets, including the `v_ScreenCoord.y` flip in `genericimage2/3/4.vert`, `common_particles.h` refraction coords and `normal.y` in `genericimage3/4.frag`. Meanwhile `#if HLSL` (8) and `#ifndef HLSL` (2, e.g. the `genericparticle.frag` refraction offset y) take the GL branch. One shader can run HLSL-convention code in one place and GL-convention code in another, a mix WE never ships. It may be right for Metal's y-down textures, or it may flip. *Update:* `9d8c262` now leaves `HLSL`/`HLSL_SM30` undefined (GL branches everywhere, like WE's GLSL backend). The risk is now anything calibrated against the old mix; see Findings E-7.
**Test.** A REFRACT particle with a +y normal over a horizontal-stripe background, and a `BLENDMODE` layer over a gradient: the displacement direction and orientation must match a WE reference capture. Keep a table test listing the `#ifdef HLSL` sites so a prelude change is deliberate.
**Status (R1, 2026-09-25).** The prelude is B's (9d8c262). On the image side, `testBlendModeReadsTheScenePixelBeneath` verifies it. Particle refraction (`a0d6c15`): `v_ScreenCoord` already runs top-down, because the particle projection puts the scene's top at GL's bottom; with the GL offset flip, `g_ViewUp` is scene −y so a +y normal samples below as in WE (`testRefractionNormalOffsetsAlongTheScreenAxes`). A WE capture: Open.

## I23. Material render state (Med, E/F)
**Scenario.**
- **Depth.** `depthtest: enabled` (`solidlayer_depthtest`, perspective scenes) with a scene pass that has no depth attachment → a pipeline with depth state on a depth-less pass, which is a validation error.
- **Cull mode.** Negative-scale (mirrored) layers under a non-`nocull` cull mode get culled.
- **Key typo.** WE's own `flatpointalphavertexcolor.json` spells it `"culling"`, not `"cullmode"`.
- **Alpha-to-coverage.** `ALPHATOCOVERAGE` uses `fwidth` and needs MSAA.
**Test.** A mirrored layer (`scale.x = -1`) is visible; a depth-test material creates a valid pipeline with no depth format when the pass has none (`MTL_DEBUG_LAYER=1`); unknown or misspelled state keys fall back to the WE defaults.
**Status (R1, 2026-09-25).** Verified by `testDepthAndCullStateKeepMirroredLayersVisible` (1dd7380). Image pipelines ignore depth and cull state, so `depthtest: enabled`, `cullmode` and `culling` all build valid pipelines for the depth-less pass, and mirrored layers draw. Open: `ALPHATOCOVERAGE` (which needs MSAA) isn't handled, and whether WE culls mirrored image layers needs a capture.

## I24. Particle blending, overbright, draw order (Med, F)
**Scenario.**
- **Additive alpha.** Native additive particles use `(one, one)` for alpha; the effect-graph table uses `(srcAlpha, one)` (I5). The accumulated scene-target alpha then goes through the composite blend.
- **Overbright.** `g_Overbright` (library 1.6) above 1 clamps in `rgba8`.
- **Other modes.** `CUTOUT` and fog alpha (`FOG` default 1 in `genericparticle.frag`/`genericimage4.frag`; `FOG_DIST`/`FOG_HEIGHT` must stay off unless the scene defines fog, or `g_Fog*` uniforms stay zero and colour goes to black).
- **Draw order.** Particles draw between layers by `configuration.order` (`drawParticleBatches`, `SceneMetalRenderer.swift:488-508`). If E and F each change their own draw loop, the interleaving (and the snapshot a REFRACT particle reads) can change.
**Test.**
- An additive particle with overbright 1.6 over black → channel clamps at 1, alpha behaviour matches WE.
- A scene with layer A, particles, layer B → particles are occluded by B and cover A.
- A REFRACT particle reads a snapshot that includes A but not B.
**Status (particles, H).** Draw order verified by `SceneRendererParticleTests` (`5336d12`: whole `SceneMetalRenderer` frames, GPU and CPU simulation, built-in and material draw; particles cover the layer below and the layer above covers them); overbright saturation by `testAdditiveOverbrightSaturates` (`bc63f2d`). The REFRACT snapshot holds the layers below and not those above (`a0d6c15`, `testGPUSimulatedRefractionReadsTheSceneUpToItsSystem`, `testCPUSimulatedRefractionReadsTheSceneUpToItsSystem`). Additive alpha against WE: Open.

---

## Findings (E and F commits)

_Watching `git log` on `deepratna/feature-work` from `4154ccd`._

### E: `864b9a4` (draw image materials through WE's shaders) + `c955481` (render image layers through their own material)

Line numbers are at `c955481`.

**What the commits already cover.**
- I1: alpha is applied once, tested by `testLayerAlphaIsAppliedOnceLikeWE`.
- I6: `BLENDMODE` gets a per-layer snapshot. At `c955481` the blend still read the vertically mirrored scene pixel; the test recorded that as a known gap with a strict `XCTExpectFailure`. `9d8c262` fixed it; see issue 7.
- I7: the pipeline key includes the attachment format.
- I9: frames are baked into the texcoords when `SPRITESHEET` is off, so animated `.tex` without the combo still animate.
- I16: failures fall back natively and are logged once. `LIGHTING`/`REFLECTION` are refused.
- I17: `ImageMaterialSweepTests` plans, translates and builds the `bgra8Unorm` pipeline for every library image material, using the in-process compiler.

**Confirmed issues.**
1. **Material `Brightness` is applied twice (I20). Medium.**
   - The legacy heuristic reads `constantshadervalues` `"Brightness"` into `materialEffects.brightness` (`Scene/Loading/SceneContentLoader.swift:1033`, via `Scene/Format/SceneMaterial.swift:40-41`).
   - The renderer folds it into `uniform.effects.x` (`Scene/Rendering/SceneMetalRenderer.swift:557`) and passes that as the draw's brightness (`:576`).
   - `ImageMaterialPlanBuilder` also takes the same constant as the live factor for `g_Brightness` (`Scene/Plans/ImageMaterialPlan.swift:121-124`), which `ImageMaterialUniforms.live` multiplies in again (`Scene/Rendering/ImageMaterialUniforms.swift:89-90`).
   - A legacy genericimage2 material with `"Brightness": 1.5` draws at 2.25× (≈1.5² once clamped). The heuristic's other aliases (`intensity`, `overbright`, `gain`) also leak into `g_Brightness` and into `g_Color4` for `VERSION` shaders (`ImageMaterialUniforms.swift:86-88`).
   - The fixture tests only use a material factor of 1 (`testLegacyAlphaConstantScalesTheLiveAlpha` asserts `g_Brightness == 1`), so they miss it.
   - **Test:** a legacy material with `Brightness` 1.5 over black, texel 0.4 → expect 0.6, not 0.9.
2. **`normal` blending now leaves texture alpha in the scene target, which the composite blends with the clear colour (I5). High, a regression for `normal` materials whose texture has alpha.**
   - `EffectGraphRenderer.blendMode("normal")` is nil, so the image pipeline overwrites RGBA (`Scene/Rendering/ImageMaterialRenderer.swift:271-278`). `testNormalBlendingOverwritesTheScene` asserts that the scene target then holds alpha 64/255.
   - The final composite draws the scene target with `renderPipeline` (`sourceAlpha, oneMinusSourceAlpha`; `SceneMetalRenderer.swift:168-175`, composite at `:601-620`) over the drawable's clear colour. Those pixels come out darkened toward black.
   - WE ignores target alpha when presenting, and the native path always used translucent blending, so this is new. Six library materials use `normal`.
   - **Test:** a background layer + a `normal` layer whose texture has α=0.25 → the final drawable pixel equals the texture RGB (WE), not RGB·0.25.
   - **Fix direction:** the composite should ignore scene alpha (opaque composite), or write alpha 1 for overwrite passes.
3. **App adjustment sliders silently switch every layer off the WE path (I16/I11). Medium.**
   - `nativeAdjustmentsAreIdentity(uniform)` gates the material draw (`SceneMetalRenderer.swift:573`). `uniform.effects.z` includes `_owe_saturation` (`:558`) and `colorEffects.z` includes `_owe_hue` (`:565`).
   - Any non-default app saturation/hue (or a legacy heuristic like `contrast`, `blur` or `angle` found in `constantshadervalues`) sends all layers back to `sceneFragment`. That drops `colorBlendMode`, custom image shaders and single alpha, while still paying for the per-layer scene snapshot (`readsScene` stays true through `imageMaterial.readsSceneSnapshot`, `Scene/Rendering/SceneRenderContent.swift` `readsScene`).
   - Nothing is logged, so it's not "loud".
   - **Test:** set `_owe_saturation = 0.9` → a `colorBlendMode` layer still multiplies (or a log line explains why not); `drawsEncoded` stays equal to the layer count.
4. **`clampuvs` and WE's repeat default are ignored for the layer image (I8). Medium.**
   - Slot 0 (`.current`) always uses `clampSampler` (`ImageMaterialRenderer.swift:97-98`), and asset slots always use `repeatSampler` (`:102-104`), whatever the object's `clampuvs` (18 library objects) or the `.tex` clamp flag.
   - `genericimage` (v1) scrolls with `a_TexCoord + g_Time * scroll` (`Vendor/we-assets/shaders/genericimage.vert`), which needs repeat. Under clamp, a scrolling layer smears its edge row instead of tiling.
   - **Test:** a genericimage material with `Scroll 1 X` = 1 at t = 0.25 → the texture wraps (column 0 visible at x = 25%).
5. **Solid layers keep the native draw, so their `colorBlendMode` is dropped. Low/Medium, a gap rather than a regression.** `buildSolidLayer` never builds an `imageMaterial` (`SceneContentLoader.swift:612-614`, `:690+`). Four library solid layers author a blend mode (modes 2, 3, and 31 twice, with effects). They draw with plain translucent blending. WE draws them through `solidlayer.json` → genericimage2 with `BLENDMODE`.
6. **Per-plan uniform state is shared by script clones. Low, performance only.** `programs` is keyed by `ObjectIdentifier(plan)` (`ImageMaterialRenderer.swift:215-221`). `createLayer` clones share their source's plan, so N clones alternate `lastKey` every draw and rewrite placement built-ins each time. It is still correct, because `setVertexBytes` copies. Above 4 KB it allocates a new `MTLBuffer` per draw per frame (`:163`).

7. **`ImageMaterialRenderTests` is red at HEAD because of a stale expected failure (I6/I22). High, but only for CI.**
   - `9d8c262` (fix(shaders): leave HLSL undefined) removed `#define HLSL 0`, so genericimage's `#ifdef HLSL` screen-coordinate flip no longer runs, and `BLENDMODE` now reads the pixel beneath.
   - `testBlendModeReadsTheScenePixelBeneath` still wraps its assertion in a strict `XCTExpectFailure` (`OpenWallpaperEngineTests/ImageMaterialRenderTests.swift:179`), so it fails with "Expected failure … but none recorded".
   - Verified by running the test in a scratch worktree: it passes at `c955481` and `e4adbe4` and fails at `9d8c262` and HEAD `0be8b90`. All 16 other tests in the class pass at HEAD.
   - **Fix:** remove the expectation. **Resolved by `6bc5732`**: the expectation is removed, and the whole `ImageMaterialRenderTests` class passes at `61a34d7`.
   - **Follow-up for I22:** anything else calibrated while `HLSL` was defined needs re-checking. That covers the comment on `ImageMaterialRenderer.viewProjection`, and for F the particle refraction: `common_particles.h` no longer flips `v_ScreenCoord.y`, and `genericparticle.frag`'s `#ifndef HLSL` offset flip is now taken.

**Status (R1, 2026-09-25).**
- E-1: fixed 320b7ec, verified by `testMaterialBrightnessIsAppliedOnce`.
- E-2: fixed 320b7ec, verified by `testCompositeIgnoresTheSceneAlpha`.
- E-3: fixed 320b7ec. The sliders apply on the composite, and legacy heuristics are logged once and not applied. Verified by `testObjectBrightnessAloneIsNotANativeAdjustment`.
- E-4: fixed 320b7ec, verified by `testScrollingImageWrapsUnlessClamped` and `testTexFlagsAreReadFromTheHeader`.
- E-5: fixed (2026-09-26). WE composites a layer through `materials/util/effectpassthrough_4.json` with `BLENDMODE` (0x1401ebcba…0x1401ebe55); a solid layer with a blend mode now draws its fill through it (`buildBlendComposite`). Verified against WE 2.8's captures of a band in modes 0, 2, 7, 9, 11, 18 and 31 (we-values-audit notes §9.3), `testSolidFillCompositesWithItsBlendMode` and `SceneSolidLayerBlendTests`. `testBlendModeOnAFlatMaterialIsReported` still holds for `build` itself.
- E-6: fixed 320b7ec (state per layer instance), verified by `testStillLayerRewritesNoPlacementUniforms` and `testRemovedClonesFreeTheirUniformState`.
- E-7: resolved 6bc5732.

### F: `9c3b50c` (emulate WE geometry shaders in the vertex stage) + `61a34d7` (draw particle systems through their WE material)

Line numbers are at `61a34d7`. `GeometryShaderEmulationTests` (9) and `ImageMaterialRenderTests` (17) all pass there; I ran them in a scratch worktree.

**What the commits already cover.**
- I4: each point draws `3·(N−2)` list vertices. Triangles past the emitted count, or spanning a `RestartStrip`, collapse to `vec4(0)`, and odd strip triangles swap corners to keep their winding (`Scene/Shaders/GeometryShaderEmulation.swift:137-150`, `:231-255`). `maxvertexcount` is evaluated after combos (`:45-51`).
- I14: rope renderers swap in `genericropeparticle` (`Scene/Plans/ParticleMaterialPlanBuilder.swift`). The loop-variable redeclaration is rewritten (`Scene/Shaders/HLSLStageRewrites.swift:102-128`), and `TRAILSUBDIVISION` compiles.
- I3: the vertex descriptor comes from reflection, with a per-instance step and a constant-zero buffer for missing attributes (`Scene/Rendering/ParticleMaterialRenderer.swift:272-304`). Records are 16-byte slots (no `float3` packing hazard). `SPRITESHEET` and trails force `THICKFORMAT`.
- I15: loops and runtime-bound emission work, because the whole geometry body runs per output vertex. Non-point input and `IN[1+]` are reported.
- I16: failures fall back to the built-in draw and are logged once. REFRACT is refused.
- I21: the orientation, eye, `g_RenderVar0/1` and `g_ModelMatrixInverse` (identity) built-ins are set (`Scene/Rendering/ParticleMaterialUniforms.swift`).
- I17: `ParticleMaterialSweepTests` builds pipelines for every library particle material with the in-process compiler.

**Confirmed issues.**
1. **`randomframe` sprite sheets ghost the next frame at 50%. Medium.**
   - `spritePhase` for `randomframe` returns `(frame + 0.5) / frames` (`Scene/Rendering/ParticleRecordWriter.swift:73-74`).
   - `SPRITESHEETBLEND` is on unless flag 2 is set (`ParticleMaterialPlanBuilder.swift:95`), and flags are 0 by default.
   - `ComputeSpriteFrame` blends `frac(lifetime·numFrames)` = 0.5 between frame *k* and *k+1* (`Vendor/we-assets/shaders/common_particles.h`, `genericparticle.frag` `SPRITESHEETBLEND`). Every random-frame particle except the last frame shows two frames at half opacity.
   - `testSpriteSheetPicksTheParticlesFrame` passes only because it sets `noFrameBlendingFlag` and uses the last frame.
   - **Fix direction:** phase = `frame / frames` (plus ε), or no blend for `randomframe`.
   - **Test:** a 2-frame sheet, `randomframe`, flags 0, `spriteFrame = 0` → pure frame 0.
   - Also verify flag 2 = "no frame blending" against WE.
2. **Ropes are twice as wide as the native draw. Medium, needs a WE reference.**
   - The writer passes `particle.size` as the rope's `a_PositionVec4.w` (`ParticleRecordWriter.swift:95`, `:124`, `:127`), and `genericropeparticle.geom` offsets ±`size` along the normal. So a size-10 rope is 20 units wide.
   - The record doc calls it "half the ribbon width" (`Scene/Rendering/ParticleInstanceLayout.swift:59`), the sprite doc says `size` is the full width (`:45`), and `testRopeThroughEmulatedGeometryStage` asserts 20 units.
   - The native draw was `size` wide (`SceneMetalRenderer.swift` `appendRope`, `averageSize`).
   - **Test:** compare a rope and a rope trail against a WE capture of the same preset, then settle whether the record needs `size/2`.
3. **Particle textures always sample with repeat. Medium, a regression vs native clamp.**
   - `ParticleMaterialRenderer` makes one sampler with `.repeat` on both axes and binds it to every slot (`ParticleMaterialRenderer.swift:53-60`, `:115`). The native particle draw sampled with clamp (`SceneShaders.metal` `sceneFragment`).
   - Sprites whose edge texels aren't transparent (rain streaks, light shafts, beams) get a 1-px line of the opposite edge under bilinear filtering.
   - Spritesheet frames on the atlas border bleed into the opposite side.
   - The `.tex` clamp flag is ignored.
   - **Test:** a sprite with an opaque bottom row and a transparent top row → no coloured texels along the quad's top edge.
4. **Tests check pixels only on happy-path strips (I4). Low/Medium.** `GeometryShaderEmulationTests.testRestartStripAndCustomEmitCountsTranslate` checks that a two-quad `RestartStrip` stage *translates* and counts 18 vertices; it never renders. Still missing:
   - A pixel test that the gap between the two quads stays background (no bridging triangle).
   - A stage that emits fewer vertices than `maxvertexcount` → exactly the emitted triangles.
   - A cull-mode test for odd-triangle winding.
5. **Cost grows as O(N²) per rope segment with subdivision. Low, unmeasured.** Every emulated vertex reruns the whole geometry body (`GeometryShaderEmulation.swift:137-150`), so rope segments cost `3·(2+2S)` × `(4+2S)` vertex evaluations. At `TRAILSUBDIVISION` 8 that is 54 × 20 ≈ 1 000 per segment, which is significant for rope trails with thousands of segments.
   - **Test:** frame time for 2 000 rope-trail segments at S = 0 / 4 / 8 via `OWEFrameMetrics`.
6. **REFRACT particles (13 library materials) stay on the built-in draw, as intended and logged.** They can't be recalibrated until snapshot support lands. When it does, re-check the I22 conventions: since `9d8c262`, `common_particles.h` no longer flips `v_ScreenCoord.y`, and the `#ifndef HLSL` offset flip in `genericparticle.frag` is taken.

**Status of F1–F6 (particles, H).** F1 fixed by `0591466` (`testRandomSpriteFramesShowOneFrameEvenWithFrameBlending`). F2 fixed by `0591466`, following linux-wallpaperengine and wallpaper-scene-renderer (size/2); a WE capture is still Open. F3 fixed by `0591466` (`.tex` flags pick the sampler: `testClampUVsKeepsTheOppositeEdgeOut`, `testBuilderReadsTheTextureFlags`). F4 fixed by `329a12d` (the three pixel tests above). F5 measured by `ParticleMaterialPerformanceTests.testSubdividedRopeTrailCost`: 2 000 rope-trail segments on an M4 take 2.9 / 1.9 / 3.8 ms GPU at S = 0 / 4 / 8. F6 fixed by `a0d6c15` (scene snapshot per refracting system) and `671456d` (the built-in draw's faded look-alike no longer dims them).

---

# SceneScript

Status: 2026-09-25, branch `deepratna/feature-work`, base `94a9e6e` (WP1 and WP2 landed). Adversarial list for the rewrite in [`scenescript-plan.md`](scenescript-plan.md); owners are its work packages. Paths are relative to `OpenWallpaperEngine/`. "Corpus" is `/Volumes/980Pro/dd-scenescript/corpus` (281 scripts, 508 sites); a 12-hex name like `08861b7e67b4` is `corpus/scripts/<name>.js`. §1.9 P*n* is the plan's evidence table.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| S1 | Critical | WP3 | Tokenizer: regex vs division, comments and strings that contain `export`/`import`, template literals |
| S2 | High | WP3 | Export getters pick up non-exported functions and globals named like callbacks |
| S3 | Medium | WP3 | Sloppy-mode wrapper: implicit globals and `this`, unlike WE's always-strict modules |
| S4 | High | WP3, WP2 | Line and column drift in error reports |
| S5 | Medium | WP3, WP9 | Compile failures and V8-vs-JSC language gaps (macOS 13 JSC) |
| S6 | Critical | WP8, WP11 | Return-value coercion: NaN/Infinity reach Swift `Int(...)`, broadcast, text |
| S7 | High | WP8 | Accumulators and aliasing of `value` between calls |
| S8 | High | WP4, WP8 | Load order: `scriptproperties` → `init` → `applyUserProperties`; user-bound script properties |
| S9 | High | WP4 | Timers: cancel after fire, timers added while timers run, clock source, NaN delays |
| S10 | High | WP2, WP4, WP6, WP11 | Teardown: timers, `destroy()`, storage flush, no extension teardown hook |
| S11 | High | WP2, WP7, WP11 | Reentrancy: scripts creating or destroying layers and scripts inside callbacks |
| S12 | High | WP7, WP11 | `createLayer` from assets that must be loaded, or are missing |
| S13 | Medium | WP7, WP11 | `sortLayer` and command timing relative to updates and the draw |
| S14 | High | WP7, WP6 | Vector aliasing in setters, getters and event objects |
| S15 | Medium | WP7, WP8 | Vec math interop, degrees↔radians and Float32 round trips |
| S16 | High | WP5 | Audio buffers: sharing between scripts, smoothing advanced per renderer, races with capture |
| S17 | Critical | WP2, WP5 | A script detaches a shared typed array; JSC frees Swift's memory (use after free) |
| S18 | High | WP6 | MediaRemote unavailable or slow; artwork palette on the render thread |
| S19 | High | WP2, WP11 | Watchdog runs on the main thread; one hung script freezes the app and halts everything |
| S20 | Medium | WP2, WP6, WP10 | Inbox overflow drops state-changing events |
| S21 | Medium | WP4 | `localStorage` limits, corruption, write amplification, display ids |
| S22 | High | WP11, all | Two displays must share nothing |
| S23 | High | all | Swift↔JS retain cycles leak a whole VM per wallpaper switch |
| S24 | Medium | WP9, all | Per-frame allocations, GC pauses, the < 0.5 ms target, replay determinism |
| S25 | High | WP7, WP8 | Scripts on effects and materials (`thisObject`) |
| S26 | Medium | WP8, WP10, WP11 | Scripts on hidden layers and effects |
| S27 | Medium | WP10 | Cursor hit testing: spaces, parallax, Retina, multi-display, click pairing |
| S28 | Medium | WP2, WP7 | Untrusted scripts reach `__rt` and the shared buffers |
| S29 | Medium | sound | Sound layers: double playback, playing while paused, restarts on rebuild, memory, callbacks |

---

## S1. Tokenizer edge cases (Critical, WP3)
**Scenario.** The transformer finds top-level `import`/`export` with a tokenizer (plan §4.2). The corpus has everything that trips a naive one:
- 24 scripts with commented-out exports: `// export function update(value){` (about 15 scripts), block comments `/*export function init() {` (`01d5071b6f02` and others). If a comment is not skipped, a dead `update` becomes live, or `export ` is stripped from the middle of a comment and breaks nothing visibly but shifts the next token.
- `import` inside a comment (`01aa0f2822e2:3`, `// import * as WEVector from 'WEVector';`). Blanking that line is harmless; treating it as an import and registering a dependency is not.
- Regex literals after `(`: `string.split(/\s*,\s*/)` (`1b3a92cc7a8f:83`, `6f913f89fcc9`, `867af3817c70`). The classic trap: `/` after `)` or an identifier is division, after `(`, `,`, `=`, `return`, `typeof` it starts a regex. A mis-classified `/` swallows the rest of the line as a regex and can hide a real `export` or unbalance braces so "top level" is wrong.
- Template literals with `${…}` (`159224b59e2a:10`, `f86e0df8a16e:237`) and multi-line Japanese templates containing `\n` (`f902ebf8404a:29-33`). A template that contains `}` inside `${ {a:1} }` breaks depth counting.
- 32 scripts contain CJK text and full-width punctuation `（）` in comments and strings; none have astral characters, BOM, CRLF or U+2028 today, but Workshop scripts edited on Windows commonly have CRLF.
- 147 scripts use `export let/var/const`; none use `export {…}`, `export default`, classes or generators.
**Test.**
- Corpus: for every script, the export set the compiler reports equals `per-script.json`'s exports, and the transformed source has the same line count.
- Synthetic: `a = b / c / d` and `x = y /2/ z` stay division; `return /x/.test(s)`, `(/a/)`, `[/a/]`, `!/a/` are regexes; `}` then `/` after a block vs after an object literal; `` `${ {a:1}.a }` ``; `'export function update'` in a string; `obj.export = 1`, `{ import: 1 }`, `x.import`; `export` followed by a newline and then `function` (still an export); `export let a = 1, b = 2` (two exports); `export let {a} = o` (reject or support, but decide).
- A CRLF copy and a CR-only copy of every corpus script compile to the same exports and line numbers.

## S2. Export getters resolve non-exports (High, WP3)
**Scenario.** The contract says exports are "getters for every name in `__rt.CALLBACKS` plus `scriptProperties`" (`Modules/SceneScriptModuleCompiling.swift:10-11`, plan §4.2 `get update(){ return typeof update==='function'?update:undefined }`). If the compiler emits such a getter for a name the script did not export, it resolves the identifier through the module scope and then the global scope:
- A script with a private helper `function init(){…}` or `function destroy(){…}` that it never exports gets it called by the engine. WE calls only exports.
- A name with no binding at all resolves to a global of that name, so any extension that defines a global `update`, `destroy` or `init` (or a sloppy script that leaked one, S3) is called as every other script's callback.
**Test.** A script with non-exported `function update(){ throw new Error('called') }` and `function destroy(){…}` → never called, no error. A global `globalThis.update = () => 7` defined before load → a script without `update` is not affected. Only names in the source's own export list get getters.

## S3. Sloppy-mode wrapper (Medium, WP3)
**Scenario.** ES modules are always strict; 9 corpus scripts lack `'use strict'` (`288db579f057`, `7d3bc214624c`, `a1b1d7b1a839`, `b960dd5aa8d4`, …). If the factory function is not strict:
- `counter = 0` without a declaration creates a **global** shared by every script in the scene (WE throws a ReferenceError at that line). Two scripts using the same undeclared name then step on each other, and the difference hides author bugs WE would surface.
- `this` at top level is `globalThis` instead of `undefined`; `arguments.callee`, `with`, octal literals and duplicate parameters are accepted.
**Test.** A script without `'use strict'` doing `x = 1` at global scope → ReferenceError on that line, instance disabled; `typeof this` at top level is `'undefined'`; two non-strict scripts with the same top-level `let` both run.

## S4. Line and column drift (High, WP3, WP2)
**Scenario.**
- The header is joined onto line 1 (plan §4.2), so errors on line 1 report a column shifted by the header's length.
- Blanked import lines must keep their newlines, including an import that spans lines.
- JS counts `\r\n`, lone `\r`, U+2028 and U+2029 as line terminators; a Swift tokenizer that counts only `\n` drifts after the first CR-only or U+2028 line.
- **Errors thrown by runtime or extension helpers carry the helper's line, not the script's.** Confirmed for WP2, see Findings SF1.
**Test.** Fixtures that throw on line 1 at column 5, on the line after a blanked two-line import, after a CR-only line and after a U+2028 inside a string, each reporting the original line (and column on line 1). `engine.registerAudioBuffers(16)` inside `update` on line 3 reports line 3.

## S5. Compile failures and language gaps (Medium, WP3, WP9)
**Scenario.**
- `8bb9b9a54120` (string broken across lines) must disable only that site, keep the authored value and log once with its line.
- The deployment target is macOS 13 (`OpenWallpaperEngine.xcodeproj`, `MACOSX_DEPLOYMENT_TARGET = 13.0`). WE runs V8, which has builtins that macOS 13's JSC lacks (`Object.groupBy`, `Array.prototype.toSorted`/`toReversed`/`with`, regex `v` flag, `Promise.withResolvers`, `ArrayBuffer.prototype.transfer`). A Workshop script that uses one works in WE and on macOS 15 but throws a TypeError on macOS 13 every frame. The corpus uses none, but CI and developers run the newest macOS, so no test would notice.
- HTML-like comments (`<!--`) and hashbangs are accepted by our classic-script wrapper but rejected by V8 modules (harmless leniency; note it).
**Test.** The WP9 corpus replay also runs on the oldest supported macOS once before a release; a synthetic script that calls `[].toSorted()` in `update` logs one error naming the script and line, and other scripts keep running.

## S6. Return-value coercion (Critical, WP8, WP11)
**Scenario.** P3: a number returned for a vector is broadcast (today it becomes `(n, 0, 0)`), a failed type check leaves the field unchanged, and **NaN passes the number check and is written**. What reaches Swift matters more than what reaches JS:
- `08861b7e67b4` with its `barAmount` slider at 100 reads `audioBuffer.average[64]` (past the 64-entry array) → `undefined * x` → NaN → `scale.y = NaN` on the last bar. `Infinity` comes from `1000 / (now - last)` when two frames share a millisecond (`155fe61a17a0` computes `fps` that way).
- Swift's `Int(Float.nan)` and `Int(Float.infinity)` **trap**. Any consumer that converts a scripted number to an integer (particle `rate`/`count` → emitted count, `maxrows`, `pointsize` → font size, `limitrows`, a texture-animation frame, an index) crashes the app. A NaN in a world matrix makes the layer vanish, and a NaN in `alpha` poisons blending.
- `1e39` is finite in JS but `+inf` after the Float32 table write.
- Text: `update` returning a number, `null`, `undefined`, an object or a Vec3. The text must never render `"undefined"`; what WE does with a number (convert or skip) must be decided from P3, not guessed per call site.
**Test.** A fuzz fixture per field type (number, bool, string, Vec2, Vec3, colour, text, `instanceoverride.*`, `general.*`) returning each of `NaN`, `±Infinity`, `-0`, `1e39`, `"1 2 3"`, `"abc"`, `null`, `{}`, `[]`, `true`, a Vec2 for a Vec3 field, then rendering 10 frames through the renderer: no trap, no NaN in any GPU uniform the renderer computes from the table except where P3 says WE writes it, and a clamp or skip at every `Int(...)` conversion.

## S7. Accumulators and aliasing of `value` (High, WP8)
**Scenario.** P2: `update(value)` receives the last applied value, so `value += frametime` accumulates.
- If WP8 hands the script the cached value object itself, a script that mutates it and forgets to `return` (`value.x += 1;`) moves the property in ours and not in WE, where `value` is a fresh copy.
- If `rt.apply` stores the returned object as is (`Resources/SceneScript/runtime.js:124-129` stores whatever `coerce` returns), a script that returns a module-level `Vec3` and keeps mutating it from a timer or cursor callback changes `record.value` between frames without any return.
- On an animated property (P2), the value must be this frame's animated value, so an accumulator on an animated property does not run away.
**Test.** `update(v){ v.x += 1 }` (no return) → unchanged after 10 frames. `const k = new Vec3(); update(){ k.x += 1; return k }` plus a timer that sets `k.x = 100` → the field shows only what `update` returned. `update(v){ return v + 1 }` on alpha → 0, 1, 2, … exactly. An accumulator on an animated field follows the animation plus one frame's increment.

## S8. Load order and script properties (High, WP4, WP8)
**Scenario.**
- `08861b7e67b4` reads `scriptProperties.barAmount` in `init` to decide how many bars to create; if `scriptproperties` are injected after `init` (or the user-bound `{user, value}` entries, 38 in the corpus, are unresolved at load), the wallpaper makes 32 bars instead of the user's count and never corrects it (init runs once).
- `105f9d26fe76` relies on `applyUserProperties` running after every `init` (P8).
- On a property change, the user-bound script properties must be re-injected **before** the same frame's `applyUserProperties(changed)` broadcast, or scripts see the old value for a frame (or forever, if they latch).
- `load()` is re-callable for scripts added later; runtime-added scripts then receive `applyUserProperties(all)`, which P8's best guess says WE never sends. See Findings SF5.
- `engine.userProperties` colours must be `Vec3` through `_Internal.convertUserProperties`, the same object the first `applyUserProperties` gets.
**Test.** A fixture whose `init` creates `scriptProperties.n` layers with a user-bound `n` → the user's value; changing the user property → `applyUserProperties({n})` sees the new `scriptProperties.n`. The call log of a three-script scene matches P8 exactly: bodies, injection, `init`+media per script, then all `applyUserProperties`, then all `applyGeneralSettings`.

## S9. Timers (High, WP4)
**Scenario.** Corpus pattern (`23ea5c1b7601`, `1553916bf67e`): `lastHideEvent = engine.setTimeout(() => { thisObject.visible = false }, 1000)`, and on the next media event `lastHideEvent()` to cancel.
- Cancelling a timeout that **already fired** must be a no-op. With numeric ids reused from a free list, it cancels someone else's timer.
- A timer created inside a timer callback must not fire in the same pass (P1: per script over a snapshot); an interval whose period is shorter than the frame fires once per frame (reset, not catch-up); `setTimeout(cb, 0)` fires next frame.
- `ms` of `NaN`, negative, `undefined`, a string; `cb` not a function (a string of code must not be `eval`ed).
- Clock: timers must run on scene time, so pausing the wallpaper (`playRate 0`), sleep/wake and speed changes do not fire a burst of intervals on resume; `engine.runtime` and the timer clock must agree.
- A timer whose script was removed (`destroyLayer`, reconfigure) must never fire into a destroyed object.
- Global-scope `setTimeout` throws WE's message; a timer callback that throws is logged but not disabled.
**Test.** The `lastHideEvent` pattern with a cancel after the fire, then a second timer created: the second still fires. A 1 ms interval over 10 frames of 16 ms → 10 calls. Pause for 60 s and resume → no burst. Remove a script with a pending timeout → nothing fires, no error.

## S10. Teardown (High, WP2, WP4, WP6, WP11)
**Scenario.**
- `destroy()` may write `localStorage`, start a timer, stop a sound or push commands. `SceneScriptRuntime.tearDown()` runs `__rt.teardown` and never drains the command ring or tells extensions (Findings SF4), so storage written in `destroy()` is lost if WP4 batches writes, WP4 cannot clear timers, WP6 cannot unsubscribe from the media source, and WP5 cannot release its capture client.
- `deinit` calls `tearDown()`, so script `destroy()` callbacks run on whatever thread drops the last reference to the runtime (a view model released on a background task), breaking render-thread confinement.
- A watchdog stop inside `destroy()` during teardown must not block the next wallpaper's load.
**Test.** A script whose `destroy()` does `localStorage.set('k', 1)`: after teardown and a new runtime, `get('k')` is 1. A pending interval at teardown never fires afterwards (poll 2 s). A fake media source sees one unsubscribe per runtime. Release the last reference on a background queue → `destroy()` still runs on the render thread, or not at all, by design.

## S11. Reentrancy (High, WP2, WP7, WP11)
**Scenario.** Scripts change structure from inside callbacks:
- `destroyLayer(x)` in `update` or in a cursor callback of `x` itself; then writes to `thisLayer` after its own destroy.
- `destroy()` of one script removes another script: in WP2's `destroyPending` the second one is dropped without its `destroy()` and stays in `byId` (confirmed, Findings SF2).
- `createLayer` with a scripted config inside `update` adds records while `rt.frame` iterates `rt.records` (the loop reads `records.length` live, so a new record is visited in the same frame; it is skipped only because its state is `DEFINED`).
- A command handler that calls back into JS (for example `createLayer` running the new layer's module body) pushes into the ring while `SceneScriptCommandRing.drain()` executes it; `drain` ends with `resetRing`, which drops those commands.
- Slot reuse: a stale `ILayer` kept after `destroyLayer` writes into a slot that now belongs to a new layer (ABA).
**Test.** Create and destroy 1000 layers over 1000 frames with memory flat (the WP11 clone stress test). A stale handle write after its slot is reused changes nothing. `destroy()` that removes another script → both `destroy()`s run and both ids are gone. A handler that pushes a command during `drain` → the command runs this frame or the next, never lost.
**Status.** SF2 fixed in `16f9469`; stale handles in WP7. A command pushed during `drain` now runs in the same drain, bounded by the ring's capacity (`SceneScriptRuntimeReachTests`). The clone stress test is WP11's.

## S12. `createLayer` from assets (High, WP7, WP11)
**Scenario.**
- `08861b7e67b4` and `4919ac5f12ef` call `thisScene.createLayer('models/bar.json')` up to 99 times in `init`, and immediately write `alignment`, `color`, `alpha`, `parallaxDepth` and call `sortLayer(bar, thisIndex)`. The returned object must exist synchronously with a slot, and every write before the native layer materialises must land on it.
- `f6acb397ce16` creates 63 bars from `models/workshop/2079954552/bar.json`, another Workshop item's asset. When that dependency is missing, `createLayer` returning `null` makes `newBar.parallaxDepth` throw in `init`, which disables `init` (P4) with half the bars made. What WE returns for a missing asset must be settled, and the loader must not crash on it.
- `585203d7f809` clones through `createLayer(thisScene.getInitialLayerConfig(origbar))` inside a `try` and treats any throw as "no bars".
- Loading textures and models synchronously inside the JS entry stalls the frame (and counts toward the watchdog, S19). Loading them asynchronously means the first frames draw nothing for those layers.
- The object table has a fixed capacity (`Objects/SceneScriptObjectTable.swift:39-45`; "a larger table is a new buffer"). Growing it replaces the `Float32Array`; any JS layer object that captured the old array keeps writing into a dead buffer.
**Test.** 99 bars in `init` → 99 slots with independent origins and the draw order WE gives repeated `sortLayer(bar, i)` at the same index. A missing asset path → the documented result, one log line, no crash. Grow past capacity mid-scene → earlier layer objects still move their layers.

## S13. `sortLayer` and command timing (Medium, WP7, WP11)
**Scenario.**
- `sortLayer` from `update` must reorder before this frame's draw (plan: "in the same frame"); `getLayerIndex` right after `sortLayer` in the same callback must agree with WE (immediate or deferred; unknown, decide).
- Indices count what: drawables only, or also sound and hidden objects? `getLayerIndex(thisLayer)` followed by `sortLayer(bar, thisIndex)` gives different results for each choice.
- Commands pushed during `load` (module bodies and `init`: `createLayer`, `sortLayer`, `play`, `setFrame`) are not drained until after the first frame's updates (Findings SF5).
- The ring holds 4096 commands per frame; a script calling `emitParticles` or `setMaterialProperty` per bar per frame overflows it and later commands are dropped silently after one log line.
**Test.** `sortLayer` in `update` → the rendered order changes in the same frame (render test). `getLayerIndex` after `sortLayer` matches the chosen rule. A `play()` in `init` takes effect before the first rendered frame.

## S14. Vector aliasing (High, WP7, WP6)
**Scenario.** `08861b7e67b4.update` assigns **one** `Vec3` to every bar and mutates it between assignments: `scale.y = …; bar.scale = scale;` then the next bar. `bar.color = baseColor` shares one object across all bars. `baseOrigin = thisLayer.origin` is kept across frames.
- A setter that stores the reference (the plan keeps strings and rare fields on the JS object) makes every bar end up with the last bar's value.
- A getter that returns the cached object lets `baseOrigin` follow the layer, and makes `thisLayer.scale.x = 2` take effect (4 corpus scripts commented that out because it doesn't in WE).
- Event objects: `shared.accentColor = event.primaryColor` (corpus) keeps a thumbnail colour. If WP6 pools or reuses event objects to save allocations, the stored colour changes on the next event. `rt.broadcast` passes the same argument array to every script (`runtime.js:302-308`), so one script that mutates the event (or the `resizeScreen` Vec2, or the `applyUserProperties` object) changes what the next script receives.
**Test.** The bar loop above → each bar keeps its own scale. `const o = thisLayer.origin; thisLayer.origin = new Vec3(5)` → `o` unchanged. Two scripts on `mediaThumbnailChanged`, the first does `e.primaryColor.x = 0` → decide and pin whether the second sees it (WE likely builds the event per call).

## S15. Vec math interop and units (Medium, WP7, WP8)
**Scenario.**
- WE's quirks must survive: `new Vec4(x, y, z)` sets `w = z`, `Vec2.perpendicular()` is `(y, -x)`, `equals` uses an epsilon, `new Vec3(n)` broadcasts (`08861b7e67b4`: `new Vec3(0 + barWidth)`). Only loading `baseclasses.js` unmodified guarantees that; any shim that redefines them (the old one did) breaks it.
- Coercion must accept WE Vec objects, plain `{x, y, z}`, and `"x y z"` strings, and read `x/y/z` through getters too.
- Angles are degrees at the API and radians in a Float32 table: `thisLayer.angles = new Vec3(0, 0, 90)` then `thisLayer.angles.z === 90` is false after the Float32 radians round trip (89.99999…). Scripts that compare or accumulate (`angles.z += 1` for hours) drift. The same holds for origin `0.1` → `0.10000000149`.
**Test.** Set angles 90 and read back exactly 90 (store degrees, or round-trip within 1e-4 and document it). 100 000 frames of `angles.z += 0.36` → 36 000 within 0.01. `Vec4(1, 2, 3).w === 3`.

## S16. Audio buffers (High, WP5)
**Scenario.**
- **Smoothing advance.** `AudioSpectrumAnalyzer.advanceFrame()` moves the smoothing one step and must be called "exactly once per frame" (`Audio/AudioSpectrum.swift:90-91`). Every `SceneMetalRenderer` already calls it (`Scene/Rendering/SceneMetalRenderer.swift:449`), so two displays advance it twice per frame, and a WP5 extension that also calls it makes three: faster decay, and different values per display. WP5 must read `snapshot`, and the analyzer should advance once per display-link tick, not per renderer.
- **Sharing between scripts.** One `SceneScriptSharedBuffer` per resolution shared by every script (plan §5 WP5) means a script that normalizes in place (`buf.average[i] *= gain`) changes every other script's input for the rest of the frame. None of the corpus scripts write into the arrays, but Workshop scripts that do exist in the wider Workshop.
- **Races.** Filling the typed arrays from the capture thread (tempting for "live") gives torn reads mid-`update`; filling only in `willRunFrame` from `snapshot` under the analyzer's lock does not.
- **Stereo.** `left ≠ right` needs real stereo capture; a mono source copied to both sides passes every test that only checks shape.
- Out-of-range reads (`average[64]`) are `undefined` in WE too; they feed S6.
- Two `registerAudioBuffers(16)` calls in one scene must both work; `registerAudioBuffers(128)` throws WE's message; a call from a callback throws.
**Test.** Two runtimes rendering the same tone for 60 frames → identical values and the same decay as one runtime. Script A writes `average[0] = 99` and script B reads it in the same frame → B sees the captured value (per-script arrays, or copies refreshed per call). A left-only tone → `right` stays near zero.

## S17. Detached shared buffers (Critical, WP2, WP5)
**Scenario.** `SceneScriptSharedBuffer` gives JavaScriptCore ownership of Swift's allocation (`JSObjectMakeTypedArrayWithBytesNoCopy` with a deallocator that frees it) and keeps the typed array alive, assuming that keeps the memory alive (`Runtime/SceneScriptSharedBuffer.swift:7-9`, `:20`). A script that calls `audio.left.buffer.transfer()` (available in JSC from macOS 14.4) detaches the original: the new `ArrayBuffer` takes the bytes, and when it is collected JSC calls the deallocator while `pointer` is still used by Swift. Every later `willRunFrame` write is a heap write after free. Confirmed, see Findings SF3. Audio buffers are handed to scripts by design (WP5); the object table and command ring are reachable through `__rt` (S28).
**Test.** The probe in SF3 as a unit test: transfer a shared buffer's `ArrayBuffer`, drop it, force GC, then write through `pointer` under Address Sanitizer → no report.
**Status.** Fixed (SF3, SF9); `SceneScriptObjectHardeningTests`.

## S18. Media sources (High, WP6)
**Scenario.**
- MediaRemote is restricted for third-party bundles since macOS 15.4. The adapter (`/usr/bin/perl` or a helper) can disappear in any OS update, hang, or return garbage. Failure must mean `mediaStatusChanged({enabled: false})` once, not a crash, a hang on the render thread, or a permission prompt.
- The artwork palette (k-means or median cut) on a 1000×1000 image costs tens of ms; computed on the render thread it drops frames on every track change. It must run off-thread and post the event.
- Timeline events arrive several times a second from some players; while the wallpaper is paused they pile up in the inbox (S20).
- P8: each script gets the current media state right after its `init`, including scripts added later; before the first real event the state must be "no media", with WE's field names and `MediaPlaybackEvent` constants.
- No AppleScript and no Automation prompts anywhere (the old `BrowserMediaIntegration` polled eight browsers every 2 s).
**Test.** A fake source that fails to start, hangs for 5 s on the first query, and flips availability: the first frame is not delayed, `enabled` goes false then true, no crash. Palette time on a 4K PNG measured off the main thread. `grep -r NSAppleScript` in `Scene/Scripting` is empty.

## S19. Watchdog on the main thread (High, WP2, WP11)
**Scenario.** The renderer draws from `MTKView` with `isPaused = false` and `enableSetNeedsDisplay = false` (`Scene/Rendering/SceneMetalRenderer.swift:213-214`), i.e. on the main thread. The watchdog allows 15 s per native→JS entry (`Runtime/SceneScriptRuntime.swift:16-21`), so one `while (true) {}` in any script freezes the whole app (menu bar, settings, every other display) for 15 s. WE runs scripts in the wallpaper process, so its 15 s hang does not freeze its UI.
- After the stop, the runtime is halted for good (P5): the wallpaper keeps rendering with frozen values and the only sign is one log line. The user needs a visible state or a reload.
- The limit covers the whole frame (all 71 scripts of 3453730450 plus events and timers), not each outermost call like WE's; a legitimately slow load (99 `createLayer`s with synchronous asset loads, S12) shares one 15 s budget.
- Measured on this Mac: the watchdog stops a catastrophic regex (`/^(a+)+$/` on 28 characters) but overshoots a 0.5 s limit to 1.17 s.
**Status.** The mechanism is in (`16f9469`): `SceneScriptThread` runs a runtime on its own queue and `asyncFrame` skips frames while one is in flight (`testAHungScriptOnItsThreadLeavesTheMainThreadFree`); WP11 must create every runtime on one. The whole-frame budget and the halted-state UI remain open.
**Test.** A scene with a `while(true)` in `update` of a script on display A: the main run loop stays responsive enough to open Settings (or document that it does not, and pick a shorter per-frame limit than WE's), display B keeps rendering after A's stop, one "dead lock" line names the script, and the wallpaper shows the halted state. Termination inside `load`, `frame` and `tearDown` each leave the runtime `halted` and the next wallpaper loadable.

## S20. Inbox overflow (Medium, WP2, WP6, WP10)
**Scenario.** `SceneScriptInbox.post` drops the **oldest** events past 1024 (`Runtime/SceneScriptInbox.swift:14-16`). When frames stop (`metalView.isPaused` when `playRate == 0`, `Scene/UI/SceneWallpaperView.swift:144`; occluded windows; a sleeping display), cursor moves (WP10) and media timeline events (WP6) keep arriving. A user-property change made in the sidebar while paused is then pushed out by mouse movement, and scripts never receive that `applyUserProperties`, a permanent desync. Confirmed by reading, Findings SF4.
**Status.** Fixed with SF4/SF15; WP10 posts clicks as `.keep`.
**Test.** Pause, change a user property, post 2000 cursor moves, resume → the script receives the property change. Cursor moves should be coalesced (keep the latest), and state events (properties, settings, media status, playback) never dropped.

## S21. `localStorage` (Medium, WP4)
**Scenario.**
- Cap: 100 KB per wallpaper (docs). A script that appends to a stored array every frame hits it in minutes; `set` beyond the cap must fail the way WE does (throw or return false), not grow the file or crash.
- Write amplification: a `set` every frame must not become a file write every frame on the (external) disk; batch and flush, and flush at teardown (S10).
- Corruption: a crash mid-write leaves a truncated file. Write atomically (temp file and rename); an unparsable file reads as empty and logs once, and must not throw on every `get`.
- Values: `Vec3` through `_Internal.stringifyConfig`; cyclic objects and functions (`JSON.stringify` throws) must throw into the script, not crash native code; NaN becomes null.
- Keys that are not strings throw WE's "key not a string"; calls at global scope throw.
- Scope: `'screen'` is keyed by display id. `CGDirectDisplayID` can change after a reconnect or reboot, and then per-screen data vanishes. Two runtimes of the same wallpaper on two displays share `'global'`; if each caches the file, the last writer wins and clobbers the other's keys.
**Test.** Two runtimes write different `'global'` keys → both survive a reload. Truncate the file → next load logs once and starts empty. `set` past 100 KB → WE's behaviour. A `Vec3` round-trips as a `Vec3`.

## S22. Two displays share nothing (High, WP11, all)
**Scenario.** Two instances of the same wallpaper must not share `shared`, module-level variables, timers, audio smoothing (S16), storage caches beyond `'global'` (S21), command handlers or statics in Swift. The old singleton `AudioReactiveScriptEngine.shared` keeps clobbering until WP11 removes it; any extension that keeps a `static var` cache (opcode handlers, compiled-module cache keyed by source, palette cache keyed by track) reintroduces the problem.
**Test.** Two runtimes of one scene with a counter in `shared` and in a module-level `let`; run A for 10 frames and B for 3 → 10 and 3. Tear down A → B keeps running with its timers. `grep -n "static var" Scene/Scripting` reviewed per package.

## S23. Swift↔JS retain cycles (High, all)
**Scenario.** A `@convention(block)` native installed on `rt.native` that captures the runtime or the extension strongly makes JSContext → block → runtime → JSContext: the VM is never freed. `SceneScriptCommandRing.register` stores escaping handlers (`Objects/SceneScriptCommandRing.swift:62-65`); WP7's handlers will naturally capture the runtime or the renderer, making runtime → ring → handler → runtime. A `JSValue` stored in a Swift object that JS can reach retains the context strongly (use `JSManagedValue`). Every wallpaper switch then leaks one VM, its JS heap, the object table, the ring and the audio buffers.
**Test.** Create a runtime with every extension, load a corpus scene, run 10 frames, tear down, and assert a `weak` reference to the runtime and to each extension is nil. Repeat 100 times with resident memory flat.

## S24. Per-frame cost and replay determinism (Medium, WP9, all)
**Scenario.** Target: < 0.5 ms per frame for 3453730450 (71 sites), about 1–5 µs per script.
- Swift→JS bridging per frame: `inbox.drain().map { $0.javaScriptObject }` converts Swift dictionaries each frame (cursor moves at 120 Hz), `rt.frame` gets a bridged array, `drainErrors` uses `toArray`, ring strings use `toArray`. Each is small but all run every frame.
- JS allocation: a `Vec3` per getter and per argument (like WE), event objects, closures. Eden GCs every few seconds with 1–3 ms pauses show up as p99 spikes, not in averages.
- Determinism: 62 corpus scripts use `Date` and 7 use `Math.random`. A replay harness with a fake clock must also stub `Date` and seed `Math.random`, or assertion (e) on clocks is flaky and frame-time baselines vary.
**Test.** `measure` p50 and p99 over 3600 frames of 3453730450 with a tone: p50 < 0.5 ms, p99 < 1 ms. Zero Swift→JS object creations in a frame with no events. The clock fixtures run at a fixed `Date`.
**Status.** Addressed by the optimisation pass after WP11: the JIT is on (it was off, since the app lacked `allow-jit`); the per-call closures and arrays are gone; and unchanged material writes send no command. `SceneScriptLibraryCostTests` measures after a 10 s warm-up: 3453730450 runs at p50 0.21 ms and p99 0.54 ms (plan, "After WP11"). A frame with events still bridges them (`inbox.drain().map { $0.javaScriptObject }`).

## S25. Scripts on effects and materials (High, WP7, WP8)
**Scenario.** 46 `effects[i].visible` sites (`thisObject.visible = event.hasThumbnail` 44 times) and 86 effect-constant sites. `thisObject` must be the `IEffect` or the `IMaterial` (constants by name, `thisObject.multiply`), and `thisObject.getAnimation()` must be the property's own timeline (2134765860's `multiply` with `startpaused`).
- Effects hidden at load are not built today (plan §3.3 item 11); a media event can then never show them.
- A material constant whose name collides with a member (`name`, `visible`, `getAnimation`) or with `Object.prototype` (`constructor`, `toString`, `__proto__`) shadows or breaks the object if members are defined per name on the object.
- Two effects with the same name: `getEffect(name)` returns which one?
- `setMaterialProperty` must reach every material of the effect with that constant, and nothing else.
**Test.** An effect hidden at load, shown by a `mediaThumbnailChanged` with `hasThumbnail: true`, draws. A material with a constant named `constructor` still exposes `getAnimation`. `thisObject` for an effect-constant script is the material, not the layer.

## S26. Hidden layers (Medium, WP8, WP10, WP11)
**Scenario.** P6: `update` runs on hidden layers; `03f0db0a6dff` hides its own layer in `init`. The old code drops objects hidden at load and runs visible scripts once. Also:
- a layer hidden by its parent: its scripts still run;
- cursor events on a hidden (or alpha 0) Solid layer: WE's hit test presumably skips invisible objects; ours must decide the same way;
- the renderer must skip drawing hidden layers without skipping their transform pass, or `getTransformMatrix` and hit tests read stale matrices.
**Test.** A layer hidden in `init` whose `update` shows it after 30 frames appears on frame 31. A click on a hidden Solid layer → no cursor callback.

## S27. Cursor hit testing (Medium, WP10)
**Scenario.** Three coordinate spaces meet: AppKit points (bottom-left origin), display pixels (Retina 2×, a second display at 1×), and scene space after `.cover`/`.center` fitting, camera parallax and camera shake. A hit test in points on a 2× display misses by half; one that ignores the parallax offset misses whenever the mouse is off-centre. Also:
- `cursorClick` requires down and up on the same object;
- a layer destroyed while hovered must not get `cursorLeave` afterwards;
- `openUserShortcut` only once per click;
- clicks that land on desktop icons or other apps' windows must not reach scripts (the old code counted any click via `NSEvent.pressedMouseButtons`).
**Test.** Rotated, scaled and parented Solid layers on a 2× and a 1× display, with parallax on: clicks at the layer's corners hit, 1 px outside miss. Down on A and up on B → no click. Moving across two overlapping Solid layers gives enter/leave pairs for the top one only.

## S28. Untrusted scripts reach the runtime (Medium, WP2, WP7)
**Scenario.** `__rt` is a non-writable global, but its members are writable and reachable from every script. A Workshop script can replace `__rt.hooks.coerce`, clear `__rt.records`, set `__rt.halted`, or push arbitrary opcodes and targets through `__rt.push` or directly into `__rt.ring.records`. The ring bounds-checks number ranges (`Objects/SceneScriptCommandRing.swift:95-96`), but each handler must also bounds-check `target` against the object table. Combined with S17, the shared buffers are the only path from script to memory corruption.
**Test.** A script that pushes opcode 400 with target `2^31-1`, negative targets and garbage counts → no crash, one log line. Handlers get `target` already validated or validate it themselves.
**Status.** Fixed. The memory-safety half with SF3 and SF10 (shared memory can't be freed, command numbers are validated). `__rt` is hidden from scripts (the module scope shadows it; the global reads `undefined` during every native entry and all script code, so a replaced builtin called by runtime code can't leak it) and sealed after installation (frozen hooks, read-only functions); `SceneScriptRuntimeReachTests`.

## S29. Sound layers (Medium, sound)
**Scenario.** WE plays `sound` objects through SFML streams; ours goes through `AVAudioEngine`. Things that can go wrong:
- Two displays showing one wallpaper play its sound twice. Only the display `shouldPlaySceneAudio` picks gets a gain above 0.
- A paused wallpaper keeps playing: the renderer stops drawing, so the fade runs on its own timer.
- A content rebuild (a user property) restarts the music. Layers with the same id, files and settings keep their playback.
- A very long file (hours of rain) is decoded into memory. It is streamed from disk instead.
- A script calls `play()` every frame. That restarts a loop or single clip each time, as in WE (`play()` stops and restarts).
- Completion callbacks run on AVFoundation's threads. They only hop to the main thread; scheduling from inside the callback deadlocks the engine (seen in the offline probe).

**Test.** `SceneSoundPlaybackTests`, `SceneSoundLayersTests`, `SceneScriptRenderTests.testScriptsDriveSoundsCreatedObjectsBrightnessAndSize`. On screen (manual): a wallpaper with music plays once across two displays, fades out on pause and resumes where it was, and the app's mute silences it.

---

## Findings (SceneScript)

Line numbers are at `94a9e6e` unless a commit is named. Each probe ran against the real `runtime.js` and the system JavaScriptCore on the development Mac.

### WP2: `3387d82` (per-instance runtime skeleton)

**SF1. Errors thrown by runtime helpers report the helper's line as the script's. Medium (S4).** **Fixed** in `16f9469`: lines come from the first stack frame in the script's `sourceURL`.
- `describe` takes `error.line` from the error object (`Resources/SceneScript/runtime.js:55-65`), and `drainErrors` reports it as the script's line (`Runtime/SceneScriptRuntime.swift:256-259`). JavaScriptCore sets `line` where the `Error` was **constructed**, so every error built in `runtime.js` or an extension's JS carries that file's line.
- Probe: a script whose line 3 calls `__rt.requireGlobalScope('registerAudioBuffers')` from `update` → reported `line: 135, column: 51` (the `throw` in `runtime.js:135`). This will hit every WE-message error of WP4/WP5 (`setTimeout cannot be called from global scope.`, `Resolution must be either 16, 32 or 64.`, `key not a string`).
- **Fix direction:** take the line and column from the first `error.stack` frame whose URL is the script's `sourceURL` (`owe://script/…`), or `-1` when there is none.

**SF2. `destroy()` that removes another script loses that script's `destroy()` and leaves it in `byId`. Medium (S11).** **Fixed** in `16f9469`: `__rt.destroyPending` repeats until nothing is pending.
- `destroyPending` walks `records` once, then filters on `pendingDestroy` (`runtime.js:343-354`). A record marked during another record's `destroy()` and positioned **before** it is filtered out of `records` without its `destroy()` and without `byId.delete`.
- Probe: records `c`, `b`; `b.destroy()` calls `__rt.remove('c')`; after the frame `c`'s `destroy` never ran, `records` no longer has `c`, `byId.has('c')` is true (so `isEnabled('c')` stays true and a new script with id `c` throws "Duplicate script id").
- **Fix direction:** loop until no record is pending (or collect, destroy, and repeat), and delete from `byId` in the same pass that filters.

**SF3. A script can free Swift's shared memory by detaching a typed array. Critical (S17).** **Fixed** in `0338833` and `16f9469`: memory reference counted with the deallocator, buffers pinned (JSC copies a pinned buffer on `transfer()`), and the runtime halts if a watched buffer is detached anyway.
- `SceneScriptSharedBuffer` passes a deallocator that frees the allocation (`Runtime/SceneScriptSharedBuffer.swift:20`) and relies on holding the typed array to keep it alive (`:7-9`). `ArrayBuffer.prototype.transfer` exists in this JSC (`typeof … === 'function'`).
- Probe (a Swift JSC program mirroring `SceneScriptSharedBuffer`): after `left.buffer.transfer()`, Swift's writes are visible through the new buffer; once it is dropped and GC runs, **the deallocator is called while Swift still holds `pointer`**. Every later write from `willRunFrame` or the command ring is a use after free.
- Reachable today through `__rt.ring.header/records/args` (command ring), and after WP5 and WP7 through the audio buffers and `__rt.table.values`.
- **Fix direction:** Swift owns the memory (no-op deallocator, freed in `deinit` after the context is gone), and `runtime.js` deletes `ArrayBuffer.prototype.transfer` and `transferToFixedLength` before any script runs; add the probe as a test.

**SF4. The inbox drops the oldest events, including property changes, and teardown has no extension hook. Medium (S10, S20).** **Fixed** in `16f9469`: a full inbox coalesces by `SceneScriptEvent.Coalescing`; extensions get `tearDown(_:)`; `deinit` tears down on the runtime's thread.
- `SceneScriptInbox.post` removes the oldest events past 1024 regardless of kind (`Runtime/SceneScriptInbox.swift:14-16`). Once WP10 posts cursor moves, a paused wallpaper loses the user's property changes.
- `SceneScriptRuntimeExtension` has `install`, `willRunFrame` and `didRunFrame` only (`Runtime/SceneScriptRuntimeExtension.swift:12-25`), and `tearDown` neither drains the ring nor notifies extensions (`Runtime/SceneScriptRuntime.swift:168-177`). WP4 (storage flush, timers), WP5 and WP6 (unsubscribe) have nowhere to clean up; commands pushed in `destroy()` are never executed. `deinit` runs `tearDown` (`:124-126`), so `destroy()` callbacks run on the releasing thread.
- **Fix direction:** coalesce cursor moves and never drop state events; add `willTearDown(_:)` (called after `__rt.teardown`, then drain the ring) to the extension protocol.

**SF5. `load()` differs from P8 for scripts added later, and doesn't drain the ring. Low (S8, S13).** **Fixed** in `16f9469`: later loads skip `applyUserProperties` and `load` drains the ring.
- A second `load` sends `applyUserProperties(userProperties)` to the new records (`runtime.js:258-264`). P8's best guess is that runtime-created scripts get none; if WP11 calls `load()` with the default `[:]`, they get `{}`, and a script that reads `changed.x` without `hasOwnProperty` gets `undefined`.
- `load()` does not call `commandRing.drain()` (`Runtime/SceneScriptRuntime.swift:144-151`), so `createLayer`, `sortLayer` and `play` from module bodies and `init` run only after the first frame's updates.
- **Fix direction:** skip `applyUserProperties` for records defined after the first load (or document the choice), and drain after `load`.

Probes were small `swiftc` programs outside the repo: SF1 and SF2 evaluate the repo's `runtime.js` in a plain `JSContext` and drive `define`/`load`/`remove`/`frame`; SF3 builds a typed array exactly as `SceneScriptSharedBuffer.init` does; S19's regex timing sets `JSContextGroupSetExecutionTimeLimit` to 0.5 s as `SceneScriptWatchdog` does.

### WP3: `4d5410d`, `70c7a98`, `284ec4a` (tokenizer and module compiler)

Ran 33 adversarial snippets through `SceneScriptModuleTransformer` and JavaScriptCore (a `swiftc` build of `Scene/Scripting/Modules/*.swift`). All behave like a V8 module:
- S1: division vs regex (`a / b / c`, `a /2/ c`, after `)`/`return`/a block/an `if (x)`, `/[/]/`), templates with `}` and nested templates, `export`/`import` in strings, comments and as property names, `export` on its own line, multi-declarator and destructuring exports, CJK identifiers, HTML comments, hashbangs.
- S2: only exported names get getters; a non-exported `function update(){ throw … }` is invisible.
- S3: the factory is strict; `counter = 0` throws a ReferenceError on line 1, top-level `this` is `undefined`, a top-level `return` is a compile error.
- S4: CRLF, CR-only and U+2028 sources report the original line; line 1 columns are shifted by the header, as documented.
- ASI hazards (`export let a = 1` followed by a `(` line) fail the same way V8 does.

**No confirmed issues.** SF1 still applies: errors built inside runtime or extension JS carry that file's line.

### WP4: `c75f615`, `7eb0126`, `140b510`, `73d3b6d` (engine, input, console, timers, localStorage)

**What the commits already cover.** S9: a cancel after the timer fired is a no-op (the timer object, not an id, is cancelled); timers added while timers run wait for the next frame; an interval resets to its period, so a resume after a pause fires it once; NaN, negative and missing delays fire next frame; timers die with their record. S10/S21: writes flush at most once per second of scene time and when the extension is released (after `destroy()` ran), and atomically; an unreadable file starts empty with one log line; one `SceneScriptStorage` serves every runtime, so two screens don't clobber `'global'`. S14: each `applyUserProperties` call gets its own converted object. S23: the native blocks capture `self` weakly.

**SF6. `localStorage` keys are not counted against the 100 KB cap. Low.** `setValue` sizes an entry as `8 + value.utf8.count` (`Scene/Scripting/Engine/SceneScriptStorage.swift:54`, `:158-159`); the key is free. A script that uses data as keys (`localStorage.set(JSON.stringify(state), 1)` with a new state each frame) grows the file and the in-memory store without bound. Whether wallpaper64.exe counts keys should be checked at the same address as the value size; if it doesn't, cap the key length or the entry count anyway, because the file is ours. **Fixed** in `0972d84`: keys count toward the cap.
- **Test:** 10 000 `set`s of distinct 1 KB keys → refused past the cap (or the documented WE behaviour), file size bounded.

**SF7. Writes of the last second are lost when the app quits. Low.** Flushing happens in `didRunFrame` once a second (`Engine/SceneScriptEngineExtension.swift:99-101`) and in `deinit` (`:69`, `SceneScriptStorage.swift:40`). Nothing calls `SceneScriptStorage.flush()` from `applicationWillTerminate` (`App/SafeRestart.swift:80` is the existing hook), and runtimes are not released on quit. A counter a script stores on every click loses up to one second of clicks. **Fixed** in `0972d84`: the storage flushes itself on `NSApplication.willTerminateNotification`.
- **Fix direction:** WP11 flushes the shared storage from `applicationWillTerminate` (and on sleep).

**SF8. `engine.runtime` is a Float32 and steps by more than a frame after 1.5 days. Low (verify against WE).** `frame[Slot.runtime] = Float(runtimeSeconds)` (`Engine/SceneScriptEngineExtension.swift:112`). Float32 spacing is 1/64 s at 2^17 s (36 h) and 1/32 s at 3 days, so `Math.sin(engine.runtime * k)` animations stutter on a wallpaper left running (the normal case). The commit says WE's is a float too; if that is right the behaviour is faithful, otherwise keep a Double (a getter over a `Float64Array` costs the same). **Fixed** in `5c883fe`: `engine.runtime` reads a `Float64Array`.

### WP5: `5db500f` (WE's spectrum pipeline), `18e3bfb` (registerAudioBuffers)

**What the commits already cover.** S16: the smoothing is now timed by `deltaTime` from the monotonic clock (`Audio/AudioSpectrum.swift:89-99`), so the extra `advanceFrame()` from a second display's renderer adds one 0.1 ms step instead of a whole frame; the extension only reads the snapshot. The arrays are filled on the runtime's thread before the frame (no torn reads), left/right/average are separate, 128 and non-global calls throw WE's messages.

**SF9. Every script's audio arrays are views into one store per resolution, so SF3 is now reachable from any audio script, and one script's writes reach the others. High.**
- `registerAudioBuffers` returns `store.subarray(...)` of the one shared `Float32Array` (`Scene/Scripting/Audio/sceneScriptAudioBuffers.js:15-19`). `audio.left.buffer` is that store's `ArrayBuffer`: `audio.left.buffer.transfer()` in any script detaches it for **every** script (all arrays become length 0, so every read is `undefined` and every bar goes NaN, S6) and, once collected, frees the memory `willRunFrame` keeps writing (SF3).
- A script that normalizes in place (`buf.average[i] /= max`) changes what every later script sees in the same frame. The commit cites WE's DLL tick "copying" the host arrays at `0x18164f84d`; if that copy targets per-registration arrays, WE isolates scripts and ours doesn't.
- **Fix direction:** fix SF3 first; then give each registration its own arrays refreshed in `willRunFrame` (or pin, from the DLL, that WE shares them).
- **Test:** script A writes `average[0] = 99` in `update`, script B later in the same frame reads the spectrum value; script A calls `left.buffer.transfer()` and script B still reads 16 finite values.

### WP7: `7d767aa`, `d66d6c8`, `c16472e` (object model)

**What the commits already cover.** S14: numeric setters copy into the table at once and getters return fresh `Vec`s, so `08861b7e67b4`'s one shared `scale` gives every bar its own value; strings are copied with `String()`. S11/S12: `createLayer` places the layer synchronously (a live slot the script can write before the `.create` command), a missing asset returns `null` with one log line, the table has a fixed capacity (2048 objects) instead of growing, and a destroyed layer is detached onto a private snapshot so a stale handle never writes a reused slot. S6/P3: `convert` writes NaN like WE and rejects non-numeric components and strings. `sortLayer` clamps its index and rejects NaN. Native blocks and ring handlers capture `self` weakly (S23).

**SF10. A script can crash the app with a non-finite number in a command. Critical (S6, S28).** **Fixed** in `d7c3021`: `SceneScriptNumber` for every script Float→Int conversion (also the legacy engine's audio lookups); `emitParticles` floors and clamps.
- `decode` converts ring floats with `Int(...)` (`Scene/Scripting/Objects/SceneScriptObjectModel.swift:188`, `:196-197`, `:201`, `:208`). `Int(Float)` traps on NaN, ±Infinity and values past `Int.max` ("Float value cannot be converted to Int because it is either infinite or NaN"; checked with `swiftc`).
- Reachable without any adversarial intent: `ParticleSystem.emitParticles(count)` forwards any number (`Resources/SceneScript/objects-layers.js:223-226`), so `emitParticles(audio.average[64] * 10)` (NaN, the out-of-range read of S6) or `emitParticles(1e39)` (Infinity after the Float32 ring) kills the process. The other opcodes take internal indices, but any script can push them through `__rt.push` with NaN (S28).
- **Fix direction:** decode with `Int(exactly:)` after an `isFinite` check (or clamp), and drop the command otherwise; `emitParticles` should also floor and clamp to a sane maximum in JS.
- **Test:** `emitParticles(NaN)`, `emitParticles(Infinity)`, `emitParticles(1e30)`, and `__rt.push(opcode, slot, [NaN, NaN, 1], ['x'])` for every object opcode → no trap, one log line each.

**SF11. `destroy()` runs after its layer was detached. Low.** The deferred handler detaches the layer and removes it from `order` before the runtime calls the scripts' `destroy()` (`Resources/SceneScript/objects-scene.js:230-234`, then `runtime.js` `destroyPending`). The d.ts says `destroy` runs "just before the object is destroyed": in ours, `destroy()` writes to `thisLayer` are ignored and `thisScene.getLayer(thisLayer.name)` returns `null`. **Fixed** in `39ceef8`: the scripts' `destroy()` runs before the layer is detached.
- **Fix direction:** mark the layer's scripts, run their `destroy()` inside the deferred step, then detach.

**SF12. JS-side script removal leaves the id in Swift's `instanceIDs`. Low.** `destroyLayer` removes the layer's scripts with `rt.remove(record.id)` in JS (`objects-scene.js:231`); `SceneScriptRuntime.instanceIDs` only shrinks in the Swift `remove(scriptID:)` (`Runtime/SceneScriptRuntime.swift:180-184`). If WP8/WP11 give a re-created layer's scripts the same ids (object id plus field), `add` refuses them as "duplicate script id". **Fixed** in `16f9469`: removed ids come back through `__rt.removed`.
- **Fix direction:** `destroyPending` reports removed ids back (the frame's return value or a drained list), or WP8 never reuses ids.

**SF13. Angles read back in double precision are not the degrees written. Low (S15).** `read('degrees')` multiplies the Float32 radians by a double constant (`Resources/SceneScript/objects-values.js:89`): `angles = Vec3(0, 0, 90)` reads back `90.0000025`, 45 reads `45.0000013`. Computing the conversion in float (`Math.fround(r * Math.fround(180 / Math.PI))`) gives exactly 90, 45, 180, 360, 1 and 12.5, which is presumably what WE's C++ float conversion returns. `if (thisLayer.angles.z >= 90)` differs. **Fixed** in `39ceef8`: written degrees stay authoritative while the stored radians are unchanged; others convert in float.

**Note (S25).** A material constant named like one of the instance's internals (`_t`, `_dead`, `_effect`, `_constants`, …) makes `new Material` throw (redefining a non-configurable property), so `getEffect` fails for the whole layer (`objects-effects.js:57-68` skips only names in `Material.prototype`). Scene.json constant names are shader-author strings, so it is unlikely; skipping names that are own properties too costs nothing.

### WP5 follow-up: `5342654` (per-registration audio arrays)

**SF9 is fixed for audio buffers.** Each `registerAudioBuffers` call now gets its own `Float32Array`s over extension-owned memory with a no-op deallocator (`Scene/Scripting/Audio/SceneScriptAudioBuffersExtension.swift`), so `transfer()` detaches only that script's arrays and can't free the memory; scripts still see each other's writes until the next refill, which the commit pins to WE's DLL (`0x181655170`). **SF3 stays open** for the buffers that still use `SceneScriptSharedBuffer`'s freeing deallocator and are reachable from scripts through `__rt`: the command ring (`__rt.ring.header/records/args`), the object table (`__rt.table.values`, `__rt.objects.*`) and the engine frame (`__rt.native.engineFrame`). The same no-op-deallocator pattern fixes them.

### WP6: `02e299e` (media callbacks fed by MediaRemote)

**What the commit already covers.** S18: MediaRemote is resolved with `dlopen`/`dlsym` and a missing symbol means `enabled: false` once; fetching and the artwork palette run on a utility queue, never on the render thread; timeline events come at most once a second and only while playing with a known duration; every script gets its own event object and fresh `Vec3` colours (S14); a script gets the current state right after its `init`, and queued events it already saw are skipped by version (P8). No AppleScript.

**SF14. `stop()` unregisters MediaRemote for the whole process. Medium (S18, S22), verify.** `MacMediaSessionSource.stop()` calls `MRMediaRemoteUnregisterForNowPlayingNotifications()` (`Scene/Scripting/Media/MacMediaSessionSource.swift:65`), and `SceneScriptMediaExtension.deinit` calls `stop()`. The register/unregister pair takes no token, so if WP11 gives each runtime its own source (the extension's `init(source:)` invites it), tearing down one display's runtime (switching its wallpaper) stops now-playing notifications for the other display's source too; its scripts then see only the 1 s timeline ticks, never a track or artwork change.
- **Fix direction:** one app-wide source that fans out to extensions, or reference-count register/unregister.
- **Test:** two sources started, the first stopped, a now-playing change posted → the second still publishes it.

**SF15. A paused wallpaper loses media changes, not only property changes. Medium (S20, extends SF4).** While frames are stopped (`playRate 0`, occluded, display asleep), media events keep arriving (the timeline once a second), and the inbox drops the oldest past 1024 (`Runtime/SceneScriptInbox.swift:14-16`): after about 17 minutes of paused playback, the track change or artwork change that happened early in the pause is gone. Media changes are posted as deltas (one event per changed part), so nothing re-sends it: after resuming, `mediaPropertiesChanged` scripts show the old title and `thisObject.visible = event.hasThumbnail` stays stale until the next change. **Fixed** in `16f9469` with SF4: media kinds coalesce to their newest event (`.latest`).
- **Fix direction:** coalesce media events per kind in the inbox (keep only the newest of each), like cursor moves.
- **Test:** post a properties change, then 1100 timeline events, then run a frame → the script's last `mediaPropertiesChanged` has the new title.

**SF16. Teardown blocks the render thread on artwork decoding. Low.** `stop()` runs `queue.sync` when called off the queue (`MacMediaSessionSource.swift:67`); if the queue is decoding and scoring a large artwork (`ArtworkPalette.colors(of:)` visits every pixel), the wallpaper switch waits for it on the main thread. Downscale the artwork before scoring (WE's helper works on the thumbnail) or stop asynchronously.

### Runtime hardening: `d7c3021`, `0338833`, `16f9469`, `39ceef8`, `5c883fe`, `0972d84`, `cea1147`

SF1–SF8, SF10–SF13 and SF15 are fixed, each with a regression test in `SceneScriptRuntimeHardeningTests` or `SceneScriptObjectHardeningTests`; S19 has its mechanism (`SceneScriptThread`). Still open:
- SF14 and SF16 (WP6's `MacMediaSessionSource`). `SceneScriptMediaExtension` can now stop or unsubscribe in the new `tearDown(_:)` hook instead of `deinit`.
- S19: the watchdog still covers a whole frame, not each outermost call, and nothing shows the halted state to the user.

S28 and S11 were closed with WP8 (see WP8 below).

### WP8: property binding, S11, S28

**What the commits cover.** S6/P3: returns go through WE's converter per property type, read from the DLL (`0x181620e10`): flags take only booleans (so `return 1` on `visible` is ignored, unlike the object model's direct setters), text takes `ToString` of anything but `null`/`undefined` (a number shows as its text, never "undefined"), vectors take objects with numeric components or a broadcast number and reject `"1 2 3"`; NaN is written. S7: every argument is a fresh value and every applied return is copied, so neither a mutated argument nor a returned object changed later moves the property. S8: user-bound `scriptproperties` are resolved before module bodies run and re-injected through `_Internal.updateScriptProperties` before the frame's `applyUserProperties`; user-bound values take the new value then too. S25: `thisObject` is the effect, material or scene; material constants read `getMaterialProperty` and write `setMaterialProperty`. S26: hidden layers keep updating.

**Open.**
- Which properties use the converter's Int32 and inert cases is unknown; every numeric property is treated as float. `instanceoverride.colorn` is a number (the d.ts), though scene.json writes a colour.
- The argument is the object model's live value, so it is only as right as the descriptions WP11 builds: they must carry user-resolved values and the renderer's animated values (P2).
- Direct member writes (`thisLayer.visible = 1`) still accept numbers through the object model's setters; whether WE's member setters use the same converter is not verified.

### WP11: renderer integration (`9fe7c90`…`ee8b3bf`)

**What the commits cover.**
- S19: every runtime lives on its own `SceneScriptThread` and the renderer only posts frames (`asyncFrame`), so a hung script drops script frames while the renderer keeps drawing their last values. A watchdog stop is logged, shown in a non-blocking panel like safe restart's (Retry reloads the wallpaper) and stops only that wallpaper's scripts (`SceneScriptRenderTests.testAHungScriptHaltsOnlyItsWallpaper`). The watchdog still covers a whole frame, not each outermost call.
- S22: one runtime per renderer, i.e. per display; `shared`, module variables and frame counts are their own (`testTwoDisplaysShareNothing`). Storage and the media session are shared on purpose (one `SceneScriptStorage`, one `MacMediaSessionSource`, which fans out per subscriber, so SF14 is moot).
- S11/S12: the clone stress test runs 1000 frames of create-and-destroy with the table's slots reused and the scene flat (`SceneScriptWallpaperTests.testCreatingAndDestroyingALayerEveryFrameStaysFlat`). `createLayer` describes the layer synchronously and the renderer builds it off the main thread, so it draws a frame or more later; a missing asset gives `null` and one log line.
- S13: `sortLayer` reorders at once in JS and the renderer applies the order on its next draw, with particle systems kept between the layers around them (`testDrawOrderPutsParticlesBetweenTheLayersAroundThem`).
- S26: hidden objects and effects are built and skipped; visibility scripts run every frame (`testScriptWritesReachThePixels`).
- S10: the renderer tears its runtime down on its thread (`destroy()` runs there) when the content stops or the document changes.

**Open** (the latency, the left button, `brightness`/`size` and sound layers are closed since: see "After WP11" below).
- One frame of latency: scripts run between draws, so what they write shows on the next draw (WE runs them in the frame).
- The left button counts only while Finder is frontmost, the closest this app gets to "clicks the wallpaper receives".
- `brightness` and `size` scripts (none in the corpus) keep their values in JS but aren't drawn from them; sound layers aren't played; scene, effect and material animations aren't script-controlled (WP12).
- 3453730450 takes 0.49 ms per frame (Release median, p99 0.97 ms), just under §4.6's budget, nearly all of it its 71 scripts' JavaScript; the host around them costs about 0.05 ms.

### After WP11: gaps closed, the optimisation pass

**What the commits cover.**
- **Sound layers (new S29 below).** `SceneSoundPlaybackTests` checks, against a recording output, every rule the plan lists from `wallpaper64.exe`:
  - loop with one file (native loop) and with several (random clips back to back);
  - random's wait and `isPlaying()` during it;
  - single;
  - `startsilent`;
  - pause/resume and stop/restart;
  - the `volume²` gain, and a silent start that waits for volume;
  - muting pauses and freezes timers, and a sound loaded muted starts when unmuted;
  - WE's defaults and both `sound` forms.

  `SceneSoundLayersTests` renders AVAudioEngine offline: a layer sounds, its second pass follows without a gap, `volume` 0.5 is a gain of 0.25, WE's fade takes a tenth per 60 Hz step and snaps at 0.01, a starting wallpaper fades in over 45 steps without steps in the signal (OWE's own start fade-in; not on a rebuild, a script's new layer, while muted, nor for a `startsilent` layer), the pause is silent, a rebuild keeps the same playback, and the builder finds loose and packaged files and leaves out what it can't decode. `SceneScriptRenderTests.testScriptsDriveSoundsCreatedObjectsBrightnessAndSize` checks a script `stop()`, a bound `volume`, `createLayer` of a sound and of a particle system, `brightness` 0.5 and a bound `size`, all through the real loader and renderer.
- **S27 (clicks elsewhere).** `DesktopClickMonitor` counts only presses that land on the wallpaper, in any app. `DesktopClickMonitorTests` covers: presses elsewhere ignored, a release anywhere, a click shorter than a frame seen once, two readers, and a point with no window.
- **Latency.** `SceneScriptRenderTests.testADrawShowsItsOwnScriptFrame`: each draw shows the update it ran.
- **S24 (per-frame cost).** Three changes:
  - the JIT entitlement (`SceneScriptJITTests`);
  - the binding's cached access (no closures per call);
  - typed field accessors and the binding converter without intermediate arrays, and `init`/`update` called without an arguments array;
  - material writes that change nothing send no command, and declared constants are named by pool offset instead of a string (`SceneScriptObjectModelTests`, the S28 hardening test covers the new opcode).

  After a 10 s warm-up (JIT tiering puts compile spikes into the first seconds), every library scene is at p50 ≤ 0.21 ms and p99 ≤ 0.55 ms. The table is in the plan. 3453730450's p99 rises to 0.68–0.80 ms on a busy machine, with or without polling traps; that is open.

**Open.**
- A looping file's next pass is queued from the player's played-back callback, hopped to the main thread. While the main thread is blocked longer than one pass of a very short loop (under ~50 ms), the loop can gap once. Offline rendering never reports a pass as played, so the tests can't cover the third pass.
- `spatialization` (3D sound position, `attenuation`, `mindistance`) is read but not applied. No library sound sets it.
- Ogg Vorbis relies on Core Audio's decoder. Verified on macOS 27; the deployment target (13) is not verified, and no library sound is Ogg.
- The desktop hit test treats a window at or below the desktop-icon level as the wallpaper. Clicks on Finder's desktop icons count too; WE's own treatment of icons is not known.
- ~~WE applies `brightness` only when an unidentified flag (0x2000 at layer+0xc8+0x118) is set; ours always applies it.~~ Fixed: the flag is the `ultra`/`displayhdr` post-processing setting (`0x14010e6ba`), and `SceneRenderSettings.appliesBrightness` follows it (we-reference-report notes R4).
- Unsigned test hosts (CI) run JavaScriptCore without its JIT, so CI timings are the interpreter's; `SceneScriptJITTests` skips its JIT halves there.
- **S19 again, found by the full suite in a signed host.** With the JIT on, the watchdog could not stop a compiled `while (true) {}`. `SceneScriptRenderTests.testAHungScriptHaltsOnlyItsWallpaper` hung the suite: JavaScriptCore's VMTraps thread kept signalling while the loop never reached a trap. Polling traps (`JSC_usePollingTraps`, set in `main.swift` before the first VM) fix it: the loop stops at 0.31 s under a 0.3 s limit, and tight loops cost about 10 % more. It relies on JavaScriptCore reading that option from the environment, as it does on macOS 27; `SceneScriptJITTests.testTheWatchdogStopsAJITCompiledEmptyLoop` fails if that stops working.

---

# Timeline animations

Status: 2026-09-26, branch `deepratna/feature-work`, base `fee2a06`. Landed: T0 (oracle `Scripts/timeline-reference.py`, `Tests/Fixtures/Timeline/`, sweep tests), T1 (`SceneTimelineClock`/`Channel`/`Animation`), T2 (`SceneAnimationSet`, sites, holders), T5a (`SceneTextureAnimationClock`/`Control`/`Animations`), T4a (`objects-animations.js`). T3 (renderer) landed after this list was written; its status is in "T3 status" below, and T6, T7 and the fixes of the tester's findings in "T6, T7 and the findings". Adversarial list for [`timeline-plan.md`](timeline-plan.md); owners are its packages. Paths are relative to `OpenWallpaperEngine/`. Library cases are from `/Volumes/980Pro/dd-timeline/animations.json` and `anim_scripts.json`; "the oracle" is `Scripts/timeline-reference.py`.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| TL1 | Critical | T3 | An animated site silently falls back to its static value (context without the set, site identity mismatch) |
| TL2 | Critical | T3, T4a | Script writes and bound scripts fight the timeline (P2): owned fields freeze it, or writes stick |
| TL3 | High | T3, T2 | Script calls reach the set late, twice, or get undone by the next publish |
| TL4 | High | T3 | Static-chain caching and animated constants (stale output, or 22 paused fades that never cache) |
| TL5 | High | T3 | The app's own inspector edit replaces an animated constant, so the timeline stops |
| TL6 | High | T1, T4a, T3 | NaN/Infinity `rate`/`setFrame` poison a clock for good and reach the GPU |
| TL7 | High | T5a, T3 | A texture frame out of range (`setFrame(1000)`, `-5`, NaN) indexes the frame list |
| TL8 | High | T5a, T3 | A layer's texture override advances once per *call*, not per frame |
| TL9 | Medium | T3, T6 | Frame-rate dependence: textures step once per tick; WE's fps cap vs 120/144 Hz |
| TL10 | Medium | T3 | Sleep/wake, pause, speed 0, occlusion: the delta the clocks get |
| TL11 | Medium | T1 | float32 accumulation over hours; displays at different refresh rates drift apart |
| TL12 | High | T2, T3 | Linked children when the parent is removed, or the layer comes from `createLayer` |
| TL13 | Medium | T3 | `relative` with user-bound or user-changed values; rebuilds re-bake |
| TL14 | Medium | T5a, T3 | Texture clocks shared by layers with different visibility |
| TL15 | Medium | T5a, T3 | 0 s frames and all-zero textures (`Moic (1).tex`) |
| TL16 | Medium | T3 | Reload keeps or resets clocks (content rebuild, watchdog Retry, wallpaper switch) |
| TL17 | Medium | T2, T3 | Two displays: sets, restores and texture clocks must not cross |
| TL18 | Medium | T2, T4a | `animationEvent` storms, dropped events and O(layers) dispatch |
| TL19 | Medium | T3 | Property width vs channel count (1-channel `origin`, 3-channel `alpha`, vec4 uniforms) |
| TL20 | Medium | T6 | Cost with many animations; cold Bézier-cache spikes |
| TL21 | Low | T2 | Registration order (keys sorted, not JSON order): `getAnimation(name)` duplicates, event order |
| TL22 | Low | T1 | Hostile `length`/`fps`: the lazy cache grows to `length` floats |

---

## TL1. An animated site silently falls back to static (Critical, T3)
**Scenario.** The value path is now `SceneValueSource.animation(site:)` → `SceneValueContext.animationValue(site)` → the instance's `SceneAnimationSet`. Every miss is silent: it returns the fallback, the authored `value`.
- **A context built without the set.** `LiveSceneValueContext()` defaults `animations` to nil. In T3's working tree it is built that way in `SceneObjectMotion.base`, `ParticleFrameInputs` (`values ?? LiveSceneValueContext()`), `SceneContentLoader.userValueContext` and the renderer's `baseValues`. Any of those on a path that resolves an animated constant or a particle `instanceoverride` freezes it.
- **Site identity.** The set keys sites by `SceneScriptSceneDescriber.objectID` (scene.json `id`, else the index) and scene.json pass index. The effect plan keys them by `object.id ?? -1` and the *effect document's* pass index (`SceneEffectPlan.swift` `build`, `pass: index`). The two agree only while scene.json's `passes` runs parallel to the effect's passes, command passes included (3803044683 animates passes 0, 1, 2, 4, 5, 7, 8, 10, 11 and 15 of one effect, so a one-off shift shows up there first), and while every object has an `id`. Keys are also case-sensitive (`"Cutout Gradient Value 1 (Fade = 0.1)"`, 3074485715), and `ShaderConstantResolver` matches constants case-insensitively.
- **The fallback is plausible.** 3639372043 `alpha` falls back to 0.0035 and the multiply fades fall back to 0, so a frozen timeline looks like a dim layer, not a bug.
**Test.**
- A debug assertion or log-once when a `.animation(site: nil, …)` source is resolved at render time, and when `animationValue` returns nil for a bound site that the set doesn't contain.
- A headless render of 3803044683 at t = 0 and t = 2.5 s: every one of its 10 `opacity` passes reads the oracle's value (`lib-opacity-wraploop-short`), not 0.
- A synthetic effect with a `copy` command pass *before* the animated material pass: the animated uniform moves.
- For every library site, `set.contains(site)` holds for the site the renderer builds (an enumeration test over the 15 animated items).

## TL2. Script writes and bound scripts fight the timeline (Critical, T3, T4a)
**Scenario.** §2.6: the setter writes every frame, and a bound `update`'s return wins only for its frame.
- **3546971487** (a scene; 3187908708 is its source asset). The scripts are bound to `alpha` and `origin`, export only `mediaPropertiesChanged`/`mediaThumbnailChanged`, and do `thisLayer.alpha = 0; thisObject.getAnimation().play()`. WE: `alpha = 0` is overwritten on the next frame by the linked `alpha` child, sampled on the `origin` clock, which restarts at 0. Two failures are possible: the bound script (it has no `update`) makes `alpha` "script-owned", so `owned?.scalar(.alpha)` beats the timeline forever and the layer stays at 0; or the write sticks until the next `update`.
- **Accumulators.** `update(v) { return v + 0.01 }` on an animated `alpha` must stay at `timeline + 0.01`. It must not run away, which it would if the next frame's `value` were the last return rather than the timeline's value.
- **3453730450** has 71 scripts and 9 animated `alpha` fields (one, `objects/0/alpha`, is scripted): the heaviest mix in the library.
**Test.**
- Headless render through the real loader: an animated `alpha` with a bound script that has no `update` shows the oracle's values.
- `thisLayer.alpha = 0` from an event shows 0 for exactly one frame (or none, if the timeline writes first), then the timeline.
- The accumulator case after 600 frames is within 0.01 of the oracle.
- 3546971487 replayed with a synthetic `mediaPropertiesChanged`: `origin` and `alpha` follow `lib-title-origin-linked-alpha` from the frame after the event.

## TL3. Script calls reach the set late, twice, or get undone (High, T3, T2)
**Scenario.** JS applies `play`/`pause`/`stop`/`setFrame`/`rate` to the animation buffer. `readAnimations` turns a dirty slot into `.animation(site, time, flags, rate)`, a render event applied "before the next advance". Meanwhile `publishAnimations` rewrites every slot from the set each frame.
- If the event is applied *after* the next frame's advance and publish, `restore` sets `time` back to the value from before that advance. The clock loses a frame, and the play/`setFrame` shows a frame late.
- If the restore is dropped (the script frame was skipped because the watchdog is busy, or the frame was coalesced), `isPlaying()` goes back to false on the next publish: `play()` "didn't happen".
- `restore` copies `rate` too. A `setFrame` from one script and a `rate` write from another in the same frame are merged in the buffer, which is fine only because the whole slot is copied.
- **Material and effect sites.** The multiply fades (2134765860, 2370927443, 2978204069, 2978738836, 3000562427, 3109042108, 3352730400; 22 constants) call `thisObject.getAnimation().play()` from a constant's script. The slot must map to `.material(object, effect, pass)` with the describer's material index equal to the scene.json pass index.
**Test.**
- A frame-exact test: `play()` in frame N's `update` on a `startpaused` single. The set's clock time after frame N+1's advance is exactly one delta, and the drawn value at N+1 is `S` at that time.
- `setFrame(30)` then `getFrame()` in the same call returns 30, and the drawn frame at N+1 is 30 + delta × fps.
- The multiply fade on 3352730400: after `play()`, the constant follows `lib-multiply-fade`'s `controls` run, not 0.
- A skipped script frame (watchdog stub) never reverts a clock.

## TL4. Static-chain caching and animated constants (High, T3)
**Scenario.** `EffectGraphRenderer` reuses a chain's output while `UniformProgram.isStatic` holds (`dynamic.isEmpty && frameBuiltins.isEmpty`). The `StaticChainKey` has input, colour, alpha and script revision, but no animated values.
- **Stale output.** If an animated constant ends up in `staticValues` (for example because `isDynamic` or a pre-resolution treats a paused or unbound `.animation` as literal), a `play()` or a loop never reaches the pixels.
- **The reverse.** Every `.animation` source is dynamic, so the 22 `startpaused` multiply fades and the 10 finished cutouts of 3074485715 re-render their chains every frame forever, although their value is constant. That is a performance regression on 10 items: the old path was dynamic too, but the old fades were frozen at frame 0.
**Test.**
- Pixel test: a `startpaused` fade layer's output is reused (`layersReused` grows) while paused, and changes on the frame after `play()`.
- A loop constant changes pixels every frame.
- Optional: key the static output on the animated values (one float per dynamic constant), so a paused or finished timeline caches again.

## TL5. The app's inspector edit replaces an animated constant (High, T3)
**Scenario.** `SceneEffectPlanBuilder.applyingOverrides` replaces the source with `.literal(value)`, or with a music-synced `.user`, for any key the user edited in the app's inspector. The `.animation` wrapper is thrown away, so editing 3803044683's `opacity` stops its loop. WE's rule is the reverse: the timeline beats static and user values.
**Test.** Edit an animated constant through `SceneEffectOverride` and render two times: the value still follows the oracle. Alternatively, the inspector shows animated constants as read-only. That is a product decision, but it must not stop the timeline silently.

## TL6. NaN and Infinity poison a clock (High, T1, T4a, T3)
**Scenario.** WE-faithful maths keeps NaN: `setFrame(NaN)` or `rate = NaN` gives `time = NaN`, and no branch of `advance` ever leaves it (`0 > NaN` and `NaN >= duration` are both false). The same happens after `advance(by: .infinity)`. Verified with the landed `SceneTimelineClock`: after `setFrame(.nan)` and 600 frames, the value is `[nan]` and `isPlaying` is true. The JS guard `typeof frame !== 'number'` lets NaN through. Sources in the corpus: `audio.average[...]` past the end (S6), `1000/(now-last)`.
- NaN `alpha` poisons blending; NaN `origin` makes the layer vanish; NaN in a uniform can NaN a whole effect chain.
- The texture `rate = NaN` takes control (WE does too), and then `step` does nothing: harmless.
**Test.**
- For each of `rate`, `setFrame` ∈ {NaN, ±Infinity, 1e39, -0}: 10 rendered frames with no trap. The GPU uniform and the layer alpha are either what WE would compute or a clamped substitute, and the choice is documented.
- `stop()` or `setFrame(0)` recovers a NaN clock.

## TL7. Texture frame out of range (High, T5a, T3)
**Scenario.** `ITextureAnimation.setFrame(n)` is not range-checked (as in WE), and `readAnimations` converts a NaN frame to `Int32.min`. The landed `SceneTextureAnimations.drawnFrame` returns the raw value: verified `setFrame(1000)` → 1000 and `setFrame(-5)` → -5 with delta 0. The frame only wraps once the clock steps. Any renderer code doing `frames[Int(frame)]` traps. 2963872291 calls `setFrame(0)`/`setFrame(1)` and compares `getFrame() == 30`; a typo'd or computed frame is one script away.
**Test.** Render an animated image after `setFrame(1000)`, `setFrame(-5)`, `setFrame(NaN)` and `rate = -3`: no trap, and the drawn rect is frame 0 or a documented clamp. Then `join()` goes back to the shared frame.

## TL8. A layer's texture override advances once per call (High, T5a, T3)
**Scenario.** `SceneTextureAnimationClock.advance` has a tick guard. `SceneTextureAnimationControl.advance`, called from `drawnFrame`, has none. The renderer asks for a layer's texture frame at up to four sites per frame (`SceneMetalRenderer` `textureFrame(for:)`: the effect input, the scene-reading pass, the material uniform and the text fallback). If each routes to `SceneAnimationSet.drawnTextureFrame`, a script-controlled layer (2176097362's audio-driven `rate`, 2963872291's `rate` 9) plays 2–4× too fast. Verified with the landed types: with `rate` 1.5 and two calls per tick over 10 ticks, the override reaches frame 5; with one call per tick it reaches frame 2.
**Test.** Call `drawnFrame(object:tick:delta:)` twice per tick: the override's frame and time equal those from a single call. Better, advance once per frame in the set's frame (`advance(by:)`) and make `drawnFrame` a pure read.

## TL9. Frame-rate dependence (Medium, T3, T6)
**Scenario.**
- **Timelines** are functions of the clock's time: whole-frame samples blended linearly, so 144 Hz and 30 Hz agree to float32 accumulation error (the oracle's `play-144`, `play-30` and `play-jitter` runs).
- **Textures move at most one frame per engine frame** (§2.7). A texture with 1/60 s frames plays at the authored speed at 60 Hz and above, but at half speed under WE's common 30 fps cap. `syn-tex-shorter-than-tick` (0.004 s frames) plays at the display rate: about 144 frames/s on a ProMotion display and 60 on an external one.
- **WE's fps limit.** WE caps its engine rate (the user's FPS setting) and we draw at the display's rate, so a WE-faithful clock still looks different from WE at 120 Hz. That matters for short-frame sprite sheets and particle sheets.
**Test.** The texture oracle's `60` and `144` runs (already in `TextureClockOracleTests`); a render test at 30 Hz and 120 Hz delta sequences over `lib-tex-uniform`; and a decision, recorded in the plan, on whether the engine tick follows the app's frame limiter (if any) or the display.

## TL10. Sleep/wake, pause, speed 0, occlusion (Medium, T3)
**Scenario.**
- `SceneClock` clamps a frame's delta to 0.25 s and multiplies by speed. After wake, a single fade that WE would have finished moves only 0.25 s. WE's clamp, if any, is unknown (plan open question: the delta at `0x1401802e5`).
- Speed 0: `advance(by: 0)` still increments `frameCounter`, so the texture tick guard moves on while `step` does nothing. Correct, but an override with `rate` ≠ 0 also stands still: WE uses the engine frame time, which is 0 when paused.
- When the renderer stops drawing (occluded, screensaver, lock), every clock and texture freezes, and in WE a paused wallpaper freezes too. When a wallpaper shows on only one of two displays, only that set moves.
**Test.** A 10 s gap in wall time → one 0.25 s step: a loop moves 0.25 s, a single does not finish, and no events are skipped (an event inside the 0.25 s fires once). Speed 0 for 100 frames → identical values and texture frames, and scripts still see `isPlaying()` true.

## TL11. float32 accumulation over hours (Medium, T1)
**Scenario.** Clocks are float32 sums of deltas, reduced by `fmodf` at each wrap. Huge times can't build up (loop and mirror stay in [0, duration], and single stops), but each add rounds.
- **Measured with the landed clock:** a 1 s loop (30 fps × 30) after 24 h has phase 0.856 s at 144 Hz steps and 0.979 s at 60 Hz steps. The exact phase is 0.0.
- So two displays of the same wallpaper at different refresh rates drift apart by up to about a second a day. So do two loops of different lengths, and a timeline against `g_Time` or audio. WE has the same error at its own tick rate, so this is fidelity, not a bug, but it isn't reproducible across machines.
- **Exact comparisons.** Scripts compare exactly: 2963872291 does `getFrame() == frameCount - 1`. `IAnimation.getFrame()` is fractional and a single ends at `length`, so the comparison is almost never true, in WE too. Our float32 operation order must match WE's for such a comparison to behave the same.
**Test.** Keep the oracle's float32 equality at 1e-5 over 2 × duration (T0). Add a 24 h synthetic run at 1/60 that compares the Swift clock's `time` bit-for-bit with the oracle's (`we_anim_ref.py`), not with the exact phase.

## TL12. Linked children when the parent goes or arrives (High, T2, T3)
**Scenario.**
- **The parent is removed.** `removeObject` clears the link (`0x1401774b4`). The child then samples its **own** clock, which never advanced while linked: it sits at time 0, and a `single` that isn't `startpaused` (the `alpha` children of 3187908708 and 3546971487) starts playing from 0 on the next frame. That is a visible replay, WE-faithful only if WE's child clock also never moved.
- **`createLayer`.** `addObject(fields, id:)` must be called with the id the renderer and the script table use, *before* the first draw of the layer. Otherwise the layer draws a frame of static values. Ids reused after a destroy must not inherit old entries (`removeObject` must run first).
- **Cycles.** `options.parent` pointing at itself, or two animations naming each other: the one-level lookup can't loop, but a self-parent makes the animation its own clock owner, which is fine. Pin it with a test.
- **Wrong-owner links.** A child whose parent key names a property of another owner stays unlinked (logged at debug).
**Test.** 3546971487 shape: remove the `origin`'s layer (a script `destroyLayer`, if the object model allows it; otherwise a set-level test): the child's value is `S_child` at its own time. `createLayer` of an object with a linked pair: both animate from its first drawn frame. A self-parented animation advances once per frame.

## TL13. `relative` with user-bound or changed values (Medium, T3)
**Scenario.** The bake uses the holder's `value` string at load. The library has 8 relative animations (origin 4, scale 3, angles 1), all with a literal Vec3 string, and no `user` binding together with `animation`.
- A holder `{"value": "0 0 0", "user": "pos", "animation": {… "relative": true}}` bakes against the authored value, not the user's. Whether WE re-bakes on a user change is an open question.
- A content rebuild (the user changes another property) must not re-bake from a *changed* document, or the offsets double up. `SceneTimelineSource.signature` keeps the set only while the document is the same.
- A numeric scalar `value` is never offset (`syn-relative-scalar-is-absolute`). A two-token string is ignored (`syn-relative-two-tokens-ignored`).
**Test.** A user-bound relative origin: record what we do (bake the authored value) and flag it "needs WE ground truth". Rebuild content 3 times: the origin's offsets stay single.

## TL14. Texture clocks shared by layers with different visibility (Medium, T5a, T3)
**Scenario.** One clock per texture, advanced by whichever user draws first in a tick. The renderer skips hidden layers (`guard scripts.isVisible`), so:
- Two layers share a sprite sheet and one is hidden: the visible one moves the clock. That is right.
- Both are hidden, as 2963872291's player UI is while `shared.uiopacity == 0`: the clock freezes and resumes at the old frame when shown. In WE the texture advances "when a user binds the texture", and whether a hidden layer binds it is unknown.
- A hidden layer's *override* doesn't advance either. A script polling `getFrame()` on it (2963872291 waits for `getFrame() == 30`) waits forever while hidden.
- Keyed by `textureName`: two spellings of one texture (`materials/x` and `materials/x.tex`, or a different case) get two clocks.
**Test.** Two layers sharing a texture, then one hidden: the shared frame matches the one-layer oracle. Both hidden for 60 frames: record the behaviour and flag it for ground truth. A script-controlled hidden layer's `getFrame()` over time.

## TL15. 0 s frames (Medium, T5a, T3)
**Scenario.** `Moic (1).tex` (2176097362) has a 0 s frame. The new clock shows it for exactly one tick (`lib-tex-zero-frame`), and `syn-tex-zero-frames` covers runs of them.
- **Leftovers of the old path.** The renderer's old `textureFrame(for:time:)` took scene time modulo the total: a texture whose frames are all 0 s divides by zero (NaN index → trap), and the describer's fps is `count / duration` → ∞.
- `ITextureAnimation.duration` 0 must reach scripts as 0, not NaN.
**Test.** Render an image whose TEXS frames are all 0 s: it cycles one frame per tick with no trap; `duration == 0`, and `fps` is finite or absent. `grep` that no `truncatingRemainder(dividingBy: …duration)` on texture frames survives T3.

## TL16. Reload keeps or resets clocks (Medium, T3)
**Scenario.** The renderer keeps its set "across content rebuilt from the same document" (signature), like the scripts. Four ways this can go wrong:
- A user-property change rebuilds content while the clocks keep going: correct, and texture overrides survive (the new `register` keeps them).
- The watchdog's Retry, or a script-runtime restart, rebuilds the runtime but keeps the set: the scripts' state (`resetAnim`, `appearAnim` in 2963872291) restarts while the clocks don't. The scripts' `init` then calls `stop()`/`setFrame`, so it's mostly harmless. WE reloads everything.
- Switching wallpapers and back must start at time 0 with `startpaused` held (§2.4: every clock starts at 0 on load).
- Layers removed by a rebuild stay registered in `SceneTextureAnimations` (only `removeObject` unregisters), so their clocks leak and can keep a clock alive.
**Test.** Rebuild content 3 times at t = 1 s: timeline values are continuous. Retry: the clocks reset, and the plan decides this. Switch and back: values equal the `load-60` oracle run from 0. After a rebuild that drops a layer, `textures.objectIDs` doesn't contain it.

## TL17. Two displays (Medium, T2, T3)
**Scenario.** One set per renderer. The risks are in the plumbing:
- A script's `.animation` render event applied to the other display's set (a shared `SceneScriptWallpaper` or event queue).
- A static `SceneTextureAnimations` or clock cache.
- `LiveSceneValueContext` taking `WallpaperServices.shared` for values while the set comes from the wrong renderer.
- The same wallpaper on a 60 Hz and a 120 Hz display drifts (TL11). That's expected; a shared set would be wrong.
**Test.** The two-display harness (`testTwoDisplaysShareNothing` style): `play()` on display A's animation leaves display B's paused. Texture overrides are per display. Values match the oracle per display for their own delta sequences.

## TL18. `animationEvent` storms and drops (Medium, T2, T4a)
**Scenario.** There are no library users yet. Events fire per crossing, and a loop can cross [time, new) and then [0, wrapped) in one advance.
- A `length` 2 / `fps` 120 loop with 4 events at 144 Hz fires about 4 events per frame per animation. After a 0.25 s delta a short loop still fires each event at most twice (WE-faithful).
- `dispatchAnimationEvent` walks every layer, effect and material per event to find the owner (`animationOwner`), then every script record: O(events × objects). A scene with 100 layers and a few event-heavy loops costs about a millisecond.
- Events go through the inbox (S20); overflow drops them.
- Events of a site with no animation slot are dropped by `animationEvents(_:)`. The describer must place slots for every animated site, including materials, or the scripts of a material never hear.
- A linked child's events never fire (its clock doesn't move; documented). A script expecting them gets nothing, and so it would in WE.
**Test.** A synthetic loop with events at frames 0, 15, 29.5 and 30 (`syn-events-loop`), 600 frames at 144 Hz: exactly the oracle's event count reaches `animationEvent`, in order, and the first frame's event at 0 fires once. A material animation's event reaches that material's script. Measure dispatch cost with 200 layers.

## TL19. Property width vs channel count (Medium, T3)
**Scenario.** `SceneObjectAnimation` reads a missing channel as 0 (`read(…, width:)`), and the resolver's `ShaderValue(components:)` passes one component per channel for `ShaderConstantResolver.shape` to fit.
- **A 1-channel `origin`.** The docs' "one axis" timelines have `c0` only. y and z become 0, so the layer jumps to the scene's bottom edge. WE's `0x14017242d` switch reads `componentCount` channels, and what it reads past the vector's end is unknown.
- **Channel gaps.** `syn-channels-stop-at-gap` (`c1` not an array): the channels after the gap are dropped, so `c2` also reads 0.
- **More channels than the property has.** 2963872291's `scale` has 3 channels (z unused; fine). `alpha` with 3 channels takes `c0`. A `color` timeline on a vec4 uniform: is alpha 0, or 1?
- **Rotation.** Only `angles.z` is drawn (2134765860's `angles` loop animates `c2` to 2π in radians). x and y timelines are silently ignored.
**Test.**
- 1-channel `origin`: record the behaviour and flag it for ground truth. Until then prefer the authored component over 0, and write that choice down.
- A vec3 constant animated with 1 channel: y and z are what `shape` gives a 1-component value (broadcast, or 0), matching the existing static rule for a 1-number string.
- 2134765860's angle loop: 2π in 0.5 s, and the layer is back at 0 rad at every wrap.

## TL20. Cost with many animations (Medium, T6)
**Scenario.**
- **Measured with the landed `SceneAnimationSet` (`-O`, 2 timelines per layer: a 600-frame alpha loop and a 3-channel mirror origin), `advance` plus one `value(of:)` per layer:**
  - 20 timelines: 5 µs/frame.
  - 128 timelines: 24 µs/frame.
  - 1000 timelines: 225 µs/frame.

  That is about 0.2 µs per timeline, mostly the per-frame `[Site: [Float]]` dictionary and an array per value, keyed by a `String` hash.
- **The render side multiplies it.** `SceneObjectAnimation.init` builds 7 `SceneAnimationSite`s (String keys) per layer per frame, animated or not, and `input.animations` copies a `SceneAnimationState` (with its `name` String) per site per frame for the script mirror.
- **Cold spike, measured.** `setFrame(599)` on 128 timelines of 600 frames costs **12.8 ms** on the next frame: the lazy Bézier cache fills every frame from 0 to 599, one 1000-step bisection each. That is a dropped frame. A `rate = 50` or a mirror bounce does the same the first time round.
**Test.** A `SceneScriptLibraryCostTests`-style budget for 3453730450 (9 timelines, 71 scripts) and 3803044683 (10 constants): animation work stays under 0.05 ms p99 after warm-up. A cold-spike test: `setFrame(length − 1)` on the library's longest channel (600 frames, 3639372043) stays under 2 ms. Options: fill the cache at load (600 × channels solves ≈ 0.1 ms per timeline), or cache only the segment's samples.

## TL21. Registration order (Low, T2)
**Scenario.** `SceneAnimationHolders` sorts keys within a block because `SceneJSON` doesn't keep JSON order. WE registers in document order. So:
- `getAnimation(name)` with two animations of the same `options.name` on one owner returns the alphabetically first. WE returns the first in the file.
- Events of several animations crossing in one frame fire in key order, not file order.
No library item has duplicate names or events.
**Test.** A synthetic owner with `zeta` and `alpha`, both named "fade": pin the choice. Order-preserving JSON would fix it.

## TL22. Hostile `length`/`fps` (Low, T1)
**Scenario.** The cache grows up to `length` (`frame1 ≤ length`). A Workshop file with `length: 2000000000` and a `setFrame` near the end, or a mirror bounce, allocates 8 GB and runs 2·10⁹ Bézier solves on the render thread. `fps: 1e-38` with `length: 60` gives `duration = inf` (float32 overflow), which passes the `duration > 0` check. WE does the same, but it's a denial of service by a wallpaper file.
**Test.** Load `length` 2³¹−1: no hang over 10 frames. Cap the cache or evaluate uncached past a bound (for example 1 << 16 frames). `fps` 1e-38 and 1e30: finite values, no trap.

## T3 status (2026-09-26)
- **TL1.** Sites agree: `SceneEffectPlanBuilder` binds scene.json's `passes[i]` to the effect document's pass `i` (the same index `build` reads the instance pass by, command passes included), with the object's id after `assigningFallbackIDs` and the authored key before any case-insensitive match. Only a material file's own constants stay unbound (WE animates only the scene's). The per-item enumeration and 3803044683 render are T6's.
- **TL2.** Fixed: a field a timeline drives gets the animated value in the table every frame, and the mirror reads that object's row back even when no script wrote it, so a one-off `thisLayer.alpha = 0` shows for its frame only. `TimelineRenderTests` covers the identity and accumulator scripts.
- **TL3.** Calls come back as render events (not state, so none is lost to a later frame) and are restored before the next advance. Open: a script frame that overruns the draw's wait is restored after one more advance, so that clock loses a frame.
- **TL5.** Fixed: an inspector edit replaces only the value under the timeline (and under a script).
- **TL7, TL8.** Fixed in the renderer: one sprite frame per layer per frame, and a frame outside the sheet draws frame 0.
- **TL15.** The scene-time modulo path is deleted.
- **TL16.** A rebuild from the same document keeps the set; new scripts or a new document start a new one. Open: layers dropped by a rebuild stay registered with the texture clocks.
- **TL19.** A channel the timeline lacks reads 0 (ground truth below).
- **TL20.** Only the animated fields of animated objects are read each frame. `TimelineRenderTests.testThePerFrameCostIsSmall`, Debug build, 64 three-channel 600-frame timelines: about 117 µs to advance and 65 µs to read them per frame.
- Open, not T3's: TL4, TL6, TL9–TL14, TL17, TL18, TL21, TL22.

## T6, T7 and the findings (2026-09-26)
Commits `14cb40b`…`b68c641`. Every finding below is fixed or documented, each with a test; the numbers are in the plan's §4.
- **TF1 (fixed, `3c3a8fa`).** The mirror writes each animated constant's value into the scripts' pool before a script frame and takes back the last frame's writes of it, so a bound `update`/`init` or a `setMaterialProperty` wins for its frame only; an effect-wide write keeps reaching the other materials. `TimelineRenderTests.testScriptsOnAnimatedConstantsHoldForTheirFrameOnly` (identity `update`, `init`, a one-off write: all end on the timeline's blue; all three stayed green before).
- **TF2 (fixed).** Echo and Accumulate animate 0.2 → 0.6; the test compares with the model at three times.
- **TF3 (fixed, `ef222c1`).** `general.*` numbers, `instanceoverride` values, `parallaxDepth` and `volume` draw their timelines, and bound scene-setting scripts see the animated value. `visible` stays undrawn: WE's frame evaluation writes only float and vector types, and `visible` registers as type 6 (plan §1.1). No library scene animates an image layer's own material constants (every constant timeline is under `effects`), so those stay unbound.
- **TF4 (fixed, `dfe9ddc`).** A chain without time, audio or pointer built-ins is reused while its live-bound constants keep their values (`EffectGraphReuseTests.testAnAnimatedConstantsChainIsReusedWhileItsValueStays`).
- **TF5 / TL14 (fixed, `5bfeb76`).** A layer's override steps with the frame, drawn or hidden: WE steps it in the image layer's `update`, not its draw (plan §2.7). The shared clock still moves only when a layer or material draws the texture, so a texture only hidden layers use holds. Whether WE calls a hidden layer's `update` isn't traced.
- **TF6 / TL6 (fixed, `1ec1f87`).** A value that isn't finite draws the static value, logged once; scripts still see WE's NaN, and `stop()`/`setFrame(0)` recovers (`SceneRendererAnimationsTests.testANonFiniteClockNeverReachesTheDraw`).
- **TF7 / TL11 (documented).** WE-faithful float32 drift; plan §4.
- **TF8 / TL20 / TL22 (fixed, `28e9182`).** A channel solves only the frames asked for: the first frame after `setFrame(599)` on 128 cold timelines costs 65 µs (`-O`), was 3.0 ms. Past 64 k frames nothing is cached.
- **TL1 (verified).** The sweep asserts every site the renderer binds (and every reference-model member) is in the set, for every animated library scene.
- **TL3 (fixed, `5bfeb76`).** Script calls come back tagged with the set frame they saw; a late one replays the advances since, on the restored clock (`SceneRendererAnimationsTests.testAScriptFrameThatComesBackLateLosesNoAdvance`). Texture overrides replay the same way.
- **TL8 (fixed).** The override steps once per set frame, however often a layer is drawn or asked.
- **TL16 (fixed, `11dd345`).** A rebuild drops the texture animations of the layers it lost.
- **TL21.** `thisScene.getAnimation(name)` now searches every owner (`2a99fc6`): layers in scene order, their fields, effects and materials, then the scene. Within an owner the keys are still sorted, not in file order.
- **T6 (`b68c641`).** `TimelineLibraryRenderTests`: 21 animated library scenes, 180 frames each with a song starting at frame 90. 30 sites match the model in the draw, 15 are checked against the set after scripts played them (the thumbnail fades, 3546971487's titles; one of its alphas is script-owned), and 17 sprite layers follow their clocks. Not drawn (hidden layers or effects, which WE doesn't draw either): 13 sites, and 3000562427's object 205, which isn't built (its model's asset is missing, not a timeline issue). Four scenes only have particle sprite sheets.
- **T7 (`677ce72`).** An effect's or image material's animated texture takes its texture's shared clock and binds the frame's rect (`testAnEffectsSpriteSheetFollowsTheTexturesClock`, an effect sampling slot 1 through `g_Texture1Rotation/Translation`). No library effect or material binds an animated texture today.
- Open: TL9 (texture steps per display frame, not WE's fps cap), TL10, TL12, TL13, TL17, TL18, TL19 (ground truth below).

## Needs WE ground truth (timelines)
- Missing channels for the property's width (TL19): 0, garbage, or the static value?
- Does a hidden layer's `update` run, so its texture override steps (TL14, TF5)? We step it.
- The host's order for `thisScene.getAnimation(name)` (plan §3.1).
- Does `relative` re-bake on a user change (TL13)?
- Does the engine clamp the frame delta after sleep (TL10)?
- Does WE's engine tick follow its fps cap for textures (TL9)?
- After a parent is removed, does the child's own clock carry on from 0 (TL12)?

## Findings (timelines)

### T3: `b687f6a` (the renderer draws the instance's timelines), `cb9200e` (render tests), `f942898` (docs)

These were reviewed against TL1–TL22. The claims below were checked with a throwaway render test that is not committed. It was a copy of `TimelineRenderTests` over a modified copy of `Scenes/timeline`, run with `xcodebuild test -derivedDataPath /Volumes/980Pro/dd-agentTT`. Separate `swiftc -O` programs linked the landed `Scene/Values` timeline files.

**Confirmed.**
- **TF1 (TL2, Medium): a script's return on an animated *material constant* beats the timeline for good.** The fixture's layer 8 has a `color` constant animated red→blue:
  - Unchanged, it ends blue (`testAnEffectConstantAnimates`).
  - With `export function update(value) { return value; }` bound to that constant, it stays at the authored `"0 1 0"` (green) at frames 35 and 95.
  - With only `export function init(value) { return value; }` it is also green for good, although WE applies `init`'s return once and the setter overwrites it the next frame.
  - With a script that exports neither (`cursorClick` only, the library's multiply-fade shape) it animates, blue at frame 95.

  The cause: the script's constant writes (`SceneMetalRenderer.swift:1313`, `context.constantWrites = scripted.writes`) are replayed over the resolved uniforms every frame (`EffectGraphRenderer.swift:446-447`, `program.write(...)` after `program.update(...)`). The material's JS constant pool is never given the animated value, unlike object fields (`SceneScriptTableSync.write`, `animated`). Object fields are right: an identity `update` on an `alpha` moving 0→1 draws 0.498 / 0.749 / 1.0 at frames 30 / 45 / 75.

  No library item has `update`/`init` on an animated constant today (the 22 multiply fades export only `mediaThumbnailChanged`), so nothing in the library is visibly wrong.

  Fix direction: feed the timeline's value into the material pool before scripts run (the P2 order objects already get), or drop a constant write after its frame when the constant is animated.
- **TF2 (test gap, TL2).** `testScriptsOnAnimatedFieldsSeeAndBeatTheAnimation` uses Echo/Accumulate timelines with a single keyframe (constant 0.3). It passes even if `update` receives a stale or load-time value. The moving-alpha probe above shows the behaviour is right today. The fixture should animate, so the test can catch a regression.
- **TF3 (TL1, Low): only material constants are bound to their sites.** `bindingAnimation(to:)` is called only from `SceneEffectPlan.swift:256`. Timelines on an effect's `visible` (`.effect`), on particle `instanceoverride` values (`.particleInstance`), on `general.*` (`.scene`) and on an image layer's own material constants are advanced by the set (clock cost and events), but their `.animation(site: nil, …)` sources resolve to the static fallback. So is any object field outside `SceneObjectAnimation.keys`. There are 0 library users; it matters once T6's sweep or a new wallpaper has one.
- **TF4 (TL4, Medium, open as T3 says).** Every `.animation` source is dynamic (`SceneValueSource.isDynamic`, `SceneValueSource.swift:28`), so `UniformProgram.isStatic` is false (`EffectGraphRenderer.swift:655`). A `startpaused` or finished fade's chain is never reused, although its value is constant. That applies to the 22 multiply fades and 3074485715's finished cutouts, so it costs bandwidth, not correctness.
- **TF5 (TL14, open).** Texture clocks move only for drawn layers: `textureFrame(for:)` is reached only after `guard scripts.isVisible` (`SceneMetalRenderer.swift:692`). A hidden layer's shared clock, when nobody else draws it, and its override freeze. A script polling `getFrame()` on a hidden layer waits.
- **TF6 (TL6, open).** Checked with the landed clock: `setFrame(.nan)` or `advance(by: .infinity)` leave `time` NaN for good, so the value is `[nan]`, and `isPlaying` stays true. No renderer clamp exists on `objectAnimations[…].alpha`/`origin` or on the resolved uniform.
- **TF7 (TL11).** Measured drift of the float32 loop clock (1 s loop, 24 h): the phase is 0.856 s at 1/144 steps and 0.979 s at 1/60 steps, against an exact 0. This is WE-faithful arithmetic, but displays at different refresh rates drift apart by up to about a second a day.
- **TF8 (TL20).** Cold cache spike: `setFrame(599)` on 128 timelines of 600 frames costs 12.8 ms on the next frame (`-O`), one Bézier solve per frame from 0. Steady state is about 0.2 µs per timeline (5 / 24 / 225 µs per frame for 20 / 128 / 1000 timelines). `testThePerFrameCostIsSmall` measures only the warm state.

**Verified fixed by T3.**
- **TL7.** A frame outside the sheet draws frame 0 (`SceneMetalRenderer.swift:1607`). The model alone returns 1000 or −5 after `setFrame(1000)`/`setFrame(-5)`, so the guard is load-bearing.
- **TL8.** One sprite frame per layer per frame: `spriteFrames` is cleared in `advanceAnimations` (`:492`) and filled once per layer (`:1604`). Without it, the model's override advances once per call (with two calls per tick, frame 5 instead of 2 after 10 ticks), so the cache is load-bearing too. `SceneTextureAnimationControl.advance` still has no tick guard of its own.
- **TL3.** The order is `beginFrame` events → advance → script frame → `finishFrame` events → draw (`SceneMetalRenderer.draw`). A call made in frame N is restored after N's advance and acts from N+1's advance, as in WE. An overrun script frame costs that clock one frame; T3 notes it as open.
- **TL5.** An inspector edit replaces only the base under the timeline (`replacingBase`).

---

# Lighting and reflections (roadmap notes area 5)

Status: 2026-09-26, branch `deepratna/feature-work`, HEAD `e4f7a83` (code as of `36a5796`). Adversarial list for the landed packages of docs/lighting-plan.md: L0, A1, A2, A3/A4, B1, B2, C1 and D1. **Owner** is the plan's package (§4.3). **EP** = the effects-perf agent (Match display, Texture Resolution, `SceneEffectDetail`); **ST** = settings UI.

The scenes used below:
- One piece girls 3270035750: 4 tubes lighting `f1`; `bloom` is bound to the user property `resplandorradiance`.
- witcher 3803167460: `меч`, `ведьмак розбивpng`; parallax and shake on.
- Knight 2515150033: the genericimage2 `LIGHTING`/`REFLECTION` puppet `centurion 1080p_sheet`, lit by 2 **legacy** points. Light 29 has scripts on `intensity` and `origin`.
- Hinata 3352730400: a cookie spot, turned on all three axes, with volumetrics and HDR.
- Lofi Cafe 2370927443: `REFLECTION` with 11 effects.
- The bloom scenes (24 in §1.5, plus 2868563343).
- The 3D/HDR test set: 3455121165, 3657770939, 3734636606, 3233200129, 3159348391, 3378346807, 2350874185, 2321732083.

| # | Sev | Owner | Risk |
|---|-----|-------|------|
| LR1 | Critical | A4 | A prelit layer behind a static effect chain keeps its first frame's lighting and reflection (**confirmed**, LF1) |
| LR2 | High | A2 | Light fields and the out-of-plane transform are frozen at load: scripted `intensity`, `color`, `radius`, `origin.z` (**fixed**, LF2) |
| LR3 | High | A3 | The `angles.z` sign flip: every consumer that doesn't go through `SceneAffineTransform` |
| LR4 | High | A2, D1 | A light's tilt order (`Rz·Ry·Rx` vs `Rx·Ry·Rz`) for lights turned on x/y and z (**settled** against WE's frames: ours, `Rz·Ry·Rx`) |
| LR5 | High | A4, B2 | Prelit image is RGBA8 in HDR: overbright is clipped before effects and bloom (**fixed**, LF3) |
| LR6 | High | B1, EP | Bloom radius and HDR level count follow the scene target's size (Match display, Texture Resolution, desktop resolution, two displays) |
| LR7 | High | B1, B2 | Bloom gates and live values: user-bound and scripted `bloom`, timelines on strength, `bloomhdr*` not live (**fixed**), `_owe_bloom` |
| LR8 | High | B2 | HDR float targets through every stage |
| LR9 | High | all | Cost at 5K (5120×2880), HDR and reflection on (measured: "Optimisation pass") |
| LR10 | High | all | Memory: full-size float targets, unused ping targets, targets kept after leaving HDR (copies cut, round trips guarded: "Optimisation pass") |
| LR11 | Medium | A4 | A prelit layer whose chain renders nothing draws **unlit** (**fixed**, LF5) |
| LR12 | Medium | A2, D1 | Lights (and volumetrics) don't move with camera parallax or shake; the layers they light do (**fixed** for shake; parallax doesn't move lights in WE either) |
| LR13 | Medium | A2 | Light packing: overflowing groups, budgets, legacy slot collisions, sort ties |
| LR14 | Medium | A2, A3 | Lights under animated or scripted parents, hidden ancestors, lights created or re-parented by scripts |
| LR15 | Medium | A3, A4 | Lit layers and colour, alpha, brightness, blend modes, puppets and sprite sheets |
| LR16 | Medium | A3 | PBR mask flag bits: component combos taken from `.tex` flags |
| LR17 | Medium | A1 | `SCENE_ORTHO`/`HDR`/`LIGHTS_*` in every cache key: key churn and recompiles (**fixed**, LF8) |
| LR18 | Medium | C1 | `_rt_MipMappedFrameBuffer` is a frame late: new targets, resizes and content swaps (content swaps **fixed**, LF9) |
| LR19 | Medium | C1, ST | Reflections off, on again, and the rebuild every settings change causes (**fixed**: no rebuild) |
| LR20 | Medium | D1 | Volumetric draw order: the stage runs after every object |
| LR21 | Medium | D1 | Volumetrics under camera shake, parallax and script cameras (shake **fixed**, LF6; script cameras open) |
| LR22 | Medium | D1 | One missing cookie drops every volumetric light (**fixed**, LF4); shadow casters show only with shadows off |
| LR23 | Medium | all | Two displays sharing one instance |
| LR24 | Medium | ST, all | Settings changed live: every change rebuilds the content (**fixed** for the per-frame settings) |
| LR25 | Medium | A1, A3 | Cookie spots under `LightingV1`: `_alias_lightCookie` and the zero `g_LFeature_*` projections |
| LR26 | Low | A2 | Per-frame lighting cost when a scene has no lights |

## LR1. A prelit layer behind a static effect chain keeps its first frame's lighting (Critical, A4)
**Scenario.** `SceneMetalRenderer.runEffects` (`:1406`) hands `effectGraph.apply` the prelit texture. `ImageMaterialRenderer.prelight` draws into the same `program.prelit` texture every frame (`:223-230`), and `inputVersion` stays 0. `EffectGraphRenderer.apply` keys its static-output cache on the input's identity and version (`:277`). Its `readsScene` check (`:284`) looks only at the effect passes, not at the prepass, which reads the lights and `_rt_MipMappedFrameBuffer`. So once every effect on a lit or reflective layer is static, the first frame's output is served for good.
- Moving lights, a scripted ambient, parallax and parent motion (through the `g_Alt*` matrices) and the reflection all freeze. The prepass is still encoded every frame, and its result is thrown away.
- A reflective layer can freeze on the frame where `_rt_MipMappedFrameBuffer` was just made, which is transparent black (LR18).
- At HEAD it takes a wholly static chain. EP's uncommitted `staticPrefix` cache and `SceneEffectDetail.input` use the same key, so a static *prefix* is enough there. witcher's `меч` (opacity, then foliagesway) would then keep its first reflection.

**Test.** Confirmed by LF1's probe. Add it as a renderer test: a lit layer behind the `tint` identity effect, then change the frame's lighting; the drawable must change. The existing `LitLayerLibraryTests` count `imageMaterialPrelitDraws`, which go up even when the output is discarded, so they can't catch this. The fix is to bump `inputVersion` per prepass, or to count `plan.prelighting != nil` as `readsScene`.

## LR2. Light fields and the out-of-plane transform are frozen at load (High, A2)
**Scenario.** `SceneFrameLighting.frame` packs `object.light` (`SceneFrameLighting.swift:92`), which the view model resolved once against the user properties. It also packs `object.depth` (`SceneLightDepth(object:)`, `:36`: `origin.z`, `angles.x/y`, `scale.z` as authored). Only the 2D transform is live.
- Knight 2515150033: light 29's `intensity` script flickers `1 + 0.3 sin(7.3t) + 0.2 sin(9.8t)`, and its `origin` script moves y and z (`500 + 200 sin t`). WE's `g_LightsColorRadius[0]` and `g_LightsPosition[0].z` change every frame; ours never do (LF2).
- The survey in lighting-plan §1.5 missed this scene. It says the library has 3 legacy points and that "none of the library's light fields is bound to a user property, script or animation". The Knight adds 2 legacy points, with a script on each of those two fields, and it is the **only** library layer lit by legacy lights (genericimage2 reads `g_LightsPosition`/`g_LightsColorPremultiplied`).
- The same applies to a timeline on a light's `color` or `intensity`, and to a tube's `controlpoint` (the plan's adversarial fixture). A user property change works, because it rebuilds the content.

**Test.** LF2's probe as a library test: render the Knight for 4 s at 10 fps. `g_LightsColorRadius[0].rgb` must take more than one value, and `g_LightsPosition[0].z` must follow `500 + 200 sin t`. Add a fixture with a timeline on `intensity` and a script on a tube's `controlpoint`.

## LR3. The `angles.z` sign flip (High, A3)
**Scenario.** `dc179e3` flipped `SceneAffineTransform` alone. The reviewer traced every consumer: layer quads, `g_ModelMatrix`/`g_AltModelMatrix`, text, the scripts' `worldMatrix` and `getTransformMatrix`, cursor hit testing (`SceneScriptCursorHitTest` uses the matrix axes), emitter offsets and rotation (velocity, gravity, control points, collision planes), light matrices, the volumetric projection and the packer's directions. All of them take it from there. What remains:
- **Worldspace particles.** `ParticleFrameInputs.swift:203` sets `spawnTurn = atan2(col0.y, col0.x)`, which is +θ after the flip. It is added to the particle's `rotation`. The sprite axes (`ParticleShared.h:281`, `ParticleCPUSimulation.swift:431`) turn a positive rotation clockwise, as WE's `ComputeParticleTangents` does (with `mul(x, y) = y * x`: right = (cos, −sin)). So an emitter turned θ counter-clockwise gives worldspace sprites turned θ clockwise, while its non-worldspace sprites turn with the emitter. Whether WE adds the emitter's angle to a worldspace particle's rotation is unverified.
- **Clock wallpapers and scripts that set `angles`.** They write radians into the same field, so hands now turn as WE's do (negative = clockwise). A script that computed an angle *from* a drawn position (`atan2` of a cursor delta, for example) gets the new sign as well.
- **Anything cached in the old convention:** saved property stores, the snapshots in `docs/`, and the tests' expected images.

**Test.**
- A fixture: an emitter under a parent turned +45°, drawn once with `worldspace` and once without, comparing the sprites' axes.
- A cursor-click hit test on a layer turned +30° whose quad is asymmetric (a 400×40 bar): click the tip that lies above its centre after a counter-clockwise turn.
- 2764281221 against WE's preview (the flare falls down to the right).
- One clock wallpaper at a known time.

## LR4. A light's tilt order (High, A2, D1)
**Scenario.** `SceneFrameLighting.world` computes `Rz·Ry·Rx` on column vectors (`:119`). WE's `Rz(z)·Ry(y)·Rx(x)` at 0x1401dd630 is a row-major, row-vector product. If each factor there is in row-vector form, the column-vector equivalent is `Rx·Ry·Rz`. The two agree unless z and x or y are both non-zero.

Hinata's cookie spot is (−0.141, 0.582, −0.780). Its +X direction is (0.594, −0.588, −0.550) one way and (0.594, −0.752, −0.288) the other: **17.8° apart**. `g_LSpot_Direction`, the cookie projection and the volumetric cone all follow it. `VolumetricsLibraryTests` checks that the lit texels lie in *our* frustum, so it is self-consistent and can't tell the two apart.

**Test.** Needs WE ground truth. Compare Hinata's `preview.gif` shafts with a headless frame under both orders, or check the multiply order at 0x1401dd630.

## LR5. The prelit image is RGBA8 in HDR (High, A4, B2)
**Scenario.** `ImageMaterialRenderer.prelitFormat` is `.rgba8Unorm` (`:204`), and the pipeline and texture use it (`:218`, `:225`). B2 made every other layer buffer RGBA16F in HDR, as WE's frame-buffer class is. The prepass is compiled with `HDR=1`, so `CombineLighting`'s overbright and `HDR && EMISSIVE_MAP` emissive are clipped to 1 before the layer's effects and the HDR bloom see them. No library scene combines HDR with a prelit layer today. A witcher-like layer in an HDR scene would stop blooming.

**Test.** An HDR fixture: a lit layer with an identity effect and a light bright enough that `CombineLighting` > 1. The float scene target must hold > 1 there, as the same layer drawn directly does.

## LR6. Bloom against the target size (High, B1, EP)
**Scenario.**
- **The LDR blur is fixed in target pixels.** It is 13 taps at 8× the 1/8 target, about 104 full-size pixels, so its on-screen width is a fraction of the *target*. EP's Match display draws a 3840×2160 scene (3639372043, bloom 1.92, "4K") at 1920×1080 on a 1080p display, where full detail draws it at 3840. The bloom is then twice as wide relative to the frame. The same happens with Texture Resolution and "desktop" resolution.
- **HDR levels come from `min(w, h)`** (`SceneHDRChain.levels`). A smaller target can drop a level, which changes `bloomhdrstrength / (1 + scatter^(n−2))`.
- **`fboSize` rounds** (1366 / 4 → 342), so pass 1 is no longer an exact 4×4 box at such widths [?: WE may truncate].
- **Live resizes.** EP quantises to 64ths below 1 pixel per unit, so a live resize reallocates the five LDR and ten HDR targets at each step. The 32-spare cap bounds the churn.

Which size WE blooms at for each of its scene-detail settings is the open question.

**Test.**
- Render 3639372043 and 3606529469 (HDR) at full detail and at Match display on a 1920×1080 drawable. Measure the bloom's half-width around a bright edge as a fraction of the frame, and check it against WE at the same setting.
- A unit test that `g_TexelSize` stays 1 / the actual target under every `SceneRenderSettings` size option. The reviewer found it does at HEAD plus EP's diff (`texelSizeReference` wins over `standIn`).

## LR7. Bloom gates and live values (High, B1, B2)
**Scenario.**
- `ScenePostProcess.runsBloom` = `allowsBloom && bloom.enabled`, and the live `bloom` includes scripts and user properties. One piece girls binds `bloom` to `resplandorradiance`, and 3 other scenes are user-bound. Toggling that property rebuilds the content; a script toggle doesn't.
- Strength, threshold and tint are rewritten per frame (scripts, then timelines, then the content).
- `bloomhdr*` are taken from the load: `liveBloom` passes `hdr: bloom.hdr` as built, and `SceneScriptSceneField` has no `bloomhdr*`. 2350874185's property script on `bloomhdrstrength` is ignored (B2 notes it). A timeline on `bloomhdrstrength` wouldn't animate [?: whether WE exposes them].
- `_owe_bloom` now only scales scenes that have bloom. The old app slider added bloom to any scene, so users who relied on it lose it silently.
- `SceneMetalRenderer.swift:990` still writes `bloom * _owe_bloom` into the native uniform's `effects.w`, which no shader reads. When it is non-zero, `nativeAdjustmentsAreIdentity` is false, which may log a false "ignored adjustments" [likely].

**Test.**
- One piece girls: flip `resplandorradiance` mid-run, and bloom must stop within one rebuild.
- A fixture script that sets `thisScene.bloom = false` at frame 30: no bloom from frame 31, and in HDR, `combine_srgb`.
- A timeline on `bloomstrength`: pass 1's constant follows it.
- `_owe_bloom` = 0 and 3 on a non-bloom scene: the frame is unchanged.

## LR8. HDR float targets through every stage (High, B2)
**Scenario.** In HDR the reviewer found RGBA16F in the scene target, snapshots and region copies, `rgba_backbuffer` FBOs, the effect ping-pong targets, the image and particle pipelines, the mip copy and the volumetrics light buffers. The stages that stay 8-bit:
- the prepass (LR5);
- an effect's explicit `rgba8888` FBO (WE's too, by the format name);
- the combine's sRGB output and the shared multi-display frame, which are after the combine by design.

Risks:
- **Text is rasterised in 8-bit** and then drawn into a float target. Overbright text is impossible, as in WE.
- **A new stage that allocates `.rgba8Unorm` by default** silently clips. D2's shadow atlas and area 6's depth are the next ones.
- **The composite reads the sRGB-encoded bytes through an `rgba8Unorm` view.** A future EDR output (`rgba16Float` `CAMetalLayer`) needs a different path.

**Test.** Extend `HDRLibrarySweepTests`: walk every texture the frame touches (the renderer's pools and the effect graph's states) and assert RGBA16F for every frame-buffer-class target in HDR. Run the 5 HDR scenes and the test set with `MTL_DEBUG_LAYER=1`.

## LR9. Cost at 5K (High, all)
**Scenario.** Measured by the packages, in GPU time for their stage alone on M-series with other work on the GPU:

| Stage | 1920×1080 | 5120×2880 |
|---|---|---|
| LDR bloom | 0.5–0.9 ms median | 4–7 ms median |
| HDR chain, 8 levels | 2.8–4.5 ms median | 8–21 ms median |
| Volumetrics | 4–10 ms median | (not measured) |
| Lit layer, 4 tubes | 0.6 ms vs 0.05 unlit | (not measured) |

Per frame, HDR at 5K reads the full float frame at least twice: D0 and the combine, about 300 MB. The reflection copy plus `generateMipmaps` of a 118 MB RGBA16F target adds more. Hinata at 5K with ultra runs HDR, bloom and volumetrics at once, which can exceed a 16.7 ms frame on its own.

**Test.** `SceneFrameBenchmarkTests` at 5120×2880 for Hinata (HDR, volumetrics), witcher (prelit, reflection, 3840×2160), One piece girls (tubes, bloom) and 3606529469 (HDR), in enabled and ultra. Record the median GPU ms per stage with signposts, and set a budget: for example, ultra at 5K ≤ 12 ms on the reference Mac. Then re-run under EP's Match display.

## LR10. Memory (High, all)
**Scenario.** At 5K in HDR:

| Target | Size |
|---|---|
| Scene target (RGBA16F) | 118 MB |
| Snapshot (when a layer reads the scene) | 118 MB |
| Mip-mapped copy (with its mips) | ~157 MB |
| HDR levels | ~39 MB |
| Each chain's `pingA` + `pingB`, full size | 2 × 59 MB |

Waste found:
- Only one ping target per chain is written (`EffectGraphRenderer.swift:571-572`).
- `ScenePostProcess.encodedView` (`:87`, `:185`) keeps the last HDR combine's texture alive after switching to an LDR scene or from ultra to enabled.
- HDR scenes also plan the unused LDR chain (`SceneContentLoader.swift:554`; load time only).
- Each prelit layer holds its own image-sized RGBA8 texture.

With two HDR wallpapers on two displays, each instance holds its own set.

**Test.**
- Switch Hinata → a non-HDR scene → Hinata ten times, and check that `MTLDevice.currentAllocatedSize` returns to within 5% of the first visit.
- Assert that no `engine:bloom*` state and no `encodedView` survive `setContent` of a content without that chain.
- Record the peak for 3606529469 at 5K ultra.

## LR11. A prelit layer whose chain renders nothing draws unlit (Medium, A4)
**Scenario.** The layer's own draw is planned with `LIGHTING 0, REFLECTION 0` (`ImageMaterialPlan.swift`, the `pass` variant). It relies on `dynamicTextures` holding the prelit result. `EffectGraphRenderer.apply` returns nil when every effect is hidden (`guard didRender`, `:329`) or while the chain compiles. The renderer then draws the raw texture (`SceneMetalRenderer.swift:1006`) with lighting off, and the prelit image is dropped.

Example: a user property or script hides all 9 of `ведьмак розбивpng`'s effects. That layer is ambient-only (1 1 1), so the result looks the same. The same thing on a lit layer in a scene with lights (a witcher variant with a `lightconfig`) loses its lighting for as long as the effects are hidden.

**Test.** A fixture lit layer with one effect bound to a `visible` user property. Hiding the effect must still show the layer lit, as it is on the direct path.

## LR12. Lights don't follow camera parallax or shake (Medium, A2, D1)
**Scenario.**
- `layerDraw` moves each quad by `parallaxOffset − shake` (`SceneMetalRenderer.swift:1241`), which reaches `g_ModelMatrix` and `g_AltModelMatrix`.
- `emitterWorld` does the same for emitters (`:1324`, citing 0x14018a0b3: "every object's model matrix").
- `frameLighting` (`:1073`) uses the bare hierarchy.

So with parallax on, a lit layer slides under its lights by `parallaxDepth × amount`. No library scene combines lights with parallax on today: the Knight's lights have `parallaxDepth` 1 but parallax is off, and witcher has parallax but no lights.

**Test.** One piece girls with `cameraparallax` forced on. With the cursor at the left edge, the bright bands must stay on the same image columns (WE moves the lights with their objects' matrices [?]).

## LR13. Light packing: overflow and budgets (Medium, A2)
**Scenario.** The reviewer confirmed that every write is bounds-checked (`SceneLightPacker.swift:262`) and that an overfull group spills into the next group, as in WE. What remains:
- **Budgets below the light count drop lights silently**, in sort order. One piece girls with `{"tube":3}` loses the tube whose `origin` is deepest along the view: which one depends on `dot(origin, forward)` ties, which WE's `std::sort` leaves unordered.
- **A subset above its base** (`{"spot":1,"spotcookie":3}`) moves the plain spots' cursor past the array, so they write into `g_LSpot_Origin`. That is WE-faithful garbage, and a shader must never read NaN from it.
- **Five or more legacy lights** collide on slot 0, where the later light wins. Every light type counts towards the legacy slots, so a tube before a legacy point pushes it to slot 1.
- A `lightconfig` with more lights than the scene has leaves zeroed slots: colour 0, and a radius of 0 in `saturate(1 − d/radius)` divides by zero.

**Test.**
- Packer unit tests for each case, plus a render with the zero-radius slot: every pixel finite.
- One piece girls with `{"tube":3}`: 3 bands, with the dropped one logged once.
- A fixture of 5 legacy points in scene order, checking slot 0.

## LR14. Lights under animated or scripted parents (Medium, A2, A3)
**Scenario.** The frame lighting runs after scripts and timelines, and `liveLocal` covers light objects through `objectMotions`. The reviewer confirmed that the 2D transform is this frame's. Gaps:
- **A parent's `origin.z`, tilt and non-uniform `scale.z` don't reach the light:** "the parents are the 2D hierarchy's".
- **Scripts can re-parent or create layers** (`createLayer`, `sortLayer`). Nobody has checked that a light parented to a created layer resolves, or that a light keeps its legacy slot when a layer before it is removed.
- **Hidden ancestors** drop the light from the budget *before* it is counted (WE's order). A script toggling a parent's `visible` every frame makes the lit layer strobe, as it would in WE.
- **A light's `angles.z` from a timeline** turns a spot's cone under the new CCW convention (LR3).

**Test.**
- A fixture tube parented to a layer with a `origin` timeline. `g_LTube_OriginA` and `OriginB` must follow the parent at frames 0, 30 and 60, within 1e−3.
- A script that hides the parent at frame 10: the arrays are zero from frame 11.
- A legacy point after a layer that a script removes: its slot is unchanged.

## LR15. Lit layers and colour, alpha and blend modes (Medium, A3, A4)
**Scenario.**
- **Prelit layers.** The prepass draws with `g_Color4` white and unblended, and the layer's colour, alpha and brightness are applied once by its own draw after the effects. A layer whose `alpha` is animated to 0 still pays for the prepass. A `colorBlendMode` layer (`BLENDMODE` reads `_rt_FullFrameBuffer` as `g_Texture4`) takes the blend in its final draw only. Nobody has tested that a prelit layer with a blend mode matches WE.
- **Direct lit layers.** `brightness` is multiplied into the albedo under `HDR` only. `CombineLighting` doesn't clamp in LDR, so `ambient + light` > 1 is clipped by the RGBA8 target.
- **The Knight is a puppet.** Its atlas is lit as one still image (its mesh isn't drawn), with the 2 legacy lights moving across it (LR2). WE prelights the mesh.
- **Sprite-sheet albedos keep the direct path**, and the prepass maps the whole input onto the quad (uv axes identity), so a lit sprite sheet with effects would be lit at the wrong texel positions. There is no library user.

**Test.**
- A lit fixture layer with `alpha` 0.5, `color` (1, 0.5, 0.5) and `brightness` 2, drawn prelit behind the identity effect and drawn directly. The two must agree within 3/255, as `testALayerWithAnIdentityEffectMatchesTheDirectPath` does at white.
- The same with `colorBlendMode` 2 (multiply).

## LR16. PBR mask flag bits (Medium, A3)
**Scenario.** WE defines `METALLIC_MAP`…`EMISSIVE_MAP` when the bound mask's `.tex` flags have bit 20 + k. The reviewer checked `texiWord(1)` little-endian, `0x100000 << k`, and the r, g, b, a order: `меч`'s 0x400002 gives `REFLECTION_MAP` only, and the Knight's 0x300002 gives metallic and roughness. Risks:
- **A mask re-exported without the bits** (an older editor, or a `.tex` converted by a tool) defines no component. It then reads the constants, so a painted metallic map is ignored silently.
- **A texture override by script** (`setTexture`, TL8) swaps the mask at runtime, but the combos were fixed at build.
- **A texture that isn't a mask** in slot 2 with high flag bits set (video `.tex` or GIF flags) turns components on. Only samplers with a `components` annotation are considered, which limits this to real mask slots.
- **`TEXV0001`–`TEXV0004` header variants**: the flags word is at the same offset only if `TEXI` is found within the first 64 bytes (`ImageMaterialPlan.texFlags`).

**Test.** `texFlags` over every `.tex` in the library, tallied by version, with every mask slot's flags logged. A fixture mask with flags 0 must draw the constants' metallic and roughness.

## LR17. Engine combos in every cache key (Medium, A1)
**Scenario.** `ShaderVariant.cacheKey` (`:190`) hashes every combo whether or not the shader mentions it, and `ShaderPrelude` emits `#define SCENE_ORTHO 1`. After `28da824`:
- Every effect, particle and image variant of an orthographic scene got new translation and pipeline keys: one full re-translation on upgrade.
- The same effect used in a perspective scene keeps a second key for identical MSL.
- `HDR=1` (B2) forks every variant of the 5 HDR scenes and the test set again.
- `LIGHTS_SHADOW_MAPPING_QUALITY` follows the shadows setting, so changing shadows recompiles every lit material in a scene with a shadow budget.
- Old pipeline-archive entries stay until the build number changes.

The test runs log `mdb_txn_commit error: MDB_MAP_FULL` from the process many times, a store that is already full [?: whose].

**Test.**
- Count the distinct translation keys over the library before and after dropping combos the source never names. They should differ only where a shader reads `SCENE_ORTHO` or `HDR`.
- Time a cold start of One piece girls: first frame through the material.
- Flip shadows from medium to high while Hinata runs: count recompiles.

## LR18. `_rt_MipMappedFrameBuffer` is a frame late (Medium, C1)
**Scenario.** Draws read the previous frame, as in WE. Edge cases:
- **A new target** (first frame, a resize, a Texture Resolution change, an HDR format flip) reads transparent black for one frame, so a reflective layer blinks dark on every live window resize. With LR1 it can stay dark.
- **A content swap** that also samples the target at the same size keeps `texture` and `contents = .frame` (`SceneMipMappedFrameBuffer.setContent`, `:81`). The new wallpaper's first frame reflects the previous wallpaper's last frame (reloading the Knight after a property change, or switching between two reflective scenes).
- **The volumetrics stage runs first**, so reflections include the shafts, as in WE.

**Test.**
- Render the Knight 3 frames, `setContent` witcher: `меч`'s first-frame reflection must not contain Knight pixels (expect black).
- Resize the drawable from 1920 to 1600 mid-run: at most one frame of black reflection.

## LR19. Reflections off and on again (Medium, C1, ST)
**Scenario.** Off clears the target once to (0,0,0,1). Back on, it reads black for one frame, then copies.

The setting is read per frame by the stage, but `SceneContentLoader.setRenderSettings` bumps the revision for *any* settings change, so toggling Reflections rebuilds the whole content. Per TL16 a rebuild may restart timelines, scripts and particle systems, and every lit material is re-planned. Because WE's reflections are copied or not per frame (flag 0x80), this toggle needs no rebuild.

Prelit reflective layers (`меч`, Lofi Cafe) read the black target through their prepass while it is off. Lofi Cafe has no normal map, so it is unaffected.

**Test.**
- Toggle Reflections on witcher while a timeline runs: the timeline's clock must not reset, and the `меч` reflection is its albedo within 1/255 while off.
- Count `loadScene` or `metalContent` calls per toggle: expect 0.

## LR20. Volumetric draw order (Medium, D1)
**Scenario.** WE finishes each run of lights before the next object that isn't a light (§2.8). Here the stage runs after the whole scene pass, so every object after a volumetric light in scene order is drawn *under* its shafts. Hinata's light comes after every drawn object, so it is unaffected. A scene with a foreground layer after the light (a character in front of a lamp's beam, a common layout) gets the beam over the character.

**Test.** A fixture: a volumetric spot, then an opaque layer across its beam. The beam must not show over the layer. Also run the test set's 2D-orthographic members, if any, in WE's order.

## LR21. Volumetrics under camera shake, parallax and script cameras (Medium, D1)
**Scenario.** `SceneVolumetricsCamera` is built once from scene.json (`SceneVolumetricLight.swift:36-50`), and `g_EyePosition` is fixed with it. Layers move by `parallaxOffset − shake` each frame (LR12), so with shake on, the shafts stay still while the lamp layer shakes under them. Script changes to the camera (fov, eye) are ignored.

`BuiltinFrameContext.eyePosition` and `viewForward` are never assigned (0 and (0, 0, −1)), so the packer's depth sort is right only for the default orthographic camera (LF10).

**Test.** Hinata with `camerashake` forced on: the shaft's apex must stay on the lamp's pixel within 1 px across 60 frames.

## LR22. Missing cookies and shadow casters (Medium, D1)
**Scenario.**
- **One missing cookie drops every volumetric light.** `SceneVolumetricsPlan.build` loads each cookie with `try` inside the light loop (`:113`), and `volumetricsPlan` turns the throw into a nil plan for the whole scene. A typo in one `cookie` key, or a missing `cookie/flashlight1` in the bundled assets, drops every other light too.
- **Shadow casters are inverted.** A light with `castshadow` and `castvolumetrics` is skipped while shadows are on (the default, medium), and appears when the user turns shadows *off*. That waits for D2, but users see it the wrong way round. The library has none today: all 8 `castshadow` keys are false.

**Test.**
- A fixture with two volumetric spots, one naming `cookie/missing`: the other must still draw, with one log line.
- A fixture light with `castshadow`: its visibility at each shadows setting.

## LR23. Two displays sharing one instance (Medium, all)
**Scenario.** `renderShared` draws once at the largest scene target any display needs, then each display copies the finished frame (`f80b92e`). So:
- **Bloom and reflection are computed at the largest display's density.** On a 1080p display next to a 5K one, the bloom is 2.7× narrower relative to the frame than on the 1080p display alone (LR6).
- **The post-process runs once**, in the drawable format of the renderer, not of each display.
- **"Ultra (Display HDR)" is offered when *a* display has EDR headroom** (`29ec3cd`), but the one frame is shown on both.
- **The mip buffer, volumetrics targets and bloom targets are per instance**, which is right. The per-display cursor feeds parallax, and the lights don't follow parallax (LR12).

**Test.**
- The `4722bcc` two-display benchmark with Hinata and One piece girls on a 1920×1080 view and a 5120×2880 view: record the bloom half-width as a fraction of each view, against Hinata alone on each.
- A settings test: "Ultra (Display HDR)" with one EDR and one SDR display.

## LR24. Settings changed live (Medium, ST, all)
**Scenario.** Every `SceneRenderSettings` change goes through `setRenderSettings` → `bumpRevision` → a content rebuild: post-processing, reflections, shadows, volumetrics, and EP's Match display and Texture Resolution. Consequences:
- **Rebuild side effects.** Timelines, scripts and particles may restart (TL16), and a user dragging the Volumetrics picker through its 5 values triggers 5 rebuilds.
- **HDR mismatch while rebuilding.** Between the change and the rebuilt content, the renderer draws the old content with the new settings. `drawsHDR` comes from the content, and `runsBloom` reads the settings. Switching ultra → disabled briefly shows an HDR frame through `combine_srgb`, without bloom.
- **Volumetrics targets.** They are remade on a quality change.
- **"Display HDR" coercion.** It runs only when the Performance page appears.

**Test.** Flip each setting on Hinata while recording frames:
- no frame may be black or NaN;
- the clock must not jump back (or it must, if that is accepted, documented in TL16);
- count content builds per change.

## LR25. Cookie spots under `LightingV1` (Medium, A1, A3)
**Scenario.** With a `spotcookie` budget, `LightingV1` samples `COOKIE_SAMPLER` (`g_Texture7` = `_alias_lightCookie`) at `CalculateProjectedCoords(worldPos, g_LFeature_ShadowProjection[i])`. `ImageMaterialPlan.textureInput` throws `unsupported` for any `_alias_` name, and the packer leaves the projections zero (A2 "not done"). Two cases:
- **A lit layer in a cookie scene** falls back to the native draw, or, if the sampler has no default texture, is drawn with the cookie unbound.
- **Once the alias is bound**, a zero projection matrix gives w = 0 and NaN coordinates.

Hinata has the budget but no lit layer; 3233200129 (cookie spot) is 3D.

**Test.** A fixture: a `genericimage4` `LIGHTING` layer with `{"spot":1,"spotcookie":1}` and a `usecookie` spot. It must draw through its material, with every pixel finite, and the cookie's shape visible once D1's projection feeds `g_LFeature_ShadowProjection`.

## LR26. Per-frame lighting cost with no lights (Low, A2)
**Scenario.** The lighting names are in `UniformProgram.timeVarying`. So `BuiltinUniforms.value` builds a zero-padded array for every lighting member of every pass every frame (`BuiltinUniforms.swift:121-126`), even in scenes without lights. `SceneFrameLighting.frame` also allocates closures, two arrays and about 18 dictionary entries per frame.

**Test.** An Instruments allocations run over 600 frames of a lit-free bloom scene (2134765860): the lighting's allocations per frame should be 0 when `content.lighting.lights` is empty.

## Needs WE ground truth (lighting)
- **Hinata's spot direction (LR4):** the tilt order, from its `preview.gif`, or the multiply order at 0x1401dd630.
- **Parallax and shake (LR12, LR21):** do they move light objects and the volumetrics camera?
- **Worldspace particles (LR3):** does WE add the emitter's `angles.z` to a worldspace particle's rotation?
- **Bloom width (LR6, LR23):** the bloom's width relative to the frame at WE's scene-detail settings, and on two displays of different density.
- **Captures of the reference scenes:** One piece girls, Hinata, 3606529469 and one plain bloom scene (3639372043) at `postprocessing` "enabled" and "ultra", per the plan's T package.
- **The Knight (LR2):** a WE capture of it flickering.

## Findings (lighting)

Reviewed:
- the diffs of `dc179e3`, `5029391`, `540de97`, `256796e`, `28da824`, `7f44a7f`, `b638945`, `bcf6159`, `78d5f07`, `12a009b`, `d9015b7`, `8b4355d`, `b1a73b9`, `6d9f864`, `5067e4d`, `dea657b`, `29ec3cd`, `87fb5e5`, `3bf0439` and `fd79f54`;
- EP's uncommitted diff, where it meets bloom.

The probes ran on a copy of HEAD (`git archive`) at `/Volumes/980Pro/dd-agentLTT/src`, built with `xcodebuild build-for-testing -derivedDataPath /Volumes/980Pro/dd-agentLTT/dd`. That copy's renderer has two test hooks, `probeLastLighting` and `probeLightingOverride`, and the probes aren't committed.

The lighting suites pass at HEAD: 108 tests in `SceneLightPackerTests`, `SceneTransformTests`, `ImageMaterialLightingTests`, `ImageMaterialPrelightingTests`, `ImageMaterialReflectionTests`, `SceneMipMappedFrameBufferTests`, `SceneBloomChainTests`, `SceneBloomRenderTests`, `ScenePostProcessTests`, `SceneHDRChainTests`, `SceneHDRRenderTests`, `SceneVolumetricsTests`, `SceneScriptCursorHitTestTests`, `SceneLightingSeamTests` and `LightingV1RequireTests`; 6 more in `LitLayerLibraryTests`, `VolumetricsLibraryTests` and `LightingLibraryDecodeTests`.

**Confirmed.**
- **LF1 (LR1, Critical): a prelit layer behind a static chain never relights.**
  - The probe (`ImageMaterialPrelightingTests.testLTTPrelitLayerFollowsLightingChanges`) is the existing 128×128 lit layer under a point light. Once the frame is stable, it raises the frame's ambient from 0.2 to 1.0 for 5 frames.
  - Without effects (the direct path) the drawable changes by up to 192/255.
  - Behind the identity `tint` effect it changes by **0/255**, although the prepass ran all 5 frames (`imageMaterialPrelitDraws` +5).
  - Cause: `EffectGraphRenderer.swift:277-284` and `:333`. The static key is the prelit texture's identity with `inputVersion` 0 (`runEffects`, `SceneMetalRenderer.swift:1383-1408`, never sets it), and `readsScene` ignores the prepass.
- **LF2 (LR2, High): the Knight's scripted legacy light doesn't flicker and doesn't move in z.**
  - The probe (`LTTProbeTests.testKnightScriptedLegacyLight`) loads 2515150033 with the real loader and renderer and draws 40 frames 0.1 s apart.
  - `g_LightsColorRadius` is `[0.72157, 0.35294, 0.14902, 2048, …]` on every frame: its `intensity` script is ignored, and 1.0 is used.
  - `g_LightsPosition[0]` y follows the script (500 → 616 → 689 → 691 → 621), but z stays 588, where the script says `500 + 200 sin t`.
  - Cause: `SceneFrameLighting.swift:92` packs `object.light` (resolved at build), and `:94` packs `object.depth.originZ`, parsed once by `SceneLightDepth(object:)` (`:36`).
  - The Knight is the library's only layer lit by legacy lights (genericimage2). It is missing from the §1.5 survey and from `LightingLibraryDecodeTests.known`.
- **LF3 (LR5, High, by reading):** `ImageMaterialRenderer.swift:204` hard-codes RGBA8 for the prelit image, so HDR overbright is clipped before the effects.
- **LF4 (LR22, Medium, by reading):** `SceneVolumetricsPlan.swift:113` throws for one missing cookie, and the view model's `volumetricsPlan` drops the whole plan.
- **LF5 (LR11, Medium, by reading):** a prelit layer's own draw has `LIGHTING`/`REFLECTION` 0, and it falls back to the raw texture (`SceneMetalRenderer.swift:1006`) whenever `apply` returns nil (`EffectGraphRenderer.swift:329`: every effect hidden, or compiling).
- **LF6 (LR21, Medium, by reading):** the volumetrics camera and `g_EyePosition` are built once (`SceneVolumetricLight.swift:36-50`). Layers and emitters move with shake and parallax; shafts don't.
- **LF7 (LR10, Low, by reading):**
  - `ScenePostProcess.encodedView` (`:87`, `:185`) outlives the HDR content.
  - `allocateTargets` makes `pingA` and `pingB` at full size for the engine chains, and only one is written (`EffectGraphRenderer.swift:571-572`).
  - HDR contents also plan the LDR chain (`SceneContentLoader.swift:554`).
- **LF8 (LR17, Low, by reading):** `SCENE_ORTHO` and `HDR` are hashed into every variant's key, whether or not the source reads them.
- **LF9 (LR18, Low, likely):** `SceneMipMappedFrameBuffer.setContent` keeps the old frame across a content swap of the same size, so the new content's first frame reflects the old one.
- **LF10 (LR21, Low, by reading):** `BuiltinFrameContext.eyePosition` and `viewForward` are never assigned in `SceneMetalRenderer`, so the packer's sort depth and `g_EyePosition` are the defaults in every scene.

**Checked and not a bug.**
- **Packer overflow:** every write is bounds-checked, and slices stay inside the buffer. Masked `lightconfig` counts can't go negative or past 15.
- **Arrays of any length:** they are cut or zero-padded to the shader's declaration, and `UniformWriter` honours the array stride, so `vec3[4]` in Metal is fine.
- **The particle sprite convention:** positive = clockwise, as WE's `ComputeParticleTangents` with `mul(x, y) = y * x`. It didn't need the flip (only `spawnTurn` is open, LR3).
- **The PBR component bits:** `меч` 0x400002 and Knight 0x300002 give exactly their painted channels.
- **The prelit colour and alpha:** they are applied once, straight alpha, and every texel is covered.
- **The mip count:** WE's, down to 1 level.
- **The bloom gate and per-frame LDR constants.**
- **`g_TexelSize` under EP's sizes:** it stays 1 / the actual target.
- **Tiny targets:** they never reach 0×0.

**Aside (uncommitted, EP).** The working tree's `SceneMetalRenderer.swift` prints on every frame (`print("TEMPVIEW", …)`) and for every layer with effects under Match display (`print("TEMPDETAIL", …)`). These must not be committed.

## Fixes (lighting)

Status: 2026-09-26. Each fix has a regression test that fails without it.

| Finding | Commit | What changed | Test |
|---|---|---|---|
| LF2 (LR2) | `c1a9d70` | Light fields and the out-of-plane transform are read every frame: a script's value, then the field's timeline, then the built one (`SceneLightObject.live`). `intensity`, `radius`, `exponent`, `innercone`, `outercone` and `controlpoint` are object-table fields only a bound script sets (`ILayer` has no light members). The volumetrics read the same live light. | `LitLayerLibraryTests.testKnightsScriptedLegacyLightFlickersAndMovesInDepth` (the Knight's `g_LightsColorRadius[0]` flickers and `g_LightsPosition[0].z` follows its script), `SceneLightLiveValuesTests`, `SceneScriptBindingTests.testALightFieldBindsWithoutBeingAMember` |
| B2 leftover (LR7) | `69f9530` | `bloomhdr*` are scene-buffer fields a bound script sets (not `IScene` members), and the post-process reads them per frame: a script's, a timeline's, the content's. | `SceneHDRRenderTests.testATimelineOnBloomHDRStrengthDrivesTheChain`, `SceneScriptBindingTests.testHDRBloomFieldsBindToTheSceneWithoutBeingMembers` |
| LF3 (LR5) | `961c6f4` | The prepass draws into the frame-buffer format: RGBA16F in HDR. | `ImageMaterialPrelightingTests.testAnHDRPrepassKeepsTheOverbright` |
| LF4 (LR22) | `f6e3f5e` | A cookie that doesn't load falls back to `cookie/flashlight1`, as WE does (0x14025d19f…0x14025d1cd); a light with neither is skipped alone. | `SceneVolumetricsTests.testAMissingCookieFallsBackPerLight` |
| LF5 (LR11) | `81c80ef` | A prelit layer whose chain renders nothing draws that frame's prelit image. | `ImageMaterialPrelightingTests.testALayerWhoseEffectsAreHiddenStillDrawsLit` |
| LR4 | `c7278b4` | Settled, no change: WE 2.8.0.42's frames of Hinata give a mean of 15.4 over x 300–700, y 0–400 with volumetrics disabled and 40.2/40.4/40.3 at low/medium/high. Ours are 15.3 and 40.3/40.5/40.4 with `Rz·Ry·Rx`, and about 50 with `Rx·Ry·Rz`. The quality tiers don't change the brightness, as in WE. | `VolumetricsLibraryTests.testHinatasWedgeMatchesWE` |
| LF6, LF10 (LR12, LR21) | `26ecb1d` | The binary's object loop (0x14018b062…0x14018b14e) translates only the draws' model matrices by parallax. The packer reads the world matrices (0x1401850a0) and the volumetrics the camera (ctx+0x930, eye ctx+0x68), and neither takes parallax. Shake moves WE's eye and centre (0x140199580). The renderer keeps the camera still and moves every object by −shake, so the lights (packed and volumetric) now move by it too, and not by parallax: a lit layer slides under its lights with parallax, as in WE. `g_EyePosition` and the packer's forward are the scene camera's every frame; an orthographic camera is WE's reset one (eye 0, looking down −z, 0x14018866b). | `SceneLightCameraTests`, `VolumetricsLibraryTests.testHinatasVolumeFollowsTheCameraShake` |
| LF7 (LR10), not the graph part | `74ae6bf` | A new content drops the HDR combine's output view and the last frame's bloom records; an LDR frame drops the view. HDR contents no longer plan the LDR chain. | `SceneHDRRenderTests.testTheHDROutputGoesWithTheHDRContent`, `testHDROnlyWithUltra` |
| LF9 (LR18) | `6e14c4c` | A new content makes `_rt_MipMappedFrameBuffer` again: its first frame reads transparent black, not the last content's frame. | `SceneMipMappedFrameBufferTests.testANewContentDoesntReflectTheLastOne` |
| LF8 (LR17) | `ac618e7` | Variants are keyed and translated on the combos their stages (includes inlined) or the prelude name, plus `LIGHTING`/`LIGHTS_*` under `#require LightingV1`. The MSL is unchanged (the corpus hash holds). | `ShaderVariantCacheTests.testCombosTheShaderDoesntNameStayOutOfTheKey` |
| LR19, LR24 | `591e5a8` | Only what a content is built for rebuilds it (`SceneRenderSettings.contentKey`: HDR, shadows, volumetrics, particle budget, texture reduction). Reflection, the bloom gate, render resolution and scene detail apply per frame. | `SceneRenderSettingsContentTests` |

Not done, with the evidence:
- **`ccsimple`** (step 6): WE loads it with `COL` and/or `LUT` only when the user's colour correction differs from identity (0x1401826a2…0x1401826f3: the parameters at ctx+0x3110…0x3120, a `lut/<name>` at +0x3128 with its strength at +0x3148 > 0). At the defaults no pass is made. They are WE's `wcc_v`/`wcc_amt`/`wec_*` wallpaper properties (we-values-audit notes §7.8), which the app now offers and draws through `ccsimple`; the app's `_owe_saturation`/`_owe_hue` extras stay its own.
- **The camera fade** (`fade.json`, step 7) is loaded only when `camerafade` is on **and** the scene has camera paths (0x140181bae…0x140181bda). The library has no camera paths, and the app doesn't play them, so nothing is missing.
- **Script cameras** (`setCameraTransforms`) aren't read by the renderer at all yet (layers included), so the volumetrics don't follow them either.

## Optimisation pass (lighting, bloom, HDR, reflection, volumetrics)

`LightingFrameBenchmarkTests` (`OWE_LIGHTING_BENCH=1`) draws Hinata (3352730400, HDR and volumetrics), 3606529469 (HDR), witcher (3803167460, prelit and reflective), the Knight (2515150033, legacy lights and reflection), One piece girls (3270035750, tubes and bloom) and 3639372043 (bloom) at full scene detail on a 1920×1080 and a 5120×2880 drawable, under ultra, enabled, no post-processing, and ultra without reflection or volumetrics. It records the GPU time of 60 frames after 40 warm-up frames and the Metal memory the device holds, split by holder (`SceneMetalRenderer.frameTargetBytes`). The GPU was shared with other agents' test runs, so medians swing by 2× between runs; the minima and the memory are the numbers to read.

**What was cut** (both byte-identical: six scenes' frames compared before and after):
- `6ea7cfe`: where the frame's reflection copy runs and nothing reads `_rt_MipMappedFrameBuffer` in the scene pass after the first scene-reading layer, the scene snapshot goes into the buffer's level 0 (`SceneMipMappedFrameBuffer.snapshotCanShare`).
- `e83b252`: a layer whose effects read the scene reads the paused scene target itself; only a material that reads the scene inside the resumed pass still gets a copy. This removes a full-size copy and its blit for every composition layer: Hinata's filmgrain `projectlayer`, 3639372043's, and One piece girls' largest.

Memory held after drawing, ultra (MB; scene target at the drawable's density):

| Scene | Target | Before | After | Change |
|---|---|---|---|---|
| Hinata (HDR) | 1920×1080 F16 | 197 | 181 | −16 (the F16 snapshot) |
| Hinata (HDR) | 5280×2970 F16 | 666 | 544 | −122 |
| witcher | 3840×2160 | 708 | 676 | −32 |
| witcher | 5280×2970 | 950 | 888 | −62 |
| One piece girls | 5280×2970 | 1258 | 1196 | −62 |
| 3639372043 | 3840×2160 | 409 | 377 | −32 |
| 3639372043 | 5280×2970 | 612 | 550 | −62 |
| 3606529469 (HDR) | 5280×2970 F16 | 471 | 471 | 0 (its reader is a material) |
| the Knight | 5280×2970 | 274 | 274 | 0 (no scene reader) |

GPU, fastest frame of 60 at 5120×2880, ultra (ms, same session, A then B): Hinata 12.1 → 8.4, witcher 18.2 → 17.5, 3639372043 11.5 → 9.5; One piece girls was too noisy to read (27–39 ms either way).

Stage costs at 5280×2970 after the cuts (fastest frame, ms, one run): Hinata ultra 8.4–9.5, enabled (LDR bloom) 6.6–7.6, no post-processing 5.9–6.1, so the HDR chain and float targets cost about 3 ms over no post-processing and the LDR chain about 1 ms; volumetrics 0.5–1 ms (ultra against ultra without them); the Knight's reflection copy and mips about 0.8 ms (5.45 against 4.64). At 1920×1080 every stage is under 1 ms.

**What was checked and left:**
- The mip-mapped buffer's copy and mips run every frame the setting is on, as WE's do; skipping them while no reader is visible would hand a reader that appears later a stale frame.
- The HDR combine and the LDR combine each write a full-size frame the composite reads. Folding either into the composite changes the sampling of `_rt_Bloom` under a scaled placement, so both stay WE's passes.
- The prelit images (witcher 49 MB) are needed every frame, and a layer whose chain renders nothing draws its own, so they can't be pooled across layers.
- Memoryless targets: every lighting target is read after the pass that writes it (the volumetrics' depth is converted in a later pass), so none qualifies. The scene targets, the mip buffer, the snapshots, the prelit images and the volumetrics' light buffers are `private` render targets without `shaderWrite` or `pixelFormatView`, which Apple GPUs can compress losslessly; only the volumetrics' small R32F depth copies take `shaderWrite`.
- `LightingMemoryTests`: switching one renderer between the HDR fixture and an LDR scene ten times returns within 5% of the first HDR visit, and the LDR content holds no float target nor the HDR combine's output.

## GP. Gaps after models M5: what is still open (2026-09-27)

Script model data, blended depth writes, `ALPHATOCOVERAGE` on images and layer composites (models-plan §4.3 "Gaps after M5"). Reference harness output: `/Volumes/980Pro/agentGP-out`.

- **GP1. 3734636606's cloth with shadows on — closed (MG7's RenderDoc capture matches ours, 2026-09-27).** With shadows off the cloth matches WE: over the cloth (x 990–1150, y 270–540 of `shadowsOff_t10`) WE averages (141.6, 65.7, 51.1) and ours (142.4, 66.9, 51.6). An earlier capture (`shadowsHigh_t10`) showed WE's cloth black, (34, 35, 18), with shadows high; MG7's stills (WE 2.8.0.42, 10 s) show it red at every quality, (157, 45, 48) disabled, low, medium and high alike, as ours draws it ((158, 46, 49) at every quality). So there's no black cloth to copy; ours isn't changed. MG7 also saw no shadow at any quality, so whether the cloth keeps its light under shadows that do reach the scene is still open: the RenderDoc capture (MG7) settles it (agentGQ, `/Volumes/980Pro/agentGQ-out/gp1-*.png`).
- **GP2. 3378346807's clock — fixed (2026-09-27).** WE's buffer is now centred on the lines' bounds (EX2), so the clock's first glyph sits at x 22 (its `padding`) and its first baseline at 22 + the ascender, as in WE's capture (x 22, y 54). `systemfont_cambria` resolves through WE's table to Times New Roman (`SceneFontResolver.weSystemFonts`; the measurement is below that table). The per-layer font setting was seeded with the raw `systemfont_cambria`, which reached `NSFont(name:)` and fell back to the system font; the loader now registers the resolved family under that name. The text is also rasterised in its colour when layer effects run on it, since WE's `font` pass draws colour into the buffer the effects and the overlay's `_rt_imageLayerComposite_255_a` read. Before this, the overlay showed white glyphs where WE's are cyan. Harness volOff still1 went 3.0 → 0.4 mean Δ, still2 0.6 → 0.3 (`/Volumes/980Pro/agentGQ-out/gp2-clock-we-before-after.png`). Tests: `SceneTextLayoutTests.testALeftAlignedClockStartsAtItsPadding`, `WorkshopAssetResolverTests.testSystemFontsResolveAsWEsTable`, `testASystemFontNameFindsItsFamily`. Open: Times New Roman is a stand-in. Its ascender is 30 where Cambria's is 32, so the lines sit 2 px higher.
- **GP3. `replaceData` with other shapes — fixed (2026-09-27).** WE re-creates the model from the new data (scenescript64.dll hands it to the engine as `createModelData` does, 0x1816362d9). The store tells each model layer showing the token, which plans the model again on the replacing (script) thread under the loader's scene lock, whatever the shapes now are; the render thread only takes the finished plan (`SceneScriptModelGeometry.replacement(for:)`). Planning it on the render thread raced the loader's asset cache (Thread Sanitizer; `SceneScriptModelConcurrencyTests` runs applyData, replaceData, frames and wallpaper switches together). `SceneModelRenderer.currentPlan` swaps the new plan in for drawing, and the shadow pass does the same for casting. Test: `SceneScriptModelDataTests.testTheRendererDrawsWhatApplyDataLeaves`, which replaces one shape with two, one with 32-bit indices, and checks both draw. The shadow pass now draws the index count `applyData` left (`SceneModelRenderer.indexCount(of:in:)`), not the plan's; test `SceneShadowRenderTests.testAScriptMeshCastsWithItsCurrentTriangleList`.
- **GP4. The corpus budget expectation for 3734636606 (Low, tests).** Its physics now runs every frame (about 5 ms CPU p50 here), so `SceneScriptCorpusReplayTests` expects its budget finding; a much faster machine would pass the budget and fail the strict expectation, as 3657770939's could.
- **GP5. `ADDITIVE` — fixed (2026-09-27).** Image and model material passes blending additively get `ADDITIVE` = 1 (0x140154c5a), as alpha-to-coverage ones get `ALPHATOCOVERAGE` (`ImageMaterialPlanBuilder.blendingCombos`). Only the lit shaders' fog reads it (`generic4`, `chroma4`, `fur4`, `foliage4`), and fog is off. The golden corpus hash is unchanged (no revision bump). Test: `ModelRenderTests.testAdditiveBlendingSetsItsCombo`.
- **GP6. Composite sources that read the scene — fixed (2026-09-27).** WE renders objects in scene order, effects included, and registers each composite as it goes (0x1401ea7a3). A sampled layer that reads the scene makes its image only inside the scene pass. It is now registered there, hidden or not, and every layer sampling it (directly or through another) runs its effects in the pass after it (`SceneLayerCompositeOrder.inScene`). Test: `SceneLayerCompositeTests.testLayersSamplingALayerThatReadsTheSceneRunInTheScenePass`. Open [I]: a reader drawn before its source sees nothing this frame, where WE's reader sees the image the buffer kept from the last frame. No library composite source reads the scene.

## Effect gallery (effects at their defaults)

Status 2026-09-26 (the scene-bloom default the gallery needs landed as audit §9.1). `WEEffectGalleryTests` against WE's effect gallery (we-values-audit notes §8): all 55 scenes match WE's difference and motion within tolerance. What is still open:

### FX1. The pointer's y and the effect texture projection have no capture (Medium, effects)
WE's captures had the cursor off the display, so they show nothing of cursor ripple, x-ray or the fluid simulation's force. `g_PointerPosition` is now y-down in the shaders (WE's shaders flip it "to match texture space Y"; its camera parallax flips its raw cursor the same way, §3) and `g_EffectTextureProjectionMatrix` maps the effect's texture space to the layer's quad in an orthographic scene.
- **Binary (2026-09-27).** The pointer is `GetCursorPos`, then `ScreenToClient` on the wallpaper's window, then (x, y) / the client size (0x1401115a8…0x14011164b, stored at +0x9c). It is normalised to the window, y-down and not clamped. `g_PointerPositionLast` is the previous frame's pointer (+0xa4 ← +0x9c after the frame, 0x140181615). Ours matches in y and in Last. Ours is normalised to the scene through the display's placement and clamped to 0…1; the two agree whenever the scene fills the display.
- **Ours now.** `WECursorCaptureTests` (`OWE_CURSOR_REQUEST`) draws x-ray's halo for the cursor at known points. The halo sits under the cursor within about 3 px for a centred layer; a moved, unevenly scaled, 30°-turned layer; `general.zoom` 1.5; and a 4:3 scene cropped on a 16:9 display. With camera parallax on, it stays where the cursor would be on the layer before the parallax shift (the matrix doesn't include the parallax offset).
- **Capture request.** `/Volumes/980Pro/agentFE-out/cursor-request/` holds the projects, `build_cursor_request.py`, `capture_cursor.ps1` (`SetCursorPos` stills and a logged sweep for cursor ripple and the fluid simulation) and a README. With WE's captures in `cursor_captures/`, the test compares each halo's centre with WE's (4 px).
- **Open.** Whether WE's pointer follows the window or the scene (the crop project decides), whether its matrix includes parallax (the parallax project), and perspective scenes.

### FX2. Film grain's spread: WE's last pass draws into the scene (Low, effects) — fixed
Film grain's difference was 2.2 against WE's 3.3, and its per-pixel spread over the gradient 0.66 of WE's (std 7.8 against 11.6), because we ran the whole chain in the layer's 1024² buffer and resampled it to the layer's 870² on screen. WE draws an effect's last pass straight into the scene, so the grain is evaluated at every screen pixel (WE's still fits that at correlation 0.84 against 0.44 for the buffer; its grain's lag-1 is 0.07, ours was 0.27).
- **WE's rule (wallpaper64.exe).** The object draw (0x1401e8aa0) counts the passes that render into the layer's ping-pong buffers (+0x320) and, unless flag 0x10 is set, runs all but the last of them into the buffers (0x1401e952b, the loop stops at 0x1401e9ae7); the rest of that effect is drawn with the final flag (0x1401ea140 → 0x1401ebf60), and its last pass (the effect's +0x144, 0x1401ec22b) draws the layer's quad (+0x2e8) through the layer's matrices (0x1401ec2b2) into the scene, with the image material's blend and depth state (vtable +0x108 = 0x140209160; `colorBlendMode` 31 adds). Before the effects the object's material draws the image into the first buffer with the layer's colour, alpha and brightness as `g_Color4` (base draw vtable +0xe8 = 0x140207b50, 0x140207bd2…0x140207c2a). Flag 0x10 (every pass into the buffers, then a composite material, 0x1401ea06d…0x1401ea0c9) is set for a `colorBlendMode` other than 0 and 31 (0x1401e6f74…0x1401e6fa2), in a scene with distance or height fog (0x1401e6f96; flags from `general`, 0x140186561…0x1401865ad), for a layer another object samples (`_rt_imageLayerComposite_<id>`, 0x1401881b0, 0x1401d3c1e), for a lit layer with effects (its prelighting pass, 0x140209b79) and for text (0x14020b20d). An effect that reads `_rt_FullFrameBuffer` has the scene copied before the last pass (0x1401ea0dd…0x1401ea114) and still draws directly.
- **Ours now.** `SceneMetalRenderer.runEffectsDrawingLastPass`: the layer's material without blending draws the image into a buffer with the layer's colour, alpha and brightness (`ImageMaterialRenderer.base`, drawn again only when its input or uniforms change), the chain runs up to its last pass (`EffectGraphRenderer.applyDrawingLastPass`, `lastScenePass`) and `encodeLayer` draws that pass into the scene through the layer's quad, placement (a 3D camera's too), texture crop, material blending and depth state, at the scene's samples. A static chain keeps its output up to the last pass. Buffer mode (the whole chain into the buffers, then the material) stays for WE's flag-0x10 cases and where ours draws the layer another way: text, scene regions, solid fills, `BLENDMODE` 31, effects that read the scene, a scene with a planar reflection, and for a frame while a pipeline compiles. `g_TexelSize` in the last pass stays the chain's buffer's [?: WE's setter reads the renderer's +0x74, 0x1400d849f, not traced to the bound target].
- **Test.** `EffectLastPassTests`: film grain over the gallery's gradient has spread 12.0 (WE 11.6) and lag-1 0.076 (WE 0.07). The effect gallery: filmgrain 3.30 against 3.31, motion 0.60 against 0.69; all 55 scenes match. Every other still that changed moved towards WE's (mean abs against WE's still: edge detection 1.26 → 0.40, colour key 0.78 → 0.40, pulse 1.02 → 0.62, twirl 0.85 → 0.59). The extras and the reference captures of the effect-heavy library scenes (2963872291, 3270035750, 3352730400, 3245833232, 2350874185, 3455121165, 3802047741) are unchanged within 0.3 mean abs (2963872291 0.8 → 0.5). Cost (`SceneFrameBenchmarkTests`, GPU median): the same or lower (3270035750 at 1920×1080 26.5 → 26.9 full, 5.3 → 4.8 matched; 3245833232 17.0 → 15.7).

### FX3. Image materials don't split stage uniforms (Low, image materials)
A uniform both stages declare differently now has a fragment-stage copy (`<name>_weFragment`). The effect and particle planners resolve it from the fragment's annotation; `ImageMaterialPlan` (the puppets owner's file) still merges by name, so there the copy takes the vertex stage's value, as before. No shipped image or particle shader has such a uniform. **Fix:** use `ShaderUniformDeclaration.merged(vertex:fragment:)` in `ImageMaterialPlan`.

### FX4. Motion on periodic effects — fixed in the harness (2026-09-27)
Pulse (3.5 against 4.2), shimmer (1.05 against 1.48) and the fluid simulation (0.96 against 0.70) came from how the gallery test sampled its clip, not from the effects.
- **Clip start.** capture_gallery.ps1 saves the still, then starts ffmpeg, so WE's clip starts after the still. Pulse's brightness over WE's 15 clip frames fits a start 0.3 s after it, modulo 2.09 s. The film grain in WE's still fits `frac(g_Time)` = 0.004, so the still itself is at 5 s. The test drew its clip from the still.
- **Frame rate.** WE ran the gallery at 25 fps (README). The fluid simulation runs a fixed count of pressure iterations per frame, so at our 30 fps it moved more.
- **Encoding.** WE's clip is libx264 CRF 28, and summarize.py reads it back through `fps=5,scale=480:270,format=gray`. CRF 28 flattens per-pixel noise between frames. It also gives a static scene WE's 0.01 floor.
- **Now.** The clip starts at 5.3 s (`WEEffectGallery.clipStart`) and runs 3 s at 25 fps (`WEReferenceRenderer.frameRate`). It is encoded and read back through ffmpeg exactly as summarize.py reads WE's (`WEEffectGallery.clipMotion`).
  - Pulse 4.07 (WE 4.18), shimmer 1.38 (1.48), fluid simulation 0.71 (0.70), VHS 0.75 (0.78, was 0.98), glitter 1.46 (1.47), nitro 4.96 (5.01).
  - Every animated effect except film grain (FX2) is within 7 % of WE's, so the motion tolerance is now max(0.15, 15 %), down from max(0.35, 40 %).

### FX5. The gallery took about 25 minutes — faster (2026-09-27)
- **Where the time went.** It was not the rendering.
  - Frame readback swizzled BGRA to RGBA in a Swift loop, about 150 ms a 1080p frame in a Debug build. `TextureUploadTests.read` now uses `vImagePermuteChannels_ARGB8888`.
  - The still comparison ran `WEReferenceMetrics`' edge alignment, which is ±8 px of correlations the gallery never reads. `compare(…, edges: false)` skips it.
  - Since the clock change (c875295), a running clock steps at least 0.1 ms a frame, so an animated scene can fail to settle and wait out the 30 s settle limit (shimmer and swing did: 730 frames). Holding the clock while it settles brings that down to 0.6 s (`SceneMetalRenderer.holdsClock`, the clock owner's change).
- **Now.** About 8 s a scene with the clock held (film grain, fluid simulation, pulse, shimmer and the control in 39 s), where it was about 27 s. The whole gallery takes about 8 minutes, and every effect still gets its own scene. Drawing several effects in one scene would put them in each other's bloom and cursor, so it wasn't done.

### FX6. `g_LayerModelMatrix` has no capture (Low, effects)

`g_LayerModelMatrix` (docs: "transform between layer local space and world space", a copy of the matrix applied to the layer object; the announcement's "g_LayerModalMatrix" is a typo, wallpaper64.exe has only `g_LayerModelMatrix`) is the layer's object transform with its parents', before the camera: axes scaled by the layer's `scale`, last column its `origin` (`BuiltinPassContext.layerModelMatrix`); a layer drawn through a 3D camera gets its world matrix. Parallax, camera shake and the orthographic zoom aren't in it. Which of those WE folds in, and whether a material (not an effect) sees the layer's matrix or its own, needs a capture; the one library shader that reads it (3651835769's rounded_mask) reads only the axes' lengths. A chain that reads it is kept only while it holds (`UniformProgram.readsLayerModelMatrix`).

## EX. WE 2.8's generated extras: what is still open (2026-09-26)

From the effect gallery's extras (we-values-audit notes §9). Harness: `WEExtrasComparisonTests` (`OWE_WE_EXTRAS`). Comparison output is in `/Volumes/980Pro/agentEX-out`.

- **EX1. Text glyph advances — fixed (2026-09-27).** Glyphs now advance by their advance floored to a whole unit (0x1401b1166: `x_advance >> 6`), with HarfBuzz's offsets floored the same way. Line widths use the glyphs' pixel boxes (`FT_Glyph_Get_CBox(…, FT_GLYPH_BBOX_PIXELS)` at 0x1401addb0), and each glyph is drawn at its whole-unit pen position. Against the extras' "WE Text 123" (`text_plain_nomsdf.png`, `zoom_text.png`), the glyph centres are within 1.1 units (mean 0.6); CoreText's fractional advances drifted to 2.5 at the end of the line. Extras, mean abs before → after: plain 0.54 → 0.27, msdf 0.94 → 0.85, blur 0.94 → 0.84, drop shadow 1.16 → 1.05, outline 1.67 → 1.50, defaults 1.45 → 1.29. Test: `SceneTextLayoutTests.testGlyphsAdvanceByWholeUnitsAsInWEsCapture`. Open: WE's glyphs are hinted FreeType outlines and ours are CoreText's unhinted ones, so the shapes differ by up to a pixel at small sizes.
- **EX2. Text effect buffer — fixed (2026-09-27).** The block is the lines' bounds plus `padding` on each side: the ink across, and from the first ascender to the last line's bottom. It is centred on those bounds (0x140258900 sizes it, 0x140257d70 draws the glyphs into it, 0x140258050 places it), and `padding` is capped at 512 (0x140258986). `SceneTextLayout.boxCenter` moves the quad (2D and through a camera). Verified by 3378346807's clock (GP2). Tests: `SceneTextLayoutTests.testTheBlockIsTheLinesBoundsWithPadding` and `testALeftAlignedClockStartsAtItsPadding`. Open: WE adds the padding only when the text has effects or is sampled (0x140258954); ours always adds it, which only enlarges an effectless quad with transparent texels.
- **EX3. `blockalign` — done (2026-09-27).** A line the wrap broke (the line flag set at 0x1401b1cc6) is justified to `maxwidth` (0x1401b21ee…0x1401b22d1). What it lacks is divided by the count of spaces, tabs and carriage returns in its text and added to each such glyph's advance, and its width becomes `maxwidth`. A paragraph's last line keeps its own width. Test: `SceneTextLayoutTests.testBlockAlignJustifiesWrappedLines`. No library text sets it.
- **EX4. Multi-line text against WE (Medium).** Only single-line captures exist. The `center` rule −(asc − (n−1)·L)/2 comes from the disassembly. Needs a capture of a three-line text in top, center and bottom.
- **EX5. `layerimage` emitter — done (2026-09-27).** Built as `wallpaper64.exe` does it (points 0x1401d3ae0, spawn 0x140238c45; we-values-audit notes §11.2); WE's element preview matches (coverage 33.8 % vs 34.8 %). Flags 0x20000 and 0x40000: done 2026-10-16 (PG9).
- **EX6. `collisionmodel` (Medium, with 3D models) — fixed (M10).** It collides with the linked model's bone capsules or box (models-plan §2.12), and with a Puppet Warp image's the same way, from its rig and its posed bones (0x1401d4a69).
- **EX7. SceneScript general defaults (Low, scripting).** `thisScene.bloom`, `bloomstrength` and `bloomthreshold` read 0 for a scene without them, but WE's are on, 2 and 0.65 (`SceneScriptSceneField.defaultValue`, owned by the SceneScript area).
- **EX8. Bloom default for generated scenes (Low).** A scene without `bloom` now blooms, as WE's does (§9.1). Every scene the editor saves authors it, but a hand-written or Workshop-generated one without it will now glow. Test: the extras' `none` capture matches at 0.26.
- **EX9. Script writes to a text layer's layout — done (2026-10-15).** `font`, `anchor`, `padding` (one number, both axes), `maxwidth` / `limitwidth` and `maxrows` / `limitrows` written by a script replace the authored fields when the text is laid out (`SceneMetalText.scripted(by:)`); WE keeps them as the text object's own fields (property table 0x140258d80…0x14025a1a0; `limitwidth` is flag 0x4, `limitrows` 0x8 at +0x594) and lays the text out again when one differs from its last value (0x140256fe0…0x1402570e2). The raster cache key carries every layout field (`layoutKey`). Bound layout fields decode their authored `value` (`SceneRawValue` literals), so 3238423642's `maxwidth: {script, value: 1200}` starts at 1200. A script-named font loads through `SceneTextFontLoader`, which the loader now uses for the scene's fonts too. Tests: `SceneTextScriptLayoutTests`. Open: `anchor` still moves nothing (roadmap notes §8.13).
- **EX10. Letter spacing (`spacing`, WE 2.8) — done (2026-10-15).** A vec2 at +0x4f8 of the text object (property table 0x1402594e3, default 0 0), handed to the layout as part of its parameters (0x14025744f). The layout adds `spacing.x` to each glyph's floored advance (0x1401b1194: `cvtdq2ps(x_advance >> 6) + spacing.x`) and `spacing.y` to the line height (0x1401b0c04: `size->metrics.height >> 6` plus `spacing.y`), both in layout units (one atlas pixel at 300 dpi, the scene unit). A line's width still joins its glyph boxes, so trailing spacing adds nothing (0x1401b2190…0x1401b21e3). Wrapping measures with the spacing in (CoreText `kern`). Tests: `SceneTextSpacingTests`. Open: the wrap's break test itself wasn't traced; no WE capture of spaced text exists (3802509485, Everyone, authors 10.48 10.48); `spacing` isn't a SceneScript member, and timeline animation of it isn't read.
- **EX11. Text background (`opaquebackground`, `backgroundcolor`) — done (2026-10-15).** The switch is flag 0x2 at +0x594 (property accessor 0x14019b4e0), the colour a vec3 at +0x4d0 (default black, 0x140256baf). With it on, WE sizes the text's buffer as the lines' bounds plus `min(padding, 512)` on each side (0x140258966, 0x140258b0c), offsets the glyphs by the padding (0x140257e18), and clears the buffer to `backgroundcolor` × `brightness` (+0x4dc, 1 unless engine flag 0x2000) with the object's `alpha` (+0x33c) before drawing the glyphs (0x140257c30…0x140257cbe). Here the raster fills the block opaque under the glyphs (font effects composite over it) and draws natively in its colours; opacity and brightness apply once, at the draw. A script's `opaquebackground` / `backgroundcolor` applies the same frame. Tests: `SceneTextBackgroundTests`. Checked against WE 2.8.0.42 (capture 537, `SceneTextCapture537Tests`): the box is the layout box (615 × 153 for the capture's text) plus the padding on every side; +0x4dc is `backgroundbrightness` (registered at 0x140258d72), not `brightness`; at alpha 0.5 the box reads half over the scene and the glyphs show it through them ((156, 170, 197) for white over (0.2, 0.4, 0.8)), which is WE's buffer cleared with the alpha and the glyphs drawn into it with the alpha. Without layer effects the box is now its own quad under the glyphs, both at the layer's opacity, and `backgroundbrightness` scales it where WE applies brightness; with effects it stays baked into the raster. Bloom treats it as any colour (it glows at alpha 1). No library wallpaper turns it on (all 30-odd authored values are false, black).

## PG. WE's particle gallery: what is still open (2026-09-27)

WE 2.8.0.42 drew every built-in particle preset variant and every component preview (we-values-audit notes §11). `WEParticleGalleryTests` (gated by `OWE_PARTICLE_GALLERY`) compares each clip's coverage and motion with WE's; the items below are its known gaps (`knownGap` in `Tests/Fixtures/WEParticleGallery/expected.json`).

- **PG1. Operators still act in the plane (Medium, particles) — fixed (M10).** The program runs in 3D with oriented control points (we-values-audit notes §11.6); the vortex orb matches WE, the leaves don't (PG11). Was: Particles have depth now (emitters, `velocityrandom`, `movement`), but every other operator and initializer is 2D, and control points have no orientation. WE simulates all of them in 3D. That leaves the leaves presets' motion at about half of WE's (`turbulentvelocityrandom` turns the velocity in depth, so leaves swing toward the perspective camera; WE's clip coverage spikes to 20 % when one passes close), DNA's helix flat (`mapsequencearoundcontrolpoint` about the y axis, a `vortex` about y), and the vortex orb (magic_12) a flat ring: its `controlpointangle1` override, animated by a timeline, tilts the vortex axis. Needs the program in 3D (positions, velocities and control points as float3, control point matrices) on both simulations.
- **PG2. Light-shaft particles too bright (Low, particles) — lightshafts_4 and _5 match; _6 open.** The light-shaft systems keep two to four particles alive, so one capture is one random draw. WE's emission, prewarm and carry are ours: the init prewarms at 0x14022f28e in 0.05 s steps that emit (r8b 1 → 0x14023771b), and the rate carries at +0x24 from 0. The gallery now averages such an item over particle seeds (`seeds` in expected.json, `SceneMetalRenderer.particleSeed`): lightshafts_5 is 4.55 over 4 seeds against WE's 3.88 (seed 0 alone 6.40, the others 1.78…5.92). lightshafts_6 (the same system as _4 with the thin-ray texture) is still 1.17 against 0.41: WE's clip never rises more than 80 above the background, one fan at a time, where ours reaches 140 with two or three. Its 8-seed range (0.66…1.73) doesn't reach WE's capture, so the cause is still open. Measured again (2026-09-27, agent PX): WE's clip of lightshafts_6 (and of lightshafts_4, the same system) is one young fan: its covered centroid and top edge follow, frame for frame, the fan our simulation emits at 5 s with `starttime` set to 0 (centroid (469, 192) → (485, 184) at half size against ours (469, 192) → (481, 182)); coverage 0.50 against WE's 0.41, motion 0.33 against 0.32. With the prewarm ours keeps two older fans (born at 5.05 s of the prewarm and just after it). The prewarm itself is WE's (0x14022f28e…0x14022f2fa, step 0x140492644 = 0.05 s, emitting); zeroing every preset's `starttime` makes 18 of the 34 prewarmed gallery items worse and 4 better (snow_1's flakes, magic_0, fog_0, the leaves), so it isn't dropped in general. Why light_shafts_0/2 lose their prewarmed fans in WE and light_shafts_1 (lightshafts_5) doesn't is still open; what they have and it hasn't: `distancemax` 0, a fixed `velocityrandom`, vector `rotationrandom`/`angularvelocityrandom` and an `angularmovement` operator. Side finding (fixed): WE's particle object update (0x140230650) clears a hidden object on its first hidden step with particles alive (`isVisible` 0x140185010 false and alive count +0x604 > 0 → 0x1402306b5 object time 0, 0x1402306bc system restart 0x14022f6c0: system time, emitter clocks, carry and period counts; 0x1402306c1…0x1402307a2 particles, static children and event children removed); every hidden step then runs the system with emission off (0x140230869, `emit` = visible), so its time runs on and its clocks stand still; shown again it emits from the re-armed clocks with no pre-simulation (the `starttime` loop runs only at build). Ours froze a hidden system; now `ParticleFrameInputs.hidden` does WE's (`ParticleHiddenObjectTests`, `ParticleSimulationParityTests.testAHiddenSystemClearsOnTheGPUAndStartsOverWhenShown`). Differences left: each system (a child too) decides by its own live count, where WE clears the tree when the root has particles; a system hidden from the start skips its pre-simulation, where WE runs it and then clears it (the same unless the pre-simulation left no particle but moved the clocks).
- **PG3. Light-shaft effect presets draw white (Medium, effects) — fixed.** A `shape` object is an image subclass (0x1401907af) sized as a square the scene's orthographic height on each side (0x14025fac0, the height from 0x1401875fb), and it writes `DIRECTDRAW` 1 into every pass of its effects before they load (0x14025ff50, per pass at 0x1401e7ad2). Ours drew the effect over a full-scene layer without the combo, so the gradient was added to the white placeholder. lightshafts_0…2 now cover 0.92 / 0.32 / 0.59 % against WE's 1.05 / 0.40 / 0.64 (was 6.44 / 2.07 / 3.77). Tests: `SceneShapeObjectTests`.
- **PG4. `collisionbounds` preview (Low, particles) — fixed.** The cause was the `speed` instance override (2.9 in the preview): WE binds every emitter's `speedmin` / `speedmax` to it (0x1401c6354, 0x1401c6a86, 0x1401c6f9c), ours scaled only the velocity initializers. Coverage 4.96 against 4.36 (was 8.05), motion 8.47 against 7.57 (was 11.81), and the coverage per column now peaks at the walls as WE's does. WE also resolves only one of the four bounds planes per particle a frame (P3 > P2 > P1 > P0, 0x14024f8b1) where ours resolves each in turn; that isn't built and made no measurable difference here. Test: `ParticleOverrideTests.testTheSpeedOverrideScalesTheEmittersSpeed`.
- **PG5. Snowstorm fog (Low, particles).** snow_2's clip coverage is about twice WE's (20…30 % over 4 seeds against 14 %), its light 1.5 ×, and its light-weighted centre 140 px left and 60 px higher than WE's. The fog child (`snowstormfog`, a non-perspective static child of a perspective system, 1500…2500 px sprite-sheet sprites) carries it. Not random: no seed reaches WE's value. Checked (2026-09-27, agent PX): `colorrandom` keeps `min` and `max − min` (0x1401c74bb…0x1401c7778, 0x14005f0a0), so an inverted range draws between the two as ours does (`ParticleProgramTests.testColorRandomWithItsMinimumAboveItsMaximumDrawsBetweenThem`): not the cause. A static child's local matrix is origin in row 3 with the angles and scale (0x1401d0a57…0x1401d0cd2); it draws with the model stack's top × that matrix (0x140236b7e…0x140236bb7) and, the flag-4 view and projection popped before the children (0x140236ace…0x140236ae2), through the scene's orthographic camera, which is what ours does. Yet WE's fog stays in the lower half (coverage by fifth of the height, top to bottom: 0.1 / 2.2 / 4.8 / 21.8 / 32.4 %) and moves down at about 320 px/s and left at about 22 px/s, as its `velocityrandom` says. Moving the child's origin in a scratch copy of the preset: "0 0 0" gives 0.0 / 0.0 / 1.4 / 18.0 / 36.5 % (coverage 11.4 % against 14.1 %) but centres the light 140 px left of WE's; "150 0 0" puts it at x 995 against 990, 175 px below WE's. So WE places the fog near the parent's emitter (`origin` "150 650 0") and well below the child's 650; the transform that does it isn't found. Open.
- **PG6. `collisionmodel` preview (Low, with models).** `collisionmodel` works since M10 (the particles collide with the sphere; coverage 36.7 % against WE's 37.8 %), but the motion is 4.2 against 2.3: the preview is an orthographic scene and WE depth-tests the particles (`depthtest` enabled) against the model, hiding those behind it. Since MG6 an orthographic scene with models has depth here too, and the preview hides them (density ratio 0.07 against WE's 0.13–0.28); the motion wasn't measured again. Its lit particles get the frame's `_rt_shadowAtlas` (`ParticleShadowAtlasTests`).
- **PG7. Thunderbolt (deprecated) sampling (Low, tests).** lightning_1 spawns one bolt a second whose glow child lives 0.1 s. Ours spawns on whole seconds and the harness samples at 5.5 + 0.2 k s, so its 5 fps clip never shows a glow; WE's capture started at an arbitrary phase. A property of the measure, not a bug; the item is excluded.
- **PG8. Captures that may be the previous project (Low, tests).** The gallery's README warns that WE sometimes drops a switch. The flag tests' `pf_remapclamp_absent` capture draws like flags 1 although WE's parser reads an absent `flags` as 0 (no clamp); it is probably `pf_remapclamp_1` again. `testFlagTestsMatchWE` reports it and asserts the others.
- **PG9. `layerimage` flags 0x20000 and 0x40000 — done (2026-10-16).** 0x20000 samples the layer's drawn texture again once a second of emitting (0x140238d4f; async, `ParticleEmitterImageResampler`); on a Puppet Warp layer every point takes a bone from the rig's hit boxes (0x1401d6d30) and spawns follow it, flag or not; 0x40000 launches spawns with their point's motion times `speedmin`…`speedmax` (0x1402397d3). Verified by `ParticleEmitterImageFlagsTests` and `ParticleSimulationParityTests.testLayerImageEmitterInheritsLayerMotion`. Open: no WE asset or library wallpaper sets either flag, so no WE capture; the timer counts steps that may spawn, WE's those that do; for a sprite-sheet layer WE may sample the whole sheet, here the drawn frame.
- **PG11. Leaves presets move about half as much as WE's (Medium, particles).** leaves_0 coverage 0.99 % against 2.16 %, motion 1.63 against 4.40; leaves_2 1.55 against 3.00. Not the 3D operators: WE's `turbulentvelocityrandom` keeps the velocity in the xy plane with its default axes (0x1401bb359), and the leaves' depth comes only from their emitter (`directions` "1 0.1 1", distance 0…750, flag 4 perspective). Candidates: the perspective draw of near leaves; their 3D rotation (`rotationrandom`/`angularvelocityrandom` are vec3 in WE) is simulated now (we-values-audit notes §11.6), which turns the leaves' quads out of the plane where their presets set x or y. Measured again with the 3D rotation (2026-09-27, agent PX): leaves_0 1.00 / 1.66, leaves_2 0.92 / 1.58 (8 seeds: 1.09 / 1.88 and 1.02 / 1.82). Frame by frame the two agree: WE's median clip coverage is 0.91 (leaves_0), 1.04 (leaves_1), 0.86 (leaves_2) against ours 0.89 / 0.97 / 0.85, and the median motion 1.72 / 1.65 / 1.52 against 1.65 / 1.44 / 1.59; the leaves' blob count and sizes in the stills match (median 200 against 197 px). WE's means come from near-camera passes: in leaves_0 one leaf fills 28.6 % of one frame (motion 34 over two frames), in leaves_2 two passes reach 4.5 %. The emitter is WE's (sphere, `cbrt` radius, 0x140237d7b…0x140237f63). Our simulation does pass leaves close to the camera (a 120 s run: one 5 s window in 24 with a leaf projected above 900 px at 5 fps, two above 470), but more rarely than WE's four clips suggest; with four clips that is a 5…10 % draw, not yet a proven gap. Open.
- **PG10. The gallery takes about 45 minutes (Low, tests).** 122 items at about 20 s each (Debug build, 1080p, 11 s of simulation). `OWE_PARTICLE_GALLERY_ONLY` runs a subset.

# Models and puppets: tester pass (2026-09-27)

Tester package T of `docs/models-plan.md` §4.3, after M0–M10, P1 and P2. Tests: `ModelLibraryRenderTests` (the library), `ModelAdversarialTests` (written wallpapers; `ModelFixtureWallpaper` and `FixtureMDL` write `.mdl`s in WE's layout, nothing from the Workshop), `ModelScriptStressTests` (script model data under load), `ModelGroundTruthProjects` (the generated projects below). Shared harness: `ModelSceneHarness` (the real loader and renderer, a stepped clock, GPU errors, frame-time bound, NaN checks of float targets and posed bones, the process log through `OSLogStore`).

## Library render (all 26 scenes that are perspective or have models or puppets)

Every scene draws with shadows off, low, medium and high and the reflection on, and with shadows high and the reflection off: no model or puppet falls back (every `.mdl` mesh with triangles and a material is planned; every puppet layer has its mesh plan), no GPU error, no frame over 5 s, every posed bone finite. Frame times are the render thread's median (scripts' waits included) and the GPU's median over 30 frames at 1920×1080 on this Mac (Debug build):

| Scene | Models / meshes / bones | Puppets | Draws a frame (shadows off → on) | CPU ms, off → on | GPU ms |
|---|---|---|---|---|---|
| 3159348391 PaRappa | 26 / 59 / 356 | | 47 meshes, +44 caster draws | 12.3 → 21–22 | 1.7–2.2 |
| 3378346807 Snowflakes | 100 / 200 / 60 | | 18–42 meshes (85–90 culled), +20–65 casters | 6.8 → 13–19 | 5–25 |
| 3657770939 WE_Phys | 30 / 30 / 0 | | 273 meshes, +807 casters | 24.6 → 73–77 | 1.5 → 7 |
| 3734636606 More Physics | 46 / 52 / 0 | | 500 meshes, +483 casters | 43.6 → 76–83 | 3.2 → 5.4 |
| 3455121165 Solar system | 20 / 20 / 0 | | 20 meshes, +38 casters | 7.4 → 9.4 | 2–3.7 |
| 3453730450 Moon | 5 / 8 / 0 | | 8 | 3.6–4.7 | 2–4.8 |
| 3384390033 Ghoti (ortho) | 3 / 3 / 0 | | 3 | 3.6–5.9 | 17–28 |
| 2350874185 Razer logo | 2 / 2 / 0 | | 2 | 1.2–1.7 | 1.6–3.3 |
| 3233200129 SAS shuffle | 1 / 1 / 35 | | 1, +1 caster | 1.1 → 1.8 | 2.4–2.9 |
| audiophile, fantasticcar | 4 / 4, 4 / 9 | | 7 and 17 with 3 reflected; 4 and 9 with the reflection off | 0.4–0.9 | 0.5–2.7 |
| arsenal, techno, ricepod, dna_fragment, demon_core, neon_sunset, retro | 1–6 models | | as many as meshes | 0.2–0.6 | 0.4–3 |
| 2542737668 M4 SOPMOD II | | 22 (62 bones) | 19.8 puppet meshes | 3.0–3.6 | 19–25 |
| 3803167460 the witcher | | 3 (77 bones) | 3 | 5.6–6.1 | 21–30 |
| 2515150033 Knight, 2804817823, 2321732083, 3802767544, 3803042537 | | 1–2 each | 1–2 | 0.6–2.4 | 1.5–9 |

The full table (every variant, culled models, shadow maps, reflected models, settled or not) prints from the test; `OWE_MODEL_LIBRARY_OUT` writes it. Every library scene's scene target is 8-bit at the default post-processing, so the NaN check there is the posed bones'; the float checks run in the adversarial fixtures with `hdr` and post-processing "ultra".

## Findings

- **MT1. Morph weights that aren't finite reached the GPU — fixed (High, models).** A clip's morph track sample of NaN or ±∞, or a layer weight that isn't finite, went into `g_MorphWeights` (`SceneMorphWeights.apply` stored it with layer weight 1, and blended NaN otherwise); `ScenePuppetAnimator.perform(.setBlendShape)` with NaN or ∞ did too (only the JS side filtered it). The mesh's vertices then sit at NaN. Both are now dropped, as the script API already dropped them. Test: `ModelAdversarialTests.testMorphWeightsThatArentFiniteOrAreOutOfRangeStayFinite` (replace, blended and additive layers; a finite 5 or 1e30 is kept, as WE keeps it).
- **MT2. An unknown `attachment` was silent — fixed (Medium, models/puppets).** An object naming an attachment its parent's rig doesn't have (or whose parent has no rig, or which has no parent) hangs from its parent as if it named none, as before, and is now logged once per content (`SceneAttachmentCheck`, called by the loader after the models are built). Test: `testAnUnknownAttachmentNameIsLoggedAndTheObjectStillDraws`.
- **MT3. audiophile "couldn't be removed" — test harness, not the app (fixed in the harness).** The M9 probe removed its script-storage folder unconditionally; audiophile has no script, so the folder was never made and `removeItem` failed with "couldn't be removed" (Cocoa error 4, no such file). The committed tests all check the folder exists first. Behind it: WE's default projects' `project.json` has no `type` (WE opens their `.json` file as a scene), which `WEProject` requires, so audiophile and techno don't decode. `ModelSceneHarness.project(in:)` reads a missing type as "scene" (not for Workshop assets); `ModelLibraryRenderTests` now draws audiophile (3 reflected models into its two `_rt_Reflection` grids; none with the reflection off). The app never lists default projects, so `WEProject` is unchanged.
- **MT4. The shadow pass's CPU cost — fixed (O package).** With shadows on, the render thread's median frame went 24.6 → 73–77 ms on 3657770939 (807 caster draws a frame), 43.6 → 76–83 ms on 3734636606 (483) and 12.3 → 21 ms on PaRappa (44 caster draws, so not only a per-draw cost); the GPU cost stays small (≤ 7 ms). The pass redid each caster's whole draw per batch of views (uniforms, pipeline key, textures, the views flattened per caster and written per component, the views' planes per caster), and every model draw resolved its built-ins by name and its bound user properties per draw. Now 3657770939 draws in 10.2 ms off and 13.5–16.6 ms on, 3734636606 in 26.1 and 28.5–32.1 ms (Debug), frames and atlases byte for byte as before: `docs/models-plan.md` §4.3 O.
- **MT5. Indices past the vertices — fixed (models).** `createModelData` accepts indices past its vertex count, and `applyData` may shrink a vertex buffer under the indices (WE's rules allow a smaller buffer), so those triangles fetched past the vertex buffer, which Metal doesn't define. D3D11, WE's API, returns zeros for such fetches: `SceneModelRenderer` now pads a mesh's vertex buffer with zeros to its largest drawn index (the index list's largest is kept while `applyData` changes only the vertices). Tests: `ModelRenderTests.testIndicesPastTheVerticesReadZeros`, `testScriptModelDataAbuseFailsCleanly` (index 60000 of 4 vertices; a shrink to one vertex).
- **MT6. A hidden model as a `collisionmodel` target (closed, WE confirmed).** The particles collide with a hidden model's capsules (its plan exists), as WE's do (MG8). Links to an image layer and to a missing object are logged once and collide with nothing. Test: `testCollisionModelLinksToNonModelsFailCleanly`.
- **MT7. Thread safety of script model data (checked).** `ModelScriptStressTests` (`applyData` every `update`, `replaceData` from a timer every 30 ms with 1–3 shapes and 16/32-bit indices, 400 frames back to back without waiting for the script thread, the content rebuilt twice), `SceneScriptModelDataTests`, `SceneScriptModelConcurrencyTests` and 3734636606's library render run clean under the Thread Sanitizer at HEAD (after 5769f83 moved the replan to the script thread). One runtime warning: `SceneScriptModelConcurrencyTests` waits on a default-QoS `Thread` from the main thread (a priority inversion in the test, not the app).
- **MT8. A held scene clock crept since c875295 — fixed (test harnesses).** `SceneClock` clamps every frame's step to at least 0.1 ms, as WE's loop does, so a renderer whose `wallTime` stands still still advanced 0.1 ms a frame, and `WEReferenceRenderer` (the effect, particle and extras galleries and the reference comparison), which settles with the clock stopped until the frame stops changing, never settled on an animated scene (30 s each) and started its stills late. A harness can now hold the clock (`SceneClock.hold`, `SceneMetalRenderer.holdsClock`: the time stays, the step is 0; the app never sets it), which `WEReferenceRenderer` does while it settles. `ModelSceneHarness.settle` keeps its tolerance (a frame within a fifth of a level of the one 8 frames before, twice). Test: `SceneRenderPrimitivesTests.testHeldClockStandsStill`.
- **What fails cleanly** (`ModelAdversarialTests`, each loaded and drawn with GPU errors, frame time, bones and float targets checked): 128 bones draw with `BONECOUNT` 128 and a vertex on bone 127; 129 bones are rejected and logged; a mesh with 32-bit indices past 65535; a model with no materials and a missing `.mdl` are logged and skipped; a camera layer hidden by its script after 0.5 s hands the frame to the scene camera; two camera layers switch every half second; an image-only scene without `orthogonalprojection` is perspective and draws its image; `skin` 7 of 2 takes the last material and −3 the first; a growing `applyData` and `replaceData` from `update` log WE's messages; a reflective model with every other model `reflected: false` clears its reflection and draws nothing into it; a shadowed spot with no caster draws an empty map; 256 lights of every kind, all casting shadows and volumetrics, under the largest budget, draw in bounded time with finite HDR targets.

## Needs WE ground truth (models)

A capture list for the Windows WE session (WE 2.8.0.42, 1920×1080 at 100 %, as `tools/peer/shoot.ps1`). The generated projects are in `/Volumes/980Pro/agentT-out/we-ground-truth/<project>/` (copy each folder into WE's `projects/myprojects` and open it); our frames at the same times are in `.../we-ground-truth/ours/<project>-t<time>.png`. `ModelGroundTruthProjects` writes both again (`OWE_GROUND_TRUTH_OUT`).

- **MG1. Camera-layer `queuemode` random order (models-plan §5.4).** 3159348391 (PaRappa), property `camerastyle` = 0 ("Dynamic Cam", layer 203: 13 paths of 132 frames at 30 fps, 4.4 s each, mode `single`, `queuemode` random). Record 70 s from load (about 16 paths), three times, restarting WE between two of them. Measure: the path of each 4.4 s segment (names in `scripts/camera_paths_203.json`: Left to Right, Right to Left, Center Out, Center In, Rotate 1, Rotate 2, Overhead, Full Scroll, Sunny Focus, PJ Focus, Boxy Focus, Twist, Still); whether one path plays twice before all 13 have played (a bag or independent draws), whether a path ever follows itself, and whether the order (and the first path) is the same across loads (a fixed seed).
  - **Captured (3 × 70 s, run 3 after a WE restart; `/Volumes/980Pro/dd-agentREF/peer/tools/peer/models_gt/captures/MG1_sequences.json`).** Each run opens with the same ~4.4 s door dolly, then about 15 paths. No path followed itself (0 in ~44 transitions), every run repeated a path before all 13 had played, no path played three times, and the order and first path differed in every run (runs 1 and 2 without a restart too).
  - **Resolved.** The dolly is not a path or a queue rule: it is "Camera Start" (222), the last camera layer, whose `origin` timeline (132 frames, "single") fires "end", whose script sets `shared.camoff`, and whose `visible` script then hides it; "Dynamic Cam" plays its first path (also 132 frames) underneath. The draws are WE's bag (0x1401f2bab…0x1401f2e70: a uniform index, stepped past the last path, removed once drawn), but the first bag holds 12 of the 13 paths twice: loading a path's `visible` key calls the visibility hook (0x1401f1ca0, the bool loader 0x1401e1a90 calls it unconditionally), which queues the earlier visible paths, and the load then queues all of them again (0x1401f2919). That explains the repeats without triples (independent draws excluding the last would give a triple in 98.5 % of three such runs, and fewer distinct paths than the 10, 10, 11 seen). The generator is seeded per load now. Tests: `SceneCameraLayersTests.testRandomPathsDrawFromTheBagTheLoadLeaves`, `testRandomPathsMatchWEsStatistics`, `testRandomQueuesAreSeededPerLoad`, `SceneCameraLibraryTests.testPaRappasIntroIsTheCameraStartLayer`.
- **MG2. `transparentsorting` in a library scene (§5.30).** 3455121165 (Solar system, `transparentsorting` true; translucent orbit rings over Saturn and its ring), default properties, shadows off: stills at 10 s and 20 s. Then a local copy of the item with only `"transparentsorting": false` in `scene.json`, the same stills. Measure: where an orbit ring crosses Saturn's ring and a planet, which translucent object is on top (the colour of the overlap), in both; and whether the order changes as the camera moves.
  - **Captured (weak).** `transparentsorting` false shows no visible difference from the shipped scene at 10 s or 20 s, and the Workshop item and a local copy are equivalent (mean differences 0.33 and 0.43 levels, planet phase only). The camera doesn't move and the orbit lines are only about +20/255 over the background, so an ordering difference may not show; this doesn't settle the order.
  - **Packages.** A loose `scene.json` next to `scene.pkg` makes WE read it and look for every asset loose (hundreds of "Failed opening"), so the capture swapped `scene.json` inside the package. Ours differs: `SceneContentLoader` takes the package's `scene.json` whenever `scene.pkg` exists and ignores the loose one (a loose file is only a fallback for fonts). No library item ships both, so nothing draws differently; a user who edits an unpacked copy beside its package sees WE and the app disagree.
- **MG3. Additive layer composition (§5.2).** Generated `gt-additive-full` and `gt-additive-half`: a red arm on bone 1 of a white base; a replacing layer turns it 90° about x (+y → +z), an additive layer 90° about z (+y → −x), blend 1 and 0.5. Stills at 1, 2 and 3 s (the pose is constant). Measure: the arm's direction on screen: along +z (towards the lower left from the eye at (6, 4, 10); ours, `additive · base`) or along −x (to the left, slightly up; `base · additive`); with blend 0.5, the angle. Library check: 3803167460 (the witcher: layer 1 replacing, 2, 6, 7 and 8 additive, 8 at 0.62) and 3803042537 (an additive layer at 0.76 under a normal one at 0.31), 10 s video from load: the silhouette and the sword's tip (the object attached to "правая рука") at 2, 4, 6 and 8 s.
  - **Captured, fixed.** WE's arm points at 168.8° at blend 1 (along −x: `base · additive`) and −175.3° at 0.5 (45° about z, then the x turn: the change nlerped by the blend); ours pointed at −151.4° and −151.7° (+z, `additive · base`, where the z turn doesn't move the arm). 0x1401f9820 composes `pose · Δ` with `Δ = bind⁻¹ · sample` (its SoA products). Ours now draws 168.8° and −175.3° (the centroid of the red pixels from the white ones, y up, as the capture was measured). Tests: `ModelGroundTruthProjects.testAdditiveLayersMatchWEsCaptures`, `SceneAnimationLayersTests.testAdditiveRotationsComposeAfterThePose`. **Pending:** the library check (3803167460, 3803042537); subscribing needs the user's Chrome.
  - **Library check (2026-09-27, WE's `captures/MG3_library_*`, `ModelGroundTruthLibraryTests.testTheAdditiveLibraryItemsAgainstWEsStills`).** 3803042537 matches: mean difference 2.7–3.7 levels over the frame and 4.1–6.4 over the figure at 2, 4, 6 and 8 s after load. 3803167460 (the witcher): the rig's pose (arms, gloves, head) matches WE's, but **the sword hung from his origin**: the layer draw composed the parents' world with the child's own transform and left the child's own attachment out (`SceneMetalRenderer.parentWorld` used `parentWorld(of:)`, which only carries the ancestors' attachments). With `attachedParentWorld(of:)` the crossguard sits in his right glove as in WE's stills (it was about 237 px up-left of it). Test: `ScenePuppetAttachmentTests.testTheChildHangsFromThePosedBone`. The witcher's frame still differs by 37–39 levels (28–34 over the figure): WE's frame is about 12 % larger and blurs the forest (its post layer's `blur` and the camera parallax and shake with WE's cursor), and ours shows thin red strands over his head and arm and a second hilt on his back that WE's doesn't; these aren't the additive layers' and are open.
- **MG4. Root-motion axes (§5.3).** Generated `gt-rootmotion-0x00000` (no flag) and `gt-rootmotion-0x00800` … `0x10000` (one of the six flag bits 0x1f800 each): a red box on one bone whose looping 1 s clip moves the bone by (1, 2, 3)·t and turns it by (0.3, 0.6, 0.9)·t rad. Record 5 s of each. Measure: the box's screen centre and orientation at 0.5, 1, 2, 3 and 4 s: without root motion it loops back every second (ours, every project); a flag that carries translation or rotation into the object makes it drift. Which bit is which axis of translation and rotation. If the WE editor offers root-motion options when importing an animated model, the `.mdl` it writes (its MDLA clip flags) is worth sending back too.
  - **Captured: `0x00000` only.** It loops back every second with no drift, as ours: the box's centre at 1–4 s is (971–972, 675), ours (960, 692); its axis 8.5–9.6°, ours 179.9° (the same line within 9°, mod 180). At 0.5 s (1017, 612) at 37.8° against ours (1002, 632) at 29.4°. **Flags: nothing to observe.** In the second session WE 2.8.0.42 silently refused to load a model with any of the six clip-flag bits 0x00800…0x10000 set (the screen kept the previous wallpaper, nothing logged, and several in a row left the renderer black until a restart); each project differs from the working `0x00000` by the one byte at `gt_rootmotion.mdl` offset 0x710. The refusal isn't copied: the generated flags may simply not be where WE reads root motion. **Open:** which bit is which axis needs a `.mdl` written by WE's own importer with root motion on (a user item).
  - **Captured with the editor's files (2026-09-27), implemented.** WE's model editor writes the flags into the clip record it makes for a cut clip (`MDLAnimation.Reference`: flag 0x1, then u16 source, Start, End, Frame offset, root bone), which the generated projects lacked: WE dereferences that record for root motion, hence the refusals. Bits: 0x400 Match loop, 0x800/0x1000/0x2000 position x/y/z, 0x8000 rotation y (x and z can't be set). `SceneRootMotion` implements 0x140225900 (models-plan §2.8). Against the capture's box centroid at frames 5–25 of a loop (1920×1080): none, posX, posY, posZ and all axes are within 20 px mean (e.g. posY frame 20: WE (611, 563), ours (623, 563); all on frame 20: WE (740, 911), ours (745, 885)), and the flagless path is more than twice as far for every flagged file. No drift across loops (the editor's clip ends where it starts; WE's box at frame 10 of five loops spans 7 px, ours 12 px or less). **Open:** yaw alone (0x8401): WE keeps the object's yaw (the capture fits the pose's yaw removal without the object turning: 14 px mean), where the binary turns the object as it does with all axes on (which the capture follows: 27 px with the turn, 113 without); `XCTExpectFailure` in `SceneRootMotionTests.testTheLoopFollowsWEsCaptures`. Tests: `SceneRootMotionTests` (the 9 editor files parse; the committed one, `mg4-rootmotion-all-on.mdl`, the user's WE output, with each setting written in; WE's fast-fail on out-of-range frames; a cut clip without Match loop reading its source, 0x14021c6b3).
- **MG5. A puppet with morphs (§4.3 M7).** No library rig has morph targets. In the WE editor: puppet-warp any image, add a blend shape that moves a group of vertices by a known offset (e.g. 100 px right), animate its weight 0 → 1 over 2 s in a clip, save, and send the project folder (the `.mdl` with its `MDMP` section). Record 4 s. Measure: the vertices' offset at weights 0.25, 0.5 and 1 (linear?), with the clip's layer at blend 1 and 0.5, and with a script calling `thisLayer.setBlendShapeWeight` (does a script weight hold after the frame it is set in?).
  - **Pending** (the user makes the puppet in the WE editor).
  - **Captured (2026-09-27, `mg5/`): parsed; WE shows no deformation, unexplained.** The editor's `MDMP` (target "Shape 31", id 31; mesh float 126.47; 62 morph vertices listed by `a_PositionVec4.w`; flag 0x1000 alpha) reads back through ours, but its deltas are **16-bit signed normalised**, not halves: WE's "morph" and "morph_<n>" textures are format 0x13 → DXGI 13 (R16G16B16A16_SNORM, 0x1400d2a4d) and the editor's vertex 196 (mesh vertex 195, w 58) is 0x7FB1 · 126.47 / 32767 = +126.168, the editor's offset. Ours read halves (that vertex was NaN); now SNORM (`SceneMorphTargetsTests.testTheEditorsBlendShapeReadsAsWEsSnormTexture`; the synthetic tests moved to the SNORM grid). **Why WE shows none:** the traced path says it should deform: the setter stores the weight and the bit (0x1402105c0); the update clears them before the scripts (0x1401fecba); the uniforms are built from them by 0x14020cff0 in the layer's quad draw (vt+0xF0, 0x1402087df, and vt+0xE8 when image+0x4a0 exists), which runs **after** the puppet's own draw into its target (vt+0xE0, 0x140207740, 0x1401e968a), so that draw uses the renderer context's morph state from the last build (+0x12ea count, +0x1330 weight 0; nothing else writes them): last frame's script weights, one frame late, with a script setting them every frame. No script-access gate was found (the `scriptaccess` key is the editor JSON's). So ours keeps deforming (in the same frame, not one late). Open [?]: what stops WE's; candidates not ruled out: the context state reset elsewhere between the build and the next frame's puppet draw, or the uniform upload (0x1400d9f18) skipping the puppet material.
- **MG6. Depth in the 2D frame when models are present (PG6).** Generated `gt-ortho-depth-near-first` and `gt-ortho-depth-far-first`: an orthographic 1920×1080 scene with a red cube at z −500 and a green one at z −1500 overlapping at (960, 540), in both draw orders. Stills at 2 s. Measure: the colour at (960, 540) in each. The same colour (red) in both means WE's orthographic frame depth-tests models; the last-drawn cube in each (green, then red: ours) means it has no depth. Then the particle gallery's `ptce_collisionmodel` preview with the particle system's `depthtest` enabled and disabled: are particles hidden behind the sphere?
  - **Captured, fixed.** WE draws (253, 0, 0) at (960, 540) in both `near-first` and `far-first`: its orthographic frame depth-tests models whatever their order (ours drew the last one). In the `collisionmodel` preview the orange particles' density inside the sphere's screen area over that outside, 1.5–5 s, is 1.55 with the particle material's `depthtest` disabled, 0.13 enabled and 0.28 shipped (enabled): particles behind the sphere are hidden. WE's frame buffer always has depth (models-plan M4 deviations: `_rt_FullFrameBuffer`'s depth format 0x16/0x1a, 0x14017f59c). An orthographic scene with model objects now gets the pass's depth, and its unplaced layers and its particles draw through WE's orthographic projection, which the models use. Ours now: red at (960, 540) in both; densities 0.07 enabled and 1.07 disabled (the particles in front of the sphere are darker here, so fewer count as orange). Tests: `ModelGroundTruthProjects.testOrthographicDepthMatchesWEsCaptures`, `testCollisionModelParticlesHideBehindTheSphereAsInWE`. **Guard:** an orthographic scene without models is unchanged by construction (every new branch needs the pass's depth). The eight orthographic reference items drawn at 7154ea3 and at the change (after 32557c2 held the harness clock): 15 of 29 stills byte-identical, the rest differing on at most 0.47 % of their pixels (particles; those scenes take none of the new branches). The one library orthographic scene with models, 3384390033, changes on 0.6 % of its pixels (at most 32 levels).
- **MG7. 3734636606's cloth turns black under shadows (GP1).** Shadows off and high, still at 10 s: RenderDoc on WE with shadows high, the cloth's draw (the script mesh, two sheets with `generic4`, alpha 0.6): the pixel shader's combos (`LIGHTS_SHADOW_MAPPING`, `LIGHTS_*`), its constants (`g_LightAmbientColor`, `g_LightsColorPremultiplied`, the shadow transforms), the atlas it samples, and the output of a cloth pixel. Also the stills with shadows low and medium: is the cloth black at every quality?
  - **Captured (stills at 10 s).** The cloth is **not** black at any quality: its mean is (157.0, 44.8, 47.9) disabled, (157.1, 44.7, 47.9) low, (157.1, 44.8, 47.9) medium, (157.0, 44.7, 47.9) high. No shadow shows at low, medium or high either (the floor and box are identical to the disabled capture), so the setting may not reach this scene and this doesn't prove the cloth survives active shadows. Ours at HEAD (`ModelLibraryRenderTests`, frames raw): the cloth's red pixels average (158.5, 46.3, 49.0) with shadows off and (158.4, 46.2, 49.0) low, medium and high; not black. **Pending:** the RenderDoc capture (needs RenderDoc and the user's go-ahead).
  - **RenderDoc (2026-09-27, `mg7/`), matches ours.** WE draws shadows high into a 1536×512 R32 atlas: three 512² cascades side by side, `g_LFeature_ShadowProjectionTransform[i]` = (i/3, 0, 1/3, 1); the cloth's draw (event 15469) has ambient and skylight (0.1255, 0.2588, 0.3804), the light (6, 5.2941, 4.8941) along (0.5068, 0.7514, −0.4226), and writes ≈ (0.621, 0.177, 0.192) at alpha 0.6, i.e. (158, 45, 49). Ours with shadows high: the same atlas (1536×512, three maps), transforms, ambient, skylight, light colour and direction (within 2e-3), and the cloth's red pixels around WE's two probe points average within 6 levels of (158.4, 45.1, 49.0) (`ModelGroundTruthLibraryTests.testTheClothUnderHighShadowsMatchesWEsCapture`). Nothing to fix; GP1 closed.
- **MG8. A hidden model as a `collisionmodel` target (MT6).** The particle gallery's `ptce_collisionmodel` preview with the sphere's `visible` set false: do the particles still bounce off it? Record 5 s.
  - **Captured, matches ours.** With the sphere's `visible` false it isn't drawn (0.00 % orange inside its area against 0.04 % outside) and the particles still collide with it, as ours do (MT6). The earlier black captures weren't a locked screen: WE's "pause while an app is maximized" rule was showing the desktop.
