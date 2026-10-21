//
//  WorkshopAssetResolver.swift
//  Open Wallpaper Engine
//
//  Wallpapers reuse assets published as *other* Workshop items. WE writes such a reference as
//  `<category>/workshop/<id>/<rest>` (e.g. `fonts/workshop/2981960200/Quicksand-Bold.otf`,
//  `effects/workshop/<id>/name/effect.json`), and resolves it inside item <id>'s folder, where the
//  asset lives under its ordinary path `<category>/<rest>`. This type does that lookup against
//  every folder that holds downloaded items.
//

import Foundation

struct WorkshopAssetResolver {
    /// A parsed `…/workshop/<id>/<rest>` path.
    struct Reference: Hashable {
        /// The path before `workshop/`, e.g. `fonts` (empty when the path starts with `workshop/`).
        let category: String
        let workshopId: String
        /// The path after the id, e.g. `Quicksand-Bold.otf`.
        let remainder: String

        /// Where the asset lives inside the item, most specific first.
        var candidatePaths: [String] {
            var paths: [String] = []
            if !category.isEmpty { paths.append("\(category)/\(remainder)") }
            paths.append(remainder)
            // Some asset packs keep the full referencing path.
            if !category.isEmpty { paths.append("\(category)/workshop/\(workshopId)/\(remainder)") }
            return paths
        }
    }

    /// Folders whose children are workshop items named by id, searched in order.
    let roots: [URL]

    init(roots: [URL]) {
        self.roots = roots
    }

    /// The app's own download folder (the Wallpaper Storage folder).
    static func defaultRoots(fileManager: FileManager = .default) -> [URL] {
        if SceneBackendRuntimeContext.isActive { return [] }
        return [fileManager.wallpapersDirectory]
    }

    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(?:^|[\\/])workshop[\\/](\d{5,})[\\/]"#)

    private static let anyIdPattern = try! NSRegularExpression(pattern: #"workshop[\\/](\d{5,})[\\/]"#)

    /// Parses the first `workshop/<id>/` component of an asset path.
    static func reference(in path: String) -> Reference? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = referencePattern.firstMatch(in: normalized, range: range),
              let whole = Range(match.range, in: normalized),
              let idRange = Range(match.range(at: 1), in: normalized) else { return nil }
        let category = String(normalized[..<whole.lowerBound])
        let remainder = String(normalized[whole.upperBound...])
        guard !remainder.isEmpty else { return nil }
        return Reference(category: category, workshopId: String(normalized[idRange]), remainder: remainder)
    }

    /// Every workshop id referenced anywhere in `text` (a path list, scene.json, a material…).
    static func referencedIds(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var ids = Set<String>()
        for match in anyIdPattern.matches(in: text, range: range) {
            if let idRange = Range(match.range(at: 1), in: text) { ids.insert(String(text[idRange])) }
        }
        return ids
    }

    /// The downloaded folder of item `workshopId`, if any root has it.
    func itemDirectory(for workshopId: String) -> URL? {
        let fm = FileManager.default
        for root in roots {
            let candidate = root.appending(path: workshopId, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                // A dependency linked into the library is listed through the folder it points to.
                return ContainedPath.followingFolderLink(candidate)
            }
        }
        return nil
    }

    func isInstalled(_ workshopId: String) -> Bool {
        itemDirectory(for: workshopId) != nil
    }

    /// The loose file a workshop path points to, if the item stores it unpacked. It must lie
    /// inside that item's own folder (`AssetPathResolver`).
    func url(for path: String) -> URL? {
        guard let reference = Self.reference(in: path), let item = itemDirectory(for: reference.workshopId) else { return nil }
        for candidate in reference.candidatePaths {
            if let url = AssetPathResolver.fileURL(candidate, in: item) { return url }
        }
        return nil
    }

    /// The bytes a workshop path points to, loose or inside one of the item's `.pkg` archives.
    func data(for path: String) -> Data? { located(path)?.data }

    /// The bytes a workshop path points to and the file they are read from (the loose file or the `.pkg`).
    func located(_ path: String) -> (data: Data, source: URL)? {
        if let url = url(for: path) {
            do {
                return (try AssetPathResolver.readRegularFile(at: url), url)
            } catch {
                OWELog.error(.workshop, "Failed to read workshop asset \(url.path): \(error)")
                return nil
            }
        }
        guard let reference = Self.reference(in: path), let item = itemDirectory(for: reference.workshopId) else { return nil }
        for pkg in Self.packages(in: item) {
            let parser: PKGParser
            do {
                parser = try PKGParser(url: pkg)
            } catch {
                OWELog.error(.workshop, "Failed to open \(pkg.path) for \(path): \(error)")
                continue
            }
            for candidate in reference.candidatePaths {
                if let entry = parser.fileList.first(where: {
                    $0.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(candidate) == .orderedSame
                }), let data = parser.extractFile(named: entry) {
                    return (data, pkg)
                }
            }
        }
        return nil
    }

    static func packages(in directory: URL) -> [URL] {
        // A missing or unreadable folder simply has no packages.
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension.lowercased() == "pkg" }.sorted { $0.path < $1.path }
    }
}
