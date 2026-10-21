import Foundation

@main struct WebProjectImportSafetyTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("gw-web-import-safety-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { failures.append(name); print("FAIL: \(name)") }
        }
        func project(_ name: String, extras: [String: Data] = [:]) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"type":"web","file":"index.html","title":"Fixture"}"#.utf8).write(to: directory.appendingPathComponent("project.json"))
            try Data("<html>fixture</html>".utf8).write(to: directory.appendingPathComponent("index.html"))
            for (name, bytes) in extras { try bytes.write(to: directory.appendingPathComponent(name)) }
            return directory
        }
        func newStore(_ name: String) -> VideoLibraryStore {
            VideoLibraryStore(storage: AppStorage(root: root.appendingPathComponent(name, isDirectory: true)))
        }
        func managedProjects(_ store: VideoLibraryStore) -> [URL] {
            (try? fm.contentsOfDirectory(at: store.storage.mediaDirectory.appendingPathComponent("WebProjects"), includingPropertiesForKeys: nil)) ?? []
        }
        let source = try project("source", extras: ["asset.txt": Data("original resource".utf8)])
        let originalConfig = try Data(contentsOf: source.appendingPathComponent("project.json"))
        let originalResource = try Data(contentsOf: source.appendingPathComponent("asset.txt"))
        let store = newStore("library")
        let imported = try await WebWallpaperProjectImporter.importProject(source, store: store)
        check(imported.isWebWallpaper && imported.fileURL.resolvingSymlinksInPath().path.hasPrefix(store.storage.mediaDirectory.resolvingSymlinksInPath().path + "/"), "managed web record")
        check(imported.originalURL?.resolvingSymlinksInPath() == source.appendingPathComponent("project.json").resolvingSymlinksInPath(), "source path retained")
        check(try Data(contentsOf: imported.fileURL) == originalConfig, "project copied byte-for-byte")
        check(try Data(contentsOf: imported.fileURL.deletingLastPathComponent().appendingPathComponent("asset.txt")) == originalResource, "resources copied byte-for-byte")
        check(try Data(contentsOf: source.appendingPathComponent("project.json")) == originalConfig, "source configuration unchanged")
        check(try Data(contentsOf: source.appendingPathComponent("asset.txt")) == originalResource, "source resources unchanged")
        let same = try await WebWallpaperProjectImporter.importProject(source, store: store)
        check(same.id == imported.id && store.items.count == 1 && managedProjects(store).count == 1, "identical copy deduplicates and cleans staging")
        let reloaded = VideoLibraryStore(storage: store.storage)
        check(reloaded.items.first?.id == imported.id && reloaded.items.first?.isWebWallpaper == true, "web record durable on restart")
        let legacy = WallpaperItem(title: "Legacy", filePath: root.appendingPathComponent("old.mp4").path)
        let legacyData = try LibraryPersistence.makeEncoder().encode(LibraryDocument(items: [legacy]))
        check(!String(decoding: legacyData, as: UTF8.self).contains("contentKind"), "legacy JSON omits content kind")
        check(try LibraryPersistence.makeDecoder().decode(LibraryDocument.self, from: legacyData).items.first?.isWebWallpaper == false, "legacy record remains video")

        // Distinct file trees must not hash as the same concatenated byte stream.
        let collisionA = try project("boundary-a", extras: ["a.txt": Data("b.txt\0X".utf8)])
        let collisionB = try project("boundary-b", extras: ["a.txt": Data(), "b.txt": Data("X".utf8)])
        let boundaries = newStore("boundaries")
        let a = try await WebWallpaperProjectImporter.importProject(collisionA, store: boundaries)
        let b = try await WebWallpaperProjectImporter.importProject(collisionB, store: boundaries)
        check(a.id != b.id && a.contentFingerprint != b.contentFingerprint && boundaries.items.count == 2, "file boundary fingerprint cannot collide structurally")

        let bad = try project("bad-entry")
        try Data(#"{"type":"web","file":"../source/index.html"}"#.utf8).write(to: bad.appendingPathComponent("project.json"))
        do { _ = try await WebWallpaperProjectImporter.importProject(bad, store: store); check(false, "outside entry refused") }
        catch { check(true, "outside entry refused") }
        check(store.items.count == 1 && managedProjects(store).count == 1, "failed descriptor adds no record or copy")
        let linked = try project("linked-resource")
        try fm.createSymbolicLink(at: linked.appendingPathComponent("escape.txt"), withDestinationURL: source.appendingPathComponent("asset.txt"))
        do { _ = try await WebWallpaperProjectImporter.importProject(linked, store: store); check(false, "symlink resource refused") }
        catch { check(true, "symlink resource refused") }
        check(store.items.count == 1 && managedProjects(store).count == 1, "failed copy cleans partially created project")

        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createDirectory(at: alias, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: alias.appendingPathComponent("project.json"), withDestinationURL: source.appendingPathComponent("project.json"))
        do { _ = try await WebWallpaperProjectImporter.importProject(alias, store: store); check(false, "selected project symlink refused") }
        catch { check(true, "selected project symlink refused") }

        let blocked = newStore("blocked-save")
        let diskBefore = try LibraryPersistence.makeEncoder().encode(LibraryDocument())
        try diskBefore.write(to: blocked.storage.libraryFile)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.storage.root.path)
        do { _ = try await WebWallpaperProjectImporter.importProject(source, store: blocked); check(false, "persistence failure thrown") }
        catch { check(true, "persistence failure thrown") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.storage.root.path)
        check(blocked.items.isEmpty && managedProjects(blocked).isEmpty, "failed persistence leaves no in-memory record or managed copy")
        check(try Data(contentsOf: blocked.storage.libraryFile) == diskBefore, "failed persistence preserves prior bytes")

        let escapedStore = newStore("escaped-storage")
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.removeItem(at: escapedStore.storage.mediaDirectory)
        try fm.createSymbolicLink(at: escapedStore.storage.mediaDirectory, withDestinationURL: outside)
        do { _ = try await WebWallpaperProjectImporter.importProject(source, store: escapedStore); check(false, "symlink managed Media refused") }
        catch { check(true, "symlink managed Media refused") }
        check(!fm.fileExists(atPath: outside.appendingPathComponent("WebProjects").path), "rejected managed root creates nothing outside storage")

        let containing = try project("containing-library")
        let nestedStore = VideoLibraryStore(storage: AppStorage(root: containing.appendingPathComponent("nested-library", isDirectory: true)))
        do { _ = try await WebWallpaperProjectImporter.importProject(containing, store: nestedStore); check(false, "source containing managed destination refused") }
        catch { check(true, "source containing managed destination refused") }
        check(nestedStore.items.isEmpty && managedProjects(nestedStore).isEmpty, "recursive source rejection leaves no records or copies")

        let denied = try project("denied-subdirectory")
        let unreadable = denied.appendingPathComponent("private", isDirectory: true)
        try fm.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("must not silently disappear".utf8).write(to: unreadable.appendingPathComponent("required.txt"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        do { _ = try await WebWallpaperProjectImporter.importProject(denied, store: store); check(false, "unreadable subtree fails instead of partial success") }
        catch { check(true, "unreadable subtree fails instead of partial success") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unreadable.path)

        let cancelledStore = newStore("cancelled")
        let task = Task { try await WebWallpaperProjectImporter.importProject(source, store: cancelledStore) }
        task.cancel()
        do { _ = try await task.value; check(false, "cancelled import throws") }
        catch { check(error is CancellationError, "cancelled import throws CancellationError") }
        check(cancelledStore.items.isEmpty && managedProjects(cancelledStore).isEmpty, "cancellation leaves no record or partial project")
        print("Web project import safety: \(checks - failures.count)/\(checks) checks passed")
        if !failures.isEmpty { throw NSError(domain: "WebProjectImportSafety", code: failures.count, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "; ")]) }
    }
}
