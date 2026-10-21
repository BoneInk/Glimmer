import AppKit
import Foundation
import WebKit

/// No Steam executable, network, native desktop window, real Trash or user library is used.
@main @MainActor enum WorkshopWebIntegrationTests {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) throws {
        guard condition else { throw WebProjectError.invalid(name) }
        checks += 1; print("PASS \(name)")
    }
    static func wait(_ name: String, until predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<750 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw WebProjectError.invalid("Timed out: \(name)")
    }
    static func text(_ runtime: WebWallpaperRuntime) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            runtime.webView.evaluateJavaScript("document.getElementById('caption').textContent") { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: String(describing: result ?? "nil")) }
            }
        }
    }
    static func run(root: URL) async throws {
        let fm = FileManager.default
        let original = root.appendingPathComponent("Original")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        let files = [
            "project.json": #"{"title":"Web workshop fixture","type":"web","file":"index.html","general":{"properties":{"caption":{"type":"textinput","text":"Caption","value":"DEFAULT"}}}}"#,
            "index.html": #"<!doctype html><html><head><link rel="stylesheet" href="style.css"></head><body><div id="caption">WAIT</div><script src="main.js"></script></body></html>"#,
            "main.js": #"window.wallpaperPropertyListener={applyUserProperties:function(p){if(p.caption)document.getElementById('caption').textContent=p.caption.value;}};"#,
            "style.css": "body { background: #225533; }"
        ]
        for (name, content) in files { try Data(content.utf8).write(to: original.appendingPathComponent(name)) }
        let storage = AppStorage(root: root.appendingPathComponent("App"))
        let store = VideoLibraryStore(storage: storage)
        let importer = ImportService(store: store, storage: storage, probeOperation: { _ in
            throw WebProjectError.invalid("A Web import must never invoke VideoProbe")
        })
        let layout = SteamCMDLayout(root: storage.workshopDirectory.appendingPathComponent("SteamCMD"))
        let id = "99887766"
        let download = layout.downloadDirectory(for: WorkshopItemID(id)!)
        try fm.createDirectory(at: download.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: original, to: download)
        let seed = WorkshopDownloadItem(publishedFileID: id, title: "Web fixture", kind: .web,
            declaredTags: ["Web"], previewImageURLString: nil, fileSizeBytes: nil)
        let service = WorkshopDownloadService(layout: layout, executable: URL(fileURLWithPath: "/never-execute-steam"))
        let coordinator = WorkshopCoordinator(account: SteamAccountManager(layout: layout), downloadPreflight: { nil },
            contentDownloadOperation: { item, _, progress, _ in
                progress(.downloading(fraction: 0.5, text: "Isolated copy executor"))
                progress(.validating("Real project validation"))
                guard let verified = await service.verifyExisting(item: item), let result = verified.validatedProject else {
                    throw WebProjectError.invalid("Fixture failed real download verification")
                }
                return result
            }, queuePersistence: .disabled)
        var importIDs: [UUID] = []
        coordinator.onImportProject = { project, metadata in
            switch await WorkshopWallpaperApplication.importItem(url: project.projectJSONURL,
                metadata: metadata, store: store, importer: importer) {
            case .success(let item): importIDs.append(item.id); return nil
            case .failure(let error): return error.message
            }
        }
        coordinator.enqueueDownload(seed)
        try await wait("initial completed import") { importIDs.count == 1 && coordinator.importingItemIDs.isEmpty }
        guard let completed = coordinator.downloadProgress.items.first,
              let web = completed.validatedProject?.webProject,
              let first = store.item(withID: importIDs[0]) else { throw WebProjectError.invalid("Missing imported Web") }
        try check(completed.state == .completed && completed.kind == .web, "typed Web download reaches completed")
        try check(completed.project == nil && completed.validatedProject?.videoProject == nil, "Web never creates a video project or probe")
        try check(first.isWebWallpaper && first.source == .steamWorkshop && first.workshopID == id, "automatic import records Web source and Workshop ID")
        try check(coordinator.hasLocalWallpaper(itemID: id) && coordinator.localPreview(for: id) == nil,
            "Web settings route exists while AV preview stays unavailable")
        try check(coordinator.localWallpaperURL(for: id)?.lastPathComponent == "project.json", "unified route uses actual Web project descriptor")
        let marker = download.appendingPathComponent("glimmer-download.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(WorkshopDownloadManifest.self, from: Data(contentsOf: marker))
        try check(manifest.schemaVersion == 2 && manifest.projectType == "web" && manifest.videoRelativePath == nil,
            "real v2 download manifest has no fabricated video fields")
        let again = try await WorkshopProjectResolver.resolve(workshopID: id, directory: download, declaredTags: ["Web"])
        try check(again.webProject?.contentFingerprint == web.contentFingerprint, "root host manifest is excluded from content fingerprint")
        try check(first.contentFingerprint == web.contentFingerprint, "resolver and importer use identical complete-tree fingerprints")
        let importedRoot = URL(fileURLWithPath: first.filePath).deletingLastPathComponent()
        try check(!fm.fileExists(atPath: importedRoot.appendingPathComponent("glimmer-download.json").path), "host annotation is excluded from managed project copy")
        store.rename(id: first.id, to: "My retained name")
        store.toggleFavorite(id: first.id)
        let author = try AuthorPropertyServices.project(for: first)!
        let overrides = AuthorPropertyServices.shared.store(storage: storage)
        try await overrides.set(.string("SAVED"), for: "caption", itemID: first.id, project: author)
        var detailIDs: [UUID] = []
        coordinator.onOpenWallpaperDetails = { url, metadata in
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item): detailIDs.append(item.id); return nil
            case .failure(let error): return error.message
            }
        }
        try check(await coordinator.openWallpaperDetails(itemID: id) == nil, "first unified detail open imports or reuses real Web")
        try check(await coordinator.openWallpaperDetails(itemID: id) == nil, "repeated unified detail open succeeds")
        try check(detailIDs == [first.id, first.id] && store.items.count == 1, "same Workshop ID and full content reuse UUID after marker write")
        try check(store.item(withID: first.id)?.title == "My retained name" && store.item(withID: first.id)?.isFavorite == true,
            "detail reuse preserves renamed title and favorite")
        let frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let displays = DisplayRegistry(snapshot: [.init(id: "test-display", displayID: 1, localizedName: "Isolated",
            frame: frame, visibleFrame: frame, backingScaleFactor: 1, isPrimary: true, pixelSize: frame.size)])
        let playback = DesktopPlaybackController(store: store, displayRegistry: displays, storage: storage, previewOnly: true)
        defer { playback.tearDownAll() }
        try check(playback.sessions.isEmpty && store.assignments.isEmpty, "download and detail opening never auto-apply")
        coordinator.onApplyWallpaper = { url, metadata, target in
            await WorkshopWallpaperApplication.apply(url: url, metadata: metadata, target: target,
                currentDisplayID: "test-display", store: store, importer: importer, displays: displays, playback: playback)
        }
        let apply = await coordinator.applyWallpaper(itemID: id, target: .currentDisplay)
        try check(apply.succeeded, "explicit Web apply crosses real importer and desktop resolver")
        guard let session = playback.session(for: "test-display"), let runtime = session.webRuntime else {
            throw WebProjectError.invalid("Missing real Web session")
        }
        try await wait("WebKit ready") { runtime.state == .ready || runtime.state == .paused || session.lastError != nil }
        if let error = session.lastError { throw WebProjectError.invalid(error) }
        try check(session.window == nil && session.player == nil && session.webHostView === runtime.webView,
            "isolated apply uses real WebKit without desktop window or AVPlayer")
        try check(try await text(runtime) == "SAVED", "saved author override survives dedup and reaches actual DOM")
        try await overrides.set(.string("LIVE"), for: "caption", itemID: first.id, project: author)
        try await AuthorPropertyServices.shared.applySavedSettings(project: author, itemID: first.id, storage: storage)
        try check(try await text(runtime) == "LIVE", "explicit author-setting ACK changes real WebKit DOM")
        var lockCalls = 0
        coordinator.onRequestDynamicLockScreen = { _, _ in lockCalls += 1; return nil }
        try check(await coordinator.requestDynamicLockScreen(itemID: id) != nil && lockCalls == 0,
            "Web dynamic lockscreen is rejected before handler invocation")
        let oldCSS = try Data(contentsOf: importedRoot.appendingPathComponent("style.css"))
        try Data("body { background: #882244; }".utf8).write(to: download.appendingPathComponent("style.css"))
        coordinator.removeDownload(itemID: id)
        coordinator.enqueueDownload(seed)
        try await wait("changed-content import") { importIDs.count == 2 && coordinator.importingItemIDs.isEmpty }
        guard let second = store.item(withID: importIDs[1]) else { throw WebProjectError.invalid("Missing second version") }
        try check(second.id != first.id && store.items.count == 2, "same Workshop ID with changed CSS imports distinct version UUID")
        try check(playback.session(for: "test-display") === session && store.assignments["test-display"] == first.id,
            "new version never replaces old active session or assignment")
        try check(try Data(contentsOf: importedRoot.appendingPathComponent("style.css")) == oldCSS,
            "new download cannot mutate old managed project")
        try check(try await text(runtime) == "LIVE", "active old page and applied author value remain intact")
        let secondRoot = URL(fileURLWithPath: second.filePath).deletingLastPathComponent()
        var trashed: [URL: URL] = [:]
        let deletion = ManagedWallpaperDeletionService(store: store, playback: playback, storage: storage,
            workshopLayout: layout, trashOperation: { source in
                let trash = root.appendingPathComponent("SimulatedTrash")
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                let target = trash.appendingPathComponent(UUID().uuidString)
                try fm.moveItem(at: source, to: target)
                trashed[source.standardizedFileURL] = target
                return target
            })
        coordinator.onDeleteWallpaper = { workshopID in await deletion.delete(workshopID: workshopID) }
        try check(await coordinator.deleteDownloadedWallpaper(itemID: id) == nil, "explicit delete completes real managed deletion transaction")
        for folder in [download, importedRoot, secondRoot] {
            guard let target = trashed[folder.standardizedFileURL] else { throw WebProjectError.invalid("Whole project not trashed: \(folder.lastPathComponent)") }
            try check(!fm.fileExists(atPath: folder.path) && fm.fileExists(atPath: target.appendingPathComponent("project.json").path)
                && fm.fileExists(atPath: target.appendingPathComponent("main.js").path)
                && fm.fileExists(atPath: target.appendingPathComponent("style.css").path), "Trash contains complete project folder \(folder.lastPathComponent)")
        }
        try check(store.items.isEmpty && store.assignments.isEmpty && playback.sessions.isEmpty && runtime.state == .disposed,
            "deletion clears versions, assignments and live WebKit session")
        try check(coordinator.downloadProgress.items.isEmpty && !coordinator.hasLocalWallpaper(itemID: id), "deleted download cannot reopen dangling details")
        for (name, content) in files { try check(try Data(contentsOf: original.appendingPathComponent(name)) == Data(content.utf8), "external source untouched: \(name)") }
        try check(VideoLibraryStore(storage: storage).items.isEmpty, "successful deletion persists across library reload")
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Workshop-Web-Integration-\(UUID())")
            do { try await run(root: root); print("RESULT \(checks) passed, 0 failed") }
            catch { print("FAIL \(error)"); try? FileManager.default.removeItem(at: root); exit(1) }
            try? FileManager.default.removeItem(at: root); exit(0)
        }
        app.run()
    }
}
