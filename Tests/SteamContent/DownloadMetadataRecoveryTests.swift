import Foundation
import Darwin

@main @MainActor enum DownloadMetadataRecoveryTests {
    static let fm = FileManager.default
    static var checks = 0
    struct Failure: Error { let message: String }
    static func check(_ value: Bool, _ text: String) throws { guard value else { throw Failure(message: text) }; checks += 1; print("PASS \(text)"); fflush(stdout) }
    static func run(_ root: URL) async throws {
        let layout = SteamCMDLayout(root: root.appendingPathComponent("SteamCMD"))
        let id = WorkshopItemID("17")!, directory = layout.downloadDirectory(for: WorkshopItemID("17")!)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let projectJSON = Data("{\"type\":\"web\",\"file\":\"index.html\"}".utf8)
        let html = Data("<!doctype html><title>Original local fixture</title>".utf8)
        try projectJSON.write(to: directory.appendingPathComponent("project.json")); try html.write(to: directory.appendingPathComponent("index.html"))
        let annotation = layout.manifestURL(for: id)
        let service = WorkshopDownloadService(layout: layout, executable: root.appendingPathComponent("never-execute"))
        let seed = WorkshopDownloadItem(publishedFileID: id.value, title: "工坊作品 17", kind: .video, declaredTags: [], previewImageURLString: nil, fileSizeBytes: nil)
        let original: [String:Any] = ["schemaVersion":2,"appID":431960,"publishedFileID":"17","title":"Original Steam title","projectType":"web","projectJSONRelativePath":"../untrusted.json","validatedAt":"2026-01-02T03:04:05Z","declaredTags":["Web","Nature"],"appVersion":"fixture","downloadBackend":"steamkit2","previewImageURLString":"https://example.invalid/original-cover.jpg","fileSizeBytes":12345,"entryRelativePath":"../outside.html","projectFingerprint":"untrusted","projectByteSize":999999]
        func write(_ fields:[String:Any]) throws { try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).write(to: annotation) }
        func read() throws -> [String:Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: annotation)) as! [String:Any] }
        try write(original)
        let restored = await service.verifyExisting(item: seed)
        try check(restored?.title == "Original Steam title" && restored?.previewImageURLString == original["previewImageURLString"] as? String, "generic reload seed recovers original Steam title and cover")
        try check(restored?.declaredTags == ["Web","Nature"] && restored?.fileSizeBytes == 12345 && restored?.kind == .web, "display tags/file size recover while actual project decides kind")
        try check(restored?.validatedProject?.entryRelativePath == "index.html" && restored?.validatedProject?.contentFingerprint != "untrusted" && restored?.validatedProject?.totalByteSize != 999999, "annotation path/fingerprint/size never replace real resolver identity")
        let rewritten = try read()
        try check(rewritten["downloadBackend"] as? String == "steamkit2" && rewritten["previewImageURLString"] as? String == original["previewImageURLString"] as? String && rewritten["fileSizeBytes"] as? Int == 12345, "rewritten typed manifest preserves backend cover and display size")
        try check(rewritten["entryRelativePath"] as? String == "index.html" && rewritten["projectJSONRelativePath"] as? String == "project.json", "rewritten project paths come only from validated local tree")
        let restoredAgain = await service.verifyExisting(item: seed)
        try check(restoredAgain?.title == restored?.title && restoredAgain?.declaredTags == restored?.declaredTags && restoredAgain?.completedAt == restored?.completedAt, "repeated restart verification retains display metadata and prior completion time")
        var fresh = seed; fresh.title = "New search title"; fresh.declaredTags = ["Web","Updated"]; fresh.previewImageURLString = "https://example.invalid/new-cover.jpg"; fresh.fileSizeBytes = 456
        let freshResult = await service.verifyExisting(item: fresh)
        try check(freshResult?.title == fresh.title && freshResult?.declaredTags == fresh.declaredTags && freshResult?.previewImageURLString == fresh.previewImageURLString && freshResult?.fileSizeBytes == 456, "fresh caller metadata takes precedence over retained display annotation")
        var legacy = original; legacy["schemaVersion"] = 1; legacy.removeValue(forKey:"downloadBackend");legacy.removeValue(forKey:"previewImageURLString");legacy.removeValue(forKey:"fileSizeBytes")
        try write(legacy); let old = await service.verifyExisting(item: seed)
        try check(old?.title == "Original Steam title" && old?.previewImageURLString == nil && old?.fileSizeBytes == nil, "legacy manifest without optional metadata remains readable")
        for key in ["publishedFileID","appID"] {
            var mismatch = original; mismatch[key] = key == "appID" ? 480 : "18"
            try write(mismatch); let ignored = await service.verifyExisting(item: seed)
            try check(ignored?.state == .completed && ignored?.title == seed.title && ignored?.previewImageURLString == nil, "mismatched \(key) annotation cannot supply another item's display identity")
        }
        var bad = original; bad["title"] = "title\ncontrol"; bad["previewImageURLString"] = "file:///private/etc/passwd";bad["downloadBackend"] = "untrusted";bad["fileSizeBytes"] = -1;bad["declaredTags"] = ["Web","unsafe\ncontrol"]
        try write(bad); let sanitized = await service.verifyExisting(item: seed); let clean = try read()
        try check(sanitized?.title == seed.title && sanitized?.previewImageURLString == nil && sanitized?.fileSizeBytes == nil && sanitized?.declaredTags == ["Web"] && clean["downloadBackend"] == nil, "unsafe display strings local URL unknown backend and negative display size are ignored")
        var large = original; large["title"] = String(repeating:"x",count:300000)
        try write(large); let bounded = await service.verifyExisting(item: seed)
        try check(bounded?.state == .completed && bounded?.title == seed.title, "oversized annotation is discarded without blocking valid project recovery")
        try Data("{truncated".utf8).write(to: annotation); let malformed = await service.verifyExisting(item: seed)
        try check(malformed?.state == .completed && malformed?.title == seed.title, "malformed annotation never blocks real project revalidation")
        try fm.removeItem(at: annotation); precondition(mkfifo(annotation.path,0o600) == 0)
        let start = Date(); _ = await service.verifyExisting(item: seed)
        try check(Date().timeIntervalSince(start) < 2, "FIFO annotation read is nonblocking and not decoded as metadata")
        try? fm.removeItem(at: annotation)
        let outside = root.appendingPathComponent("outside-original.json"); let outsideBytes = try JSONSerialization.data(withJSONObject:original)
        try outsideBytes.write(to:outside);try fm.createSymbolicLink(at:annotation,withDestinationURL:outside)
        _ = await service.verifyExisting(item:seed)
        try check(try Data(contentsOf:outside) == outsideBytes, "symlink annotation never changes external target bytes")
        try check(try Data(contentsOf:directory.appendingPathComponent("project.json")) == projectJSON && Data(contentsOf:directory.appendingPathComponent("index.html")) == html, "all metadata recovery cases preserve project and resource bytes")
        print("RESULT \(checks) metadata recovery checks passed; real resolver/temporary files only, no Steam network/profile/account")
    }
    static func main() async throws {
        let root=URL(fileURLWithPath:"/private/tmp/GW-DownloadMetadata-\(UUID())")
        try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try?fm.removeItem(at:root)}
        try await run(root)
    }
}
