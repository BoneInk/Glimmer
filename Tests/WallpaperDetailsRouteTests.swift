import AppKit
import Foundation

/// 故意不响应Task取消，确保取消能传到实际导入且保护保持到probe真正返回。
actor DetailsProbeBarrier {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var holding = true
    private(set) var enteredCount = 0
    func wait() async {
        enteredCount += 1
        if holding { await withCheckedContinuation { continuations.append($0) } }
    }
    func releaseOne() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
    func releaseAll() { holding = false; let pending = continuations; continuations.removeAll(); pending.forEach { $0.resume() } }
}

@main
struct WallpaperDetailsRouteTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, "FAIL: \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Details-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AppStorage(root: root)
        let store = VideoLibraryStore(storage: storage)
        let displays = DisplayRegistry(observeChanges: false)
        let playback = DesktopPlaybackController(store: store, displayRegistry: displays,
            storage: storage, previewOnly: true, writesToLibrary: false)
        defer { playback.tearDownAll(); store.flush() }
        let importer = ImportService(store: store, storage: storage, thumbnailCache: ThumbnailCache(storage: storage))
        let account = SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("SteamCMD")))
        let coordinator = WorkshopCoordinator(account: account, browserStore: WorkshopBrowserStore(persistenceURL: nil),
                                              queuePersistence: .disabled)
        func downloaded(_ id: String, width: Int) async throws -> WorkshopDownloadItem {
            let video = root.appendingPathComponent("\(id).mp4")
            try await SyntheticVideoWriter.write(to: video, options: .init(width: width, height: 64, frameRate: 10, frameCount: 10))
            var item = WorkshopDownloadItem(publishedFileID: id, title: "fixture \(id)", kind: .video, declaredTags: ["Video"])
            item.state = .completed
            item.project = WorkshopVideoProject(videoURL: video, videoRelativePath: video.lastPathComponent,
                projectJSONPath: "project.json", projectRoot: root, projectType: "video", projectTitle: "fixture \(id)",
                workshopID: id, declaredTags: ["Video"], videoByteSize: Int64(try Data(contentsOf: video).count),
                probe: .init(isPlayable: true, durationSeconds: 1, pixelWidth: width, pixelHeight: 64, hasAudioTrack: false), diagnostics: [])
            return item
        }
        let a = try await downloaded("111", width: 64)
        let b = try await downloaded("222", width: 96)
        coordinator.downloadProgress.items = [a, b]
        let unavailable = await coordinator.openWallpaperDetails(itemID: "111")
        check(unavailable != nil && store.items.isEmpty && playback.sessions.isEmpty, "unwired details fail without importing or starting playback")
        var opened: [UUID] = []
        var lockRequests = 0
        coordinator.onRequestDynamicLockScreen = { _, _ in lockRequests += 1; return nil }
        coordinator.onOpenWallpaperDetails = { url, metadata in
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item):
                guard !Task.isCancelled else { return "cancelled" }
                opened.append(item.id)
                return nil
            case .failure(let error): return error.message
            }
        }
        let unknown = await coordinator.openWallpaperDetails(itemID: "unknown")
        check(unknown != nil && opened.isEmpty, "unknown item never reaches details bridge")
        coordinator.downloadProgress.items[0].state = .queued
        let queued = await coordinator.openWallpaperDetails(itemID: "111")
        check(queued != nil && store.items.isEmpty, "incomplete download cannot open local settings")
        coordinator.downloadProgress.items[0].state = .completed
        let first = await coordinator.openWallpaperDetails(itemID: "111")
        let aID = store.items.first!.id
        check(first == nil && opened == [aID] && store.items.count == 1, "details bridge imports validated video and opens its actual UUID")
        store.rename(id: aID, to: "用户重命名")
        store.toggleFavorite(id: aID)
        let preferences = VideoPlaybackPreferences(isMuted: false, volume: 0.25, rate: 1.5, gravity: .fit)
        store.updateVideoPlaybackPreferences(preferences, itemID: aID)
        let repeated = await coordinator.openWallpaperDetails(itemID: "111")
        check(repeated == nil && store.items.count == 1 && opened == [aID, aID], "repeated details reuse UUID without duplicate file copy or record")
        check(store.item(withID: aID)?.title == "用户重命名" && store.item(withID: aID)?.isFavorite == true && store.videoPlaybackPreferences(for: aID) == preferences,
            "opening details preserves renamed title favorite and per-wallpaper preferences")
        check(playback.sessions.isEmpty && store.assignments.isEmpty && lockRequests == 0,
            "details opening neither applies desktop nor registers/prepares lock screen")
        let selection = WallpaperDetailsSelection(itemID: aID)
        store.rename(id: aID, to: "实时新名称")
        check(store.item(withID: selection.itemID)?.title == "实时新名称", "details selection resolves live store value rather than cached item snapshot")

        opened.removeAll()
        coordinator.onOpenWallpaperDetails = { url, metadata in
            if metadata.publishedFileID == "111" { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return "cancelled" }
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item):
                guard !Task.isCancelled else { return "cancelled" }
                selection.itemID = item.id
                opened.append(item.id)
                return nil
            case .failure(let error): return error.message
            }
        }
        let slowA = Task { await coordinator.openWallpaperDetails(itemID: "111") }
        for _ in 0..<100 where coordinator.openingDetailsItemID != "111" { await Task.yield() }
        let latestB = await coordinator.openWallpaperDetails(itemID: "222")
        _ = await slowA.value
        let bID = store.items.first { $0.workshopID == "222" }!.id
        check(latestB == nil && selection.itemID == bID && opened == [bID], "fast A then B cancels stale A presentation and opens only B")
        check(coordinator.openingDetailsItemID == nil, "singleflight busy state clears after newest request")
        opened.removeAll()
        let cancelled = Task { await coordinator.openWallpaperDetails(itemID: "111") }
        for _ in 0..<100 where coordinator.openingDetailsItemID != "111" { await Task.yield() }
        cancelled.cancel()
        _ = await cancelled.value
        check(opened.isEmpty && selection.itemID == bID && coordinator.openingDetailsItemID == nil,
            "caller cancellation propagates into import/presentation bridge")
        let pending = Task { await coordinator.openWallpaperDetails(itemID: "111") }
        for _ in 0..<100 where coordinator.openingDetailsItemID != "111" { await Task.yield() }
        let deniedDelete = await coordinator.deleteDownloadedWallpaper(itemID: "111")
        check(deniedDelete?.contains("正在打开") == true, "deletion cannot race an opening details import")
        coordinator.cancelOpeningWallpaperDetails()
        selection.itemID = bID
        _ = await pending.value
        check(opened.isEmpty && selection.itemID == bID, "direct library selection cancels older workshop presentation")
        coordinator.onOpenWallpaperDetails = { _, _ in "fixture import failure" }
        let failed = await coordinator.openWallpaperDetails(itemID: "111")
        check(failed == "fixture import failure" && coordinator.wallpaperDetailsError == failed && coordinator.downloadBanner?.contains("fixture import failure") == true,
            "details error is shared across source controls and download banner")
        coordinator.onApplyWallpaper = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return .failed("fixture only")
        }
        let applying = Task { await coordinator.applyWallpaper(itemID: "111", target: .allDisplays) }
        for _ in 0..<100 where !coordinator.isApplyingWallpaper { await Task.yield() }
        let busy = await coordinator.openWallpaperDetails(itemID: "222")
        check(busy?.contains("正在处理") == true && coordinator.openingDetailsItemID == nil,
            "application-in-flight returns explicit details feedback without another import")
        _ = await applying.value

        // Record removal uses actual isolated AV sessions, including a disconnected/suspended screen.
        let frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        let snapshots = ["A", "A-offline", "B"].map { id in
            DisplayDescriptor(id: id, displayID: 1, localizedName: id, frame: frame, visibleFrame: frame,
                backingScaleFactor: 1, isPrimary: id == "A", pixelSize: frame.size)
        }
        let registry = DisplayRegistry(snapshot: snapshots)
        let sessions = DesktopPlaybackController(store: store, displayRegistry: registry,
            storage: storage, previewOnly: true, writesToLibrary: true)
        defer { sessions.tearDownAll() }
        check(sessions.apply(item: store.item(withID: aID)!, to: ["A", "A-offline"]) == nil &&
              sessions.apply(item: store.item(withID: bID)!, to: ["B"]) == nil, "isolated removal fixtures start real players for both wallpapers")
        sessions.reconcileSessions(onlineDisplayIDs: ["A", "B"], displays: snapshots.filter { $0.id != "A-offline" })
        check(sessions.suspendedAssignments["A-offline"] == aID, "one removed-item session is genuinely suspended")
        let aBytes = try Data(contentsOf: a.project!.videoURL)
        try WallpaperDetailsActions.removeRecord(itemID: aID, store: store, playback: sessions)
        check(store.item(withID: aID) == nil && !store.assignments.values.contains(aID), "remove commits record and all its assignments")
        check(!sessions.sessions.values.contains { $0.item.id == aID } && !sessions.suspendedAssignments.values.contains(aID),
            "record removal releases active and suspended sessions for that item")
        check(sessions.session(for: "B")?.item.id == bID && store.item(withID: bID) != nil,
            "unrelated wallpaper record and live session remain")
        check(try Data(contentsOf: a.project!.videoURL) == aBytes, "record removal preserves original video bytes")
        selection.itemID = aID
        check(store.item(withID: selection.itemID) == nil, "deleted selection becomes unavailable instead of showing stale item")
        store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        var rejected = false
        do { try WallpaperDetailsActions.removeRecord(itemID: bID, store: store, playback: sessions) }
        catch { rejected = true }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        check(rejected && store.item(withID: bID) != nil && sessions.session(for: "B") != nil,
            "failed persistence keeps record and active player intact")
        // A real import held at the probe boundary must remain deletion-protected after UI cancel/switch.
        let measuredProbe = try await VideoProbe.probe(url: a.project!.videoURL)
        let cancelStorage = AppStorage(root: root.appendingPathComponent("cancel-boundary"))
        let cancelStore = VideoLibraryStore(storage: cancelStorage)
        let barrier = DetailsProbeBarrier()
        let cancelImporter = ImportService(store: cancelStore, storage: cancelStorage,
            thumbnailCache: ThumbnailCache(storage: cancelStorage), probeOperation: { _ in
                await barrier.wait()
                return measuredProbe
            })
        let protected = WorkshopCoordinator(account: account, browserStore: WorkshopBrowserStore(persistenceURL: nil),
                                            queuePersistence: .disabled)
        protected.downloadProgress.items = [a, b]
        var presented = 0
        var destructiveCalls = 0
        protected.onDeleteWallpaper = { _ in destructiveCalls += 1; return nil }
        protected.onOpenWallpaperDetails = { url, metadata in
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: cancelStore, importer: cancelImporter) {
            case .success:
                guard !Task.isCancelled else { return "cancelled" }
                presented += 1
                return nil
            case .failure(let error): return error.message
            }
        }
        let heldA = Task { await protected.openWallpaperDetails(itemID: "111") }
        for _ in 0..<1000 {
            if await barrier.enteredCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        check(await barrier.enteredCount == 1, "controlled actual import reached noncooperative probe")
        let heldB = Task { await protected.openWallpaperDetails(itemID: "222") }
        for _ in 0..<100 where protected.openingDetailsItemID != "222" { await Task.yield() }
        check(protected.detailsImportItemIDs == ["111", "222"], "switching A to B preserves old actual-import protection")
        let refuseOldA = await protected.deleteDownloadedWallpaper(itemID: "111")
        check(refuseOldA != nil && destructiveCalls == 0, "old cancelled A cannot be deleted while its probe is still running")
        protected.cancelOpeningWallpaperDetails() // Same method invoked by native windowWillClose.
        check(protected.openingDetailsItemID == nil && protected.detailsImportItemIDs == ["111", "222"],
            "window close clears presentation but retains actual imports until they return")
        await barrier.releaseAll()
        _ = await heldA.value
        _ = await heldB.value
        check(cancelStore.items.isEmpty && presented == 0 && protected.detailsImportItemIDs.isEmpty,
            "caller cancellation reaches runImport inner task; no late store.add or reopened window")
        check(FileManager.default.fileExists(atPath: a.project!.videoURL.path), "cancel/delete refusal preserves source fixture")

        let sameBarrier = DetailsProbeBarrier()
        let sameImporter = ImportService(store: cancelStore, storage: cancelStorage,
            thumbnailCache: ThumbnailCache(storage: cancelStorage), probeOperation: { _ in
                await sameBarrier.wait()
                return measuredProbe
            })
        protected.onOpenWallpaperDetails = { url, metadata in
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: cancelStore, importer: sameImporter) {
            case .success:
                guard !Task.isCancelled else { return "cancelled" }
                presented += 1
                return nil
            case .failure(let error): return error.message
            }
        }
        let firstSame = Task { await protected.openWallpaperDetails(itemID: "111") }
        for _ in 0..<1000 {
            if await sameBarrier.enteredCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let secondSame = Task { await protected.openWallpaperDetails(itemID: "111") }
        for _ in 0..<100 { await Task.yield() }
        await sameBarrier.releaseOne()
        for _ in 0..<1000 {
            if await sameBarrier.enteredCount == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = await firstSame.value
        check(await sameBarrier.enteredCount == 2 && protected.detailsImportItemIDs.contains("111"),
            "old same-ID request finishing cannot remove newer request UUID protection")
        let refuseSame = await protected.deleteDownloadedWallpaper(itemID: "111")
        check(refuseSame != nil && destructiveCalls == 0, "same-ID successor remains protected from deletion")
        protected.cancelOpeningWallpaperDetails()
        await sameBarrier.releaseAll()
        _ = await secondSame.value
        check(cancelStore.items.isEmpty && presented == 0 && protected.detailsImportItemIDs.isEmpty,
            "closing final same-ID request leaves no record or stale presentation after probe completion")
        cancelStore.flush()
        print("WallpaperDetailsRouteTests: \(checks) checks passed; temporary store, real preview-only players; no user library/account/system lock screen")
    }
}
