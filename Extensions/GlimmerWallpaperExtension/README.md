# Experimental native wallpaper extension

This is a real `com.apple.wallpaper` ExtensionFoundation `.appex`, not a desktop
window or a `.saver`. It exports WallpaperExtensionKit lifecycle/settings XPC,
creates a remote `CAContext`, and uses a muted `AVQueuePlayer`/`AVPlayerLooper` with
`AVPlayerItemVideoOutput` feeding `AVSampleBufferDisplayLayer`. No captured frames
are written to disk. The separately linked diagnostic helper does not register or activate
an extension and never edit Apple's wallpaper store or restart WallpaperAgent.

## Host contract

- Bundle ID: `com.boneinkzhong.glimmer.wallpaper-extension`
- Bundle: host `Contents/PlugIns/GlimmerWallpaperExtension.appex`
- Extension point: `com.apple.wallpaper`; package type `XPC!`; target macOS 26+ arm64.
- Provider: same bundle ID; choice/identifier: `glimmer.native-video`.
- Descriptor configuration: UTF-8 bytes of `glimmer.native-video`.
- Descriptor files may remain empty; the extension reads its fixed same-user stage.
- Stage: `/Users/Shared/GlimmerNativeLockScreen/<getuid()>/`.
- Global root must be non-symlink, owned by root/current user, and not writable by
  other users. UID directory must be current-user-owned, non-symlink, mode 0700.
- `config.json` and the video must be current-user-owned non-symlink regular files,
  mode 0600. Video basename must match the configured UUID, extension mp4/mov/m4v.
- Never replace a staged asset in place; stage a new UUID then atomically replace
  config. To switch active media the host must cause a new system acquire. The
  extension deliberately does not poll files or mutate Apple's selection.

```json
{
  "schemaVersion": 1,
  "assetID": "11111111-2222-3333-4444-555555555555",
  "videoFileName": "11111111-2222-3333-4444-555555555555.mp4",
  "gravity": "fill",
  "isMuted": true
}
```

`fit` is also accepted. Audio is always muted; configurations requesting audio are
rejected. The extension's sandbox grants read-only access to the staging root,
while ownership/mode/UID checks prevent cross-user selection. It has no shared-root
write entitlement. XPC accepts only same-user/root Apple-signed peers verified by
audit token. A changed runtime without this identity SPI is rejected.

The host service owns staging, backup/CAS store transactions, registration and
restoration. This directory/build script performs none of those operations.

## Build and verification

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/build-wallpaper-extension.sh --typecheck
GW_VERSION=0.5.0 GW_BUILD_NUMBER=2 scripts/build-wallpaper-extension.sh \
  --output /absolute/Host.app/Contents/PlugIns/GlimmerWallpaperExtension.appex
