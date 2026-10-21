import CryptoKit
import Foundation

/// Explodes a wallpaper's `.pkg` into loose files inside the same wallpaper directory.
///
/// The runtime already prefers a `.pkg` when present and otherwise reads loose files, so removing
/// the archive from the search path is all that is needed to switch a wallpaper over. The original
/// archive is moved into `.owe-source/` rather than deleted; reclaiming that space is a separate,
/// explicit step because the converter is not yet lossless for every Wallpaper Engine feature.
enum WallpaperPackageConverter {
    static let converterVersion = 3

    /// For each converter version, which bundles made by an earlier version it changes. A stale
    /// bundle no newer rule matches is only stamped current. Add an entry with every bump.
    static let versionRules: [Int: (Manifest, URL) -> Bool] = [
        // Version 3 extracts the `workshop/<id>/` asset-pack files version 2 left in the package.
        // Manifests from before the field was recorded are checked against the files themselves.
        3: { manifest, directory in
            if let entries = manifest.dependencyEntries { return !entries.isEmpty }
            return hasUnresolvedWorkshopReference(in: directory)
        },
    ]

    /// Whether any version after the bundle's own changes what this one would produce.
    static func isAffectedByNewerVersions(_ manifest: Manifest, directory: URL) -> Bool {
        guard manifest.converterVersion < converterVersion else { return false }
        return ((manifest.converterVersion + 1)...converterVersion).contains { version in
            versionRules[version]?(manifest, directory) ?? true
        }
    }

    private static let assetCategories = ["", "materials", "models", "particles", "effects", "shaders",
                                          "scripts", "sounds", "fonts"]
    private static let workshopReference = try! NSRegularExpression(
        pattern: #""([^"]*workshop(?:/|\\\\)+[0-9]+(?:/|\\\\)[^"]*)""#)

    /// Whether a JSON file in the bundle (the scene, materials, models, particles, effects) names a
    /// `workshop/<id>/…` file that neither the bundle nor its dependency links provide. A text scan:
    /// linked dependency folders are not descended into.
    static func hasUnresolvedWorkshopReference(in directory: URL, fileManager: FileManager = .default) -> Bool {
        guard let files = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                 options: [.skipsHiddenFiles]) else { return false }
        for case let file as URL in files where file.pathExtension.lowercased() == "json" {
            // Optional: a file that isn't UTF-8 text names no Workshop items.
            guard let text = try? String(contentsOf: file, encoding: .utf8), text.contains("workshop") else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in workshopReference.matches(in: text, range: range) {
                guard let found = Range(match.range(at: 1), in: text) else { continue }
                let reference = text[found].replacingOccurrences(of: "\\\\", with: "/")
                    .split(separator: "/").joined(separator: "/")
                if !resolves(reference, in: directory, fileManager: fileManager) { return true }
            }
        }
        return false
    }

    private static func resolves(_ reference: String, in directory: URL, fileManager: FileManager) -> Bool {
        for category in assetCategories {
            let base = category.isEmpty ? directory : directory.appending(path: category)
            for suffix in ["", ".tex", ".json"] {
                // fileExists follows the dependency links the resolver made.
                if fileManager.fileExists(atPath: base.appending(path: reference + suffix).path(percentEncoded: false)) {
                    return true
                }
            }
        }
        return false
    }

    /// Records the bundle as made by the current version without converting it again.
    static func stampCurrent(in wallpaperDirectory: URL) {
        guard var current = manifest(in: wallpaperDirectory) else { return }
        current.converterVersion = converterVersion
        write(current, to: wallpaperDirectory)
    }

    static let manifestName = ".owe-bundle.json"
    static let sourceFolderName = ".owe-source"

    struct Manifest: Codable {
        var converterVersion: Int
        var sourcePackage: String
        var sourceHash: String
        var sourceRetained: Bool
        var extractedFiles: [String]
        var warnings: [String]
        var convertedAt: Date
        /// Set once the converted bundle has actually rendered, which is the precondition for
        /// ever removing the archived original.
        var verifiedAt: Date?
        var verifiedObjectCount: Int?
        /// Version 2 only: entries under `…/workshop/<id>/` it did not extract. Since version 3 they
        /// are extracted like any other entry (Wallpaper Engine reads them from the package), and an
        /// empty list is written so that none is recorded; absent only in manifests older than the field.
        var dependencyEntries: [String]?
    }

    static func manifestURL(in wallpaperDirectory: URL) -> URL {
        wallpaperDirectory.appending(path: manifestName)
    }

