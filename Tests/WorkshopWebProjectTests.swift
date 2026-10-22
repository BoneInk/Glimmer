import CryptoKit
import Darwin
import Foundation

@main struct WorkshopWebProjectTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-workshop-web-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ name: String) { checks += 1; precondition(value, name) }
        func rejects(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure(name) } catch { checks += 1 }
        }
        func writeProject(_ directory: URL, type: String = "web", entry: String = "index.html") throws {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["type": type, "file": entry, "title": "Web fixture", "preview": "poster.svg"])
                .write(to: directory.appendingPathComponent("project.json"))
            try Data("<html><script src='script.js'></script><link rel='stylesheet' href='style.css'></html>".utf8).write(to: directory.appendingPathComponent("index.html"))
            try Data("window.fixture=1;".utf8).write(to: directory.appendingPathComponent("script.js"))
            try Data("body{color:red}".utf8).write(to: directory.appendingPathComponent("style.css"))
            try Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).write(to: directory.appendingPathComponent("poster.svg"))
        }
        func referenceFingerprint(_ files: [(path: String, data: String)],
                                  ordering: WorkshopProjectTreeOrdering) -> String {
            var tree = SHA256()
            let ordered = files.sorted {
                WorkshopProjectTreeValidator.areInIncreasingOrder(
                    $0.path, $1.path, ordering: ordering)
            }
            for file in ordered {
                tree.update(data: Data(file.path.utf8))
                tree.update(data: Data([0]))
                tree.update(data: Data(SHA256.hash(data: Data(file.data.utf8))))
            }
            return tree.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let referenceTree = root.appendingPathComponent("reference-tree", isDirectory: true)
        try fm.createDirectory(at: referenceTree, withIntermediateDirectories: true)
        let referenceFiles: [(path: String, data: String)] = [
            ("assets/a.txt", "alpha"), ("assets/z.txt", "zulu"), ("index.html", "<html></html>")
        ]
        for file in referenceFiles {
            let target = referenceTree.appendingPathComponent(file.path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.data.utf8).write(to: target)
        }
        let canonicalReferenceTree = try WebProjectPaths.canonical(referenceTree)
        let referenceExcluded = root.appendingPathComponent("reference-excluded.json")
        let webTree = try WorkshopProjectTreeValidator.validate(
            root: canonicalReferenceTree, excluded: referenceExcluded, label: "Web", ordering: .string)
        let sceneTree = try WorkshopProjectTreeValidator.validate(
            root: canonicalReferenceTree, excluded: referenceExcluded, label: "Scene", ordering: .utf8)
        let webReference = referenceFingerprint(referenceFiles, ordering: .string)
        let sceneReference = referenceFingerprint(referenceFiles, ordering: .utf8)
        let pinnedReference = "807f9dc38daf2d1762d5704c2161d698bad45a4a3a6cba693f210604332ee002"
        check(webTree.contentFingerprint == webReference &&
              sceneTree.contentFingerprint == sceneReference &&
              webReference == pinnedReference &&
              webTree.totalByteSize == sceneTree.totalByteSize &&
              webTree.entries.map(\.path) == sceneTree.entries.map(\.path),
              "shared tree validator reproduces both existing Web and Scene fingerprint bytes and the pinned legacy digest")
        let decomposed = "e\u{301}.txt", precomposed = "é.txt"
        check(!WorkshopProjectTreeValidator.areInIncreasingOrder(
                decomposed, precomposed, ordering: .string) &&
              !WorkshopProjectTreeValidator.areInIncreasingOrder(
                precomposed, decomposed, ordering: .string) &&
              WorkshopProjectTreeValidator.areInIncreasingOrder(
                decomposed, precomposed, ordering: .utf8),
              "Web keeps Swift String ordering while Scene keeps UTF-8 byte ordering")
        let layout = SteamCMDLayout(root: root.appendingPathComponent("SteamCMD", isDirectory: true))
        let id = WorkshopItemID("123456")!
        let download = layout.downloadDirectory(for: id)
        try writeProject(download)
        let configBefore = try Data(contentsOf: download.appendingPathComponent("project.json"))
        let result = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download, declaredTags: ["Web"])
        guard case .web(let web) = result else { preconditionFailure("Web must not construct a video project") }
        check(result.videoProject == nil && result.kind == .web, "typed Web result has no video or probe")
        check(web.projectDirectory == web.downloadRoot && web.entryRelativePath == "index.html", "canonical Web root and HTML entry")
        check(web.resourceCount == 5 && web.totalByteSize > 0 && web.contentFingerprint.count == 64, "complete dependency tree measured and fingerprinted")
        check(web.projectPreviewFileName == "poster.svg", "project poster preserved")
        check(web.diagnostics.contains { $0.contains("远程") } && web.diagnostics.contains { $0.contains("尚未运行") }, "structural validation distinguishes runtime and network limits")
        check(try Data(contentsOf: web.projectJSONURL) == configBefore, "resolver never rewrites source project")
        let service = WorkshopDownloadService(layout: layout, executable: root.appendingPathComponent("never-executed"))
        let seed = WorkshopDownloadItem(publishedFileID: id.value, title: "Seed", kind: .video, declaredTags: [], previewImageURLString: nil, fileSizeBytes: nil)
        guard let restored = await service.verifyExisting(item: seed) else { preconditionFailure("existing Web must validate without Steam authentication") }
        check(restored.state == .completed && restored.kind == .web && restored.project == nil, "existing Web restores typed completion and never fills legacy video field")
        check(restored.validatedProject?.webProject?.contentFingerprint == web.contentFingerprint, "verified content identity retained")
        check(restored.metadata?.projectType == "web" && restored.metadata?.videoRelativePath == nil && restored.metadata?.videoByteSize == nil, "Web metadata has no fictitious video fields")
        check(restored.metadata?.projectJSONRelativePath == "project.json" && restored.metadata?.projectByteSize == web.totalByteSize, "Web metadata identifies actual project and byte size")
        let manifestData = try Data(contentsOf: layout.manifestURL(for: id))
        let manifestJSON = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        check(manifestJSON["schemaVersion"] as? Int == 2 && manifestJSON["projectFingerprint"] as? String == web.contentFingerprint, "v2 manifest records Web tree identity")
        check(manifestJSON["videoRelativePath"] == nil && manifestJSON["videoByteSize"] == nil && manifestJSON["videoSHA256"] == nil, "v2 Web manifest omits all video-only fields")
        let currentManifestURL = layout.manifestURL(for: id)
        let compatibilityManifestURL = layout.legacyManifestURL(for: id)
        try fm.moveItem(at: currentManifestURL, to: compatibilityManifestURL)
        guard let legacyFilenameRestored = await service.verifyExisting(item: seed) else {
            preconditionFailure("legacy manifest filename must remain readable")
        }
        check(legacyFilenameRestored.state == .completed,
              "downloaded project is restored from the legacy manifest filename")
        check(fm.fileExists(atPath: currentManifestURL.path),
              "legacy manifest restore rewrites the current Glimmer manifest without deleting compatibility input")
        let again = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(again.webProject?.contentFingerprint == web.contentFingerprint && again.webProject?.resourceCount == 5, "exact root host annotation excluded from hash and resource count")
        try Data("host marker changed".utf8).write(to: layout.manifestURL(for: id))
        let annotationChanged = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(annotationChanged.webProject?.contentFingerprint == web.contentFingerprint, "host annotation mutation does not change project identity")
        try Data("window.fixture=2;".utf8).write(to: download.appendingPathComponent("script.js"))
        let dependencyChanged = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(dependencyChanged.webProject?.contentFingerprint != web.contentFingerprint, "JavaScript dependency content changes tree identity")
        let assets = download.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        let authorSameName = assets.appendingPathComponent("glimmer-download.json")
        try Data("author resource A".utf8).write(to: authorSameName)
        let authorA = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        try Data("author resource B".utf8).write(to: authorSameName)
        let authorB = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(authorA.webProject?.contentFingerprint != authorB.webProject?.contentFingerprint, "same-name author resource outside exact root annotation still contributes to identity")
        let oversizedMedia = assets.appendingPathComponent("large.mp4")
        fm.createFile(atPath: oversizedMedia.path, contents: nil)
        let oversizedHandle = try FileHandle(forWritingTo: oversizedMedia)
        try oversizedHandle.truncate(atOffset: 32 * 1024 * 1024 + 1); try oversizedHandle.close()
        let limitedRuntime = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(limitedRuntime.webProject?.diagnostics.contains { $0.contains("32 MiB") } == false && limitedRuntime.videoProject == nil,
              "large binary media is not mislabeled as exceeding the buffered HTML document limit")
        try fm.removeItem(at: oversizedMedia)
        let oversizedHTML = assets.appendingPathComponent("large.html")
        fm.createFile(atPath: oversizedHTML.path, contents: nil)
        let htmlHandle = try FileHandle(forWritingTo: oversizedHTML)
        try htmlHandle.truncate(atOffset: 32 * 1024 * 1024 + 1); try htmlHandle.close()
        let documentLimited = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        check(documentLimited.webProject?.diagnostics.contains { $0.contains("HTML") && $0.contains("32 MiB") } == true,
              "buffered HTML document limits are still reported accurately")
        try fm.removeItem(at: oversizedHTML)
        let nestedDownload = root.appendingPathComponent("nested-download", isDirectory: true)
        let nestedProject = nestedDownload.appendingPathComponent("resolution/web", isDirectory: true)
        try writeProject(nestedProject)
        let nested = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: nestedDownload)
        check(nested.webProject?.projectJSONRelativePath == "resolution/web/project.json" && nested.webProject?.entryRelativePath == "index.html", "nested project download-root and document-root paths stay distinct")
        let badEntry = root.appendingPathComponent("bad-entry", isDirectory: true)
        try writeProject(badEntry, entry: "../nested-download/resolution/web/index.html")
        await rejects("entry traversal rejected") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: badEntry) }
        let remoteEntry = root.appendingPathComponent("remote-entry", isDirectory: true)
        try writeProject(remoteEntry, entry: "https://example.invalid/index.html")
        await rejects("remote document entry is not a local Web project") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: remoteEntry) }
        let linkedConfig = root.appendingPathComponent("linked-config", isDirectory: true)
        try fm.createDirectory(at: linkedConfig, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedConfig.appendingPathComponent("project.json"), withDestinationURL: nestedProject.appendingPathComponent("project.json"))
        await rejects("project JSON symlink outside download root rejected") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: linkedConfig) }
        let hugeConfig = root.appendingPathComponent("huge-config", isDirectory: true)
        try fm.createDirectory(at: hugeConfig, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 2_097_153).write(to: hugeConfig.appendingPathComponent("project.json"))
        await rejects("project JSON read bounded to2MiB") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: hugeConfig) }
        let linked = download.appendingPathComponent("outside.js")
        try fm.createSymbolicLink(at: linked, withDestinationURL: nestedProject.appendingPathComponent("script.js"))
        await rejects("symlink resource escape rejected") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download) }
        try fm.removeItem(at: linked)
        let special = download.appendingPathComponent("special.sock")
        check(mkfifo(special.path, 0o600) == 0, "test fixture can create a special file")
        await rejects("special file in project tree rejected") {
            _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download)
        }
        try fm.removeItem(at: special)
        let huge = download.appendingPathComponent("huge.bin")
        fm.createFile(atPath: huge.path, contents: nil)
        let hugeHandle = try FileHandle(forWritingTo: huge)
        try hugeHandle.truncate(atOffset: 2_147_483_649); try hugeHandle.close()
        await rejects("actual Web tree size is bounded before reading sparse payload") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download) }
        try fm.removeItem(at: huge)
        let tooMany = root.appendingPathComponent("too-many-entries", isDirectory: true)
        try fm.createDirectory(at: tooMany, withIntermediateDirectories: true)
        for index in 0...20_000 {
            fm.createFile(atPath: tooMany.appendingPathComponent(String(format: "f%05d", index)).path,
                          contents: Data())
        }
        do {
            _ = try WorkshopProjectTreeValidator.validate(
                root: try WebProjectPaths.canonical(tooMany),
                excluded: root.appendingPathComponent("too-many-excluded.json"),
                label: "Web", ordering: .string)
            preconditionFailure("20,001-entry tree must be rejected")
        } catch { checks += 1 }
        for type in ["scene", "application"] {
            let unsupported = root.appendingPathComponent(type, isDirectory: true)
            try writeProject(unsupported, type: type)
            await rejects("unsupported engine type remains rejected") { _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: unsupported) }
        }
        let videoRoot = root.appendingPathComponent("video", isDirectory: true)
        try fm.createDirectory(at: videoRoot, withIntermediateDirectories: true)
        let movie = videoRoot.appendingPathComponent("clip.mp4")
        try await SyntheticVideoWriter.write(to: movie)
        try Data(#"{"type":"video","file":"clip.mp4"}"#.utf8).write(to: videoRoot.appendingPathComponent("project.json"))
        let video = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: videoRoot)
        check(video.videoProject?.probe.isPlayable == true && video.webProject == nil, "video branch still uses real AVFoundation validation")
        var legacyItem = seed
        legacyItem.project = video.videoProject
        check(legacyItem.validatedProject == video && legacyItem.metadata?.projectType == "video", "legacy video fixtures retain typed metadata fallback")
        let oldJSON = Data(#"{"schemaVersion":1,"appID":431960,"publishedFileID":"123456","title":"Old","projectType":"video","projectJSONRelativePath":"project.json","videoRelativePath":"clip.mp4","videoByteSize":123,"validatedAt":"2026-10-18T00:00:00Z","declaredTags":[],"appVersion":"0.7.0"}"#.utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let oldManifest = try decoder.decode(WorkshopDownloadManifest.self, from: oldJSON)
        check(oldManifest.schemaVersion == 1 && oldManifest.videoByteSize == 123 && oldManifest.projectFingerprint == nil, "v1 video manifest remains decodable")
        let linkedID = WorkshopItemID("654321")!
        let linkedDownload = layout.downloadDirectory(for: linkedID)
        try fm.createSymbolicLink(at: linkedDownload, withDestinationURL: nestedProject)
        var linkedSeed = seed; linkedSeed.publishedFileID = linkedID.value
        check(await service.verifyExisting(item: linkedSeed) == nil, "disk restore refuses symlink download directories")
        let cancelled = Task { try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: download) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled resolve must throw") } catch { check(error is CancellationError, "Web validation cancellation propagates without fake success") }
        check(WorkshopItemKind.web.isSupportedWallpaper && !WorkshopItemKind.web.isSupportedVideo && WorkshopItemKind.web.unsupportedReason == nil, "Web download support is distinct from video-only operations")
        check(WorkshopItemKind.scene.isSupportedWallpaper && !WorkshopItemKind.scene.isSupportedVideo, "Scene candidate requires real subset validation without video support")
        var sceneSeed = seed; sceneSeed.kind = .application
        await rejects("unsupported type preflight does not invoke Steam or read account state") {
            _ = try await service.download(item: sceneSeed, username: nil, progress: { _ in }, logLine: { _ in })
        }
        print("WorkshopWebProjectTests: \(checks) passed; typed Web validation, complete tree identity, legacy video compatibility, safe reload and v2 manifests; no Steam account/network execution")
    }
}
