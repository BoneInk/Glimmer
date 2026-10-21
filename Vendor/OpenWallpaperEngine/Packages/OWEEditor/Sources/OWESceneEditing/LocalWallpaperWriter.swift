import Foundation
import WEFormat

/// Save as New Wallpaper: a new wallpaper folder in the library with the edits baked into its
/// scene.json. The source wallpaper (a Workshop item, usually) is only read.
public struct LocalWallpaperWriter {
    public struct Source {
        /// The wallpaper's folder.
        public var directory: URL
        /// project.json's `file`, e.g. `scene.json`.
        public var sceneFile: String
        /// The files of the wallpaper's `.pkg` by their path inside it, when the scene is packed;
        /// they are written as loose files and the package left out, as the app's own converter does.
        public var packageFiles: [String: Data]?
        /// The package's name in the folder (`scene.pkg`), left out of the copy.
        public var packageName: String?
        /// The editor's own files for the wallpaper (`EditorAssetStore`): imported images, sounds,
        /// fonts and painted masks, which the edited scene names. Copied in beside the wallpaper's.
        public var assetsDirectory: URL?

        public init(directory: URL, sceneFile: String, packageFiles: [String: Data]? = nil, packageName: String? = nil,
                    assetsDirectory: URL? = nil) {
            self.directory = directory
            self.sceneFile = sceneFile
            self.packageFiles = packageFiles
            self.packageName = packageName
            self.assetsDirectory = assetsDirectory
        }
    }

    public enum WriteError: Error, Equatable {
        /// A package path that leaves the folder (`../`, absolute).
        case unsafePath(String)
        case noProject
    }

    public let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Copies `source` into `library` as a new folder named after `title`, writes `scene` as its
    /// scene file and `title` into its project.json, which no longer names a Workshop item.
    /// Hidden files (the app's caches and kept package sources) and symbolic links (Workshop
    /// dependencies, linked again when the copy loads) stay behind. The copy is made in a hidden
    /// folder and renamed into place, so the library never lists half a wallpaper. `editProject`
    /// changes the copy's project.json first (the editor's user properties). `files` are written
    /// into the copy by their path (the editor's puppets, `PuppetSceneBake`), then
    /// `additionalFiles` (the particle editor's documents) over it. `thumbnail`, when the user made
    /// one (Take Snapshot, Record GIF), replaces the source's preview (`writeThumbnail`); without
    /// one the copy keeps the source's.
    @discardableResult
    public func save(_ source: Source, scene: Data, title: String, into library: URL,
                     editProject: ((inout [String: Any]) -> Void)? = nil,
                     files: [String: Data] = [:], additionalFiles: [String: Data] = [:],
                     thumbnail: WallpaperThumbnail? = nil) throws -> URL {
        try fileManager.createDirectory(at: library, withIntermediateDirectories: true)
        let staging = library.appending(path: ".owe-editor-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try copyContents(of: source.directory, to: staging, skipping: source.packageName)
            for (path, data) in source.packageFiles ?? [:] {
                let destination = try Self.contained(path, in: staging)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            if let assets = source.assetsDirectory, fileManager.fileExists(atPath: assets.path) {
                try merge(assets, into: staging)
            }
            for (path, data) in files.merging(additionalFiles, uniquingKeysWith: { $1 }) {
                let destination = try Self.contained(path, in: staging)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            try scene.write(to: try Self.contained(source.sceneFile, in: staging), options: .atomic)
            try writeProject(in: staging, title: title, edit: editProject)
            if let thumbnail { try writeThumbnail(thumbnail, into: staging) }
            let destination = uniqueFolder(named: Self.folderName(title), in: library)
            try fileManager.moveItem(at: staging, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: staging) // Best effort: a partial copy is hidden anyway.
            throw error
        }
    }

    private func copyContents(of source: URL, to destination: URL, skipping packageName: String?) throws {
        // The wallpaper's folder itself may be a link into another library; its links inside stay behind.
        let items = try fileManager.contentsOfDirectory(at: source.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                        options: [.skipsHiddenFiles])
        for item in items where item.lastPathComponent != packageName {
            try copy(item, to: destination.appending(path: item.lastPathComponent))
        }
    }

    /// Copies `item` without symbolic links, recursing into folders.
    private func copy(_ item: URL, to destination: URL) throws {
        let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true { return }
        guard values.isDirectory == true else { return try fileManager.copyItem(at: item, to: destination) }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                                           options: [.skipsHiddenFiles])
        for child in children { try copy(child, to: destination.appending(path: child.lastPathComponent)) }
    }

    /// Copies the folder's files into `destination`'s folders of the same names, keeping what is there.
    private func merge(_ source: URL, into destination: URL) throws {
        let items = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        for item in items {
            let target = destination.appending(path: item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                try merge(item, into: target)
            } else if !fileManager.fileExists(atPath: target.path) {
                try fileManager.copyItem(at: item, to: target)
            }
        }
    }

    /// project.json with the new title and without the Workshop item it came from, so the copy is
    /// a local wallpaper with its own identity (its own properties and edits).
    private func writeProject(in folder: URL, title: String, edit: ((inout [String: Any]) -> Void)?) throws {
        let url = WEProjectFile.url(in: folder)
        guard let data = fileManager.contents(atPath: url.path),
              var project = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.noProject }
        edit?(&project)
        project["title"] = title
        for key in Self.workshopKeys { project.removeValue(forKey: key) }
        let written = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try written.write(to: url, options: .atomic)
    }

