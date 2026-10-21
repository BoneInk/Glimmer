//
//  WorkshopDependencyCleanup.swift
//  Open Wallpaper Engine
//
//  Removes dependency-only Workshop items no wallpaper in the library needs any more. In WE these
//  are Steam subscriptions the user can still see and unsubscribe from in Steam; here they are
//  hidden from Installed, so leaving them after their last wallpaper is gone would keep them on disk
//  with no way to remove them. Only ids the dependency service downloaded are candidates, never an
//  item the user downloaded themselves, and one still reached from any remaining item (directly or
//  through another dependency) is kept.
//

import Foundation

enum WorkshopDependencyCleanup {
    /// The dependency ids in `library` that no other item there references, directly or through a chain.
    static func orphanedDependencies(in library: URL, dependencyIds: Set<String>) -> Set<String> {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)
        } catch {
            OWELog.error(.workshop, "Can't list \(library.path) for unused workshop dependencies: \(error)")
            return []
        }
        let present = Set(folders.map(\.lastPathComponent)).intersection(dependencyIds)
        var queue = folders.filter { !dependencyIds.contains($0.lastPathComponent) }
        var reached = Set<String>()
        while let folder = queue.popLast() {
            for id in WorkshopDependencyResolver.referencedWorkshopIds(inItemAt: folder)
            where present.contains(id) && reached.insert(id).inserted {
                queue.append(library.appending(path: id, directoryHint: .isDirectory))
            }
        }
        return present.subtracting(reached)
    }

    /// Deletes the orphaned dependencies of `library`, forgets them and returns their ids. Scans
    /// every item's references, so call it off the main thread.
    @discardableResult
    static func removeOrphans(in library: URL, index: WorkshopDependencyIndex) -> [String] {
        var removed: [String] = []
        for id in orphanedDependencies(in: library, dependencyIds: index.ids).sorted() {
            let folder = library.appending(path: id, directoryHint: .isDirectory)
            do {
                try FileManager.default.removeItem(at: folder)
                index.remove(id)
                removed.append(id)
                OWELog.info(.workshop, "Removed workshop dependency \(id): no wallpaper in the library uses it any more")
            } catch {
                OWELog.error(.workshop, "Can't remove unused workshop dependency \(folder.path): \(error)")
            }
        }
        return removed
    }
}
