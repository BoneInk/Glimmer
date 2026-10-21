import Foundation
import OWEControlProtocol

/// `folders_list`, `folder_create` and `wallpaper_move_to_folder`: the Installed tab's folders
/// (`InstalledFolderTree`), changed as its Create Folder and Move to Folder commands change them.
extension LibraryControlRequests {
    func foldersList(_ lookup: ControlLookup) -> JSONValue {
        let tree = service.installedFolders
        let wallpapers = lookup.model.wallpapers()
        var byKey: [String: [ControlWallpaper]] = [:]
        for wallpaper in wallpapers { byKey[service.folderKey(of: wallpaper), default: []].append(wallpaper) }
        let filed = tree.filedKeys
        let topLevel = wallpapers.filter { !filed.contains(service.folderKey(of: $0)) }.count
        let total = tree.allFolders().count
        return [
            "folders": .array(InstalledFolderTree.sortedByTitle(tree.folders).map { json($0, path: $0.title, byKey: byKey) }),
            "top_level_wallpaper_count": .number(Double(topLevel)),
            "message": .string("\(total) \(total == 1 ? "folder" : "folders"); \(topLevel) \(topLevel == 1 ? "wallpaper is" : "wallpapers are") at the top level."),
        ]
    }

    func createFolder(_ params: ControlParameters) throws -> JSONValue {
        let name = try params.required("name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ControlError(.invalidParams, "name must not be blank.") }
        let parent = try folder(params.string("parent"))
        var created: UUID?
        service.changeInstalledFolders { created = $0.create(title: name, in: parent?.id) }
        guard let created, let folder = service.installedFolders.folder(created) else {
            throw ControlError(.failed, "The folder \"\(name)\" wasn't created.")
        }
        let path = service.installedFolders.path(to: created).map(\.title).joined(separator: " / ")
        return ["folder": json(folder, path: path, byKey: [:]),
                "message": .string("Created the folder \"\(path)\".")]
    }

    func moveToFolder(_ params: ControlParameters, _ lookup: ControlLookup) throws -> JSONValue {
        let ids = try params.strings("wallpaper_ids")
        guard !ids.isEmpty else { throw ControlError(.invalidParams, "wallpaper_ids must name at least one wallpaper.") }
        let wallpapers = try ids.map(lookup.wallpaper)
        let destination = try folder(params.string("folder"))
        let keys = wallpapers.map(service.folderKey(of:))
        service.changeInstalledFolders { $0.move(items: keys, to: destination?.id) }
        let path = destination.map { service.installedFolders.path(to: $0.id).map(\.title).joined(separator: " / ") }
        let what = wallpapers.count == 1 ? "\"\(wallpapers[0].title)\"" : "\(wallpapers.count) wallpapers"
        return [
            "folder": destination.map { JSONValue.string($0.id.uuidString) } ?? .null,
            "wallpapers": .array(wallpapers.map(ControlLookup.json)),
            "message": .string(path.map { "Moved \(what) to \"\($0)\"." } ?? "Moved \(what) to the top level."),
        ]
    }

    /// A folder by id or by its path of names ("Games/Retro", case-insensitive); nil for none or "".
    private func folder(_ reference: String?) throws -> InstalledFolder? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        let tree = service.installedFolders
        if let id = UUID(uuidString: reference), let folder = tree.folder(id) { return folder }
        let wanted = reference.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let matches = tree.allFolders().filter { entry in
            let path = tree.path(to: entry.folder.id).map(\.title)
            return path.count == wanted.count
                && zip(path, wanted).allSatisfy { $0.caseInsensitiveCompare($1) == .orderedSame }
        }
        guard let match = matches.first else {
            throw ControlError(.notFound, "No folder \"\(reference)\". folders_list lists them.")
        }
        guard matches.count == 1 else {
            throw ControlError(.invalidParams, "\(matches.count) folders are named \"\(reference)\"; pass the id from folders_list.")
        }
        return match.folder
    }

    private func json(_ folder: InstalledFolder, path: String, byKey: [String: [ControlWallpaper]]) -> JSONValue {
        let wallpapers = folder.items.sorted().flatMap { byKey[$0] ?? [] }
        return [
            "id": .string(folder.id.uuidString),
            "name": .string(folder.title),
            "path": .string(path),
            "color": folder.color.map { .string($0.controlName) } ?? .null,
            "icon": folder.icon.map { .string($0.systemImage) } ?? .null,
            "wallpaper_ids": .array(wallpapers.map { .string($0.id) }),
            "subfolders": .array(InstalledFolderTree.sortedByTitle(folder.subfolders).map {
                json($0, path: path + " / " + $0.title, byKey: byKey)
            }),
        ]
    }
}
