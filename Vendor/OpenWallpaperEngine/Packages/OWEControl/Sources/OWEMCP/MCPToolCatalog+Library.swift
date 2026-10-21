import Foundation
import OWEControlProtocol

/// The library and the app (`docs/mcp.md`): playlists, favourites, the Installed folders, deleting wallpapers, the
/// displays wallpapers are shown on, the app's settings and the plugins' status. Each tool does
/// what the app's own control does; the deleting ones need `confirm: true`.
extension MCPToolCatalog {
    static let libraryTools: [MCPTool] = playlistTools + wallpaperTools + folderTools + displayTools + settingsTools + cacheTools + pluginTools

    private static let libraryPlaylist = JSONSchema.string(
        "A playlist's name (case-insensitive) or id, from list_playlists.", minLength: 1)
    private static let libraryConfirm = JSONSchema.boolean(
        "Must be true: the client confirms the user asked for this removal.")

    // MARK: - Playlists

    private static let playlistTools: [MCPTool] = [
        MCPTool("playlist_create", title: "Create Playlist",
                description: "Creates a playlist, as the playlist sidebar does, optionally with wallpapers in it, and makes it the playlist shown and played next. A name another playlist has is refused.",
                input: JSONSchema.object([
                    "name": JSONSchema.string("The new playlist's name.", minLength: 1),
                    "wallpaper_ids": JSONSchema.stringArray("Wallpapers to put in it, in order: ids from list_wallpapers.", maxItems: 500),
                ], required: ["name"]), annotations: .change) { message($0) },
        MCPTool("playlist_update", title: "Update Playlist",
                description: "Changes a playlist's own options, as its view and its Playlist Settings sheet do: when it changes wallpaper (change_wallpaper), how long each wallpaper shows (snapped to the view's steps: 5 seconds below a minute, 15 from a minute on), the timer's options, the time-of-day slots and the transition between its wallpapers. The timer's options apply only with change_wallpaper \"timer\". Rotate, shuffle and repeat are app-wide: settings_set's playlist_rotate, playlist_shuffle and playlist_repeat.",
                input: JSONSchema.object([
                    "playlist": libraryPlaylist,
                    "change_wallpaper": JSONSchema.string("When it changes wallpaper: logon (one step each time the app starts), timer (every duration_seconds), daytime (each wallpaper at its time of day, see daytime_ends), dayofweek (up to 7 wallpapers share the week from its first day) or never (only Next and Previous).", oneOf: ControlPlaylistOptions.timings),
                    "duration_seconds": JSONSchema.number("Seconds each wallpaper shows, 5 to 3600.", minimum: 5, maximum: 3600),
                    "change_when_video_ends": JSONSchema.boolean("true: a video wallpaper moves on to the next item when it ends."),
                    "change_while_paused": JSONSchema.boolean("true: the timer runs on while the wallpaper is paused; false: it stands still until it plays again."),
                    "begin_with_first_wallpaper": JSONSchema.boolean("true: the playlist starts at its first wallpaper when the app starts or the playlist is started."),
                    "first_wallpaper_at_startup_only": JSONSchema.boolean("true (with begin_with_first_wallpaper): the first wallpaper plays at startup only and the rotation leaves it out."),
                    "daytime_ends": JSONSchema.stringArray("For daytime: the time each wallpaper's slot ends, \"HH:MM\" (24-hour), one per wallpaper in the playlist's order; \"\" shares the time up to the next end evenly. The first slot starts at midnight, each next one where the previous ends, and the last runs to midnight whatever is given for it. Ends must not go back in time.", maxItems: 500),
                    "transition": JSONSchema.string("The transition between its wallpapers: none_reduce_flicker or none for none, random for one from transition_pool each time, or a transition.", oneOf: ControlPlaylistOptions.transitionChoices),
                    "transition_pool": JSONSchema.stringArray("The transitions random picks from; every transition when left as it is. An empty list picks none.", maxItems: 27),
                    "transition_time_ms": JSONSchema.integer("How long a transition takes, in milliseconds, 0 to 3000 (snapped to 50).", minimum: 0, maximum: 3000),
                ], required: ["playlist"]), annotations: .idempotent) { message($0) },
        MCPTool("playlist_add_items", title: "Add to Playlist",
                description: "Adds wallpapers to the end of a playlist, as Add to Playlist in the library's menu does. A wallpaper already in it is left where it is.",
                input: JSONSchema.object([
                    "playlist": libraryPlaylist,
                    "wallpaper_ids": JSONSchema.stringArray("The wallpapers to add: ids from list_wallpapers.", maxItems: 500),
                ], required: ["playlist", "wallpaper_ids"]), annotations: .change) { message($0) },
        MCPTool("playlist_remove_items", title: "Remove from Playlist",
                description: "Removes wallpapers from a playlist, as its Remove buttons do. The wallpapers stay in the library.",
                input: JSONSchema.object([
                    "playlist": libraryPlaylist,
                    "wallpaper_ids": JSONSchema.stringArray("The wallpapers to remove: ids from list_playlists.", maxItems: 500),
                ], required: ["playlist", "wallpaper_ids"]), annotations: .destructive) { message($0) },
        MCPTool("playlist_move_item", title: "Move Playlist Item",
                description: "Moves a wallpaper up (negative offset) or down (positive) in a playlist by that many places, as its Move Up and Move Down buttons do one place at a time.",
                input: JSONSchema.object([
                    "playlist": libraryPlaylist,
                    "wallpaper_id": JSONSchema.string("The wallpaper to move: an id from list_playlists.", minLength: 1),
                    "offset": JSONSchema.integer("Places to move: -1 is one up, 1 one down."),
                ], required: ["playlist", "wallpaper_id", "offset"]), annotations: .change) { message($0) },
        MCPTool("playlist_delete", title: "Delete Playlist",
                description: "Deletes a playlist, as its Delete button does. Its wallpapers stay in the library. Needs confirm: true.",
                input: JSONSchema.object(["playlist": libraryPlaylist, "confirm": libraryConfirm], required: ["playlist", "confirm"]),
                annotations: .destructive) { message($0) },
    ]

