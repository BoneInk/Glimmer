import Foundation
import OWEControlProtocol

/// What `LibraryControlRequests` changes in the app: playlists, favourites, deleting wallpapers,
/// the displays wallpapers are shown on, the app's settings and the plugins' status. The app's
/// implementation (`AppLibraryControlService`) drives the same view models and stores the app's
/// controls do; tests use a fake. Requests are checked before they get here: the playlists and
/// wallpapers exist, values are allowed.
@MainActor
protocol LibraryControlService: AnyObject {
    // MARK: Playlists

    /// Creates a playlist with `wallpapers` and makes it the active one, as the sidebar does;
    /// returns its id.
    func createPlaylist(named name: String, wallpapers: [ControlWallpaper]) throws -> UUID
    /// Whether a playlist's video wallpapers move on when they end.
    func changesWhenVideoEnds(playlist id: UUID) -> Bool
    func setDuration(_ seconds: Double, playlist id: UUID) throws
    func setChangesWhenVideoEnds(_ enabled: Bool, playlist id: UUID) throws
    /// A playlist's Playlist Settings: when it changes wallpaper, the timer's options, the items'
    /// time-of-day ends and the transition.
    func playlistSettings(playlist id: UUID) -> ControlPlaylistSettings
    /// Saves them as the Playlist Settings sheet does.
    func setPlaylistSettings(_ settings: ControlPlaylistSettings, playlist id: UUID) throws
    /// Appends each wallpaper the playlist doesn't have yet.
    func add(_ wallpapers: [ControlWallpaper], toPlaylist id: UUID) throws
    func remove(_ wallpapers: [ControlWallpaper], fromPlaylist id: UUID) throws
    /// Moves the wallpaper one place up (-1) or down (1), as the playlist view's buttons do.
    func moveOnePlace(_ wallpaper: ControlWallpaper, by step: Int, inPlaylist id: UUID) throws
    func deletePlaylist(_ id: UUID) throws

    // MARK: Wallpapers

    func isFavorite(_ wallpaper: ControlWallpaper) -> Bool
    func setFavorite(_ favorite: Bool, for wallpaper: ControlWallpaper) throws
    /// Deletes the wallpaper's folder, or moves it to the Trash, as the library's Unsubscribe does.
    func delete(_ wallpaper: ControlWallpaper, toTrash: Bool) async throws

    // MARK: Installed folders

    /// The Installed tab's folders.
    var installedFolders: InstalledFolderTree { get }
    /// Changes them as the Installed tab's folder commands do, saving the result.
    func changeInstalledFolders(_ change: (inout InstalledFolderTree) -> Void)
    /// The key a wallpaper is filed under (`FavoritesStore.key(for:)`).
    func folderKey(of wallpaper: ControlWallpaper) -> String

    // MARK: Displays

    /// Shows wallpapers on the display or not, as Display Settings' Enabled switch does.
    func setDisplay(_ id: String, enabled: Bool)

    // MARK: Settings

    /// A setting's value: a bool, a number, one of its choices as text, or null for an action.
    func value(of setting: LibrarySetting) -> JSONValue
    /// Sets a value already checked against the setting (`LibrarySetting.parse`).
    func set(_ value: JSONValue, of setting: LibrarySetting) throws

    // MARK: Caches

    /// Each cache's bytes on disk, as Settings › Performance › Caches adds them up.
    func cacheSizes() async -> [ControlCacheSize]
    /// Clear Caches, as Settings' button does after its confirmation.
    func clearCaches() async -> ControlCacheClearResult

    // MARK: Plugins

    /// Settings › Plugins' entries, in its order.
    func plugins() -> [ControlPluginStatus]
}

/// One cache's size, as `caches_get` lists it.
struct ControlCacheSize: Equatable {
    var id: String
    var bytes: Int64
}

/// What `caches_clear` removed.
struct ControlCacheClearResult: Equatable {
    var removedEntries: Int
    var removedBytes: Int64
    var metalCacheResetRequested: Bool
}

/// One of Settings › Plugins' entries, as `plugin_status` lists it.
struct ControlPluginStatus: Equatable {
    var id: String
    var name: String
    var installed: Bool
    /// Turned on (the Screen Saver's toggle); nil for a plugin without a switch.
    var enabled: Bool?
    var version: String?
    var updateAvailable: Bool
    /// Anything else the plugin's row says (the MCP Server's socket error, say).
    var detail: String?
}
