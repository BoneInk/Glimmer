import CryptoKit
import Darwin
import Foundation

private final class DeliveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<WorkshopResolvedProject, Error>?
    private var requested = false
    func attach(_ task: Task<WorkshopResolvedProject, Error>) { lock.lock(); self.task = task; let cancel = requested; lock.unlock(); if cancel { task.cancel() } }
    func cancel() { lock.lock(); requested = true; let task = task; lock.unlock(); task?.cancel() }
}

@main struct ProjectDeliveryTests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-project-delivery-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks.append(name) }
        func rejects(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure(name) } catch { checks.append(name) }
        }
        func write(_ data: String, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(data.utf8).write(to: url)
        }
        func web(_ url: URL) throws {
            try write("{\"type\":\"web\",\"file\":\"index.html\",\"title\":\"Original fixture\"}", to: url.appendingPathComponent("project.json"))
            try write("<html><link rel='stylesheet' href='assets/style.css'><body>original</body></html>", to: url.appendingPathComponent("index.html"))
            try write("body{color:red}", to: url.appendingPathComponent("assets/style.css"))
            try write("author resource, not host annotation", to: url.appendingPathComponent("assets/glimmer-download.json"))
        }
        func tree(_ directory: URL) throws -> [String: Data] {
            let prefix = directory.path + "/"
            let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])!
            var result: [String: Data] = [:]
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(file.path.dropFirst(prefix.count))] = try Data(contentsOf: file)
            }
            return result
        }
        func inode(_ url: URL) -> UInt64 { var value = stat(); precondition(lstat(url.path, &value) == 0); return value.st_ino }
        let source = root.appendingPathComponent("helper/items/123/456/content")
        try web(source)
        let before = try tree(source)
        let layout = SteamCMDLayout(root: root.appendingPathComponent("managed/SteamCMD"))
        let id = WorkshopItemID("123")!
        let item = WorkshopDownloadItem(publishedFileID: id.value, title: "Discovery title", kind: .web,
            declaredTags: ["Web", "Nature"], previewImageURLString: "https://example.invalid/fixture.jpg", fileSizeBytes: 123)
        let delivery = SteamContentProjectDelivery(layout: layout)
        let result = try await delivery.deliver(contentURL: source, item: item, progress: { _ in })
        let destination = layout.downloadDirectory(for: id)
        check(result.kind == .web && result.videoProject == nil, "Web delivery uses real resolver without fabricated video probe")
        check(result.projectRoot == WorkshopProjectResolver.canonicalURL(destination) && result.projectJSONURL == WorkshopProjectResolver.canonicalURL(destination).appendingPathComponent("project.json"), "all returned URLs point at final managed download root")
        check(try tree(source) == before && !fm.fileExists(atPath: source.appendingPathComponent("glimmer-download.json").path), "helper exact tree remains unchanged and has no host manifest")
        check(try Data(contentsOf: destination.appendingPathComponent("assets/style.css")) == before["assets/style.css"], "nested dependency copied exactly")
        check(try Data(contentsOf: destination.appendingPathComponent("assets/glimmer-download.json")) == before["assets/glimmer-download.json"], "author nested same-name resource preserved")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifestData = try Data(contentsOf: layout.manifestURL(for: id))
        let manifest = try decoder.decode(WorkshopDownloadManifest.self, from: manifestData)
        check(manifest.schemaVersion == 2 && manifest.projectType == "web" && manifest.projectFingerprint == result.contentFingerprint, "existing v2 manifest decoder reads real Web identity")
        check(manifest.videoRelativePath == nil && manifest.videoSHA256 == nil && manifest.title == "Original fixture" && manifest.declaredTags == item.declaredTags, "manifest title/tags semantics and absent video fields retained")
        let json = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        check(json["downloadBackend"] as? String == "steamkit2" && json["previewImageURLString"] as? String == item.previewImageURLString && json["fileSizeBytes"] as? Int64 == item.fileSizeBytes, "optional reload backend/preview/size fields retained without changing old schema")
        var permissions = stat(); _ = lstat(destination.appendingPathComponent("index.html").path, &permissions)
        check(permissions.st_mode & 0o777 == 0o600, "managed copied files are private0600")
        let service = WorkshopDownloadService(layout: layout, executable: root.appendingPathComponent("never-run"))
        let restored = await service.verifyExisting(item: item)
        check(restored?.state == .completed && restored?.validatedProject?.kind == .web, "legacy existing-download verifier accepts native delivered project")
        let sparseMetadata = WorkshopDownloadItem(publishedFileID: id.value, title: "工坊作品 \(id.value)", kind: .web, declaredTags: [], previewImageURLString: nil, fileSizeBytes: nil)
        let recovered = await service.verifyExisting(item: sparseMetadata)
        check(recovered?.previewImageURLString == item.previewImageURLString && recovered?.fileSizeBytes == item.fileSizeBytes && recovered?.declaredTags == item.declaredTags, "restart verifier recovers stored preview size and tags for sparse discovery metadata")
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL(for: id))) as! [String: Any]
        check(rewritten["downloadBackend"] as? String == "steamkit2" && rewritten["fileSizeBytes"] as? Int64 == item.fileSizeBytes, "verifier rewrite preserves native backend and source size annotation")
        try write("old-extra", to: destination.appendingPathComponent("old-only.txt"))
        let old = try tree(destination); let oldIdentity = inode(destination)
        try write("body{color:blue}", to: source.appendingPathComponent("assets/style.css"))
        let updated = try await delivery.deliver(contentURL: source, item: item, progress: { _ in })
        check(updated.contentFingerprint != result.contentFingerprint && inode(destination) != oldIdentity, "new content atomically replaces previous root only after validation")
        let sibling = try fm.contentsOfDirectory(at: layout.root.appendingPathComponent(".steam-content-previous"), includingPropertiesForKeys: [])
        check(try sibling.contains { try tree($0) == old }, "successful exchange retains complete old download for deliberate parent cleanup")
        check(!fm.fileExists(atPath: destination.appendingPathComponent("old-only.txt").path), "new target has only new project resources and host manifest")
        let stable = try tree(destination); let stableIdentity = inode(destination)
        let sourceNow = try tree(source)
        let invalid = root.appendingPathComponent("invalid")
        try write("{\"type\":\"application\",\"file\":\"app.exe\"}", to: invalid.appendingPathComponent("project.json"))
        try write("not an executable", to: invalid.appendingPathComponent("app.exe"))
        await rejects("unsupported project fails before replacing old target") { _ = try await delivery.deliver(contentURL: invalid, item: item, progress: { _ in }) }
        check(try tree(destination) == stable && inode(destination) == stableIdentity, "resolver failure leaves old bytes and root inode intact")
        let preCopy = DeliveryCancellation()
        let cancelled = Task { try await delivery.deliver(contentURL: source, item: item, progress: { state in
            if case .validating(let text) = state, text == "正在复制本地项目文件" { preCopy.cancel() }
        }) }
        preCopy.attach(cancelled)
        await rejects("cancel at copy boundary propagates cancellation") { _ = try await cancelled.value }
        check(try tree(destination) == stable && inode(destination) == stableIdentity, "copy cancellation leaves old download untouched")
        let postPromote = DeliveryCancellation()
        let swapped = Task { try await delivery.deliver(contentURL: source, item: item, progress: { state in
            if case .validating(let text) = state, text == "复验已交付项目" { postPromote.cancel() }
        }) }
        postPromote.attach(swapped)
        await rejects("cancel after atomic promote triggers transaction rollback") { _ = try await swapped.value }
        check(try tree(destination) == stable && inode(destination) == stableIdentity, "rollback restores exact previous root inode and every old byte")
        check(try tree(source) == sourceNow, "failed/cancelled transactions never mutate helper source")
        let style = source.appendingPathComponent("assets/style.css")
        await rejects("source change during copy detected before promotion") {
            _ = try await delivery.deliver(contentURL: source, item: item, progress: { state in
                if case .validating(let text) = state, text == "正在复制本地项目文件" { try? Data("mutated concurrently".utf8).write(to: style) }
            })
        }
        check(try tree(destination) == stable, "source mutation does not replace previous managed download")
        try write("body{color:blue}", to: style)
        let concurrent = destination.appendingPathComponent("concurrent.txt")
        await rejects("existing target CAS refuses concurrent external update") {
            _ = try await delivery.deliver(contentURL: source, item: item, progress: { state in
                if case .validating(let text) = state, text == "正在复制本地项目文件" { try? Data("keep external change".utf8).write(to: concurrent) }
            })
        }
        check(try Data(contentsOf: concurrent) == Data("keep external change".utf8), "external target edit preserved rather than overwritten")
        let unsafe = root.appendingPathComponent("unsafe-source"); try web(unsafe)
        let outside = root.appendingPathComponent("outside-original"); try write("original outside", to: outside)
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("escape"), withDestinationURL: outside)
        await rejects("source symlink rejected before resolver/copy") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        try fm.removeItem(at: unsafe.appendingPathComponent("escape"))
        precondition(link(outside.path, unsafe.appendingPathComponent("hardlink").path) == 0)
        await rejects("source hardlink rejected") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        try fm.removeItem(at: unsafe.appendingPathComponent("hardlink"))
        precondition(mkfifo(unsafe.appendingPathComponent("pipe").path, 0o600) == 0)
        await rejects("FIFO rejected without blocking") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        try fm.removeItem(at: unsafe.appendingPathComponent("pipe"))
        let oversized = unsafe.appendingPathComponent("oversized.bin")
        let sparseFD = open(oversized.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        precondition(sparseFD >= 0)
        precondition(ftruncate(sparseFD, 2 * 1024 * 1024 * 1024 + 1) == 0)
        close(sparseFD)
        await rejects("sparse oversized resource rejected before copying or allocating its logical bytes") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        try fm.removeItem(at: oversized)
        let invalidName = unsafe.appendingPathComponent("unsafe\\name.txt")
        try write("not a portable resource name", to: invalidName)
        await rejects("backslash resource name rejected instead of changing target path semantics") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        try fm.removeItem(at: invalidName)
        try write("author marker", to: unsafe.appendingPathComponent("glimmer-download.json"))
        await rejects("reserved root marker collision rejected without overwriting author content") { _ = try await delivery.deliver(contentURL: unsafe, item: item, progress: { _ in }) }
        check(try Data(contentsOf: outside) == Data("original outside".utf8), "external source bytes remain unchanged across all unsafe cases")
        let alias = root.appendingPathComponent("source-link"); try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        await rejects("source root symlink rejected") { _ = try await delivery.deliver(contentURL: alias, item: item, progress: { _ in }) }
        let badLayout = SteamCMDLayout(root: root.appendingPathComponent("bad-layout")); try fm.createDirectory(at: badLayout.root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: badLayout.downloadsURL, withDestinationURL: source)
        await rejects("managed downloads root symlink rejected") { _ = try await SteamContentProjectDelivery(layout: badLayout).deliver(contentURL: source, item: item, progress: { _ in }) }
        let conflictLayout = SteamCMDLayout(root: root.appendingPathComponent("external-replace-layout"))
        let conflictDelivery = SteamContentProjectDelivery(layout: conflictLayout)
        _ = try await conflictDelivery.deliver(contentURL: source, item: item, progress: { _ in })
        let conflictTarget = conflictLayout.downloadDirectory(for: id)
        let conflictOld = try tree(conflictTarget)
        let movedPromoted = root.appendingPathComponent("externally-moved-promoted")
        await rejects("post-promote external root replacement does not trigger destructive rollback") {
            _ = try await conflictDelivery.deliver(contentURL: source, item: item, progress: { state in
                if case .validating(let text) = state, text == "复验已交付项目" {
                    try? FileManager.default.moveItem(at: conflictTarget, to: movedPromoted)
                    try? FileManager.default.createDirectory(at: conflictTarget, withIntermediateDirectories: true)
                    try? Data("external new choice".utf8).write(to: conflictTarget.appendingPathComponent("external.txt"))
                }
            })
        }
        check(try tree(conflictTarget) == ["external.txt": Data("external new choice".utf8)], "external replacement bytes retained without overwrite")
        let conflictSiblings = try fm.contentsOfDirectory(at: conflictTarget.deletingLastPathComponent(), includingPropertiesForKeys: [])
        check(try conflictSiblings.filter { $0.lastPathComponent.hasPrefix(".steam-content-stage-") }.contains { try tree($0) == conflictOld }, "old target still recoverable after concurrent root replacement")
        check(fm.fileExists(atPath: movedPromoted.appendingPathComponent("project.json").path), "externally moved promoted copy also retained")
        let backupRaceLayout = SteamCMDLayout(root: root.appendingPathComponent("backup-replace-layout"))
        let backupRaceDelivery = SteamContentProjectDelivery(layout: backupRaceLayout)
        _ = try await backupRaceDelivery.deliver(contentURL: source, item: item, progress: { _ in })
        let backupRaceTarget = backupRaceLayout.downloadDirectory(for: id)
        let backupRaceOld = try tree(backupRaceTarget)
        let movedBackup = root.appendingPathComponent("externally-moved-old-backup")
        let backupCancel = DeliveryCancellation()
        let backupRaceTask = Task { try await backupRaceDelivery.deliver(contentURL: source, item: item, progress: { state in
            if case .validating(let text) = state, text == "复验已交付项目" {
                let parent = backupRaceTarget.deletingLastPathComponent()
                if let stage = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: []).first(where: { $0.lastPathComponent.hasPrefix(".steam-content-stage-") }) {
                    try? FileManager.default.moveItem(at: stage, to: movedBackup)
                    try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                    try? Data("external replacement backup".utf8).write(to: stage.appendingPathComponent("external.txt"))
                }
                backupCancel.cancel()
            }
        }) }
        backupCancel.attach(backupRaceTask)
        await rejects("rollback rejects replaced retained-backup inode rather than installing it") { _ = try await backupRaceTask.value }
        check(try tree(movedBackup) == backupRaceOld, "externally moved original backup stays byte-identical")
        check(fm.fileExists(atPath: backupRaceTarget.appendingPathComponent("project.json").path) && !fm.fileExists(atPath: backupRaceTarget.appendingPathComponent("external.txt").path), "failed backup CAS preserves promoted project and does not install replacement")
        let retainedReplacements = try fm.contentsOfDirectory(at: backupRaceTarget.deletingLastPathComponent(), includingPropertiesForKeys: []).filter { $0.lastPathComponent.hasPrefix(".steam-content-stage-") }
        check(try retainedReplacements.contains { try tree($0) == ["external.txt": Data("external replacement backup".utf8)] }, "replaced hidden backup retained without cleanup")
        let scene = root.appendingPathComponent("scene-helper")
        let sceneFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/SceneScriptWallpaper")
        try fm.copyItem(at: sceneFixture, to: scene)
        let sceneBefore = try tree(scene)
        let sceneItem = WorkshopDownloadItem(publishedFileID: "125", title: "Scene", kind: .scene, declaredTags: ["Scene"], previewImageURLString: nil, fileSizeBytes: nil)
        let sceneResult = try await delivery.deliver(contentURL: scene, item: sceneItem, progress: { _ in })
        check(sceneResult.kind == .scene && sceneResult.sceneProject?.resourceCount ?? 0 > 0 && sceneResult.videoProject == nil, "renderable original Scene fixture uses existing Inspector resolver without VideoProbe")
        check(try tree(scene) == sceneBefore, "Scene helper cache remains unchanged")
        let video = root.appendingPathComponent("video-helper")
        try write("{\"type\":\"video\",\"file\":\"media/demo.mp4\",\"title\":\"Real video\"}", to: video.appendingPathComponent("project.json"))
        try fm.createDirectory(at: video.appendingPathComponent("media"), withIntermediateDirectories: true)
        try await SyntheticVideoWriter.write(to: video.appendingPathComponent("media/demo.mp4"), options: .init(width: 64, height: 48, frameRate: 10, frameCount: 4))
        let videoBefore = try tree(video)
        let videoItem = WorkshopDownloadItem(publishedFileID: "124", title: "Video", kind: .video, declaredTags: ["Video"], previewImageURLString: nil, fileSizeBytes: nil)
        let videoResult = try await delivery.deliver(contentURL: video, item: videoItem, progress: { _ in })
        check(videoResult.videoProject?.probe.isPlayable == true && videoResult.videoProject?.probe.pixelWidth == 64 && videoResult.videoProject?.probe.durationSeconds ?? 0 > 0, "real H264 fixture AVFoundation probe survives delivery without fake data")
        check(videoResult.videoProject.map { WorkshopProjectResolver.canonicalURL($0.videoURL) } == WorkshopProjectResolver.canonicalURL(layout.downloadDirectory(for: WorkshopItemID("124")!).appendingPathComponent("media/demo.mp4")), "video result points to promoted nested file")
        check(try tree(video) == videoBefore, "real video helper cache remains byte-identical")
        let videoManifest = try decoder.decode(WorkshopDownloadManifest.self, from: Data(contentsOf: layout.manifestURL(for: WorkshopItemID("124")!)))
        check(videoManifest.videoSHA256 == SHA256.hash(data: videoBefore["media/demo.mp4"]!).map { String(format: "%02x", $0) }.joined(), "video manifest uses actual copied video SHA256")
        let output: [String: Any] = ["passed": checks.count, "checks": checks, "scope": "real temp filesystem, atomic Darwin exchange/rollback, existing project resolver and synthetic H264; no network/account/library data"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
