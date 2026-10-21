# Read-only Steam library inventory

```swift
let report = try await SteamLibraryScanner().scan(selectedRoot: selectedFolderURL)
// Present report.items in a native sheet. Only explicitly checked
// item.isImportCandidate entries are handed to existing Video/Web importers.
```

The caller must obtain the root from an explicit native folder selection. The scanner balances security-scoped access during `scan`; it does not retain a grant for later imports. The caller must retain/reacquire the selected-root authorization and existing importers must revalidate paths and actual media/HTML at import time.

`SteamLibraryScanReport` contains `selectedRoot`, `contentRoots`, `items`, `diagnostics`, and `wasTruncated`. Each item has `workshopID`, source `itemRoot`/`projectURL`, bounded `title`, `kind`, optional safe `entryURL`, `availability`, and per-item diagnostics. `id` is the source project path, so the same Workshop ID in another library remains a distinct source candidate. `isImportCandidate` means only a regular local Video/Web entry was found, never that it is playable or engine compatible.

Only these locations are considered:

- selected root / `steamapps/workshop/content/431960`
- selected root / `workshop/content/431960`
- selected root itself if its basename is exactly `431960`

There is no recursive library discovery, external VDF expansion, login, SteamCMD execution, network request, copying, media execution or library mutation. Video, Web and Scene items with a valid local entry become validation candidates; Scene render/script compatibility is checked by the importer before acceptance. Application/unknown items are inventoried but cannot be imported through this candidate flag. Item IDs must be nonzero ASCII decimal UInt64 values; normalized IDs retain exact source directories.

POSIX descriptor-relative `openat`/`fstatat` with no-follow checks rejects symbolic links in candidate paths, item directories, project files and entries. Arbitrary symlink ancestors of the selected root are rejected; macOS `/tmp` and `/var` system aliases are canonicalized. Special project/entry files (including FIFOs) are rejected without reading them. Project reads are chunked and cancellation-aware; source inode/device and size/mtime checks detect changes around reads. A later external mutation still requires importer revalidation.

Limits default and hard-ceiling at 2,000 candidates, 10,000 directory entries, 2 MiB per project JSON, and 1,024 title characters. Callers can lower them with `SteamLibraryScanLimits`. Count limits produce an explicit truncated report; byte limits and malformed projects produce item diagnostics. The bounded partial inventory is sorted numerically by Workshop ID and then source path; which items fit an exceeded enumeration limit depends on filesystem enumeration order.

Run `scripts/test-steam-library-import.sh`. Its self-created multi-library tree includes corrupt/oversized projects, traversal paths, symlinks, FIFOs and duplicate IDs. A complete tree hash (regular bytes, names, link destinations and directory/special-file metadata; no access time) must remain unchanged before/after all scans. No real Steam path is scanned.
