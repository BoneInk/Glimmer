import Foundation

private struct ManifestCompatibilityFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct GlimmerDownloadManifestCompatibilityTests {
    private static var checks = 0

    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/glimmer-manifest-\(UUID().uuidString)",
                       isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let layout = SteamCMDLayout(root: root.appendingPathComponent("SteamCMD", isDirectory: true))
        let itemID = WorkshopItemID("123456")!
        let download = layout.downloadDirectory(for: itemID)
        try fm.createDirectory(at: download, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html","title":"Manifest fixture"}"#.utf8)
            .write(to: download.appendingPathComponent("project.json"))
        try Data("<html><script src='script.js'></script></html>".utf8)
            .write(to: download.appendingPathComponent("index.html"))
        try Data("window.manifestFixture = true;".utf8)
            .write(to: download.appendingPathComponent("script.js"))

        let service = WorkshopDownloadService(
            layout: layout,
            executable: root.appendingPathComponent("never-executed"))
        let seed = WorkshopDownloadItem(
            publishedFileID: itemID.value,
            title: "Seed",
            kind: .web,
            declaredTags: ["Web"],
            previewImageURLString: nil,
            fileSizeBytes: nil
        )
        guard let initial = await service.verifyExisting(item: seed) else {
            throw ManifestCompatibilityFailure(description: "initial Web project must verify")
        }
        try check(initial.state == .completed && initial.kind == .web,
                  "current Glimmer manifest verifies a Web download")

        let currentManifest = layout.manifestURL(for: itemID)
        let legacyManifest = layout.legacyManifestURL(for: itemID)
        let initialData = try Data(contentsOf: currentManifest)
        let initialFingerprint = try checkString(
            initial.validatedProject?.webProject?.contentFingerprint,
            "initial project fingerprint")
        try fm.moveItem(at: currentManifest, to: legacyManifest)

        guard let restored = await service.verifyExisting(item: seed) else {
            throw ManifestCompatibilityFailure(
                description: "legacy manifest filename must remain readable")
        }
        try check(restored.state == .completed && restored.kind == .web,
                  "legacy glasswallpaper-download.json remains a read compatibility input")
        try check(try Data(contentsOf: legacyManifest) == initialData,
                  "legacy manifest is retained byte-for-byte after compatibility read")
        try check(fm.fileExists(atPath: currentManifest.path),
                  "compatibility read rewrites the current Glimmer manifest")

        let resolved = try await WorkshopProjectResolver.resolve(
            workshopID: itemID.value, directory: download)
        try check(resolved.webProject?.contentFingerprint == initialFingerprint,
                  "host manifests under either filename are excluded from project identity")

        let legacyV1 = Data(#"{"schemaVersion":1,"appID":431960,"publishedFileID":"123456","title":"Old","projectType":"video","projectJSONRelativePath":"project.json","videoRelativePath":"clip.mp4","videoByteSize":123,"validatedAt":"2026-10-18T00:00:00Z","declaredTags":[],"appVersion":"0.7.0"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldManifest = try decoder.decode(WorkshopDownloadManifest.self, from: legacyV1)
        try check(oldManifest.schemaVersion == 1 && oldManifest.videoByteSize == 123
                    && oldManifest.projectFingerprint == nil,
                  "v1 download manifest remains decodable")

        print("GlimmerDownloadManifestCompatibilityTests: \(checks) checks passed; temp filesystem only, no Steam account/network")
    }

    private static func check(_ condition: @autoclosure () throws -> Bool,
                              _ label: String) throws {
        guard try condition() else {
            throw ManifestCompatibilityFailure(description: label)
        }
        checks += 1
        print("PASS \(label)")
    }

    private static func checkString(_ value: String?,
                                    _ label: String) throws -> String {
        guard let value else {
            throw ManifestCompatibilityFailure(description: "missing \(label)")
        }
        return value
    }
}
