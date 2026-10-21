//
//  WorkshopDependencyResolver.swift
//  Open Wallpaper Engine
//
//  Some wallpapers reuse fonts, effects, materials or models that live in a *different* Steam
//  Workshop item (an "asset pack"), referenced by paths like `effects/workshop/<id>/…`, or name one
//  in project.json's `dependency`. This finds those ids in a wallpaper (its package entries,
//  scene.json, materials and every other JSON it ships, and project.json), reports which aren't
//  installed, and links installed ones in so the loose-file loaders resolve them.
//

import Darwin
import Foundation

enum WorkshopDependencyResolver {
    /// Every other Workshop item the item in `directory` references.
    static func referencedWorkshopIds(inItemAt directory: URL) -> Set<String> {
        var ids = Set<String>()
        for pkg in WorkshopAssetResolver.packages(in: directory) {
            let parser: PKGParser
            do {
                parser = try PKGParser(url: pkg)
            } catch {
                OWELog.error(.workshop, "Can't scan \(pkg.path) for workshop dependencies: \(error)")
                continue
            }
            for entry in parser.fileList {
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: entry))
                guard entry.lowercased().hasSuffix(".json"), let data = parser.extractFile(named: entry) else { continue }
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: String(decoding: data, as: UTF8.self)))
            }
        }
        if let manifest = WallpaperPackageConverter.manifest(in: directory) {
            // Converted wallpapers no longer have the archive; the manifest lists its paths.
            for path in manifest.extractedFiles + (manifest.dependencyEntries ?? []) {
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: path))
            }
        }
        ids.formUnion(looseReferences(in: directory))
        ids.formUnion(projectDependencies(inItemAt: directory))
        ids.remove(directory.lastPathComponent)
        return ids
    }

    /// project.json's `dependency`: a single id (string or number) or a list of them.
    static func projectDependencies(inItemAt directory: URL) -> Set<String> {
        let url = WEProject.url(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let object: Any
        do {
            object = try WEProject.object(in: directory)
        } catch {
            OWELog.error(.workshop, "Can't read \(url.path) for its dependency: \(error)")
            return []
        }
        guard let project = object as? [String: Any], let value = project["dependency"] else { return [] }
        let values: [Any] = (value as? [Any]) ?? [value]
        return Set(values.compactMap { item -> String? in
            let id = (item as? String) ?? (item as? NSNumber)?.stringValue
            guard let id, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            return id
        })
    }

    /// References in the item's loose files: folder names (`materials/workshop/<id>`) and the
    /// contents of its JSON files. Linked dependency folders are not followed.
    private static func looseReferences(in directory: URL) -> Set<String> {
        var ids = Set<String>()
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return ids }
        let base = directory.standardizedFileURL.path
        for case let url as URL in enumerator {
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
            ids.formUnion(WorkshopAssetResolver.referencedIds(in: relative + "/"))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "json" else { continue }
            do {
                ids.formUnion(WorkshopAssetResolver.referencedIds(in: String(decoding: try Data(contentsOf: url), as: UTF8.self)))
            } catch {
                OWELog.error(.workshop, "Can't read \(url.path) for workshop dependencies: \(error)")
            }
        }
        return ids
    }

    /// The referenced ids no root has downloaded yet.
    static func missingWorkshopIds(for wallpaper: WEWallpaper,
                                   resolver: WorkshopAssetResolver = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())) -> Set<String> {
        referencedWorkshopIds(inItemAt: wallpaper.wallpaperDirectory).filter { !resolver.isInstalled($0) }
    }

    /// Links each installed dependency's category folder into the wallpaper
    /// (`<wallpaper>/effects/workshop/<id>` → `<item>/effects`), so the loose-file loaders find
    /// `effects/workshop/<id>/…` like any other file. Idempotent.
    static func linkInstalledDependencies(for wallpaper: WEWallpaper,
                                          resolver: WorkshopAssetResolver = WorkshopAssetResolver(roots: WorkshopAssetResolver.defaultRoots())) {
        guard !SceneBackendRuntimeContext.isActive else { return }
        linkInstalledDependencies(inItemAt: wallpaper.wallpaperDirectory, resolver: resolver)
    }

    /// Links the installed dependencies of the item in `directory`; see
    /// `linkInstalledDependencies(for:resolver:)`.
    static func linkInstalledDependencies(inItemAt directory: URL, resolver: WorkshopAssetResolver) {
        let fm = FileManager.default
        for id in referencedWorkshopIds(inItemAt: directory) {
            guard let item = resolver.itemDirectory(for: id) else { continue }
            let categories: [URL]
            do {
                categories = try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            } catch {
                OWELog.error(.workshop, "Can't list workshop dependency \(item.path): \(error)")
                continue
            }
            for categorySource in categories {
                linkDependency(id: id, category: categorySource.lastPathComponent, to: categorySource, inItemAt: directory)
            }
        }
    }

    /// Creates `<directory>/<category>/workshop/<id>` as a link to `source`. Existing folders on
    /// the way are used only when none of them is a symbolic link, so the link and its parent
    /// folders always stay inside `directory`. An existing link at the destination is one this
    /// resolver made and is replaced when it points elsewhere (removing a link never touches what
    /// it points at); a real file or folder there is kept. Returns whether the link is in place.
    @discardableResult
    static func linkDependency(id: String, category: String, to source: URL, inItemAt directory: URL) -> Bool {
        guard !id.isEmpty, id.allSatisfy(\.isNumber),
              !category.isEmpty, category != ".", category != "..", !category.contains("/") else {
            OWELog.error(.workshop, "Not linking workshop dependency \(id): unusable folder name \(category)")
            return false
        }
        let parentPath = "\(category)/workshop"
        let linkParent = directory.appending(path: category).appending(path: "workshop")
        let linkPath = linkParent.appending(path: id)
        guard ContainedPath.hasNoLinks(below: directory, relativePath: parentPath) else {
            OWELog.error(.workshop, "Not linking workshop dependency \(id): \(parentPath) in \(directory.path) is a symbolic link")
            return false
        }
        let fm = FileManager.default
        let linkFilePath = linkPath.path(percentEncoded: false)
        if ContainedPath.isSymbolicLink(linkPath) {
            let destination: String
            do {
                destination = try fm.destinationOfSymbolicLink(atPath: linkFilePath)
            } catch {
                OWELog.error(.workshop, "Can't read workshop dependency link \(linkPath.path): \(error)")
                return false
            }
            if URL(fileURLWithPath: destination).standardizedFileURL.path == source.standardizedFileURL.path { return true }
            guard unlink(linkFilePath) == 0 else {
                OWELog.error(.workshop, "Can't replace workshop dependency link \(linkPath.path): errno \(errno)")
                return false
            }
        } else if fm.fileExists(atPath: linkFilePath) {
            // The wallpaper ships these files itself.
            return true
        }
        do {
            try fm.createDirectory(at: linkParent, withIntermediateDirectories: true)
            // Checked again once the parents exist: they must still be real folders.
            guard ContainedPath.hasNoLinks(below: directory, relativePath: "\(parentPath)/\(id)") else {
                OWELog.error(.workshop, "Not linking workshop dependency \(id): \(parentPath) in \(directory.path) is a symbolic link")
                return false
            }
            try fm.createSymbolicLink(at: linkPath, withDestinationURL: source)
            return true
        } catch {
            OWELog.error(.workshop, "Failed to link workshop dependency \(id): \(error)")
            return false
        }
    }
}
