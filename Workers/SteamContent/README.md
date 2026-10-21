# Independent Steam content helper

This native ARM64 .NET helper integrates with the Swift broker, account flow, serial queue and project delivery in Glimmer. Controlled fixtures test the protocol and transfer behavior; real-account acceptance is a separate, user-authorized operation. Historical local acceptance reports are not distributed with the source repository.

No SteamCMD/Steam GUI account database, cache, content log or credentials are read. No session is connected at startup. Only an explicit valid `login` command in production mode calls `SteamClient.Connect`.

## Build and run

Run `scripts/prepare-dependencies.sh` once, then `scripts/build-steam-content-helper.sh`. This prepares SDK 10.0.402 osx-arm64 (SHA512-pinned in `sdk-pin.json`) and the matching SteamKit2 source archive (SHA256-pinned in `source-pin.json`), under project `.tools` only. CLI home/package cache are private to this project. The explicit `NuGet.Config` uses only official nuget.org; `--locked-mode` retains exact content hashes. No global PATH, service or default runtime is changed.

* No arguments: protocol introspection/shutdown only; no production network capability.
* `--fixture-root /canonical/private/path`: original isolated loopback transfer fixtures only. Never a production URL authorization route.
* `--workspace-root /canonical/private/existing-directory`: enables the official own-session production commands below. The directory must already exist, be owned by the current user, have mode0700 and have no symlink components. The helper never treats an arbitrary schema/source URL as authorization.

`build/SteamContent/GlimmerSteamContent` is the native executable. It requires the adjacent managed DLL, original C ABI shim, external SteamKit2 DLL and published runtime/dependencies; the executable alone is not the whole helper.

Tests: `scripts/test-steam-content-session.sh` runs controlled authentication/session tests plus actual SDK manifest/chunk methods against an original local HTTP fixture and real managed filesystem. `scripts/test-steam-content-helper.sh` retains the original transport regression suite. `Tests/SteamContent/production_cli_probe.py` checks production CLI rejection paths with deliberately invalid login inputs, without connecting to Steam.

## Protocol v1

Strict UTF-8 JSONL, maximum65,536 bytes per line, LF/CRLF, incomplete final line fatal. Every command has `v:1`, `commandName` and UUID `requestID`. Every event has fresh `sessionNonce`, monotonic `seq`, matching request/job/item/depot/manifest identity as available. Counter values and output epoch are decimal strings. Input epoch is a positive UInt64 JSON number. Only one authentication operation or item transfer is active at once. Repeated/older job epochs reject; the process keeps up to1,024 job IDs.

`login` carries `auth`:

* `{method:"credentials",username,password,guardData?}`
* `{method:"qr"}`
* `{method:"refresh",username,refreshToken}`

The host must obtain credentials explicitly and send them through stdin, never argv, environment, logs or a shared SteamCMD profile. `auth_started` identifies the new session. `auth_challenge` includes `sessionID`, `challengeID`, `type` (`device_code`, `email_code`, `device_confirmation`, or `qr`), retry flag and optional email hint/QR challenge URL. Reply with `auth_response` containing `response:{sessionID,challengeID,code}` or `accepted` for a device confirmation. Wrong/stale IDs and replayed responses reject. QR approval is obtained only from Steam's real polling result; a host cannot approve QR authentication by sending `accepted:true`.

`auth_result` is a **designated secret-bearing pipe event** containing the authenticated account/SteamID, refresh token and optional new GuardData. The native host owns Keychain storage and redaction. Ordinary progress/failure events never echo these secrets. Managed strings cannot be securely zeroed; references are released promptly, with no plaintext credential/token disk persistence. A login has a five-minute bound; ready sessions are not silently expired by that authentication timer. A distinct random LoginID is used, without claiming to bypass Steam's account/session restrictions.

`auth_cancel` or `logout` requires the current `sessionID`. It cancels/drains the owned transfer and login, disconnects the owned adapter and revokes pending challenges before `logged_out`. Stale logout cannot cancel a newer session. `shutdown` or stdin EOF stops the owned transfer/session. A cancelled old authentication result cannot publish a token into a new session.

`download` contains `sessionID`, UUID `jobID`, positive `epoch`, and decimal-string `publishedFileID`. **No production URL, key, caller manifest or transfer plan is accepted.** The matching current session must already be authenticated.

The official API route is: authenticated `PublishedFile.GetDetails` → result/item/app431960/type/ban checks → PICS app access token/product info → actual `depots.workshopdepot` (appid fallback only when absent in valid inline depot data) → depot decryption key → nonzero manifest request code → official CM CDN discovery → per-host CDN token → SDK manifest/chunk download. CDN tokens are memory-only, scoped to depot+host, cached until near expiry, and invalidated on HTTP401/403. Transfers retry boundedly over discovered servers, including a single-server retry case.

