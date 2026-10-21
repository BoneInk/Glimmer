import CryptoKit
import Foundation

/// Which `SceneScriptStorage` store (and script id prefix) a wallpaper gets.
///
/// The key comes from where the wallpaper is installed, never from what its `project.json` says:
/// the Steam folder id (the wallpaper folder's name when it is all ASCII digits, as Steam names
/// Workshop items), or else `local-<hash of the standardized folder path>`. A `workshopid` in
/// `project.json` is chosen by the author, so keying on it would let one wallpaper read another's
/// store.
///
/// Earlier versions keyed on a numeric `workshopid` when there was one. `legacyKeyToAdopt` names
/// such a store when this wallpaper should take it over (`SceneScriptStorage.adoptLegacyStore`
/// copies it once, and only while the new key has no store):
/// - a numeric folder whose name equals the `workshopid` already used that key; nothing moves;
/// - a numeric folder with a different `workshopid` does not adopt it: the store belongs to the
///   Workshop item of that id;
/// - a folder that isn't numeric adopts it only if the folder next to it (same library) is not
///   named after that id, i.e. the Workshop item that could claim the store isn't installed there.
///   The legacy store is copied, not moved, so it stays for that item if it is installed later.
enum SceneScriptStorageKey {
    static let localPrefix = "local-"

    /// The key of the wallpaper in `directory`.
    static func key(forWallpaperDirectory directory: URL) -> String {
        steamFolderID(of: directory) ?? localKey(forWallpaperDirectory: directory)
    }

    /// The folder's name when it is a Steam item id (ASCII digits only), else nil.
    static func steamFolderID(of directory: URL) -> String? {
        let folder = directory.standardizedFileURL.lastPathComponent
        return !folder.isEmpty && folder.allSatisfy({ $0.isASCII && $0.isNumber }) ? folder : nil
    }

    /// `local-` and the first 8 bytes of the SHA-256 of the standardized folder path, in hex.
    static func localKey(forWallpaperDirectory directory: URL) -> String {
        let digest = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
        return localPrefix + Digest.hex(digest.prefix(8))
    }

    /// The key an earlier version used for this wallpaper (`previousKey`: the numeric `workshopid`,
    /// else what `key(forWallpaperDirectory:)` gives) when its store should be adopted under the
    /// current key, else nil. See the type's documentation for the rule.
    static func legacyKeyToAdopt(previousKey: String, wallpaperDirectory directory: URL,
                                 fileManager: FileManager = .default) -> String? {
        let current = key(forWallpaperDirectory: directory)
        // Only a `workshopid` key differs from the current one; anything else has nothing to adopt.
        guard previousKey != current, !previousKey.isEmpty, previousKey.allSatisfy(\.isNumber) else { return nil }
        // A Steam folder's store is its own id's; another id's store belongs to that item.
        guard steamFolderID(of: directory) == nil else { return nil }
        let claimant = directory.standardizedFileURL.deletingLastPathComponent()
            .appending(path: previousKey, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: claimant.path) else { return nil }
        return previousKey
    }
}
