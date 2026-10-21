import AppKit
import Darwin
import Foundation

@main @MainActor enum SceneProjectBackendTests {
    static var count = 0
    static let fm = FileManager.default
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw WebProjectError.invalid(label) }
        count += 1; print("PASS \(label)")
    }
    static func reject(_ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { try check(true, label); return }
        throw WebProjectError.invalid(label + " unexpectedly passed")
    }
    static func u32(_ value: UInt32) -> Data { var value = value.littleEndian; return withUnsafeBytes(of: &value) { Data($0) } }
    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func fixture(_ root: URL, packaged: Bool, unsupported: Bool = false) throws -> URL {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let project: [String: Any] = ["type": "scene", "file": "scene.json", "title": "Synthetic Scene", "general": ["properties": ["show": ["type": "bool", "value": true]]]]
        let scene: [String: Any] = ["general": ["orthogonalprojection": ["width": 400,"height": 300],"bloom": false,"hdr": unsupported],
            "objects": [["id": 1, "image": "models/image.json", "origin": "200 150 0", "visible": ["user": "show", "value": true], "size": "200 150"]]]
        var texture = Data("TEXV0005\0TEXI0001\0".utf8)
        for n: UInt32 in [0,0,2,2,2,2,0] { texture += u32(n) }
        texture += Data("TEXB0001\0".utf8)
        for n: UInt32 in [1,1,2,2,16] { texture += u32(n) }
        texture += Data(repeating: 255, count: 16)
        let entries: [(String,Data)] = [("scene.json", try json(scene)),
            ("models/image.json", try json(["material":"materials/image.json"])),
            ("materials/image.json", try json(["passes":[["shader":"genericimage2","blending":"translucent","textures":["image"]]]])),
            ("materials/image.tex", texture)]
        try json(project).write(to: root.appendingPathComponent("project.json"))
        if packaged {
            var header = Data("PKGV0005".utf8); header = u32(UInt32(header.count)) + header + u32(UInt32(entries.count))
            var offset: UInt32 = 0, payload = Data()
            for (name, bytes) in entries {
                let name = Data(name.utf8)
                header += u32(UInt32(name.count)) + name + u32(offset) + u32(UInt32(bytes.count))
                offset += UInt32(bytes.count); payload += bytes
            }
            try (header + payload).write(to: root.appendingPathComponent("scene.pkg"))
        } else {
            for (name, bytes) in entries {
                let target = root.appendingPathComponent(name)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: target)
            }
        }
        return root.appendingPathComponent("project.json")
    }
    static func main() async throws {
        _ = NSApplication.shared
        let capabilityMessage = SceneWallpaperProjectDescriptor.unsupportedSummary([
            .init(severity: .unsupported, path: "objects[0].effects", message: "Effects are unsupported."),
            .init(severity: .unsupported, path: "objects[1].effects", message: "Effects are unsupported."),
            .init(severity: .unsupported, path: "material.copybackground", message: "Unsupported material.")])
        try check(capabilityMessage == "此 Scene 仍需未支持的功能：材质与图层特效、背景采样。", "Scene failure names missing capabilities once without raw engine diagnostics")
        let root = fm.temporaryDirectory.appendingPathComponent("GW-Scene-Backend-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let storage = AppStorage(root: root.appendingPathComponent("App")), id = WorkshopItemID("12345678")!
        let store = VideoLibraryStore(storage: storage)
        let importer = ImportService(store: store, storage: storage, probeOperation: { _ in
            throw WebProjectError.invalid("Scene must never call VideoProbe")
        })
        let original = try fixture(root.appendingPathComponent("Original"), packaged: true)
        let originalPackage = try Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("scene.pkg"))
        let descriptor = try SceneWallpaperProjectDescriptor(projectURL: original)
        try check(descriptor.entryURL.lastPathComponent == "scene.pkg" && descriptor.inspection.isRenderableSubset,
            "packaged Scene resolves declared internal scene.json through actual scene.pkg")
        let localOutcome = await importer.importLocalSceneProject(original)
        guard case .imported(let localID) = localOutcome, let local = store.item(withID: localID) else { throw WebProjectError.invalid("Local Scene import failed: \(localOutcome)") }
        try check(local.isSceneWallpaper && local.isProjectWallpaper && !local.isVideoWallpaper && !local.isWebWallpaper,
            "Scene kind uses project.json and never video defaults")
        try check(local.filePath.contains("/Media/SceneProjects/") && local.pixelWidth == 400 && local.pixelHeight == 300 && local.durationSeconds == nil,
            "owned Scene copy records inspected canvas without fabricated duration")
        try check(store.assignments.isEmpty && local.source == .local, "local Scene import never applies or stamps fake Workshop provenance")
        let persisted = VideoLibraryStore(storage: storage)
        try check(persisted.item(withID: local.id)?.isSceneWallpaper == true, "Scene kind and UUID survive library restart")
        var legacy = WallpaperItem(title: "legacy", filePath: "old.mp4")
        let encoded = try JSONEncoder().encode(legacy)
        legacy = try JSONDecoder().decode(WallpaperItem.self, from: encoded)
        try check(legacy.isVideoWallpaper && !legacy.isProjectWallpaper, "missing legacy contentKind still means video")

        let migrationRoot = URL(fileURLWithPath: "/private/tmp/GW-Legacy-Kind-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: migrationRoot) }
        let migrationStorage = AppStorage(root: migrationRoot)
        try migrationStorage.prepareDirectories()
        func managedProject(_ namespace: String, _ id: UUID, _ object: [String: Any]) throws -> URL {
            let directory = migrationStorage.mediaDirectory.appendingPathComponent(namespace).appendingPathComponent(id.uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = directory.appendingPathComponent("project.json")
            try json(object).write(to: result)
            return result
        }
        let sceneLegacyID = UUID(), webLegacyID = UUID(), mismatchID = UUID(), linkedID = UUID(), oversizedID = UUID()
        let damagedID = UUID(), missingID = UUID(), hardlinkedID = UUID()
        let sceneLegacyURL = try managedProject("SceneProjects", sceneLegacyID, ["type": "scene", "file": "scene.pkg"])
        let webLegacyURL = try managedProject("WebProjects", webLegacyID, ["type": "web", "file": "index.html"])
        let mismatchURL = try managedProject("SceneProjects", mismatchID, ["type": "web", "file": "index.html"])
        let externalProject = root.appendingPathComponent("ExternalProject.json")
        try json(["type": "scene"]).write(to: externalProject)
        let linkedDirectory = migrationStorage.mediaDirectory.appendingPathComponent("SceneProjects").appendingPathComponent(linkedID.uuidString)
        try fm.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let linkedURL = linkedDirectory.appendingPathComponent("project.json")
        try fm.createSymbolicLink(at: linkedURL, withDestinationURL: externalProject)
        let oversizedDirectory = migrationStorage.mediaDirectory.appendingPathComponent("WebProjects").appendingPathComponent(oversizedID.uuidString)
        try fm.createDirectory(at: oversizedDirectory, withIntermediateDirectories: true)
        let oversizedURL = oversizedDirectory.appendingPathComponent("project.json")
        try Data(repeating: 0x20, count: 1024 * 1024 + 1).write(to: oversizedURL)
        let damagedDirectory = migrationStorage.mediaDirectory.appendingPathComponent("SceneProjects").appendingPathComponent(damagedID.uuidString)
        try fm.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        let damagedURL = damagedDirectory.appendingPathComponent("project.json")
        try Data("not-json".utf8).write(to: damagedURL)
        let missingURL = migrationStorage.mediaDirectory.appendingPathComponent("WebProjects").appendingPathComponent(missingID.uuidString).appendingPathComponent("project.json")
        let hardlinkedDirectory = migrationStorage.mediaDirectory.appendingPathComponent("WebProjects").appendingPathComponent(hardlinkedID.uuidString)
        try fm.createDirectory(at: hardlinkedDirectory, withIntermediateDirectories: true)
        let hardlinkedURL = hardlinkedDirectory.appendingPathComponent("project.json")
        let hardlinkSource = root.appendingPathComponent("HardlinkProject.json")
        try json(["type": "web"]).write(to: hardlinkSource)
        try fm.linkItem(at: hardlinkSource, to: hardlinkedURL)
        let preservedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sceneLegacy = WallpaperItem(id: sceneLegacyID, title: "Edited legacy Scene", filePath: sceneLegacyURL.path,
            source: .steamWorkshop, isFavorite: true, addedAt: preservedDate, lastPlayedAt: preservedDate,
            fileSizeBytes: 1234, contentFingerprint: "kept-fingerprint", workshopID: "kept-workshop", notes: "kept-note")
        let webLegacy = WallpaperItem(id: webLegacyID, title: "Edited legacy Web", filePath: webLegacyURL.path)
        let ordinaryVideo = WallpaperItem(title: "Legacy video", filePath: migrationStorage.mediaDirectory.appendingPathComponent("clip.mp4").path)
        let mismatch = WallpaperItem(id: mismatchID, title: "Mismatch", filePath: mismatchURL.path)
        let outside = WallpaperItem(title: "Outside", filePath: externalProject.path)
        let linkedRecord = WallpaperItem(id: linkedID, title: "Linked", filePath: linkedURL.path)
        let oversized = WallpaperItem(id: oversizedID, title: "Oversized", filePath: oversizedURL.path)
        let damaged = WallpaperItem(id: damagedID, title: "Damaged", filePath: damagedURL.path)
        let missing = WallpaperItem(id: missingID, title: "Missing", filePath: missingURL.path)
        let hardlinked = WallpaperItem(id: hardlinkedID, title: "Hardlinked", filePath: hardlinkedURL.path)
        let migrationDocument = LibraryDocument(items: [sceneLegacy, webLegacy, ordinaryVideo, mismatch, outside, linkedRecord, oversized, damaged, missing, hardlinked],
            assignments: ["display-kept": sceneLegacyID])
        _ = try LibraryPersistence.save(migrationDocument, to: migrationStorage.libraryFile)
        let migratedStore = VideoLibraryStore(storage: migrationStorage)
        let migratedScene = migratedStore.item(withID: sceneLegacyID)
        try check(migratedScene?.contentKind == .scene && migratedStore.item(withID: webLegacyID)?.contentKind == .web,
            "legacy managed Scene and Web project records recover their explicit project kind")
        try check(migratedScene?.title == sceneLegacy.title && migratedScene?.isFavorite == true &&
                  migratedScene?.workshopID == sceneLegacy.workshopID && migratedScene?.contentFingerprint == sceneLegacy.contentFingerprint &&
                  migratedScene?.notes == sceneLegacy.notes && migratedStore.assignedItemID(for: "display-kept") == sceneLegacyID,
            "kind migration preserves IDs edits provenance favorites and assignments")
        try check([ordinaryVideo.id, mismatchID, outside.id, linkedID, oversizedID, damagedID, missingID, hardlinkedID].allSatisfy {
            migratedStore.item(withID: $0)?.contentKind == nil
        }, "video outside mismatch symlink hardlink damaged missing and oversized records remain unclassified")
        let migratedAgain = VideoLibraryStore(storage: migrationStorage)
        try check(migratedAgain.item(withID: sceneLegacyID)?.contentKind == .scene &&
                  migratedAgain.item(withID: webLegacyID)?.contentKind == .web &&
                  migratedAgain.items.count == migrationDocument.items.count,
            "safe legacy project kinds persist once without replacing library records")
        store.rename(id: localID, to: "Kept title"); store.toggleFavorite(id: localID)
        let repeated = await importer.importLocalSceneProject(original)
        guard case .duplicated(let reusedID, _) = repeated else { throw WebProjectError.invalid("Repeat Scene not deduplicated") }
        try check(reusedID == localID && store.item(withID: localID)?.title == "Kept title" && store.item(withID: localID)?.isFavorite == true,
            "repeat local Scene keeps UUID rename and favorite")
        try fm.removeItem(at: URL(fileURLWithPath: local.filePath).deletingLastPathComponent())
        let repaired = await importer.importLocalSceneProject(original)
        guard case .duplicated(let repairedID, _) = repaired else { throw WebProjectError.invalid("Missing Scene repair failed") }
        try check(repairedID == localID && store.item(withID: localID)?.fileExists == true, "same-content missing Scene copy repairs existing UUID")
        let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
        let download = layout.downloadDirectory(for: id)
        try fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original.deletingLastPathComponent(), to: download)
        let seed = WorkshopDownloadItem(publishedFileID: id.value, title: "Scene download", kind: .scene,
            declaredTags: ["Scene"], previewImageURLString: nil, fileSizeBytes: nil)
        let service = WorkshopDownloadService(layout: layout, executable: URL(fileURLWithPath: "/never-execute-steam"))
        guard let completed = await service.verifyExisting(item: seed), let scene = completed.validatedProject?.sceneProject else {
            throw WebProjectError.invalid("Scene real verifyExisting failed")
        }
        try check(completed.state == .completed && completed.project == nil && completed.validatedProject?.videoProject == nil,
            "real download verify returns typed Scene with no video project or probe")
        try check(scene.resourceCount == 2 && scene.totalByteSize > 0 && !scene.diagnostics.isEmpty,
            "typed Scene reports actual package tree size and bounded capability diagnostics")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(WorkshopDownloadManifest.self, from: Data(contentsOf: download.appendingPathComponent("glimmer-download.json")))
        try check(manifest.projectType == "scene" && manifest.videoRelativePath == nil && manifest.videoByteSize == nil && manifest.videoSHA256 == nil
            && manifest.projectFingerprint == scene.contentFingerprint && manifest.entryRelativePath == "scene.pkg",
            "Scene manifest has real package fingerprint/entry and omits video fields")
        var unknownSeed = seed; unknownSeed.kind = .unknown
        try check(await service.verifyExisting(item: unknownSeed)?.validatedProject?.kind == .scene, "unknown Steam page type resolves authoritative actual Scene content")
        try check(completed.metadata?.projectType == "scene" && completed.metadata?.videoRelativePath == nil && completed.metadata?.videoByteSize == nil, "Scene callback metadata never masquerades as video")
        let metadata = ImportWorkshopMetadata(publishedFileID: id.value, title: "Workshop Scene", pageURLString: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id.value)", previewImageURLString: nil, authorSteamID: nil, fileByteSize: nil)
        let workshop = await importer.importWorkshopScene(scene.projectJSONURL, metadata: metadata, managedDownloadRoot: download)
        guard case .imported(let workshopID) = workshop, let first = store.item(withID: workshopID) else { throw WebProjectError.invalid("Workshop Scene import failed") }
        try check(first.source == .steamWorkshop && first.workshopID == id.value && first.contentFingerprint == scene.contentFingerprint,
            "Scene importer and resolver agree on hash excluding exact root host marker and atomic source stamp")
        try check(first.id != localID, "local and Workshop provenance retain independent Scene UUIDs")
        let managedRoot = first.fileURL.deletingLastPathComponent()
        try check(!fm.fileExists(atPath: managedRoot.appendingPathComponent("glimmer-download.json").path), "Scene managed copy excludes host annotation")
        let repeatedWorkshop = await importer.importWorkshopScene(scene.projectJSONURL, metadata: metadata, managedDownloadRoot: download)
        guard case .duplicated(let sameID, _) = repeatedWorkshop else { throw WebProjectError.invalid("Workshop Scene dedup failed") }
        try check(sameID == first.id, "same Workshop Scene content reuses UUID")
        let oldPackage = try Data(contentsOf: managedRoot.appendingPathComponent("scene.pkg"))
        try Data("new harmless sidecar".utf8).write(to: download.appendingPathComponent("extra.txt"))
        let next = await importer.importWorkshopScene(scene.projectJSONURL, metadata: metadata, managedDownloadRoot: download)
        guard case .imported(let nextID) = next else { throw WebProjectError.invalid("Changed Scene should import new version") }
        try check(nextID != first.id && store.item(withID: first.id)?.filePath == first.filePath && (try Data(contentsOf: managedRoot.appendingPathComponent("scene.pkg"))) == oldPackage,
            "changed complete Scene tree creates new version and preserves old managed package")
        let unsupported = try fixture(root.appendingPathComponent("Unsupported"), packaged: false, unsupported: true)
        let beforeIDs = Set(store.items.map(\.id)), projects = storage.mediaDirectory.appendingPathComponent("SceneProjects")
        let beforeFolders = try fm.contentsOfDirectory(atPath: projects.path).sorted()
        let failed = await importer.importLocalSceneProject(unsupported)
        guard case .failed(let reason) = failed else { throw WebProjectError.invalid("Unsupported Scene was accepted") }
        try check(reason.contains("光照与泛光") && Set(store.items.map(\.id)) == beforeIDs && (try fm.contentsOfDirectory(atPath: projects.path).sorted()) == beforeFolders,
            "unsupported Scene is explicitly rejected without record or half-copied project")
        try await reject("unsupported Workshop Scene cannot become completed") {
            _ = try await WorkshopProjectResolver.resolve(workshopID: id.value, directory: unsupported.deletingLastPathComponent(), declaredTags: ["Scene"])
        }
        let loose = try fixture(root.appendingPathComponent("Loose"), packaged: false)
        try check(try SceneWallpaperProjectDescriptor(projectURL: loose).entryURL.lastPathComponent == "scene.json", "loose Scene entry remains a real local file")
        let linked = loose.deletingLastPathComponent().appendingPathComponent("extra-link")
        try fm.createSymbolicLink(at: linked, withDestinationURL: original)
        let denied = await importer.importLocalSceneProject(loose)
        guard case .failed = denied else { throw WebProjectError.invalid("Scene symlink source was copied") }
        try check(Set(store.items.map(\.id)) == beforeIDs, "unreferenced source symlink still blocks complete-tree import")
        try fm.removeItem(at: linked)
        let cancelled = Task { await importer.importLocalSceneProject(loose) }; cancelled.cancel()
        guard case .failed = await cancelled.value else { throw WebProjectError.invalid("Cancelled Scene imported") }
        try check(Set(store.items.map(\.id)) == beforeIDs, "pre-cancelled import creates no Scene record")
        try check(try fm.contentsOfDirectory(atPath: projects.path).sorted() == beforeFolders,
            "failed and cancelled Scene imports leave no staged project folders")
        let unsafeStorage = AppStorage(root: root.appendingPathComponent("UnsafeApp"))
        let unsafeStore = VideoLibraryStore(storage: unsafeStorage)
        let external = root.appendingPathComponent("ExternalDoNotWrite")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try fm.createSymbolicLink(at: unsafeStorage.mediaDirectory.appendingPathComponent("SceneProjects"), withDestinationURL: external)
        try await reject("SceneProjects destination symlink is rejected") {
            _ = try await SceneWallpaperProjectImporter.importProject(original, store: unsafeStore)
        }
        try check(unsafeStore.items.isEmpty && (try fm.contentsOfDirectory(atPath: external.path)) == ["sentinel"]
            && (try Data(contentsOf: sentinel)) == Data("untouched".utf8), "rejected managed root leaves outside directory and library untouched")
        let steamRoot = root.appendingPathComponent("SteamLibrary/steamapps/workshop/content/431960/\(id.value)")
        try fm.createDirectory(at: steamRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original.deletingLastPathComponent(), to: steamRoot)
        let report = try await SteamLibraryScanner().scan(selectedRoot: steamRoot.deletingLastPathComponent())
        try check(report.items.first?.isImportCandidate == true && report.items.first?.kind == .scene
            && report.items.first?.entryURL?.lastPathComponent == "scene.pkg" && report.items.first?.diagnostics.contains { $0.code == .validationRequired } == true,
            "Steam scan discovers archived Scene candidate with explicit later-validation boundary")
        try check(try Data(contentsOf: original.deletingLastPathComponent().appendingPathComponent("scene.pkg")) == originalPackage,
            "original Scene package remains byte-identical after validation/import/repair")
        print("SceneProjectBackendTests: \(count) passed; real supported PKG/TEX Scene import and typed download; temp only, no Steam account/network/runtime apply")
    }
}
