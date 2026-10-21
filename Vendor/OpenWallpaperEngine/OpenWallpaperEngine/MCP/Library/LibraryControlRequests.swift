import Foundation
import OWEControlProtocol

/// The control channel's requests for the library and the app: playlists, favourites, the Installed folders, deleting wallpapers, displays, the app's settings, its caches and plugin status (`docs/mcp.md`).
/// Each checks its parameters, finds what it names through `ControlLookup` and asks `service`,
/// which drives the app's own view models; the result is the changed thing with a `message`.
@MainActor
final class LibraryControlRequests: ControlRequestGroup {
    let methods: Set<String> = [
        "playlist_create", "playlist_update", "playlist_add_items", "playlist_remove_items", "playlist_move_item",
        "playlist_delete", "wallpaper_set_favorite", "wallpaper_delete", "display_settings_get", "display_settings_set",
        "settings_get", "settings_set", "plugin_status", "folders_list", "folder_create", "wallpaper_move_to_folder",
        "caches_get", "caches_clear",
    ]

    let service: LibraryControlService

    init(service: LibraryControlService) {
        self.service = service
    }

    static func make(app: AppDelegate, model: AppControlModel) -> LibraryControlRequests {
        LibraryControlRequests(service: AppLibraryControlService(app: app, model: model))
    }

