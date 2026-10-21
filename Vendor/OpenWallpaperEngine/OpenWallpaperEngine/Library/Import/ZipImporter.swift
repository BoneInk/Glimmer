import Foundation

enum ZipImporter {
    /// Extracts a zip file and copies any wallpaper folders (containing project.json) to
    /// `destination`, the wallpapers directory unless given. Symbolic links in the archive are
    /// removed before anything is copied. Returns the number of wallpapers imported.
    @discardableResult
    static func importZip(at zipURL: URL, into destination: URL? = nil) -> Int {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appending(path: UUID().uuidString)

        defer { try? fm.removeItem(at: tempDir) }

        // Extract zip using macOS built-in ditto
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipURL.path, tempDir.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            OWELog.error(.importer, "ditto failed: \(error)")
            return 0
        }
        guard process.terminationStatus == 0 else {
            OWELog.error(.importer, "ditto exited with status \(process.terminationStatus)")
            return 0
        }
        do {
            try ImportedFolderLinks.removeLinks(in: tempDir)
        } catch {
            OWELog.error(.importer, "Can't import \(zipURL.lastPathComponent): removing its symbolic links failed: \(error)")
            return 0
        }

        // Find wallpaper folders inside extracted content
        let wallpaperURLs = findWallpaperFolders(in: tempDir)
        let dest = destination ?? fm.wallpapersDirectory
        var imported = 0

        for url in wallpaperURLs {
            let target = dest.appending(path: url.lastPathComponent)
            if !fm.fileExists(atPath: target.path) {
                do {
                    try ImportedFolderLinks.copyWithoutLinks(from: url, to: target)
                    DispatchQueue.global(qos: .utility).async {
                        WallpaperPreparation.prepare(wallpaperDirectory: target)
                    }
                    imported += 1
                } catch {
                    OWELog.error(.importer, "Copy failed for \(url.lastPathComponent): \(error)")
                }
            }
        }

        return imported
    }

    /// Whether `url` is a real folder (not a symbolic link to one) holding a project.json.
    private static func isWallpaperFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        return !ContainedPath.isSymbolicLink(url)
            && fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            && fm.fileExists(atPath: WEProject.url(in: url).path)
    }

    /// Searches for wallpaper folders: `directory` itself, its children, or its grandchildren
    /// (a zip may have a wrapper folder). Folders that are symbolic links are skipped.
    static func findWallpaperFolders(in directory: URL) -> [URL] {
        let fm = FileManager.default
        if isWallpaperFolder(directory) { return [directory] }

        guard let children = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var results: [URL] = []
        for child in children where !ContainedPath.isSymbolicLink(child) {
            if isWallpaperFolder(child) {
                results.append(child)
            } else if let grandchildren = try? fm.contentsOfDirectory(
                at: child, includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) {
                results.append(contentsOf: grandchildren.filter(isWallpaperFolder))
            }
        }
        return results
    }
}
