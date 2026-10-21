import Foundation
import OWEControlProtocol

/// One area of the control channel's requests (the scene and its editors, the library, the
/// system features), answered for `ControlRequestRouter`. Each group checks its own parameters
/// and drives the app through the code its UI uses; a request it can't do is a `ControlError`
/// saying why and what to ask instead.
@MainActor
protocol ControlRequestGroup: AnyObject {
    /// The request methods (tool names) it answers.
    var methods: Set<String> { get }
    func result(for method: String, _ params: ControlParameters, lookup: ControlLookup) async throws -> JSONValue
}

/// Finding what a request names: wallpapers, displays and playlists, as `ControlAppModel` lists
/// them, with the error a client reads when there is no such thing.
@MainActor
struct ControlLookup {
    let model: ControlAppModel

    /// A wallpaper by its folder name, its Workshop id or its folder's path.
    func wallpaper(_ id: String) throws -> ControlWallpaper {
        let wallpapers = model.wallpapers()
        let path = URL(fileURLWithPath: (id as NSString).expandingTildeInPath).standardizedFileURL.path
        if let found = wallpapers.first(where: { $0.id == id })
            ?? wallpapers.first(where: { $0.workshopID == id })
            ?? wallpapers.first(where: { $0.folder.standardizedFileURL.path == path }) {
            return found
        }
        throw ControlError(.notFound, "No wallpaper with the id \"\(id)\" in the library. list_wallpapers lists them.")
    }

    /// A scene wallpaper; both editors edit scenes only.
    func sceneWallpaper(_ id: String) throws -> ControlWallpaper {
        let wallpaper = try wallpaper(id)
        guard wallpaper.type.lowercased() == "scene" else {
            throw ControlError(.unsupported, "\"\(wallpaper.title)\" is a \(wallpaper.type) wallpaper; only scene wallpapers have layers to edit.")
        }
        return wallpaper
    }

    func display(_ id: String) throws -> ControlDisplay {
        let displays = model.displays()
        if let display = displays.first(where: { $0.id == id || $0.name.caseInsensitiveCompare(id) == .orderedSame }) {
            return display
        }
        let known = displays.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
        throw ControlError(.notFound, "No display \"\(id)\". Displays: \(known).")
    }

    /// The display the request names, or every display wallpapers are shown on.
    func targetDisplays(_ params: ControlParameters) throws -> [ControlDisplay] {
        if let id = try params.string("display") { return [try display(id)] }
        let displays = model.displays()
        let enabled = displays.filter(\.isEnabled)
        return enabled.isEmpty ? displays : enabled
    }

    /// A playlist by its name (case-insensitive) or id.
    func playlist(_ name: String) throws -> ControlPlaylist {
        let playlists = model.playlists()
        if let playlist = playlists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? playlists.first(where: { $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame }) {
            return playlist
        }
        let names = playlists.map { "\"\($0.name)\"" }.joined(separator: ", ")
        throw ControlError(.notFound, "No playlist named \"\(name)\". " + (names.isEmpty ? "There are no playlists." : "Playlists: \(names)."))
    }

    /// The wallpaper as the results write it: id, title, type, tags, folder and Workshop id.
    static func json(_ wallpaper: ControlWallpaper) -> JSONValue {
        [
            "id": .string(wallpaper.id), "title": .string(wallpaper.title), "type": .string(wallpaper.type),
            "tags": .array(wallpaper.tags.map { .string($0) }), "folder": .string(wallpaper.folder.path),
            "workshop_id": wallpaper.workshopID.map { .string($0) } ?? .null,
        ]
    }
}
