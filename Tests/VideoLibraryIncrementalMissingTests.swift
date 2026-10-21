import AppKit
import Foundation

struct LibrarySceneInspectionStub {}

enum SceneWallpaperInspector {
    static func inspectUsingAvailableEngineAssets(projectURL: URL) throws -> LibrarySceneInspectionStub {
        throw WebProjectError.invalid("Scene rendering is not part of this isolated library probe")
    }
}

enum SceneWallpaperRenderer {
    static func render(inspection: LibrarySceneInspectionStub, pixelSize: CGSize) throws -> CGImage {
        throw WebProjectError.invalid("Scene rendering is not part of this isolated library probe")
    }
}

@main @MainActor struct VideoLibraryIncrementalMissingTests {
    static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-video-library-incremental-\(UUID().uuidString)",
                       isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        func writeMedia(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("fixture-\(name)".utf8).write(to: url)
            return url
        }

        let storage = AppStorage(root: root.appendingPathComponent("App", isDirectory: true))
        try storage.prepareDirectories()
        let missingAURL = root.appendingPathComponent("missing-a.mp4")
        let missingBURL = root.appendingPathComponent("missing-b.mp4")
        let missingA = WallpaperItem(title: "Missing A", filePath: missingAURL.path)
        let missingB = WallpaperItem(title: "Missing B", filePath: missingBURL.path)
        _ = try LibraryPersistence.save(
            LibraryDocument(items: [missingA, missingB]), to: storage.libraryFile)
        let store = VideoLibraryStore(storage: storage)
        check(store.missingItemIDs == [missingA.id, missingB.id],
              "launch performs the full missing-file scan")

        // Restoring an unrelated old file is intentionally not discovered by an
        // incremental mutation; activation or the explicit command owns that scan.
        try Data("externally restored".utf8).write(to: missingAURL)
        let freshlyPresentURL = try writeMedia("freshly-present.mp4")
        let freshlyPresent = WallpaperItem(title: "Fresh", filePath: freshlyPresentURL.path)
        store.add(freshlyPresent)
        check(store.missingItemIDs == [missingA.id, missingB.id],
              "add checks only the new record instead of rescanning unrelated lost files")
        store.refreshMissingState()
        check(store.missingItemIDs == [missingB.id],
              "explicit full refresh still discovers externally restored files")

        var lost = store.item(withID: missingA.id)!
        lost.filePath = root.appendingPathComponent("moved-away.mp4").path
        store.update(lost)
        check(store.missingItemIDs == [missingA.id, missingB.id],
              "update marks its changed record missing without touching others")
        var restored = store.item(withID: missingA.id)!
        restored.filePath = missingAURL.path
        store.update(restored)
        check(store.missingItemIDs == [missingB.id],
              "update restores its changed record when the new path exists")

        let persistedMissingURL = root.appendingPathComponent("persisted-missing.mp4")
        var persistedMissing = WallpaperItem(title: "Persisted missing", filePath: persistedMissingURL.path)
        try store.addPersistedItem(persistedMissing)
        check(store.item(withID: persistedMissing.id) != nil &&
              store.missingItemIDs == [missingB.id, persistedMissing.id],
              "addPersistedItem checks and publishes exactly its persisted record")

        let replacementURL = try writeMedia("replacement.mp4")
        persistedMissing.filePath = replacementURL.path
        try store.replacePersistedItem(persistedMissing)
        check(store.item(withID: persistedMissing.id)?.filePath == replacementURL.path &&
              store.missingItemIDs == [missingB.id],
              "replacePersistedItem checks only the replacement record")

        persistedMissing.filePath = root.appendingPathComponent("replacement-lost.mp4").path
        try store.replacePersistedItem(persistedMissing)
        check(store.missingItemIDs == [missingB.id, persistedMissing.id],
              "replacement can transition a record to missing")

        store.relink(id: persistedMissing.id, to: replacementURL, probe: nil)
        check(store.missingItemIDs == [missingB.id] &&
              store.item(withID: persistedMissing.id)?.filePath == replacementURL.path,
              "relink clears missing state for its record only")

        let missingDURL = root.appendingPathComponent("missing-d.mp4")
        let missingD = WallpaperItem(title: "Missing D", filePath: missingDURL.path)
        try store.addPersistedItem(missingD)
        store.remove(id: missingB.id)
        check(store.item(withID: missingB.id) == nil &&
              store.missingItemIDs == [missingD.id] &&
              store.item(withID: missingD.id) != nil,
              "removing a record only subtracts that ID from missing state")

        // A failed atomic write must leave both the item array and derived missing
        // state untouched, including for replacement commits.
        store.flush()
        try fm.removeItem(at: storage.libraryFile)
        try fm.createDirectory(at: storage.libraryFile, withIntermediateDirectories: true)
        let failedAdd = WallpaperItem(
            title: "Failed add", filePath: root.appendingPathComponent("failed-add.mp4").path)
        let itemsBeforeFailure = store.items
        let missingBeforeFailure = store.missingItemIDs
        var addFailed = false
        do { try store.addPersistedItem(failedAdd) } catch { addFailed = true }
        check(addFailed && store.items == itemsBeforeFailure &&
              store.missingItemIDs == missingBeforeFailure &&
              store.item(withID: failedAdd.id) == nil,
              "addPersistedItem write failure publishes neither item nor missing-state change")

        let originalD = store.item(withID: missingD.id)!
        var failedReplacement = originalD
        failedReplacement.title = "Must not publish"
        failedReplacement.filePath = replacementURL.path
        var replaceFailed = false
        do { try store.replacePersistedItem(failedReplacement) } catch { replaceFailed = true }
        check(replaceFailed && store.item(withID: missingD.id) == originalD &&
              store.missingItemIDs == missingBeforeFailure,
              "replacePersistedItem write failure publishes neither replacement nor missing-state change")

        try fm.removeItem(at: storage.libraryFile)
        store.flush()
        let restarted = VideoLibraryStore(storage: storage)
        check(Set(restarted.items.map(\.id)) == Set(store.items.map(\.id)) &&
              restarted.missingItemIDs == store.missingItemIDs &&
              restarted.item(withID: missingD.id)?.title == originalD.title,
              "successful mutations and incremental missing state survive restart")

        print("VideoLibraryIncrementalMissingTests: \(checks) checks passed; incremental add/update/addPersisted/replace/relink/lost/remove and failed-write transactional boundaries")
    }
}