    // MARK: - Wallpapers

    private static let wallpaperTools: [MCPTool] = [
        MCPTool("wallpaper_set_favorite", title: "Set Favorite",
                description: "Marks a wallpaper as a favourite or not, as the heart in the library does (the Installed tab's My Favourites filter).",
                input: JSONSchema.object([
                    "id": wallpaperID,
                    "favorite": JSONSchema.boolean("true to favourite it, false to stop."),
                ], required: ["id", "favorite"]), annotations: .idempotent) { message($0) },
        MCPTool("wallpaper_delete", title: "Delete Wallpaper",
                description: "Deletes a wallpaper from the library, as Unsubscribe in the library does: its folder goes to the Trash (or is deleted at once with to_trash false), it leaves the displays showing it, and Workshop dependencies nothing else uses are removed. Steam subscriptions are not touched. Needs confirm: true.",
                input: JSONSchema.object([
                    "id": wallpaperID,
                    "confirm": libraryConfirm,
                    "to_trash": JSONSchema.boolean("true (the default) moves the folder to the Trash; false deletes it immediately."),
                ], required: ["id", "confirm"]), annotations: .destructive) { message($0) },
    ]

    // MARK: - Installed folders

    private static let folderTools: [MCPTool] = [
        MCPTool("folders_list", title: "List Folders",
                description: "The Installed tab's folders, as Wallpaper Engine organises its Installed list: each folder's id, name, colour, icon, path (\"Games / Retro\"), the ids of the installed wallpapers filed in it and its subfolders, plus how many wallpapers are at the top level. A wallpaper is in one folder at most.",
                annotations: .readOnly) { message($0) },
        MCPTool("folder_create", title: "Create Folder",
                description: "Creates a folder in the Installed tab, as Create Folder does, at the top level or inside parent. Names may repeat, as in Wallpaper Engine.",
                input: JSONSchema.object([
                    "name": JSONSchema.string("The new folder's name.", minLength: 1),
                    "parent": JSONSchema.string("The folder to make it in: an id or path (\"Games/Retro\", case-insensitive) from folders_list. Omit for the top level."),
                ], required: ["name"]), annotations: .change) { message($0) },
        MCPTool("wallpaper_move_to_folder", title: "Move to Folder",
                description: "Files wallpapers in a folder, as Move to Folder in the Installed tab does: out of the folder each was in, into folder, or back to the top level when folder is omitted or empty. Nothing is copied or deleted.",
                input: JSONSchema.object([
                    "wallpaper_ids": JSONSchema.stringArray("The wallpapers to move: ids from list_wallpapers.", maxItems: 500),
                    "folder": JSONSchema.string("The folder: an id or path (\"Games/Retro\", case-insensitive) from folders_list. Omit or \"\" for the top level."),
                ], required: ["wallpaper_ids"]), annotations: .idempotent) { message($0) },
    ]

