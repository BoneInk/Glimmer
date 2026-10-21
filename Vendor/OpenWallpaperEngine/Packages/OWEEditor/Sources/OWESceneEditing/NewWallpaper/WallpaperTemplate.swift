import Foundation
import WEFormat

/// A Wallpaper Engine project template (`projects/templates/<name>` of the user's WE copy, or the
/// assets cache's `templates`): `template.json` names it (`name`, `preview`, `type`), and
/// project.json's `templateoptions` say what its Template Wizard asks for: each `replacetexture`
/// option is a picture the user picks, copied to `destination`, the scene's size following it
/// when `adjustprojection` is set. Only 2D scene templates are offered (`scene2d`; WE's
/// application templates aren't).
public struct WallpaperTemplate: Hashable, Sendable, Identifiable {
    public struct Option: Hashable, Sendable {
        /// The file the picked picture replaces, inside the template (`materials/flag.png`).
        public var destination: String
        /// As authored (WE's templates write English).
        public var name: String
        public var description: String
        /// The scene's size becomes the picture's.
        public var adjustsProjection: Bool
        /// Only an animated picture (a GIF) fits it.
        public var animatedOnly: Bool
    }

    public var folder: URL
    public var name: String
    public var preview: URL?
    /// The project's scene file (`scene.json`, `gifscene.json`).
    public var sceneFile: String
    public var options: [Option]

    public var id: URL { folder }

    /// The 2D scene templates in `directory`'s subfolders, by name. A folder without a readable
    /// template.json and project.json isn't one.
    public static func templates(in directory: URL, fileManager: FileManager = .default) -> [WallpaperTemplate] {
        // No templates folder: nothing to offer.
        guard let folders = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                 options: .skipsHiddenFiles) else { return [] }
        return folders.compactMap { read($0, fileManager: fileManager) }.sorted { $0.name < $1.name }
    }

    /// The template in `folder`, or nil when it isn't a 2D scene template (an unreadable file is
    /// no template: the list just leaves it out).
    public static func read(_ folder: URL, fileManager: FileManager = .default) -> WallpaperTemplate? {
        guard let templateData = fileManager.contents(atPath: folder.appending(path: "template.json").path),
              let projectData = fileManager.contents(atPath: WEProjectFile.url(in: folder).path),
              let template = EditorLog.attempt("Template \(folder.lastPathComponent): template.json", { try TolerantJSON.object(from: templateData) }) as? [String: Any],
              let project = EditorLog.attempt("Template \(folder.lastPathComponent): project.json", { try TolerantJSON.object(from: projectData) }) as? [String: Any],
              (template["type"] as? String)?.lowercased() == "scene2d",
              let sceneFile = project["file"] as? String,
              fileManager.fileExists(atPath: folder.appending(path: sceneFile).path) else { return nil }
        let options = (project["templateoptions"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
            guard option["type"] as? String == "replacetexture", let destination = option["destination"] as? String,
                  (try? LocalWallpaperWriter.contained(destination, in: folder)) != nil else { return nil }
            let parameters = option["parameters"] as? [String: Any]
            return Option(destination: destination, name: option["name"] as? String ?? destination,
                          description: option["description"] as? String ?? "",
                          adjustsProjection: option["adjustprojection"] as? Bool ?? false,
                          animatedOnly: parameters?["animatedonly"] as? Bool ?? false)
        }
        let preview = (template["preview"] as? String).flatMap { try? LocalWallpaperWriter.contained($0, in: folder) }
        return WallpaperTemplate(folder: folder, name: template["name"] as? String ?? folder.lastPathComponent,
                                 preview: preview.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil },
                                 sceneFile: sceneFile, options: options)
    }
}
