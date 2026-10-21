import Foundation
import Darwin

@main struct AuthorPropertyAssetTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-author-assets-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        func rejects(_ message: String, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure(message) } catch { checks += 1 }
        }
        let projectData = Data(#"{"type":"web","general":{"properties":{"image":{"type":"file","value":"/not/a/grant.png","fileType":"image"},"gallery":{"type":"directory","value":"","fileType":"image","mode":"fetchall"},"random":{"type":"directory","value":"","fileType":"image","mode":"ondemand"},"text":{"type":"textinput","value":""}}}}"#.utf8)
        let project = try AuthorPropertyProject.parse(data: projectData, projectURL: root.appendingPathComponent("project.json"))
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("hello image.png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6p9sAAAAASUVORK5CYII=")!
        try png.write(to: image)
        let vault = root.appendingPathComponent("vault", isDirectory: true)
        let store = AuthorPropertyAssetStore(directory: vault)
        do {
            let restrictedParent = root.appendingPathComponent("traverse-only-source", isDirectory: true)
            try fm.createDirectory(at: restrictedParent, withIntermediateDirectories: true)
            let selectedFile = restrictedParent.appendingPathComponent("selected.png")
            try png.write(to: selectedFile)
            try fm.setAttributes([.posixPermissions: 0o100], ofItemAtPath: restrictedParent.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedParent.path) }
            let deniedDirectory = open(restrictedParent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            let parentReadDenied = deniedDirectory < 0 && errno == EACCES
            if deniedDirectory >= 0 { close(deniedDirectory) }
            check(parentReadDenied, "fixture explicitly denies parent directory read while permitting traversal")
            let leastPrivilegeStore = AuthorPropertyAssetStore(directory: root.appendingPathComponent("least-privilege-vault", isDirectory: true))
            let leastPrivilege = try await leastPrivilegeStore.selectFile(selectedFile, itemID: UUID(), propertyKey: "image", project: project)
            check(leastPrivilege.kind == .file && leastPrivilege.assetCount == 1, "single-file selection succeeds without parent directory read permission")
            check(try Data(contentsOf: leastPrivilege.assets[0].url) == png, "least-privilege selection copies exact media bytes")
            let parentAttributes = try fm.attributesOfItem(atPath: restrictedParent.path)
            check(try Data(contentsOf: selectedFile) == png && (parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o100,
                  "single-file import preserves source bytes and never broadens parent permissions")
        }
        let item = UUID(), other = UUID()
        check(try await store.grants(itemID: item).isEmpty, "schema default path is not a grant")
        check(!fm.fileExists(atPath: vault.path), "reading nonexistent grants has no filesystem writes")
        let checkpoint = try await store.checkpoint(itemID: item, propertyKey: "image")
        let fileGrant = try await store.selectFile(image, itemID: item, propertyKey: "image", project: project)
        check(fileGrant.kind == .file && fileGrant.assetCount == 1, "explicit file selection grants one immutable copy")
        check(fileGrant.value.stringValue == fileGrant.assets[0].virtualPath, "property receives virtual asset value")
        check(fileGrant.value.stringValue?.hasPrefix("__gw_assets__/") == true && !fileGrant.value.stringValue!.contains(root.path), "property does not disclose native path")
        check(try Data(contentsOf: fileGrant.assets[0].url) == png, "managed bytes match selected source")
        check(try Data(contentsOf: image) == png, "selected source remains unchanged")
        check(try await store.grants(itemID: other).isEmpty, "item UUID isolation")
        let manifest = try await store.manifest(itemID: item)
        check(manifest.assets == fileGrant.assets && manifest.directories.isEmpty, "file grant native manifest")
        check(manifest.assets.allSatisfy { $0.url.path.hasPrefix(manifest.rootURL.path + "/") }, "manifest assets stay within item root")
        let restart = AuthorPropertyAssetStore(directory: vault)
        check(try await restart.grants(itemID: item).first?.value == fileGrant.value, "grants survive actor restart")
        check(try await restart.refresh(itemID: item, propertyKey: "image", project: project).revision == fileGrant.revision, "bookmark refresh with no changes keeps stable revision")
        let attributes = try fm.attributesOfItem(atPath: fileGrant.assets[0].url.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "managed copy private permissions")
        let rootAttributes = try fm.attributesOfItem(atPath: manifest.rootURL.path)
        check((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "item vault private permissions")
        try await store.restore(checkpoint, replacingRevision: fileGrant.revision)
        check(try await store.grants(itemID: item).isEmpty, "failed override can restore missing old grant")
        check(fm.fileExists(atPath: fileGrant.assets[0].url.path), "rollback retains versions until caller confirms no host references")
        try await store.pruneUnreferencedAssets(itemID: item)
        check(!fm.fileExists(atPath: fileGrant.assets[0].url.path), "explicit safe prune removes unreferenced copy")

        let gallery = root.appendingPathComponent("gallery", isDirectory: true)
        try fm.createDirectory(at: gallery, withIntermediateDirectories: true)
        let first = gallery.appendingPathComponent("one.png"), second = gallery.appendingPathComponent("two.png")
        try png.write(to: first)
        let initial = try await store.selectDirectory(gallery, itemID: item, propertyKey: "gallery", project: project)
        check(initial.directoryMode == .fetchall && initial.assetCount == 1, "fetchall initial selection")
        check(initial.value.stringValue == "__gw_assets__/\(initial.id.uuidString)", "directory gets opaque virtual namespace")
        try png.write(to: second)
        let added = try await store.refresh(itemID: item, propertyKey: "gallery", project: project)
        check(added.assetCount == 2 && added.revision != initial.revision, "directory refresh detects additions")
        check(added.assets.contains { $0.virtualPath == initial.assets[0].virtualPath && $0.contentIdentity == initial.assets[0].contentIdentity }, "directory addition keeps unchanged file virtual path and identity")
        check(added.value == initial.value, "same directory retains stable property namespace when contents change")
        let oldCheckpoint = try await store.checkpoint(itemID: item, propertyKey: "gallery")
        try (png + Data([0])).write(to: first)
        let changed = try await store.refresh(itemID: item, propertyKey: "gallery", project: project)
        check(Set(changed.assets.map(\.contentIdentity)) != Set(added.assets.map(\.contentIdentity)), "directory refresh detects content edits")
        check(changed.assets.first { $0.virtualPath == initial.assets[0].virtualPath }?.contentIdentity != initial.assets[0].contentIdentity, "modified file keeps its path with changed identity for addedOrChanged callback")
        check(changed.assets[1].virtualPath == added.assets[1].virtualPath && changed.assets[1].contentIdentity == added.assets[1].contentIdentity, "editing one file does not re-add unaffected files")
        try fm.removeItem(at: second)
        let removed = try await store.refresh(itemID: item, propertyKey: "gallery", project: project)
        check(removed.assetCount == 1 && removed.revision != changed.revision, "directory refresh detects removals")
        check(removed.assets[0].virtualPath == initial.assets[0].virtualPath && removed.value == initial.value, "deletion retains surviving virtual file path and directory namespace")
        await rejects("stale rollback cannot override newer grant") { try await store.restore(oldCheckpoint, replacingRevision: changed.revision) }
        check(try await store.grants(itemID: item).first?.revision == removed.revision, "newer choice remains after stale rollback")
        let random = try await store.selectDirectory(gallery, itemID: item, propertyKey: "random", project: project)
        let directoryManifest = try await store.manifest(itemID: item)
        check(directoryManifest.directories.count == 2 && directoryManifest.assets.count == 2, "manifest contains both directory modes and flattened assets")
        check(directoryManifest.directories.first { $0.propertyKey == "random" }?.mode == .ondemand && random.assetCount == 1, "ondemand exact allowed candidates available to runtime")
        check(try await store.sourceURLs(itemID: item).count == 2, "native monitoring can resolve only explicitly bookmarked sources")
        check(directoryManifest.assets.allSatisfy { $0.name == "resource.png" }, "virtual basenames omit private source names and URL metacharacters")
        let renameSource = root.appendingPathComponent("rename-source", isDirectory: true)
        try fm.createDirectory(at: renameSource, withIntermediateDirectories: true)
        try png.write(to: renameSource.appendingPathComponent("stable.png"))
        let renameItem = UUID()
        let beforeRename = try await store.selectDirectory(renameSource, itemID: renameItem, propertyKey: "gallery", project: project)
        let afterRenameURL = root.appendingPathComponent("renamed-source", isDirectory: true)
        try fm.moveItem(at: renameSource, to: afterRenameURL)
        let afterRename = try await store.refresh(itemID: renameItem, propertyKey: "gallery", project: project)
        check(afterRename.value == beforeRename.value && afterRename.assets[0].virtualPath == beforeRename.assets[0].virtualPath, "bookmark root rename retains directory and file virtual namespaces")
        check(afterRename.revision == beforeRename.revision, "root rename alone does not report content modifications")
        check(try await store.sourceURLs(itemID: renameItem).first?.resolvingSymlinksInPath() == afterRenameURL.resolvingSymlinksInPath(), "monitoring roots follow bookmark directory rename")
        let renameMetadata = vault.appendingPathComponent(renameItem.uuidString).appendingPathComponent("grants.json")
        let validRenameMetadata = try Data(contentsOf: renameMetadata)
        var tamperedDocument = try JSONSerialization.jsonObject(with: validRenameMetadata) as! [String: Any]
        var tamperedRecords = tamperedDocument["records"] as! [String: Any]
        var tamperedRecord = tamperedRecords["gallery"] as! [String: Any]
        tamperedRecord["relativeTokens"] = ["stable.png": "../outside"]
        tamperedRecords["gallery"] = tamperedRecord; tamperedDocument["records"] = tamperedRecords
        let tamperedBytes = try JSONSerialization.data(withJSONObject: tamperedDocument)
        try tamperedBytes.write(to: renameMetadata)
        await rejects("corrupt persisted token cannot become a filesystem path") { _ = try await store.refresh(itemID: renameItem, propertyKey: "gallery", project: project) }
        check(try Data(contentsOf: renameMetadata) == tamperedBytes, "corrupt token metadata remains untouched")
        try validRenameMetadata.write(to: renameMetadata)

        await rejects("type mismatch cannot grant resource") { _ = try await store.selectFile(image, itemID: item, propertyKey: "text", project: project) }
        let bad = source.appendingPathComponent("script.html")
        try Data("<script>bad()</script>".utf8).write(to: bad)
        await rejects("file type filter blocks executable HTML") { _ = try await store.selectFile(bad, itemID: item, propertyKey: "image", project: project) }
        let link = source.appendingPathComponent("linked.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: image)
        await rejects("selected symlink is not an explicit file grant") { _ = try await store.selectFile(link, itemID: item, propertyKey: "image", project: project) }
        let escape = gallery.appendingPathComponent("escape.png")
        try fm.createSymbolicLink(at: escape, withDestinationURL: image)
        await rejects("directory cannot escape via symlink") { _ = try await store.refresh(itemID: item, propertyKey: "gallery", project: project) }
        check(try await store.grants(itemID: item).first { $0.propertyKey == "gallery" }?.revision == removed.revision, "failed directory refresh preserves old committed grant")
        try fm.removeItem(at: escape)
        var limits = AuthorPropertyAssetStore.Limits()
        limits.maximumFileBytes = 10
        let bounded = AuthorPropertyAssetStore(directory: root.appendingPathComponent("bounded"), limits: limits)
        await rejects("actual resource bytes bounded") { _ = try await bounded.selectFile(image, itemID: item, propertyKey: "image", project: project) }
        check(try await bounded.grants(itemID: item).isEmpty, "size failure does not commit grant")
        await rejects("directory containing managed vault cannot recursively grant it") { _ = try await store.selectDirectory(root, itemID: other, propertyKey: "gallery", project: project) }
        var countLimits = AuthorPropertyAssetStore.Limits()
        countLimits.maximumFiles = 1
        try png.write(to: second)
        let countBounded = AuthorPropertyAssetStore(directory: root.appendingPathComponent("count-bounded"), limits: countLimits)
        await rejects("directory file count bounded") { _ = try await countBounded.selectDirectory(gallery, itemID: item, propertyKey: "gallery", project: project) }
        try fm.removeItem(at: second)
        let cancelled = Task { try await store.selectFile(image, itemID: other, propertyKey: "image", project: project) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled selection should fail") } catch { check(error is CancellationError, "selection cancellation is propagated") }
        check(try await store.grants(itemID: other).isEmpty, "cancelled selection grants nothing")
        let large = source.appendingPathComponent("large.png")
        fm.createFile(atPath: large.path, contents: nil)
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: 32 * 1024 * 1024)
        try largeHandle.close()
        let duringCopy = Task { try await store.selectFile(large, itemID: other, propertyKey: "image", project: project) }
        try await Task.sleep(for: .milliseconds(5))
        duringCopy.cancel()
        do { _ = try await duringCopy.value; preconditionFailure("in-flight copy cancellation should fail") } catch { check(error is CancellationError, "in-flight copy propagates cancellation") }
        check(try await store.grants(itemID: other).isEmpty, "in-flight cancellation publishes no grant")
        let otherRoot = vault.appendingPathComponent(other.uuidString)
        check((try? fm.contentsOfDirectory(atPath: otherRoot.path))?.isEmpty == true, "in-flight cancellation cleans its staging version")
        let external = root.appendingPathComponent("external", isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let unsafeVault = root.appendingPathComponent("unsafe-vault")
        try fm.createSymbolicLink(at: unsafeVault, withDestinationURL: external)
        let unsafe = AuthorPropertyAssetStore(directory: unsafeVault)
        await rejects("symlink managed vault refused") { _ = try await unsafe.selectFile(image, itemID: other, propertyKey: "image", project: project) }
        check(try fm.contentsOfDirectory(atPath: external.path).isEmpty, "rejected vault has no external writes")
        let oldBytes = try Data(contentsOf: first)
        try await store.revoke(itemID: item, propertyKey: "gallery")
        check(try await store.manifest(itemID: item).directories.count == 1, "revoke removes directory from authorized manifest")
        try await store.revokeAll(itemID: item)
        check(try await store.manifest(itemID: item).assets.isEmpty, "revoke all removes all effective permissions")
        try await store.pruneUnreferencedAssets(itemID: item)
        check(try Data(contentsOf: first) == oldBytes && Data(contentsOf: image) == png, "revoke and cleanup never modify selected sources")
        let grantFile = vault.appendingPathComponent(item.uuidString).appendingPathComponent("grants.json")
        try Data("corrupt".utf8).write(to: grantFile)
        await rejects("revokeAll does not overwrite corrupt grants") { try await store.revokeAll(itemID: item) }
        check(try Data(contentsOf: grantFile) == Data("corrupt".utf8), "corrupt metadata retained for recovery")
        print("AuthorPropertyAssetTests: \(checks) passed; explicit bookmarks, private immutable vault, bounded copies, directory changes, CAS rollback, revoke and item isolation")
    }
}
