import Foundation
import OWEControlProtocol

/// Answers the control channel's requests (`docs/mcp.md`): checks each request's parameters,
/// finds the wallpapers, displays and playlists it names, asks `model` and writes the result as
/// JSON. A request that can't be done is answered with a `ControlError` whose message says why and
/// what to ask instead.
@MainActor
final class ControlRequestRouter {
    static let defaultLimit = 50
    static let maxLimit = 500

    private let model: ControlAppModel
    /// The other areas' requests: the scene and its editors, the library, the system features.
    private let groups: [ControlRequestGroup]
    private var lookup: ControlLookup { ControlLookup(model: model) }

    init(model: ControlAppModel, groups: [ControlRequestGroup] = []) {
        self.model = model
        self.groups = groups
    }

    func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return ControlResponse(id: request.id, result: try await result(for: request.method, ControlParameters(request.params)))
        } catch let error as ControlError {
            return ControlResponse(id: request.id, error: error)
        } catch {
            OWELog.error(.app, "MCP: \(request.method) failed: \(error)")
            return ControlResponse(id: request.id, error: ControlError(.failed, error.localizedDescription))
        }
    }

    private func result(for method: String, _ params: ControlParameters) async throws -> JSONValue {
        switch method {
        case "list_displays": return ["displays": .array(model.displays().map(json))]
        case "get_status": return try status(params)
        case "list_wallpapers": return try listWallpapers(params)
        case "get_wallpaper": return try getWallpaper(params)
        case "set_wallpaper": return try setWallpaper(params)
        case "pause", "resume", "toggle_playback", "stop": return playback(method)
        case "set_volume": return try setVolume(params)
        case "set_muted": return try setMuted(params)
        case "set_user_property": return try setUserProperty(params)
        case "list_playlists": return ["playlists": .array(model.playlists().map(json))]
        case "play_playlist": return try playPlaylist(params)
        case "next_wallpaper", "previous_wallpaper": return try step(params, forward: method == "next_wallpaper")
        case "import_wallpaper": return try await importWallpaper(params)
        case "open_editor": return try openEditor(params)
        case "snapshot": return try await snapshot(params)
        default:
            if let group = groups.first(where: { $0.methods.contains(method) }) {
                return try await group.result(for: method, params, lookup: lookup)
            }
            throw ControlError(.unknownMethod, "The app doesn't know \"\(method)\". Update Open Wallpaper Engine or the MCP Server plugin.")
        }
    }

    // MARK: - Library and displays

    private func status(_ params: ControlParameters) throws -> JSONValue {
        let displays = try targetDisplays(params)
        let playback = model.playback
        let active = model.playlists().first(where: \.isActive)
        return [
            "displays": .array(displays.map { display in
                var item = json(display)
                if case .object(var object) = item {
                    object["playing"] = .bool(!playback.paused && !playback.stopped && display.isEnabled
                                              && ["run", "mute"].contains(display.rule))
                    item = .object(object)
                }
                return item
            }),
            "paused": .bool(playback.paused),
            "stopped": .bool(playback.stopped),
            "volume": .number(playback.volume),
            "muted": .bool(playback.volume == 0),
            "playlist": active.map(json) ?? .null,
        ]
    }

    private func listWallpapers(_ params: ControlParameters) throws -> JSONValue {
        let query = try params.string("query")?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let type = try params.string("type")?.lowercased()
        let tags = try params.strings("tags").map { $0.lowercased() }
        let limit = min(try params.int("limit") ?? Self.defaultLimit, Self.maxLimit)
        let offset = try params.int("offset") ?? 0
        guard limit >= 1, offset >= 0 else { throw ControlError(.invalidParams, "limit must be at least 1 and offset at least 0.") }
        let words = query.split(separator: " ").map(String.init)
        let matches = model.wallpapers().filter { wallpaper in
            if let type, wallpaper.type.lowercased() != type { return false }
            let ownTags = Set(wallpaper.tags.map { $0.lowercased() })
            guard tags.allSatisfy(ownTags.contains) else { return false }
            let text = ([wallpaper.title, wallpaper.id, wallpaper.description ?? ""] + wallpaper.tags).joined(separator: " ")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let page = matches.dropFirst(offset).prefix(limit)
        return [
            "total": .number(Double(matches.count)),
            "offset": .number(Double(offset)),
            "limit": .number(Double(limit)),
            "wallpapers": .array(page.map { json($0) }),
        ]
    }

    private func getWallpaper(_ params: ControlParameters) throws -> JSONValue {
        let wallpaper = try findWallpaper(params.required("id"))
        guard case .object(var object) = json(wallpaper, detailed: true) else { return .null }
        object["displays"] = .array(model.displays().filter { model.wallpaper(onDisplay: $0.id)?.folder == wallpaper.folder }
            .map { .string($0.id) })
        object["properties"] = .array(model.properties(of: wallpaper).map(json))
        return ["wallpaper": .object(object)]
    }

    private func setWallpaper(_ params: ControlParameters) throws -> JSONValue {
        let wallpaper = try findWallpaper(params.required("id"))
        let displays = try targetDisplays(params).map(\.id)
        try model.setWallpaper(wallpaper, displays: displays)
        return ["wallpaper": json(wallpaper), "displays": .array(displays.map { .string($0) })]
    }

    private func importWallpaper(_ params: ControlParameters) async throws -> JSONValue {
        let path = (try params.required("path") as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ControlError(.invalidParams, "path must be an absolute path.") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ControlError(.notFound, "Nothing at \(url.path).")
        }
        let result = try await model.importWallpapers(at: url)
        return [
            "imported": .array(result.imported.map { json($0) }),
            "skipped": .array(result.skipped.map { ["path": .string($0.path), "reason": .string($0.reason)] }),
        ]
    }

    private func snapshot(_ params: ControlParameters) async throws -> JSONValue {
        let display = try params.string("display").map(findDisplay)
            ?? model.displays().first(where: \.isMain) ?? model.displays().first
        guard let display else { throw ControlError(.unavailable, "There is no display.") }
        let picture = try await model.snapshot(display: display.id)
        return [
            "display": .string(picture.display),
            "wallpaper": picture.wallpaper.map { json($0) } ?? .null,
            "source": .string(picture.source),
            "width": .number(Double(picture.width)),
            "height": .number(Double(picture.height)),
            "png_base64": .string(picture.png.base64EncodedString()),
        ]
    }

    // MARK: - Playback

    /// Pause, Resume (which ends a stop too), Stop, and the toggle: playing pauses, paused or
    /// stopped resumes.
    private func playback(_ method: String) -> JSONValue {
        switch method {
        case "stop": model.stop()
        case "pause": model.setPaused(true)
        case "resume": model.setPaused(false)
        default: model.setPaused(!(model.playback.paused || model.playback.stopped))
        }
        return ["paused": .bool(model.playback.paused), "stopped": .bool(model.playback.stopped)]
    }

    private func setVolume(_ params: ControlParameters) throws -> JSONValue {
        guard let level = try params.double("level"), (0...1).contains(level) else {
            throw ControlError(.invalidParams, "level must be a number from 0 to 1.")
        }
        model.setVolume(level)
        return volume()
    }

    private func setMuted(_ params: ControlParameters) throws -> JSONValue {
        guard let muted = try params.bool("muted") else { throw ControlError(.invalidParams, "muted must be true or false.") }
        model.setMuted(muted)
        return volume()
    }

    private func volume() -> JSONValue {
        let volume = model.playback.volume
        return ["volume": .number(volume), "muted": .bool(volume == 0)]
    }

    private func step(_ params: ControlParameters, forward: Bool) throws -> JSONValue {
        let displays = try targetDisplays(params).map(\.id)
        let shown = model.step(forward: forward, displays: displays)
        return ["displays": .array(displays.map { id in
            ["id": .string(id), "wallpaper": (shown[id] ?? nil).map { json($0) } ?? .null]
        })]
    }

    // MARK: - User properties and playlists

    private func setUserProperty(_ params: ControlParameters) throws -> JSONValue {
        let wallpaper = try findWallpaper(params.required("id"))
        let key = try params.required("key")
        guard let value = params.raw["value"] else { throw ControlError(.invalidParams, "value is required.") }
        let properties = model.properties(of: wallpaper)
        guard let property = properties.first(where: { $0.key == key }) else {
            let keys = properties.filter { !["text", "group", ""].contains($0.type) }.map(\.key).sorted().joined(separator: ", ")
            throw ControlError(.notFound, "\"\(wallpaper.title)\" has no user property \"\(key)\". "
                               + (keys.isEmpty ? "It has none to set." : "Its properties: \(keys)."))
        }
        let stored = try ControlUserPropertyValue.stored(value, for: property)
        let stores = model.setUserProperty(key, to: stored, of: wallpaper)
        return [
            "id": .string(wallpaper.id), "title": .string(wallpaper.title), "key": .string(key),
            "value": .string(stored), "stores": .array(stores.map { .string($0) }),
        ]
    }

    private func playPlaylist(_ params: ControlParameters) throws -> JSONValue {
        let name = try params.required("name")
        let playlists = model.playlists()
        guard let playlist = playlists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? playlists.first(where: { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame }) else {
            let names = playlists.map { "\"\($0.name)\"" }.joined(separator: ", ")
            throw ControlError(.notFound, "No playlist named \"\(name)\". " + (names.isEmpty ? "There are no playlists." : "Playlists: \(names)."))
        }
        guard !playlist.wallpapers.isEmpty else {
            throw ControlError(.unsupported, "The playlist \"\(playlist.name)\" is empty.")
        }
        let displays = try targetDisplays(params).map(\.id)
        model.playPlaylist(playlist, displays: displays)
        return ["playlist": .string(playlist.name), "displays": .array(displays.map { .string($0) })]
    }

    private func openEditor(_ params: ControlParameters) throws -> JSONValue {
        let wallpaper = try findWallpaper(params.required("id"))
        guard let editor = ControlEditor(rawValue: try params.required("editor")) else {
            throw ControlError(.invalidParams, "editor must be \"scene\" or \"wallpaper\".")
        }
        guard wallpaper.type.lowercased() == "scene" else {
            throw ControlError(.unsupported, "\"\(wallpaper.title)\" is a \(wallpaper.type) wallpaper; both editors edit scene wallpapers only.")
        }
        try model.openEditor(editor, for: wallpaper)
        return ["id": .string(wallpaper.id), "title": .string(wallpaper.title), "editor": .string(editor.rawValue)]
    }

    // MARK: - Lookups

    private func findWallpaper(_ id: String) throws -> ControlWallpaper { try lookup.wallpaper(id) }

    private func findDisplay(_ id: String) throws -> ControlDisplay { try lookup.display(id) }

    private func targetDisplays(_ params: ControlParameters) throws -> [ControlDisplay] { try lookup.targetDisplays(params) }

    // MARK: - JSON

    private func json(_ display: ControlDisplay) -> JSONValue {
        [
            "id": .string(display.id), "name": .string(display.name), "main": .bool(display.isMain),
            "enabled": .bool(display.isEnabled), "width": .number(Double(display.width)),
            "height": .number(Double(display.height)), "scale": .number(display.scale),
            "rule": .string(display.rule),
            "wallpaper": model.wallpaper(onDisplay: display.id).map { json($0) } ?? .null,
        ]
    }

    private func json(_ wallpaper: ControlWallpaper, detailed: Bool = false) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(wallpaper.id), "title": .string(wallpaper.title), "type": .string(wallpaper.type),
            "tags": .array(wallpaper.tags.map { .string($0) }), "folder": .string(wallpaper.folder.path),
            "workshop_id": wallpaper.workshopID.map { .string($0) } ?? .null,
        ]
        if detailed {
            object["description"] = wallpaper.description.map { .string($0) } ?? .null
            object["content_rating"] = wallpaper.contentRating.map { .string($0) } ?? .null
        }
        return .object(object)
    }

    private func json(_ property: ControlUserProperty) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(property.key), "title": .string(property.title), "type": .string(property.type),
            "value": .string(property.value), "default": .string(property.defaultValue),
            "condition": property.condition.map { .string($0) } ?? .null,
        ]
        if property.type == "slider" {
            object["min"] = .number(property.minimum)
            object["max"] = .number(property.maximum)
            object["step"] = property.step.map { .number($0) } ?? .null
            object["whole_numbers"] = .bool(!property.fraction)
        }
        if property.type == "combo" {
            object["options"] = .array(property.options.map { ["label": .string($0.label), "value": .string($0.value)] })
            object["free_text"] = .bool(property.editable)
        }
        return .object(object)
    }

    private func json(_ playlist: ControlPlaylist) -> JSONValue {
        [
            "id": .string(playlist.id.uuidString), "name": .string(playlist.name),
            "active": .bool(playlist.isActive), "rotating": .bool(playlist.isRotating),
            "shuffle": .bool(playlist.shuffles), "duration_seconds": .number(playlist.duration),
            "displays": .array(playlist.displays.map { .string($0) }),
            "wallpapers": .array(playlist.wallpapers.map { ["id": .string($0.id), "title": .string($0.title), "type": .string($0.type)] }),
        ]
    }
}