    static func manifest(in wallpaperDirectory: URL) -> Manifest? {
        // No manifest: not converted. One that can't be read or decoded logs and counts as none.
        OWELog.attempt(.importer, "Convert: manifest of \(wallpaperDirectory.lastPathComponent)", quietIfMissing: true) {
            try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL(in: wallpaperDirectory)))
        }
    }

    /// True when the directory already holds a bundle produced by this converter version.
    static func isConverted(_ wallpaperDirectory: URL) -> Bool {
        manifest(in: wallpaperDirectory)?.converterVersion == converterVersion
    }

    @discardableResult
    static func convertIfNeeded(wallpaperDirectory: URL) -> Manifest? {
        guard !isConverted(wallpaperDirectory) else { return manifest(in: wallpaperDirectory) }
        guard let sceneFile = primarySceneFile(in: wallpaperDirectory) else { return nil }

        let packageName = (sceneFile as NSString).deletingPathExtension + ".pkg"
        let livePackageURL = wallpaperDirectory.appending(path: packageName)
        let archivedPackageURL = wallpaperDirectory.appending(path: sourceFolderName).appending(path: packageName)
        // Re-converting an existing bundle has to read the archived copy, since the first pass
        // moved it out of the wallpaper directory.
        let packageURL = FileManager.default.fileExists(atPath: livePackageURL.path(percentEncoded: false))
            ? livePackageURL
            : archivedPackageURL
        guard FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) else { return nil }

        guard let packageData = try? Data(contentsOf: packageURL, options: .mappedIfSafe),
              let parser = try? PKGParser(data: packageData) else {
            OWELog.error(.importer, "Convert: unable to read \(packageName)")
            return nil
        }

        var extracted: [String] = []
        var warnings: [String] = []
        guard let root = ContainedPath.canonical(wallpaperDirectory) else {
            OWELog.error(.importer, "Convert: can't resolve \(wallpaperDirectory.path)")
            return nil
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)

        for entry in parser.fileList {
            guard let relativePath = sanitizedRelativePath(entry) else {
                warnings.append("Skipped unsafe entry path: \(entry)")
                continue
            }
            // Entries under `workshop/<id>/` are the asset-pack files the wallpaper uses, bundled by
            // the editor. Wallpaper Engine reads them from the package before the installed item,
            // so they are extracted too; the dependency resolver keeps a real folder it finds there.
            guard let data = parser.extractFile(named: entry) else {
                warnings.append("Missing data for entry: \(entry)")
                continue
            }
            let destination = rootURL.appending(path: relativePath)
            do {
                // Entries are written inside the folder only, never through a symbolic link.
                guard ContainedPath.hasNoLinks(below: rootURL, relativePath: relativePath) else {
                    warnings.append("Skipped entry under a symbolic link: \(entry)")
                    continue
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard let parent = ContainedPath.canonical(destination.deletingLastPathComponent()),
                      ContainedPath.isInside(parent, root: root) else {
                    warnings.append("Skipped escaping entry path: \(entry)")
                    continue
                }
                try data.write(to: destination, options: .atomic)
                // A clean extraction is the only thing gating removal of the original, so prove
                // each file landed byte-for-byte instead of trusting the write.
                guard let written = try? Data(contentsOf: destination), written == data else {
                    warnings.append("Readback mismatch for \(relativePath)")
                    continue
                }
                extracted.append(relativePath)
            } catch {
                warnings.append("Failed to write \(relativePath): \(error.localizedDescription)")
            }
        }

        // Without the scene descriptor on disk the wallpaper would not load at all, so leave the
        // archive in place and report failure rather than half-converting it.
        let sceneOnDisk = FileManager.default.fileExists(
            atPath: wallpaperDirectory.appending(path: sceneFile).path(percentEncoded: false))
        guard sceneOnDisk else {
            OWELog.error(.importer, "Convert: \(sceneFile) missing after extraction; keeping \(packageName)")
            return nil
        }

        let sourceFolder = wallpaperDirectory.appending(path: sourceFolderName)
        var sourceRetained = packageURL == archivedPackageURL
        if !sourceRetained, !ContainedPath.hasNoLinks(below: wallpaperDirectory, relativePath: sourceFolderName) {
            warnings.append("Could not archive \(packageName): \(sourceFolderName) is a symbolic link")
        } else if !sourceRetained {
            do {
                try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
                let archived = sourceFolder.appending(path: packageName)
                try? FileManager.default.removeItem(at: archived)
                try FileManager.default.moveItem(at: packageURL, to: archived)
                sourceRetained = true
            } catch {
                warnings.append("Could not archive \(packageName): \(error.localizedDescription)")
            }
        }

        let manifest = Manifest(converterVersion: converterVersion,
                                sourcePackage: packageName,
                                sourceHash: Digest.hex(SHA256.hash(data: packageData)),
                                sourceRetained: sourceRetained,
                                extractedFiles: extracted,
                                warnings: warnings,
                                convertedAt: Date(),
                                verifiedAt: nil,
                                verifiedObjectCount: nil,
                                dependencyEntries: [])
        write(manifest, to: wallpaperDirectory)

        OWELog.info(.importer, "Converted \(wallpaperDirectory.lastPathComponent): \(extracted.count) files, \(warnings.count) warnings")
        return manifest
    }

    /// Deletes the archived original. Extraction is byte-for-byte, so once a bundle has rendered
    /// and nothing was skipped, the archive holds no bytes the directory doesn't already have.
    @discardableResult
    static func reclaimSource(in wallpaperDirectory: URL) -> Bool {
        guard var current = manifest(in: wallpaperDirectory), current.sourceRetained else { return false }
        guard let reason = ineligibilityReason(for: current, directory: wallpaperDirectory) else {
            let sourceFolder = wallpaperDirectory.appending(path: sourceFolderName)
            guard (try? FileManager.default.removeItem(at: sourceFolder)) != nil else { return false }
            current.sourceRetained = false
            write(current, to: wallpaperDirectory)
            OWELog.info(.importer, "Reclaimed original package for \(wallpaperDirectory.lastPathComponent)")
            return true
        }
        OWELog.info(.importer, "Keeping original for \(wallpaperDirectory.lastPathComponent): \(reason)")
        return false
    }

    /// nil means the bundle is fully migrated and the archive is safe to delete.
    ///
    /// Extraction copies every entry byte-for-byte and reads each one back, so a warning-free
    /// conversion means the directory already holds everything the archive did. Dependent
    /// wallpapers symlink to this directory's asset folders, never to the archive.
    static func ineligibilityReason(for manifest: Manifest, directory: URL) -> String? {
        if manifest.converterVersion != converterVersion { return "converted by an older version" }
        if !manifest.warnings.isEmpty { return "conversion reported \(manifest.warnings.count) warning(s)" }
        if manifest.extractedFiles.isEmpty { return "nothing was extracted" }
        return nil
    }

    /// Records that the converted files actually produced a scene.
    static func markVerified(wallpaperDirectory: URL, objectCount: Int) {
        guard var current = manifest(in: wallpaperDirectory), current.verifiedAt == nil, objectCount > 0 else { return }
        current.verifiedAt = Date()
        current.verifiedObjectCount = objectCount
        write(current, to: wallpaperDirectory)
    }

    /// Converts wallpapers that were installed before conversion existed.
    static func convertInstalledLibrary() {
        let fileManager = FileManager.default
        let root = fileManager.wallpapersDirectory
        guard let entries = libraryFolders(in: root) else { return }
        var converted = 0
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !isConverted(entry) else { continue }
            if convertIfNeeded(wallpaperDirectory: entry) != nil { converted += 1 }
        }
        if converted > 0 {
            OWELog.info(.importer, "Converted \(converted) previously installed wallpaper(s)")
        }
    }

    /// Reclaims every bundle that is fully migrated. Returns the number of archives removed.
    @discardableResult
    static func reclaimEligibleSources() -> Int {
        let fileManager = FileManager.default
        guard let entries = libraryFolders(in: fileManager.wallpapersDirectory) else { return 0 }
        return entries.reduce(into: 0) { total, entry in
            if reclaimSource(in: entry) { total += 1 }
        }
    }

    /// Bytes currently held by archived originals that are safe to delete.
    static func reclaimableBytes() -> Int64 {
        let fileManager = FileManager.default
        guard let entries = libraryFolders(in: fileManager.wallpapersDirectory) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, entry in
            guard let manifest = manifest(in: entry), manifest.sourceRetained,
                  ineligibilityReason(for: manifest, directory: entry) == nil else { return }
            let archive = entry.appending(path: sourceFolderName).appending(path: manifest.sourcePackage)
            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
    }

    /// The library's folders; nil, after one log line, when the library can't be listed.
    private static func libraryFolders(in root: URL) -> [URL]? {
        OWELog.attempt(.importer, "Convert: listing \(root.path(percentEncoded: false))") {
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        }
    }

    private static func write(_ manifest: Manifest, to wallpaperDirectory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        OWELog.attempt(.importer, "Convert: writing the manifest of \(wallpaperDirectory.lastPathComponent)") {
            try encoder.encode(manifest).write(to: manifestURL(in: wallpaperDirectory), options: .atomic)
        }
    }

    private static func primarySceneFile(in wallpaperDirectory: URL) -> String? {
        guard let project = OWELog.attempt(.importer, "Convert: project.json of \(wallpaperDirectory.lastPathComponent)", {
            try WEProject.read(in: wallpaperDirectory)
        }) else { return nil }
        return project.file.lowercased().hasSuffix(".json") ? project.file : nil
    }

    /// PKG entries are authored on Windows and are untrusted input, so reject anything absolute or
    /// containing a parent traversal before it is joined onto the wallpaper directory.
    private static func sanitizedRelativePath(_ raw: String) -> String? {
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains(":") else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        for component in components where component == ".." || component == "." || component.isEmpty {
            return nil
        }
        return components.joined(separator: "/")
    }
}
