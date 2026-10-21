//
//  SceneShaderCompat.swift
//  Open Wallpaper Engine
//
//  WE ships fixed copies of a few Workshop shaders that later WE versions broke, in
//  `assets/zcompat/scene/shaders/<workshopid>/`. Its `config.json` is
//  `{"maximumprojectid", "frag", "vert"}`: the fixed stage files, and the newest project that still
//  needs them. Projects published after that id (a higher Workshop id) ship a working copy
//  themselves. `<workshopid>` is the item that owns the shader: either an asset item referenced as
//  `…/workshop/<id>/…`, or the wallpaper's own custom shader when the wallpaper is that item.
//

import Foundation

struct SceneShaderCompat {
    struct Entry: Equatable {
        let directory: URL
        let maximumProjectId: UInt64
        /// Stage file names, e.g. `pixelate.frag`.
        let files: [String]
    }

    /// `assets/zcompat/scene/shaders`.
    let root: URL

    init(root: URL) {
        self.root = root
    }

    init?(assetsDirectory: URL?) {
        guard let assetsDirectory else { return nil }
        let root = assetsDirectory.appending(path: "zcompat/scene/shaders", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        self.root = root
    }

    func entry(for workshopId: String) -> Entry? {
        guard !workshopId.isEmpty, workshopId.allSatisfy(\.isASCII), workshopId.allSatisfy(\.isNumber) else { return nil }
        let directory = root.appending(path: workshopId, directoryHint: .isDirectory)
        let config = directory.appending(path: "config.json")
        // Most items have no compat entry; a missing config is the normal case.
        guard FileManager.default.fileExists(atPath: config.path) else { return nil }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: config))
            guard let json = object as? [String: Any] else {
                OWELog.error(.scene, "zcompat \(config.path) is not a JSON object")
                return nil
            }
            // WE writes the id as a string (it is a 64-bit Steam id); accept a number too.
            let maximum = (json["maximumprojectid"] as? String).flatMap(UInt64.init)
                ?? (json["maximumprojectid"] as? NSNumber)?.uint64Value
                ?? UInt64.max
            let files = ["frag", "vert"].compactMap { json[$0] as? String }
            return Entry(directory: directory, maximumProjectId: maximum, files: files)
        } catch {
            OWELog.error(.scene, "Failed to read zcompat \(config.path): \(error)")
            return nil
        }
    }

    /// The fixed copy of the shader stage at `path` (`shaders/…/name.frag`) for a project with
    /// Workshop id `projectId` (nil for a local project, which predates every bound).
    func replacement(forShaderPath path: String, projectId: String?) -> Data? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let fileName = (normalized as NSString).lastPathComponent
        let stage = (fileName as NSString).pathExtension.lowercased()
        guard stage == "frag" || stage == "vert" else { return nil }
        let owner = WorkshopAssetResolver.reference(in: normalized)?.workshopId ?? projectId
        guard let owner, let entry = entry(for: owner) else { return nil }
        let project = projectId.flatMap(UInt64.init) ?? 0
        guard project <= entry.maximumProjectId,
              let file = entry.files.first(where: { $0.caseInsensitiveCompare(fileName) == .orderedSame }) else { return nil }
        let url = entry.directory.appending(path: file)
        do {
            guard let data = try AssetPathResolver.data(file, in: entry.directory) else {
                OWELog.error(.scene, "zcompat shader \(url.path) is not a usable file in its entry")
                return nil
            }
            return data
        } catch {
            OWELog.error(.scene, "Failed to read zcompat shader \(url.path): \(error)")
            return nil
        }
    }
}
