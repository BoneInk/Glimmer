import Foundation

@MainActor final class CleanupProtectionBox { var urls = Set<URL>() }
actor CleanupTrashRecorder {
    private(set) var names: [String] = []
    func move(_ source: URL, to directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: source, to: destination)
        names.append(source.lastPathComponent)
        return destination
    }
}

@main @MainActor enum StorageCleanupProjectProtectionTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        checks += 1; print("PASS \(name)")
    }
    static func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    static func item(_ id: UUID, root: URL, kind: WallpaperContentKind) -> WallpaperItem {
        WallpaperItem(id: id, title: "Fixture", filePath: root.appendingPathComponent("project.json").path,
                      contentKind: kind)
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GW-Cleanup-Protection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let paths = GWManagedStoragePaths(root: root), media = paths.mediaDirectory
        let webID = UUID(), sceneID = UUID()
        let webRoot = media.appendingPathComponent("WebProjects/\(webID.uuidString)")
        let sceneRoot = media.appendingPathComponent("SceneProjects/\(sceneID.uuidString)")
        try write("{}", webRoot.appendingPathComponent("project.json"))
        try write("html", webRoot.appendingPathComponent("index.html"))
        try write("image", webRoot.appendingPathComponent("assets/image.png"))
        try write("{}", sceneRoot.appendingPathComponent("project.json"))
        try write("scene", sceneRoot.appendingPathComponent("assets/layer.bin"))
        let prefixSibling = media.appendingPathComponent("WebProjects/\(webID.uuidString)-other/orphan.bin")
        let ordinary = media.appendingPathComponent("orphan.mp4")
        try write("sibling", prefixSibling); try write("video", ordinary)
        let outside = root.appendingPathComponent("outside.bin"); try write("outside", outside)
        try fm.createSymbolicLink(at: media.appendingPathComponent("outside-link.bin"), withDestinationURL: outside)

        let web = item(webID, root: webRoot, kind: .web), scene = item(sceneID, root: sceneRoot, kind: .scene)
        let webProtection = GWStorageProtection.urls(for: web, storageRoot: root)
        let sceneProtection = GWStorageProtection.urls(for: scene, storageRoot: root)
        let webProtectionPaths = Set(webProtection.map { $0.standardizedFileURL.path })
        try check(webProtectionPaths.contains(webRoot.standardizedFileURL.path)
                  && webProtectionPaths.contains(root.appendingPathComponent("AuthorPropertyAssets/\(webID.uuidString)").standardizedFileURL.path)
                  && webProtectionPaths.contains(root.appendingPathComponent("AuthorPropertyOverrides/\(webID.uuidString).json").standardizedFileURL.path),
                  "Web reference expands to its full project and author-resource paths")
        try check(Set(sceneProtection.map { $0.standardizedFileURL.path }).contains(sceneRoot.standardizedFileURL.path),
                  "Scene reference expands to its full managed project root")

        let scan = GWStorageScanner.scan(paths: paths, protectedURLs: webProtection.union(sceneProtection))
        let candidatePaths = Set(scan.candidates.map { $0.url.standardizedFileURL.path })
        try check(!candidatePaths.contains(where: { $0.hasPrefix(webRoot.path + "/") })
                  && !candidatePaths.contains(where: { $0.hasPrefix(sceneRoot.path + "/") }),
                  "scanner excludes every file below referenced Web and Scene project roots")
        try check(candidatePaths.contains(prefixSibling.path) && candidatePaths.contains(ordinary.path),
                  "path-component boundary leaves similarly prefixed siblings and ordinary orphan media cleanable")
        let outsideBytes = try Data(contentsOf: outside)
        try check(!candidatePaths.contains(media.appendingPathComponent("outside-link.bin").path)
                  && outsideBytes == Data("outside".utf8),
                  "scanner rejects a symlink without following or changing its target")

        let beforeProtection = GWStorageScanner.scan(paths: paths, protectedURLs: [])
        let latePath = webRoot.appendingPathComponent("index.html").standardizedFileURL.path
        guard let lateCandidate = beforeProtection.candidates.first(where: { $0.url.standardizedFileURL.path == latePath }) else {
            throw Failure(message: "late-protection fixture was not initially cleanable")
        }
        let late = GWStorageScanner.recheck(candidate: lateCandidate, allowedRoot: media,
            protectedPaths: GWStorageScanner.normalizedProtected([webRoot]))
        if case .skipped = late { checks += 1; print("PASS deletion recheck honors a project root protected after scanning") }
        else { throw Failure(message: "late project protection was ignored") }

        let controllerRoot = root.appendingPathComponent("Controller"), controllerPaths = GWManagedStoragePaths(root: controllerRoot)
        let controlledRoot = controllerPaths.mediaDirectory.appendingPathComponent("WebProjects/controlled")
        let controlledManifest = controlledRoot.appendingPathComponent("project.json")
        let controlledAsset = controlledRoot.appendingPathComponent("asset.bin")
        let controlledOrphan = controllerPaths.mediaDirectory.appendingPathComponent("orphan.bin")
        try write("{}", controlledManifest); try write("asset", controlledAsset); try write("orphan", controlledOrphan)
        let box = CleanupProtectionBox(), recorder = CleanupTrashRecorder(), trash = root.appendingPathComponent("FakeTrash")
        let controller = GWStorageCleanupController(paths: controllerPaths, protectedURLsProvider: { box.urls },
            trashMover: { source in try await recorder.move(source, to: trash) })
        await controller.refreshInventory()
        box.urls = [controlledRoot]
        let result = await controller.performCleanup(categories: [.unreferencedMedia])
        let moved = await recorder.names
        try check(result.removedCount == 1 && moved == ["orphan.bin"]
                  && fm.fileExists(atPath: controlledManifest.path) && fm.fileExists(atPath: controlledAsset.path),
                  "controller rechecks newly protected project root before each move and preserves the complete tree")
        print("RESULT \(checks) managed project cleanup protection checks passed; temporary fixture and fake Trash only")
    }
}