    // MARK: - Displays

    private static let displayTools: [MCPTool] = [
        MCPTool("display_settings_get", title: "Get Display Settings",
                description: "Each display's own settings, as Display Settings shows them: whether wallpapers are shown on it (enabled), the wallpaper it shows and its playback rule state. App-wide appearance (placement, render resolution, FPS, menu bar tint) is in settings_get.",
                input: JSONSchema.object(["display": display]), annotations: .readOnly) { message($0) },
        MCPTool("display_settings_set", title: "Set Display Settings",
                description: "Turns wallpapers on or off for one display, as Display Settings' Enabled switch does.",
                input: JSONSchema.object([
                    "display": JSONSchema.string("A display's id or name from list_displays.", minLength: 1),
                    "enabled": JSONSchema.boolean("true shows wallpapers on the display, false shows the desktop picture."),
                ], required: ["display", "enabled"]), annotations: .idempotent) { message($0) },
    ]

    // MARK: - Settings

    private static let settingsTools: [MCPTool] = [
        MCPTool("settings_get", title: "Get Settings",
                description: "The app settings settings_set can change (performance, quality, playback rules, audio, appearance, playlists), each with its value, its type, its allowed values or range, and what it does.",
                input: JSONSchema.object([
                    "keys": JSONSchema.stringArray("Only these settings' keys. Omit for all of them.", maxItems: 100),
                ]), annotations: .readOnly) { message($0) },
        MCPTool("settings_set", title: "Set Setting",
                description: "Changes one app setting, as its control in Settings does. settings_get lists the keys, their allowed values and ranges. Launch at login, the language, the log level, restart after crashing, the screen saver and lock screen, web wallpaper trust and plugins are not settable here.",
                input: JSONSchema.object([
                    "key": JSONSchema.string("The setting's key, from settings_get.", minLength: 1),
                    "value": JSONSchema.string("The new value as text: true or false, a number within the range, or one of the allowed values. A JSON number or boolean is accepted too."),
                ], required: ["key", "value"]), annotations: .idempotent) { message($0) },
    ]

    // MARK: - Caches

    private static let cacheTools: [MCPTool] = [
        MCPTool("caches_get", title: "Get Cache Size",
                description: "Settings › Performance › Caches: the space Open Wallpaper Engine's caches take on disk (total_bytes), and each cache's (caches: optimised textures, loading snapshots, editor previews, video textures, repaired videos, display pictures, translated shaders, the pipeline archive, and metal_shader_cache, the GPU shader cache macOS keeps for the app). Entries unused for 60 days are deleted automatically.",
                annotations: .readOnly) { message($0) },
        MCPTool("caches_clear", title: "Clear Caches",
                description: "Settings › Performance › Clear Caches: deletes the caches, except what the wallpapers on screen use (and the editor's previews while the Wallpaper Editor runs); the GPU shader cache is cleared at the app's next launch. Wallpapers load slower once while their caches are made again. Needs confirm: true.",
                input: JSONSchema.object(["confirm": libraryConfirm], required: ["confirm"]),
                annotations: .destructive) { message($0) },
    ]

    // MARK: - Plugins

    private static let pluginTools: [MCPTool] = [
        MCPTool("plugin_status", title: "Plugin Status",
                description: "The plugins Settings › Plugins lists (MCP Server, Depth Map Generation, Screen Saver, Chromium web engine) with whether each is installed or on, its version and whether an update is due. Installing and removing plugins stays in the app.",
                annotations: .readOnly) { message($0) },
    ]
}