Supported production content is the SteamPipe UGC manifest route. Explicitly unavailable paths include collections/non-community file types, legacy `file_url`, PICS HTTP-delivered appinfo without inline depot data, HTTP-only/proxy/foreign-app CDN servers, and old v4 manifest framing. These produce clear failures; no fallback URL or fake completed item is manufactured. Actual Steam service/account behavior still needs real acceptance.

## Data and counters

CDN clients have immutable per-request host/path/body-limit/cancellation scope. A custom factory counts actual response reads from the **same SDK chunk operation**, excludes manifest/auth traffic, disallows redirects and rejects private/loopback connection targets in production. Job cancellation remains linked through response-body copying; disposal awaits the SDK operation rather than just abandoning its task. Manifest ZIP and v5 section framing are bounded before SDK parsing. Signature sections are parsed by the SDK; this helper does not claim independent Valve signature verification.

All manifest files/chunks/offsets/whole-file SHA1 identities and parent paths are validated before output. The subset allows up to2GiB logical content,20,000 manifest entries,32,768 chunks,40,000 total path nodes,32 path components and1,024 path characters. It rejects absolute/traversal/empty/control/NFD components, case-insensitive duplicate file paths, symlink flags/targets and file-as-parent conflicts. Case/normalization conventions that cannot be represented safely fail rather than silently overwrite.

Output is `items/<itemID>/<manifestID>/content` inside the private workspace. Original C fixed-ABI functions use no-follow component directory handles, current-user/private directory checks and nonblocking regular/single-link file checks. Files are0600. A native descriptor walk rejects extra/unlisted files and links before completion. Source resources and original user files are never read or moved by this transport.

The atomic0600 `checkpoint.json` lies outside the project content tree and contains only version/app/item/depot/manifest/fingerprint plus completed safe chunk indices. Indices are deterministic across equivalent file ordering. There are no URLs, depot keys, credentials or tokens. The checkpoint is a hint only: restarting with the same official manifest re-reads and hashes actual bytes. Different manifests have separate directories. It never counts file length or sparse/preallocated blocks as completion.

* `receivedPayloadBytes`: observed HTTP body bytes including retries and rejected content; suitable for network rate, not a fraction over an uncompressed size.
* `logicalTotalBytes`: validated selected manifest logical file sizes.
* `downloadedVerifiedBytes`: newly validated, written and flushed logical bytes, counted once.
* `reusedVerifiedBytes`: actual existing bytes revalidated against the expected chunk SHA1.
* `successfulCompressedPayloadBytes`: accepted compressed payload, separate from logical completion.

SDK processing performs AES/decompression/expected length/Adler verification; the helper adds independent chunk SHA1 and final whole-file SHA1 checks after all writes. Progress is throttled to five periodic events/second, with immediate phase/final events. A terminal ACK follows closed handles/stopped writes and a cleared command gate.

`transfer_complete` includes counters, a workspace-relative content path, plan fingerprint and `validationRequired:true`. **It does not mean the Wallpaper Engine project is compatible/imported/applied.** The native resolver/importer must validate and acknowledge that separately. Downloaded100% can therefore still be in validation. This process is not an OS sandbox or hard memory-limit claim.

## Dependencies and replacement

SteamKit2 **3.4.0**, LGPL-2.1-only, remains an unmodified external DLL; its actual NuGet TFMs are net8.0/net10.0. Direct dependency version is exact `[3.4.0]`; `packages.lock.json` pins all content hashes. Corresponding source: https://github.com/SteamRE/SteamKit/tree/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7 (archive: https://github.com/SteamRE/SteamKit/archive/1c7bc9c41a529e8fbb1e6890f1e4dbcdc5200cb7.tar.gz). Run `scripts/prepare-dependencies.sh` to fetch and verify the unmodified matching source archive at `.tools/steamkit-source-3.4.0.tar.gz`; the App packaging script includes it with the notices.

No trimming, NativeAOT or single-file merging is used. Compatible replacement libraries remain adjacent to the executable. Preserve replacement/rebuild/re-sign ability, corresponding source and licenses when distributing a signed host. This development bundle is not a finished signed-distribution compliance review. Included notices cover SteamKit2/bundled code, protobuf-net/Core (Apache-2.0), ZstdSharp (MIT), System.IO.Hashing and self-contained .NET (MIT plus third-party notices). No GPL DepotDownloader implementation is copied.
