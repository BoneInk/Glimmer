import Foundation
import OWEControlProtocol

/// The tools `owe-mcp` offers, grouped by area (the scene and editors, the library, the system
/// features in their own files). Nothing here touches Steam accounts, logins, Workshop
/// subscriptions, plugins or anything outside the app's own data; a tool that deletes needs
/// `confirm: true`.
public enum MCPToolCatalog {
    public static let tools: [MCPTool] = library + playback + properties + playlists + windows
        + sceneTools + libraryTools + systemTools

    public static func tool(named name: String) -> MCPTool? {
        tools.first { $0.name == name }
    }

    static let display = JSONSchema.string(
        "A display's id from list_displays. Omit it for every display.", minLength: 1)
    static let wallpaperID = JSONSchema.string(
        "A wallpaper's id from list_wallpapers (its folder name; a folder path also works).", minLength: 1)

    // MARK: - Library and displays

    private static let library: [MCPTool] = [
        MCPTool("list_displays", title: "List Displays",
                description: "Lists the connected displays with their ids, names, sizes, whether wallpapers are shown on them and the wallpaper each shows.",
                annotations: .readOnly) { result in
            let displays = result["displays"]?.arrayValue ?? []
            return count(displays.count, "display") + ": "
                + displays.map { "\($0["name"]?.stringValue ?? "?") (\($0["id"]?.stringValue ?? "?"))" }.joined(separator: ", ")
        },
        MCPTool("get_status", title: "Get Status",
                description: "What each display shows (wallpaper id, title and type), whether wallpapers are playing, paused or stopped, the volume and mute, and the active playlist if any.",
                input: JSONSchema.object(["display": display]), annotations: .readOnly) { result in
            let displays = (result["displays"]?.arrayValue ?? []).map { item in
                "\(item["name"]?.stringValue ?? "?"): \(wallpaperName(item["wallpaper"]))"
            }
            let state = result["stopped"]?.boolValue == true ? "stopped"
                : result["paused"]?.boolValue == true ? "paused" : "playing"
            let sound = result["muted"]?.boolValue == true
                ? "muted" : "volume \(Int(((result["volume"]?.doubleValue ?? 0) * 100).rounded()))%"
            var text = "Wallpapers are \(state), \(sound). " + displays.joined(separator: "; ") + "."
            if let playlist = result["playlist"]?["name"]?.stringValue { text += " Playlist: \(playlist)." }
            return text
        },
        MCPTool("list_wallpapers", title: "List Wallpapers",
                description: "Searches the wallpaper library (the Installed tab, without its filters). Matches the query against titles, tags and descriptions; filters by type and tags; pages with limit and offset. Returns each wallpaper's id, title, type, tags, folder and Workshop id.",
                input: JSONSchema.object([
                    "query": JSONSchema.string("Words to find in the title, tags or description."),
                    "type": JSONSchema.string("Only wallpapers of this type.", oneOf: ["scene", "video", "web", "application"]),
                    "tags": JSONSchema.stringArray("Only wallpapers with every one of these tags (case-insensitive).", maxItems: 20),
                    "limit": JSONSchema.integer("How many to return, 50 by default.", minimum: 1, maximum: 500),
                    "offset": JSONSchema.integer("How many matches to skip.", minimum: 0),
                ]), annotations: .readOnly) { result in
            let wallpapers = result["wallpapers"]?.arrayValue ?? []
            let total = result["total"]?.intValue ?? wallpapers.count
            let offset = result["offset"]?.intValue ?? 0
            guard !wallpapers.isEmpty else { return "No wallpapers match (\(total) in all)." }
            return "Wallpapers \(offset + 1)–\(offset + wallpapers.count) of \(total) matches: "
                + wallpapers.prefix(10).map { wallpaperName($0) }.joined(separator: ", ")
                + (wallpapers.count > 10 ? ", …" : "")
        },
        MCPTool("get_wallpaper", title: "Get Wallpaper",
                description: "A wallpaper's details: title, type, tags, folder, Workshop id, description, the displays showing it, and its user properties with their types, current values, defaults, ranges and options (the values set_user_property takes).",
                input: JSONSchema.object(["id": wallpaperID], required: ["id"]), annotations: .readOnly) { result in
            let wallpaper = result["wallpaper"]
            let properties = wallpaper?["properties"]?.arrayValue ?? []
            return "\(wallpaperName(wallpaper)) with \(count(properties.count, "user property", plural: "user properties"))."
        },
        MCPTool("set_wallpaper", title: "Set Wallpaper",
                description: "Shows a wallpaper on one display, or on every display when display is omitted, as applying it in the library does. Web wallpapers must have been trusted in the app once.",
                input: JSONSchema.object(["id": wallpaperID, "display": display], required: ["id"]),
                annotations: .idempotent) { result in
            "Now showing \(wallpaperName(result["wallpaper"])) on \(displayList(result["displays"]))."
        },
        MCPTool("import_wallpaper", title: "Import Wallpaper",
                description: "Imports wallpapers into the library from a folder on this Mac, as the Import button does: a wallpaper folder (with project.json), a folder of wallpaper folders, or a .zip. Folders already in the library are skipped.",
                input: JSONSchema.object([
                    "path": JSONSchema.string("The absolute path of the folder or .zip to import.", minLength: 1),
                ], required: ["path"]), annotations: .change) { result in
            let imported = result["imported"]?.arrayValue ?? []
            let skipped = result["skipped"]?.arrayValue ?? []
            var text = "Imported \(count(imported.count, "wallpaper"))"
            if !imported.isEmpty { text += ": " + imported.compactMap { $0["id"]?.stringValue }.joined(separator: ", ") }
            if !skipped.isEmpty { text += "; skipped \(skipped.count)" }
            return text + "."
        },
        MCPTool("snapshot", title: "Snapshot",
                description: "A PNG picture of the wallpaper a display shows (the main display when omitted), at most 960 pixels wide: the scene's frame, a video's current frame, or the wallpaper's preview when no frame is available. The result says which.",
                input: JSONSchema.object([
                    "display": JSONSchema.string("A display's id from list_displays. Omit it for the main display.", minLength: 1),
                    "format": JSONSchema.string("\"image\" (the default) returns the PNG as image content; \"path\" saves it to a temporary file and returns its path, for clients that can't show images.", oneOf: ["image", "path"]),
                ]),
                annotations: .readOnly, returnsImage: true) { result in
            let size = "\(result["width"]?.intValue ?? 0)×\(result["height"]?.intValue ?? 0)"
            let source = result["source"]?.stringValue?.replacingOccurrences(of: "_", with: " ") ?? "picture"
            return "\(wallpaperName(result["wallpaper"])) on display \(result["display"]?.stringValue ?? "?"): \(source), \(size)."
        },
    ]

