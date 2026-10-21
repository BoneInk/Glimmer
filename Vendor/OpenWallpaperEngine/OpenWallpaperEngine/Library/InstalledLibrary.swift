//
//  InstalledLibrary.swift
//  Open Wallpaper Engine
//
//  What the Installed tab lists, decided the way WE does: only wallpapers (project.json `type` of
//  scene, video, web or application, or a `preset` of one, `WorkshopPresetItem`) the user got themselves. Workshop items that aren't
//  wallpapers (asset packs, effects and other `"category": "Asset"` items, which have no `type`)
//  and items downloaded only as another wallpaper's dependency stay on disk but aren't listed.
//

import Foundation

enum InstalledLibrary {
    static let wallpaperTypes: Set<String> = ["scene", "video", "web", "application"]

    /// The listed wallpapers among the folders in `directory`.
    static func wallpapers(in directory: URL, hiding dependencyIds: Set<String>) -> [WEWallpaper] {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: ContainedPath.followingFolderLink(directory), includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
        } catch {
            OWELog.error(.library, "Can't list the wallpaper library at \(directory.path): \(error)")
            return []
        }
        return folders.compactMap { wallpaper(at: $0, hiding: dependencyIds) }
    }

    /// The folder's wallpaper, or nil when it isn't listed. A folder whose project.json is missing or
    /// unreadable is still listed, as an invalid entry the user can see and delete.
    static func wallpaper(at folder: URL, hiding dependencyIds: Set<String>) -> WEWallpaper? {
        guard !dependencyIds.contains(folder.lastPathComponent) else { return nil }
        // A wallpaper is a folder: a stray file in the library (a log, a crash or profile dump) isn't one.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        // A folder without project.json is shown as invalid below, so a failed read is expected.
        guard let data = try? WEProject.data(in: folder) else {
            return WEWallpaper(using: .invalid, where: folder)
        }
        if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], WorkshopPresetItem.isPreset(root) {
            return WorkshopPresetItem.wallpaper(presetAt: folder, projectJSON: root, roots: [folder.deletingLastPathComponent()])
        }
        guard isWallpaperProject(data) != false else { return nil }
        do {
            var project = try JSONDecoder().decode(WEProject.self, from: data)
            project.applyTaggedContentRating()
            return WEWallpaper(using: project, where: folder)
        } catch {
            OWELog.debug(.library, "\(folder.lastPathComponent)/project.json doesn't decode: \(error)")
            return WEWallpaper(using: .invalid, where: folder)
        }
    }

    /// Whether project.json declares a wallpaper type; nil when it isn't a JSON object.
    static func isWallpaperProject(_ projectData: Data) -> Bool? {
        // Not JSON: reported as nil so the caller keeps the folder visible as invalid.
        guard let object = try? JSONSerialization.jsonObject(with: projectData),
              let project = object as? [String: Any] else { return nil }
        guard let type = project["type"] as? String else { return false }
        return wallpaperTypes.contains(type.lowercased())
    }
}