    func result(for method: String, _ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue {
        switch method {
        case "playlist_create": return try createPlaylist(params, lookup)
        case "playlist_update": return try updatePlaylist(params, lookup)
        case "playlist_add_items": return try addItems(params, lookup)
        case "playlist_remove_items": return try removeItems(params, lookup)
        case "playlist_move_item": return try moveItem(params, lookup)
        case "playlist_delete": return try deletePlaylist(params, lookup)
        case "wallpaper_set_favorite": return try setFavorite(params, lookup)
        case "wallpaper_delete": return try await deleteWallpaper(params, lookup)
        case "display_settings_get": return try displaySettings(params, lookup)
        case "display_settings_set": return try setDisplaySettings(params, lookup)
        case "settings_get": return try settings(params)
        case "settings_set": return try setSetting(params)
        case "plugin_status": return pluginStatus()
        case "caches_get": return await caches()
        case "caches_clear": return try await clearCaches(params)
        case "folders_list": return foldersList(lookup)
        case "folder_create": return try createFolder(params)
        case "wallpaper_move_to_folder": return try moveToFolder(params, lookup)
        default: throw ControlError(.unknownMethod, "The app doesn't know \"\(method)\".")
        }
    }

    // MARK: - Playlists

    private func createPlaylist(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let name = try params.required("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ControlError(.invalidParams, "name must not be blank.") }
        if let taken = lookup.model.playlists().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ControlError(.refused, "A playlist named \"\(taken.name)\" exists already. Choose another name, or add to it with playlist_add_items.")
        }
        let wallpapers = try unique(params.strings("wallpaper_ids").map(lookup.wallpaper))
        let id = try service.createPlaylist(named: name, wallpapers: wallpapers)
        let playlist = try saved(id, lookup)
        return result(playlist, "Created the playlist \"\(playlist.name)\" with \(Self.count(playlist.wallpapers.count, "wallpaper")); it is now the active playlist.")
    }

    private func updatePlaylist(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let playlist = try lookup.playlist(params.required("playlist"))
        let duration = try params.double("duration_seconds")
        let videoEnds = try params.bool("change_when_video_ends")
        let settingKeys = Self.playlistSettingKeys.filter(params.has)
        guard duration != nil || videoEnds != nil || !settingKeys.isEmpty else {
            throw ControlError(.invalidParams, "Give an option to change: change_wallpaper, duration_seconds, change_when_video_ends, change_while_paused, begin_with_first_wallpaper, first_wallpaper_at_startup_only, daytime_ends, transition, transition_pool or transition_time_ms. A playlist's name can't be changed: Open Wallpaper Engine has no rename.")
        }
        var changes: [String] = []
        if !settingKeys.isEmpty {
            let current = service.playlistSettings(playlist: playlist.id)
            let updated = try Self.playlistSettings(params, current: current, itemCount: playlist.wallpapers.count)
            try service.setPlaylistSettings(updated, playlist: playlist.id)
            changes.append(contentsOf: Self.describe(updated, from: current))
        }
        if let duration {
            guard PlaylistDurationFormat.range.contains(duration) else {
                throw ControlError(.invalidParams, "duration_seconds must be from 5 to 3600.")
            }
            // The view's slider snaps to its steps the same way.
            let snapped = PlaylistDurationFormat.snapped(duration)
            try service.setDuration(snapped, playlist: playlist.id)
            changes.append("each wallpaper shows for \(PlaylistDurationFormat.label(snapped, locale: Locale(identifier: "en_US")))")
        }
        if let videoEnds {
            try service.setChangesWhenVideoEnds(videoEnds, playlist: playlist.id)
            changes.append(videoEnds ? "videos move on when they end" : "videos play for the whole duration")
        }
        let updated = try saved(playlist.id, lookup)
        let summary = changes.isEmpty ? "nothing changed" : changes.joined(separator: " and ")
        return result(updated, "In \"\(updated.name)\", " + summary + ".")
    }

    private func addItems(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let playlist = try lookup.playlist(params.required("playlist"))
        let wallpapers = try unique(params.strings("wallpaper_ids").map(lookup.wallpaper))
        guard !wallpapers.isEmpty else { throw ControlError(.invalidParams, "wallpaper_ids must name at least one wallpaper.") }
        let present = Set(playlist.wallpapers.map(Self.key))
        let added = wallpapers.filter { !present.contains(Self.key($0)) }
        if !added.isEmpty { try service.add(added, toPlaylist: playlist.id) }
        let updated = try saved(playlist.id, lookup)
        var message = "Added \(Self.count(added.count, "wallpaper")) to \"\(updated.name)\""
        if added.count < wallpapers.count { message += "; \(wallpapers.count - added.count) already in it" }
        return result(updated, message + ".")
    }

    private func removeItems(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let playlist = try lookup.playlist(params.required("playlist"))
        let ids = try params.strings("wallpaper_ids")
        guard !ids.isEmpty else { throw ControlError(.invalidParams, "wallpaper_ids must name at least one wallpaper.") }
        let wallpapers = try unique(ids.map { try item($0, in: playlist, lookup) })
        try service.remove(wallpapers, fromPlaylist: playlist.id)
        let updated = try saved(playlist.id, lookup)
        return result(updated, "Removed \(Self.count(wallpapers.count, "wallpaper")) from \"\(updated.name)\"; they stay in the library.")
    }

    private func moveItem(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let playlist = try lookup.playlist(params.required("playlist"))
        let wallpaper = try item(params.required("wallpaper_id"), in: playlist, lookup)
        let offset = try params.requiredInt("offset")
        guard let from = playlist.wallpapers.firstIndex(where: { Self.key($0) == Self.key(wallpaper) }) else {
            throw ControlError(.notFound, "\"\(wallpaper.title)\" isn't in the playlist \"\(playlist.name)\".")
        }
        let to = from + offset
        guard playlist.wallpapers.indices.contains(to) else {
            throw ControlError(.invalidParams, "\"\(wallpaper.title)\" is at position \(from + 1) of \(playlist.wallpapers.count); it can move from \(-from) to \(playlist.wallpapers.count - 1 - from) places.")
        }
        // One place at a time, as the view's Move Up and Move Down buttons do.
        let step = offset < 0 ? -1 : 1
        for _ in 0..<abs(offset) { try service.moveOnePlace(wallpaper, by: step, inPlaylist: playlist.id) }
        let updated = try saved(playlist.id, lookup)
        return result(updated, "Moved \"\(wallpaper.title)\" to position \(to + 1) of \(updated.wallpapers.count) in \"\(updated.name)\".")
    }

    private func deletePlaylist(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let playlist = try lookup.playlist(params.required("playlist"))
        try Self.requireConfirmation(params, "Deleting the playlist \"\(playlist.name)\"")
        try service.deletePlaylist(playlist.id)
        return [
            "deleted": ["id": .string(playlist.id.uuidString), "name": .string(playlist.name)],
            "message": .string("Deleted the playlist \"\(playlist.name)\"; its \(Self.count(playlist.wallpapers.count, "wallpaper")) stay in the library."),
        ]
    }

    /// The playlist as it is after a change.
    private func saved(_ id: UUID, _ lookup: ControlLookup) throws -> ControlPlaylist {
        guard let playlist = lookup.model.playlists().first(where: { $0.id == id }) else {
            throw ControlError(.failed, "The playlist wasn't saved.")
        }
        return playlist
    }

    /// A wallpaper of the playlist, by the id list_playlists shows (or any id the library knows).
    private func item(_ id: String, in playlist: ControlPlaylist, _ lookup: ControlLookup) throws -> ControlWallpaper {
        if let item = playlist.wallpapers.first(where: { $0.id == id || $0.workshopID == id }) { return item }
        let wallpaper = try lookup.wallpaper(id)
        guard playlist.wallpapers.contains(where: { Self.key($0) == Self.key(wallpaper) }) else {
            throw ControlError(.notFound, "\"\(wallpaper.title)\" isn't in the playlist \"\(playlist.name)\".")
        }
        return wallpaper
    }

    /// The playlist as `list_playlists` writes it, with its own options and a `message`.
    private func result(_ playlist: ControlPlaylist, _ message: String) -> JSONValue {
        [
            "playlist": [
                "id": .string(playlist.id.uuidString), "name": .string(playlist.name),
                "active": .bool(playlist.isActive), "rotating": .bool(playlist.isRotating),
                "shuffle": .bool(playlist.shuffles), "duration_seconds": .number(playlist.duration),
                "change_when_video_ends": .bool(service.changesWhenVideoEnds(playlist: playlist.id)),
                "settings": .object(service.playlistSettings(playlist: playlist.id)
                    .json(itemCount: playlist.wallpapers.count, calendar: .autoupdatingCurrent)),
                "displays": .array(playlist.displays.map { .string($0) }),
                "wallpapers": .array(playlist.wallpapers.map {
                    ["id": .string($0.id), "title": .string($0.title), "type": .string($0.type)]
                }),
            ],
            "message": .string(message),
        ]
    }

    // MARK: - Wallpapers

    private func setFavorite(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let wallpaper = try lookup.wallpaper(params.required("id"))
        let favorite = try params.requiredBool("favorite")
        let was = service.isFavorite(wallpaper)
        if was != favorite { try service.setFavorite(favorite, for: wallpaper) }
        let message = favorite
            ? (was ? "\"\(wallpaper.title)\" was a favourite already." : "\"\(wallpaper.title)\" is now a favourite.")
            : (was ? "\"\(wallpaper.title)\" is no longer a favourite." : "\"\(wallpaper.title)\" wasn't a favourite.")
        return ["wallpaper": ControlLookup.json(wallpaper), "favorite": .bool(service.isFavorite(wallpaper)), "message": .string(message)]
    }

    private func deleteWallpaper(_ params: ControlParameters, _ lookup: ControlLookup) async throws -> JSONValue {
        let wallpaper = try lookup.wallpaper(params.required("id"))
        try Self.requireConfirmation(params, "Deleting \"\(wallpaper.title)\"")
        let toTrash = try params.bool("to_trash") ?? true
        try await service.delete(wallpaper, toTrash: toTrash)
        let message = toTrash
            ? "Moved \"\(wallpaper.title)\" to the Trash; it is no longer in the library."
            : "Deleted \"\(wallpaper.title)\" from the library."
        return ["deleted": ControlLookup.json(wallpaper), "to_trash": .bool(toTrash), "message": .string(message)]
    }

    // MARK: - Displays

    private func displaySettings(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let displays = try params.string("display").map { [try lookup.display($0)] } ?? lookup.model.displays()
        let enabled = displays.filter(\.isEnabled).count
        return [
            "displays": .array(displays.map { json($0, lookup) }),
            "message": .string("\(Self.count(displays.count, "display")), wallpapers shown on \(enabled)."),
        ]
    }

    private func setDisplaySettings(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let display = try lookup.display(params.required("display"))
        let enabled = try params.requiredBool("enabled")
        if display.isEnabled != enabled { service.setDisplay(display.id, enabled: enabled) }
        let updated = try lookup.display(display.id)
        let message = enabled ? "Wallpapers are shown on \(updated.name)." : "Wallpapers are off on \(updated.name); it shows the desktop picture."
        return ["display": json(updated, lookup), "message": .string(message)]
    }

    private func json(_ display: ControlDisplay, _ lookup: ControlLookup) -> JSONValue {
        [
            "id": .string(display.id), "name": .string(display.name), "main": .bool(display.isMain),
            "enabled": .bool(display.isEnabled), "rule": .string(display.rule),
            "wallpaper": lookup.model.wallpaper(onDisplay: display.id).map(ControlLookup.json) ?? .null,
        ]
    }

    // MARK: - Settings

    private func settings(_ params: ControlParameters) throws -> JSONValue {
        let keys = try params.strings("keys")
        let settings = keys.isEmpty ? LibrarySetting.all : try keys.map(LibrarySetting.named)
        return [
            "settings": .array(settings.map { $0.json(value: service.value(of: $0)) }),
            "message": .string(settings.count == 1
                ? "\(settings[0].key) is \(Self.text(service.value(of: settings[0])))."
                : "\(settings.count) settings."),
        ]
    }

    private func setSetting(_ params: ControlParameters) throws -> JSONValue {
        let setting = try LibrarySetting.named(params.required("key"))
        guard let raw = params.raw["value"], !raw.isNull else { throw ControlError(.invalidParams, "value is required.") }
        let value = try setting.parse(raw)
        try service.set(value, of: setting)
        let now = service.value(of: setting)
        let message: String
        if case .action = setting.kind {
            message = "Applied the \(Self.text(value)) \(setting.key.replacingOccurrences(of: "_", with: " "))."
        } else {
            message = "\(setting.key) is \(Self.text(now))."
        }
        return ["setting": setting.json(value: now), "message": .string(message)]
    }

    // MARK: - Plugins

    private func pluginStatus() -> JSONValue {
        let plugins = service.plugins()
        return [
            "plugins": .array(plugins.map { plugin in
                [
                    "id": .string(plugin.id), "name": .string(plugin.name), "installed": .bool(plugin.installed),
                    "enabled": plugin.enabled.map { .bool($0) } ?? .null,
                    "version": plugin.version.map { .string($0) } ?? .null,
                    "update_available": .bool(plugin.updateAvailable),
                    "detail": plugin.detail.map { .string($0) } ?? .null,
                ]
            }),
            "message": .string(plugins.map { "\($0.name): \($0.installed ? "installed" : "not installed")" }.joined(separator: "; ") + "."),
        ]
    }

    // MARK: - Caches

    private func caches() async -> JSONValue {
        let sizes = await service.cacheSizes()
        let total = sizes.reduce(0) { $0 + $1.bytes }
        return [
            "total_bytes": .number(Double(total)),
            "caches": .array(sizes.map { ["id": .string($0.id), "bytes": .number(Double($0.bytes))] }),
            "message": .string("The caches take \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))."),
        ]
    }

    private func clearCaches(_ params: ControlParameters) async throws -> JSONValue {
        try Self.requireConfirmation(params, "Clearing the caches")
        let cleared = await service.clearCaches()
        let freed = ByteCountFormatter.string(fromByteCount: cleared.removedBytes, countStyle: .file)
        return [
            "removed_entries": .number(Double(cleared.removedEntries)),
            "removed_bytes": .number(Double(cleared.removedBytes)),
            "metal_shader_cache_cleared_at_next_launch": .bool(cleared.metalCacheResetRequested),
            "message": .string("Removed \(cleared.removedEntries) \(cleared.removedEntries == 1 ? "cache entry" : "cache entries") (\(freed)); what the wallpapers on screen use was kept."
                                + (cleared.metalCacheResetRequested ? " The GPU shader cache is cleared at the next launch." : "")),
        ]
    }

    // MARK: - Helpers

    private static func requireConfirmation(_ params: ControlParameters, _ action: String) throws {
        guard try params.bool("confirm") == true else {
            throw ControlError(.refused, "\(action) can't be undone from here: ask the user, then pass confirm: true.")
        }
    }

    /// Wallpapers matched by folder, the way the app keys them.
    private static func key(_ wallpaper: ControlWallpaper) -> String {
        wallpaper.folder.standardizedFileURL.path
    }

    /// `wallpapers` without repeats, in order.
    private func unique(_ wallpapers: [ControlWallpaper]) -> [ControlWallpaper] {
        var seen = Set<String>()
        return wallpapers.filter { seen.insert(Self.key($0)).inserted }
    }

    private static func count(_ number: Int, _ singular: String) -> String {
        "\(number) \(number == 1 ? singular : singular + "s")"
    }

    private static func text(_ value: JSONValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "on" : "off"
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        case .string(let text): return text
        default: return "not set"
        }
    }
}