    // MARK: - Playback

    private static let playback: [MCPTool] = [
        MCPTool("pause", title: "Pause",
                description: "Pauses every wallpaper, as Pause in the menu bar does. Playback is app-wide in Open Wallpaper Engine.",
                annotations: .idempotent) { _ in "Wallpapers are paused." },
        MCPTool("resume", title: "Resume",
                description: "Resumes every wallpaper, as Resume in the menu bar does: unpauses them, and loads them again when they are stopped.",
                annotations: .idempotent) { _ in "Wallpapers are playing." },
        MCPTool("stop", title: "Stop",
                description: "Stops every wallpaper, as Stop Wallpapers in the menu bar does: unloads them, freeing their CPU, GPU and memory, and shows the macOS desktop picture until resume. Each display keeps its wallpaper, which resume loads again.",
                annotations: .idempotent) { _ in "Wallpapers are stopped." },
        MCPTool("toggle_playback", title: "Toggle Playback",
                description: "Pauses the wallpapers when they play, resumes them when paused or stopped.",
                annotations: .change) { result in
            result["paused"]?.boolValue == true ? "Wallpapers are paused." : "Wallpapers are playing."
        },
        MCPTool("set_volume", title: "Set Volume",
                description: "Sets the wallpapers' volume, from 0 (silent) to 1 (full). Volume is app-wide in Open Wallpaper Engine.",
                input: JSONSchema.object(["level": JSONSchema.number("The volume, 0 to 1.", minimum: 0, maximum: 1)],
                                         required: ["level"]),
                annotations: .idempotent) { result in
            "Volume is \(Int(((result["volume"]?.doubleValue ?? 0) * 100).rounded()))%."
        },
        MCPTool("set_muted", title: "Set Muted",
                description: "Mutes or unmutes the wallpapers, as Mute and Unmute in the menu bar do; unmuting brings back the volume from before.",
                input: JSONSchema.object(["muted": JSONSchema.boolean("true to mute, false to unmute.")], required: ["muted"]),
                annotations: .idempotent) { result in
            result["muted"]?.boolValue == true ? "Wallpapers are muted."
                : "Wallpapers are unmuted, volume \(Int(((result["volume"]?.doubleValue ?? 0) * 100).rounded()))%."
        },
        MCPTool("next_wallpaper", title: "Next Wallpaper",
                description: "The next wallpaper on a display (every display when omitted): the next item of the active playlist when one is playing there, else a random wallpaper from the library, as Next Wallpaper in the menu does.",
                input: JSONSchema.object(["display": display]), annotations: .change) { result in
            "Now showing " + changes(result) + "."
        },
        MCPTool("previous_wallpaper", title: "Previous Wallpaper",
                description: "The previous wallpaper on a display (every display when omitted): the playlist's previous item, else the wallpaper shown before, as Previous Wallpaper in the menu does.",
                input: JSONSchema.object(["display": display]), annotations: .change) { result in
            "Now showing " + changes(result) + "."
        },
    ]