```

The production executable enters `_NSExtensionMain` exactly as Xcode's extension
product type requires, then ExtensionFoundation invokes the retained Swift `_main`.
The builder checks Mach-O `LC_MAIN`, the `_NSExtensionMain` import stub and the
`__swift5_entry` section. Calling `AppExtension.main()` directly as an ordinary
program bypasses this bootstrap and crashed in `ExtensionMain` before XPC acquire
on this host. The true provider never takes the diagnostic CLI route.

For diagnostics only, `--diagnostic-entry --output /tmp/Diagnostics.bundle` builds
ordinary Swift main, keeps the same sandbox/application identity, removes
`EXAppExtensionAttributes`, and uses package type `BNDL`; it is not a wallpaper
provider. Diagnostics establish codec/private-context/XPC behavior, not system
extension bootstrap or lock-screen visuals.

Sign nested extension first and the enclosing host afterward. This experimental
builder uses ad-hoc signing and includes the application-identifier entitlement;
without it this machine rejected sandbox initialization before `main`.

```sh
Extensions/GlimmerWallpaperExtension/Tests/run-isolated-probe.sh
```

This builds the actual provider plus a separate sandboxed diagnostic bundle under `/tmp`, stages only the repository's
synthetic demo in a private UID subdirectory, verifies real changing frames,
remote-context and snapshot NSXPC transport, pause/resume/stop, settings secure
coding, and rejects five unsafe configurations. Its own demo/config subdirectory
is removed on completion. Empty safe staging root/UID directories can remain.
Evidence and signed package are copied to `evidence/native-wallpaper-extension/`.

macOS 27.0.1 (26A434), Swift 6.4 / CLT SDK 27 was tested. Running the sandboxed
binary directly from the Desktop evidence path failed pre-main code-identity
initialization; the same signed package in `/tmp` worked. Real embedded host launch
from the installed location must still be checked. AVFoundation emitted a
`sandbox_extension_issue_file_to_process ... Operation not permitted` warning for
the temporary appex path, while sandbox/private-stage reads, playback and XPC all
passed. This warning is retained as a limitation rather than hidden.

These isolated tests do NOT establish that WallpaperAgent has accepted the signed
extension, that the lock screen visually displays video, that macOS 26 behaves
identically, or that cold-boot/FileVault login can animate. Parent integration must
verify those separately and restore the original wallpaper selection afterward.

## Private interfaces and lifecycle

This backend intentionally uses undocumented system interfaces:

- `/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit`;
- `CAContext.remoteContext[WithOptions:]`, its `contextId` and hosted layer;
- `_setDisallowsVideoLayerDisplayCompositing:` on the sample-buffer display layer;
- `NSXPCConnection.auditToken` for peer identity;
- runtime layouts of `WallpaperRemoteContextXPC` / `WallpaperSnapshotXPC`;
- the `WallpaperSettingsViewModels` Codable/XPC schema and wallpaper XPC protocol.

Unknown classes/ivars, failed bounds checks, or failed video composition yield
errors. Up to 12 surfaces are held; ordinary `default` presentation freezes after
the initial frame, `locked`/`idle` and preview play, inactive/sleep states pause,
and invalidation/connection teardown releases that connection's surfaces. Context
ownership transfers on re-acquire so an old connection cannot tear down a surface
already re-owned by a new connection. No unsupported downloads, migration or
shuffle operation claims success as an implemented feature.

## Source provenance

Private interface declarations, Codable settings shapes, and guarded runtime XPC
wrappers are adapted from the MIT-licensed [Phosphene](https://github.com/kageroumado/phosphene)
project, copyright 2026 kageroumado. See `ThirdParty/Phosphene-LICENSE.txt`. Reference
main observed at commit `c60f15f2abf351c2796a4dc11ba5f0e4e69b87ec` during this work;
reference files were read from its public main branch. The renderer, fixed staging
contract, host selection behavior, safety checks and isolated diagnostic harness
are implemented here. Muro's PolyForm Shield implementation was not copied.


## Live Scene and Web (configuration schema 2)

`liveDirectoryName` is exactly `live-<assetID>` in the same private per-user
shared directory. The application copies the project, author property payload,
and verified Scene engine assets to an immutable private bundle. A bounded
manifest records every regular file's size and SHA-256; both processes reject
links, unexpected files, mutations and unsafe permissions. Existing schema 1
video configurations remain supported.

The extension presents live frames through the existing remote CAContext and
sample-buffer composition. Scene sessions use eight independently identified,
same-team authenticated nested XPC services, isolated from desktop renderers.
Each helper accepts only the extension identity. An extension-owned Metal copy
completes before the helper's IOSurface is acknowledged. Helper caches are
explicit per-revision, per-slot private directories prepared by the application.

Web uses a nonpersistent WKWebView without an NSWindow and advances/captures
frames at the selected FPS cap. HTTPS is opt-in for the lock-screen runtime;
HTTP, external navigation, child frames and native resource grants stay closed.
Weather requires a compatible service and author configuration. Hidden pages
are destroyed, retaining the last native frame; resume creates a current page.
Scene sessions pause and owned helpers terminate when their surface is released.
Source size/FPS limits apply to both live and recorded modes. Author/settings
changes apply when the wallpaper is prepared and submitted again.

Run `bash scripts/test-live-lock-screen-sandbox.sh` after the full build. It uses a copied verified local asset profile, synthetic clock/weather fixtures (coordinates 0,0), isolated review stores and a separately signed diagnostic extension. It never registers a provider or edits the actual system store.

Validation: `Tests/LiveWallpaperBundleTests.swift`,
`Tests/LiveLockScreenPreparationTests.swift`, and the diagnostic-only
`--isolated-live-probe <isolated-shared-directory>` exercise private manifests,
production preparation/staging/replacement, real sandbox Scene/Web frames,
clock resume, optional HTTPS weather, native snapshot/context XPC transport,
pause and resource release. These isolated tests do not establish visual
acceptance by the actual system lock-screen host or FileVault/startup support.
