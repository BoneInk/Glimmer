import AppKit
import Foundation

@main
struct WorkshopWallpaperApplyTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, "FAIL: \(name)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GW-Apply-Test-\(UUID())")
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
        let video = root.appendingPathComponent("fixture.mp4")
        try await SyntheticVideoWriter.write(to: video, options: .init(width: 64, height: 64, frameRate: 10, frameCount: 10))
        let bytes = (try video.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        var downloaded = WorkshopDownloadItem(publishedFileID: "777", title: "演示视频", kind: .video, declaredTags: ["Video"])
        downloaded.state = .completed
        downloaded.project = WorkshopVideoProject(videoURL: video, videoRelativePath: video.lastPathComponent,
            projectJSONPath: "project.json", projectRoot: root, projectType: "video", projectTitle: "演示视频",
            workshopID: "777", declaredTags: ["Video"], videoByteSize: bytes,
            probe: .init(isPlayable: true, durationSeconds: 1, pixelWidth: 64, pixelHeight: 64, hasAudioTrack: false), diagnostics: [])
        coordinator.downloadProgress.items = [downloaded]
        check(coordinator.localPreview(for: "777") != nil && store.items.isEmpty && playback.sessions.isEmpty,
            "opening eligible preview never imports or applies")
        check(!(await coordinator.applyWallpaper(itemID: "777", target: .currentDisplay)).succeeded,
            "unwired application fails explicitly")
        var callbackCount = 0
        coordinator.onApplyWallpaper = { url, metadata, target in
            callbackCount += 1
            return await WorkshopWallpaperApplication.apply(url: url, metadata: metadata, target: target,
                currentDisplayID: displays.primary?.id, store: store, importer: importer,
                displays: displays, playback: playback)
        }
        check(!(await coordinator.applyWallpaper(itemID: "unknown", target: .allDisplays)).succeeded && callbackCount == 0,
            "unknown entry never reaches application boundary")
        coordinator.downloadProgress.items[0].state = .queued
        check(!(await coordinator.applyWallpaper(itemID: "777", target: .allDisplays)).succeeded && callbackCount == 0,
            "incomplete download cannot apply")
        coordinator.downloadProgress.items[0].state = .completed
        let metadata = downloaded.metadata!
        let invalidTarget = await WorkshopWallpaperApplication.apply(url: video, metadata: metadata, target: .currentDisplay,
            currentDisplayID: "removed-screen", store: store, importer: importer, displays: displays, playback: playback)
        check(!invalidTarget.succeeded && store.items.isEmpty && playback.sessions.isEmpty,
            "missing selected display causes no import or session mutation")
        guard let primary = displays.primary else {
            fatalError("Integration test requires an existing display; no display configuration is changed")
        }
        let first = await coordinator.applyWallpaper(itemID: "777", target: .currentDisplay)
        check(first.succeeded && callbackCount == 1 && store.items.count == 1, "explicit current-display action imports and starts session")
        let importedID = store.items.first!.id
        check(playback.sessions.count == 1 && playback.session(for: primary.id)?.item.id == importedID,
            "current target routes only to chosen display and imported UUID")
        check(playback.sessions.values.allSatisfy { $0.window == nil && $0.isPreviewOnly }, "integration never creates desktop window")
        check(displays.displays.allSatisfy { store.assignedItemID(for: $0.id) == nil }, "preview-only application never persists desktop assignment")
        let second = await coordinator.applyWallpaper(itemID: "777", target: .allDisplays)
        check(second.succeeded && store.items.count == 1 && store.items.first?.id == importedID,
            "repeated apply reuses duplicated UUID without extra library entry")
        check(playback.sessions.count == displays.displays.count, "all-displays target reaches all existing displays")
        check(!coordinator.isApplyingWallpaper, "busy state clears after success")
        let priorIDs = playback.sessions.mapValues { $0.item.id }
        let unwiredLock = await coordinator.requestDynamicLockScreen(itemID: "777")
        check(unwiredLock != nil, "unwired lock-screen action reports unavailable without changing desktop")
        var lockRequestCount = 0
        coordinator.onRequestDynamicLockScreen = { url, metadata in
            lockRequestCount += 1
            switch await WorkshopWallpaperApplication.importItem(url: url, metadata: metadata, store: store, importer: importer) {
            case .success(let item):
                check(item.id == importedID, "lock-screen preparation reuses selected imported item")
                return nil
            case .failure(let error): return error.message
            }
        }
        let lockMissing = await coordinator.requestDynamicLockScreen(itemID: "unknown")
        check(lockMissing != nil && lockRequestCount == 0, "unknown lock-screen item never reaches app callback")
        coordinator.downloadProgress.items[0].state = .queued
        let lockQueued = await coordinator.requestDynamicLockScreen(itemID: "777")
        check(lockQueued != nil && lockRequestCount == 0, "unfinished download cannot request lock-screen setup")
        coordinator.downloadProgress.items[0].state = .completed
        let lockReady = await coordinator.requestDynamicLockScreen(itemID: "777")
        check(lockReady == nil && lockRequestCount == 1 && store.items.count == 1,
            "explicit lock-screen setup imports/reuses video without duplicate library entry")
        check(playback.sessions.mapValues({ $0.item.id }) == priorIDs,
            "requesting lock-screen preparation leaves desktop session selection unchanged")
        check(!coordinator.isPreparingDynamicLockScreen, "lock-screen busy state clears after setup")
        try FileManager.default.removeItem(at: video)
        let missing = await coordinator.applyWallpaper(itemID: "777", target: .allDisplays)
        check(!missing.succeeded && callbackCount == 2 && playback.sessions.mapValues({ $0.item.id }) == priorIDs,
            "deleted local video rejected before callback and leaves current preview sessions intact")
        try Data("not a video".utf8).write(to: video)
        let corrupt = await coordinator.applyWallpaper(itemID: "777", target: .currentDisplay)
        check(!corrupt.succeeded && playback.sessions.mapValues({ $0.item.id }) == priorIDs && store.items.count == 1,
            "corrupt video fails actual import probe without replacing sessions")
        check(!coordinator.isApplyingWallpaper, "busy state clears after error")
        let cancelled = Task { await coordinator.applyWallpaper(itemID: "777", target: .allDisplays) }
        cancelled.cancel()
        check(!(await cancelled.value).succeeded && playback.sessions.mapValues({ $0.item.id }) == priorIDs,
            "cancelled explicit request never changes active sessions")
        coordinator.onApplyWallpaper = { _, _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return .failed("测试失败")
        }
        let pending = Task { await coordinator.applyWallpaper(itemID: "777", target: .currentDisplay) }
        await Task.yield()
        let duplicate = await coordinator.applyWallpaper(itemID: "777", target: .allDisplays)
        check(!duplicate.succeeded && duplicate.message.contains("正在设置"), "concurrent clicks are rejected while action in flight")
        _ = await pending.value
        coordinator.onRequestDynamicLockScreen = { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return "隔离测试失败"
        }
        let pendingLock = Task { await coordinator.requestDynamicLockScreen(itemID: "777") }
        await Task.yield()
        let duplicateLock = await coordinator.requestDynamicLockScreen(itemID: "777")
        check(duplicateLock?.contains("正在") == true, "concurrent lock-screen setup requests rejected")
        let failedLock = await pendingLock.value
        check(failedLock == "隔离测试失败" && !coordinator.isPreparingDynamicLockScreen,
            "lock-screen callback error propagated and busy state released")
        let deletionUnwired = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionUnwired != nil && coordinator.downloadProgress.items.count == 1,
            "unwired deletion keeps record")
        var deletionCalls = 0
        coordinator.onDeleteWallpaper = { _ in deletionCalls += 1; return "模拟废纸篓失败" }
        coordinator.downloadProgress.items[0].state = .queued
        let deletionQueued = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionQueued == "模拟废纸篓失败" && deletionCalls == 1,
              "queued partial item can enter deletion after no writer owns it")
        coordinator.downloadProgress.items[0].state = .validating("fixture")
        let deletionValidating = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionValidating != nil && deletionCalls == 1,
              "validating item cannot enter destructive callback")
        coordinator.downloadProgress.items[0].state = .completed
        coordinator.downloadProgress.activeItemID = "777"
        let deletionActive = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionActive != nil && deletionCalls == 1,
              "inconsistent active item without a cancellable writer cannot enter destructive callback")
        coordinator.downloadProgress.activeItemID = nil
        let deletionFailed = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionFailed == "模拟废纸篓失败" && deletionCalls == 2
                && coordinator.downloadProgress.items.count == 1 && coordinator.deletingWallpaperIDs.isEmpty,
            "deletion backend failure preserves record and clears busy state")
        check(coordinator.downloadBanner?.contains("模拟废纸篓失败") == true,
            "deletion failure is visible in download banner")
        coordinator.downloadProgress.items[0].state = .failed(message: "retryable fixture")
        deletionCalls = 0
        coordinator.onDeleteWallpaper = { _ in
            deletionCalls += 1
            try? await Task.sleep(for: .milliseconds(100))
            return nil
        }
        let deleting = Task { await coordinator.deleteDownloadedWallpaper(itemID: "777") }
        await Task.yield()
        check(coordinator.deletingWallpaperIDs.contains("777") && coordinator.localPreview(for: "777") == nil,
            "deleting item is busy and unavailable for new preview/apply")
        coordinator.enqueueDownload(downloaded)
        coordinator.retryDownload(itemID: "777")
        coordinator.retryFailedDownloads()
        coordinator.removeDownload(itemID: "777")
        check(coordinator.downloadProgress.items.first?.state == .failed(message: "retryable fixture"),
            "enqueue/retry/batch retry/remove cannot mutate in-flight deletion")
        let deletionDuplicate = await coordinator.deleteDownloadedWallpaper(itemID: "777")
        check(deletionDuplicate != nil && deletionCalls == 1, "duplicate deletion cannot start another backend transaction")
        let deleted = await deleting.value
        check(deleted == nil && coordinator.downloadProgress.items.isEmpty && coordinator.deletingWallpaperIDs.isEmpty,
            "successful backend deletion removes record only after completion")
        check(FileManager.default.fileExists(atPath: video.path),
            "coordinator tests use fake callback and never invoke real Trash or touch files")

        let activeProject = downloaded.project!
        let activeCoordinator = WorkshopCoordinator(
            account: SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("ActiveSteamCMD"))),
            browserStore: WorkshopBrowserStore(persistenceURL: nil),
            downloadOperation: { _, _, progress, _ in
                progress(.downloading(fraction: 0.25, text: "fixture writer active"))
                try await Task.sleep(for: .seconds(30))
                return activeProject
            },
            downloadPreflight: { nil }, queuePersistence: .disabled)
        var activeDeleteCalls = 0
        activeCoordinator.onDeleteWallpaper = { _ in activeDeleteCalls += 1; return nil }
        var activeItem = WorkshopDownloadItem(publishedFileID: "888", title: "active fixture",
                                              kind: .video, declaredTags: ["Video"])
        activeItem.state = .queued
        activeCoordinator.enqueueDownload(activeItem)
        for _ in 0..<100 where activeCoordinator.downloadProgress.activeItemID != "888" { await Task.yield() }
        check(activeCoordinator.downloadProgress.activeItemID == "888", "active deletion fixture owns a real download task")
        let activeDeleted = await activeCoordinator.deleteDownloadedWallpaper(itemID: "888")
        check(activeDeleted == nil && activeDeleteCalls == 1
                && activeCoordinator.downloadProgress.activeItemID == nil
                && activeCoordinator.downloadProgress.items.isEmpty,
              "active delete cancels and drains the writer before invoking deletion and removing the row")
        print("WorkshopWallpaperApplyTests: \(checks) checks passed; temporary storage, preview-only sessions, no account/network/desktop changes")
    }
}
