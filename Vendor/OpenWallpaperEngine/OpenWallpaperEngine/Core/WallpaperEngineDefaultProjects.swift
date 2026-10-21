import Foundation

/// The default wallpapers a Wallpaper Engine install carries (`<install>/projects/defaultprojects`),
/// brought into the Wallpaper Storage folder with the assets so they show in the library like any
/// other wallpaper. Only scene, video and web projects come in: application wallpapers can't run.
enum WallpaperEngineDefaultProjects {
    struct ImportResult: Equatable {
        /// Folder names now in the storage folder.
        var imported: [String] = []
        /// Names the storage folder already had; left as they were.
        var existing: [String] = []
        /// Projects of a type the app can't play.
        var unsupported: [String] = []
    }

    static let supportedTypes: Set<String> = ["scene", "video", "web"]

    /// `projects/defaultprojects` of an install (or of the folder holding its `assets`).
    static func directory(inInstall install: URL, fileManager: FileManager = .default) -> URL? {
        var root = install.standardizedFileURL
        if root.lastPathComponent.caseInsensitiveCompare("assets") == .orderedSame { root.deleteLastPathComponent() }
        let folder = root.appending(path: "projects/defaultprojects", directoryHint: .isDirectory)
        return fileManager.fileExists(atPath: folder.path) ? folder : nil
    }

    /// The project's wallpaper type, lower-cased: its `type`, else the one its `file` implies.
    static func type(ofProjectAt folder: URL) throws -> String {
        let data = TolerantJSON.withoutBOM(try WEProject.data(in: folder))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let type = root["type"] as? String, !type.isEmpty { return type.lowercased() }
        return WEProject.impliedType(file: root["file"] as? String ?? "")
    }

    /// Moves (or copies) each supported project folder of `install` into `storage`, keeping its
    /// name and never replacing a folder that is already there.
    static func importProjects(from install: URL, into storage: URL, move: Bool,
                               fileManager: FileManager = .default) throws -> ImportResult {
        var result = ImportResult()
        guard let source = directory(inInstall: install, fileManager: fileManager) else { return result }
        let folders = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders where fileManager.fileExists(atPath: WEProject.url(in: folder).path) {
            let name = folder.lastPathComponent
            let type: String
            do {
                type = try Self.type(ofProjectAt: folder)
            } catch {
                OWELog.error(.library, "Default wallpaper \(name) skipped: its project.json doesn't read: \(error)")
                continue
            }
            guard supportedTypes.contains(type) else {
                OWELog.info(.library, "Default wallpaper \(name) skipped: type \(type.isEmpty ? "unknown" : type) isn't supported")
                result.unsupported.append(name)
                continue
            }
            let destination = storage.appending(path: name, directoryHint: .isDirectory)
            guard !fileManager.fileExists(atPath: destination.path) else {
                result.existing.append(name)
                continue
            }
            if move {
                try fileManager.moveItem(at: folder, to: destination)
            } else {
                try fileManager.copyItem(at: folder, to: destination)
            }
            result.imported.append(name)
        }
        return result
    }
}