    /// Writes `thumbnail` into the wallpaper `folder` as WE's editor does (`preview.jpg` or
    /// `preview.gif`) and names it in project.json's `preview`; the other of the two goes when the
    /// project named it, so the folder keeps one preview. File › Save writes a local wallpaper's
    /// this way; Save as New Wallpaper its copy's.
    public func writeThumbnail(_ thumbnail: WallpaperThumbnail, into folder: URL) throws {
        let url = WEProjectFile.url(in: folder)
        guard let data = fileManager.contents(atPath: url.path),
              var project = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.noProject }
        try thumbnail.data.write(to: folder.appending(path: thumbnail.fileName), options: .atomic)
        let previous = project["preview"] as? String
        project["preview"] = thumbnail.fileName
        let written = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try written.write(to: url, options: .atomic)
        if let previous, previous.lowercased() != thumbnail.fileName, WallpaperThumbnail.fileNames.contains(previous.lowercased()) {
            let old = folder.appending(path: previous)
            if fileManager.fileExists(atPath: old.path) { try fileManager.removeItem(at: old) }
        }
    }

    /// Writes the editor's project settings (`SceneProjectEdits`: the title) into the wallpaper
    /// `folder`'s project.json. File › Save writes a local wallpaper's this way.
    public func writeProjectEdits(_ edits: SceneProjectEdits, into folder: URL) throws {
        guard !edits.isEmpty else { return }
        let url = WEProjectFile.url(in: folder)
        guard let data = fileManager.contents(atPath: url.path),
              var project = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WriteError.noProject }
        edits.apply(to: &project)
        let written = try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
        try written.write(to: url, options: .atomic)
    }

    /// What ties a project to its Workshop item.
    static let workshopKeys = ["workshopid", "workshopurl"]

    /// `path` inside `folder`; throws for one that leaves it.
    static func contained(_ path: String, in folder: URL) throws -> URL {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw WriteError.unsafePath(path)
        }
        return parts.reduce(folder) { $0.appending(path: String($1)) }
    }

    /// A folder name from the title: no path separators, no leading dot, not empty.
    static func folderName(_ title: String) -> String {
        let cleaned = title.map { "/:\\".contains($0) ? "-" : $0 }
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "Wallpaper" : String(name.prefix(120))
    }

    /// `name`, else `name 2`, `name 3`… whichever isn't taken.
    func uniqueFolder(named name: String, in library: URL) -> URL {
        var candidate = library.appending(path: name, directoryHint: .isDirectory)
        var number = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = library.appending(path: "\(name) \(number)", directoryHint: .isDirectory)
            number += 1
        }
        return candidate
    }
}