    // MARK: - User properties

    private static let properties: [MCPTool] = [
        MCPTool("set_user_property", title: "Set User Property",
                description: "Changes one of a wallpaper's user properties, as its Details panel does, and applies it at once on the displays showing it. The value is checked against the property's type: a number within a slider's range, true or false for a checkbox, one of a combo's option values, a colour as \"r g b\" with each 0 to 1 (or #rrggbb), or text. get_wallpaper lists the properties.",
                input: JSONSchema.object([
                    "id": wallpaperID,
                    "key": JSONSchema.string("The property's key, from get_wallpaper.", minLength: 1),
                    "value": JSONSchema.string("The new value as text: a number for a slider, true or false for a checkbox, a combo's option value, a colour as \"r g b\" or #rrggbb, or text. A JSON number or boolean is accepted too."),
                ], required: ["id", "key", "value"]), annotations: .idempotent) { result in
            "Set \(result["key"]?.stringValue ?? "the property") of \(result["title"]?.stringValue ?? "the wallpaper") to \(result["value"]?.stringValue ?? "the value")."
        },
    ]

    // MARK: - Playlists

    private static let playlists: [MCPTool] = [
        MCPTool("list_playlists", title: "List Playlists",
                description: "Lists the playlists with their wallpapers, how long each wallpaper shows, and which one is active and rotating.",
                annotations: .readOnly) { result in
            let playlists = result["playlists"]?.arrayValue ?? []
            guard !playlists.isEmpty else { return "There are no playlists." }
            return count(playlists.count, "playlist") + ": " + playlists.map { playlist in
                let name = playlist["name"]?.stringValue ?? "?"
                return playlist["active"]?.boolValue == true ? "\(name) (active)" : name
            }.joined(separator: ", ")
        },
        MCPTool("play_playlist", title: "Play Playlist",
                description: "Makes a playlist active and starts rotating it on a display (every display when omitted), as its shortcut does. Names match case-insensitively.",
                input: JSONSchema.object([
                    "name": JSONSchema.string("The playlist's name, from list_playlists.", minLength: 1),
                    "display": display,
                ], required: ["name"]), annotations: .idempotent) { result in
            "Playing \(result["playlist"]?.stringValue ?? "the playlist") on \(displayList(result["displays"]))."
        },
    ]

    // MARK: - Windows

    private static let windows: [MCPTool] = [
        MCPTool("open_editor", title: "Open Editor",
                description: "Opens a scene wallpaper in Scene Edit / Export (\"scene\") or the Wallpaper Editor (\"wallpaper\") on this Mac, for the user to edit.",
                input: JSONSchema.object([
                    "id": wallpaperID,
                    "editor": JSONSchema.string("Which editor.", oneOf: ["scene", "wallpaper"]),
                ], required: ["id", "editor"]), annotations: .idempotent) { result in
            let editor = result["editor"]?.stringValue == "scene" ? "Scene Edit / Export" : "the Wallpaper Editor"
            return "Opened \(result["title"]?.stringValue ?? "the wallpaper") in \(editor)."
        },
    ]

    // MARK: - Summaries

    /// The sentence the app wrote in the result's `message`, which the newer tools all carry.
    static func message(_ result: JSONValue) -> String {
        result["message"]?.stringValue ?? "Done."
    }

    static func wallpaperName(_ wallpaper: JSONValue?) -> String {
        guard let wallpaper, !wallpaper.isNull else { return "no wallpaper" }
        let title = wallpaper["title"]?.stringValue ?? wallpaper["id"]?.stringValue ?? "?"
        guard let type = wallpaper["type"]?.stringValue else { return "\"\(title)\"" }
        return "\"\(title)\" (\(type))"
    }

    static func displayList(_ displays: JSONValue?) -> String {
        let ids = displays?.arrayValue?.compactMap { $0.stringValue ?? $0["id"]?.stringValue } ?? []
        switch ids.count {
        case 0: return "no display"
        case 1: return "display \(ids[0])"
        default: return "displays " + ids.joined(separator: ", ")
        }
    }

    private static func changes(_ result: JSONValue) -> String {
        let displays = result["displays"]?.arrayValue ?? []
        guard !displays.isEmpty else { return "the same wallpapers (nothing to step to)" }
        return displays.map { "\(wallpaperName($0["wallpaper"])) on display \($0["id"]?.stringValue ?? "?")" }
            .joined(separator: ", ")
    }

    static func count(_ number: Int, _ singular: String, plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : plural ?? singular + "s")"
    }
}
