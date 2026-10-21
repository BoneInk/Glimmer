import Foundation

private actor ControlledDownloadExecutor {
    struct Call: Sendable {
        let sequence: Int
        let itemID: String
        let partialExisted: Bool
    }
    struct Pending {
        let call: Call
        let progress: @Sendable (WorkshopDownloadState) -> Void
        let log: @Sendable (String) -> Void
        let continuation: CheckedContinuation<WorkshopVideoProject, Error>
    }
    let root: URL
    private(set) var calls: [Call] = []
    private var pending: [Int: Pending] = [:]
    private(set) var cancelled: Set<Int> = []
    private(set) var maximumConcurrent = 0
    private var sequence = 0
    init(root: URL) { self.root = root }
    func run(_ item: WorkshopDownloadItem, progress: @escaping @Sendable (WorkshopDownloadState) -> Void,
             log: @escaping @Sendable (String) -> Void) async throws -> WorkshopVideoProject {
        sequence += 1
        let key = sequence
        let partial = root.appendingPathComponent(item.id + ".part")
        let existed = FileManager.default.fileExists(atPath: partial.path)
        if !existed { try Data("partial bytes for \(item.id)".utf8).write(to: partial) }
        let call = Call(sequence: key, itemID: item.id, partialExisted: existed)
        calls.append(call)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[key] = Pending(call: call, progress: progress, log: log, continuation: continuation)
                maximumConcurrent = max(maximumConcurrent, pending.count)
                progress(.downloading(fraction: 0.4, text: "fixture bytes"))
            }
        } onCancel: { Task { await self.recordCancellation(key) } }
    }
    private func recordCancellation(_ key: Int) { cancelled.insert(key) }
    func emit(_ key: Int, state: WorkshopDownloadState) { pending[key]?.progress(state) }
    func savedProgress(_ key: Int) -> (@Sendable (WorkshopDownloadState) -> Void)? { pending[key]?.progress }
    func savedLog(_ key: Int) -> (@Sendable (String) -> Void)? { pending[key]?.log }
    func finishCancelled(_ key: Int) {
        pending.removeValue(forKey: key)?.continuation.resume(throwing: CancellationError())
    }
    func fail(_ key: Int) {
        pending.removeValue(forKey: key)?.continuation.resume(throwing: WorkshopDownloadError.downloadFailed(detail: "controlled failure"))
    }
    func succeed(_ key: Int) {
        guard let value = pending.removeValue(forKey: key) else { return }
        let file = root.appendingPathComponent(value.call.itemID + ".part")
        value.continuation.resume(returning: WorkshopVideoProject(videoURL: file, videoRelativePath: file.lastPathComponent,
            projectJSONPath: "project.json", projectRoot: root, projectType: "video", projectTitle: value.call.itemID,
            workshopID: value.call.itemID, declaredTags: ["Video"], videoByteSize: 20,
            probe: .init(isPlayable: true, durationSeconds: 1, pixelWidth: 16, pixelHeight: 16, hasAudioTrack: false), diagnostics: ["controlled executor; media validation outside this test"]))
    }
}

@main struct WorkshopDownloadPauseTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, "FAIL: " + label); checks += 1 }
        func waitFor(_ label: String, _ predicate: @MainActor () async -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while !(await predicate()) {
                precondition(ContinuousClock.now < deadline, "TIMEOUT: " + label)
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GWPause-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ControlledDownloadExecutor(root: root)
        var preflightError: String? = "fixture not ready"
        var preflightCalls = 0
        let account = SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("SteamCMD")))
        let coordinator = WorkshopCoordinator(account: account, browserStore: WorkshopBrowserStore(persistenceURL: nil),
            downloadOperation: { item, username, progress, log in
                precondition(username == nil, "fixture must not use an account")
                return try await executor.run(item, progress: progress, log: log)
            }, downloadPreflight: { preflightCalls += 1; return preflightError }, queuePersistence: .disabled)
        var imports: [String] = []
        coordinator.onImportVideo = { _, metadata in imports.append(metadata.publishedFileID); return nil }
        func item(_ id: String) -> WorkshopDownloadItem { .init(publishedFileID: id, title: id, kind: .video, declaredTags: ["Video"]) }
        func state(_ id: String) -> WorkshopDownloadState { coordinator.downloadProgress.items.first { $0.id == id }!.state }
        func searchResult(_ id: String) -> WorkshopSearchResult { .init(publishedFileID: id, title: id, shortDescription: "", tags: ["Video"], childCount: 0, isCollection: false) }
        check(!coordinator.hasQueuedDownloads && !coordinator.isDownloadQueuePaused, "empty queue has no pending scheduling work")
        coordinator.enqueueDownload(item("101"))
        check(coordinator.hasQueuedDownloads && !coordinator.isWaitingForQueue(itemID: "101"), "preflight-blocked queued item is not mislabeled as globally paused")
        check(!coordinator.isDownloading && state("101") == .queued && coordinator.downloadBanner == preflightError, "failed preflight keeps queue without starting executor")
        check(await executor.calls.isEmpty && preflightCalls == 1, "preflight blocks real executor boundary")
        preflightError = nil
        coordinator.setDownloadQueuePaused(true)
        check(coordinator.isWaitingForQueue(itemID: "101"), "real queued item is waiting on explicit global scheduling gate")
        coordinator.enqueueDownload(item("102"))
        check(await executor.calls.isEmpty, "paused queue starts neither old nor newly queued item")
        coordinator.setDownloadQueuePaused(false)
        await waitFor("first download progress") { if case .downloading(fraction: .some(0.4), _) = state("101") { return true }; return false }
        check(await executor.calls.map(\.itemID) == ["101"] && coordinator.downloadProgress.activeItemID == "101", "unpause starts first queued only")
        coordinator.enqueueDownload(item("103"))
        coordinator.pauseDownload(itemID: "103")
        check(state("103") == .paused && coordinator.downloadProgress.items.last?.attempts == 0, "queued pause while another item runs never starts executor")
        let oldProgress = await executor.savedProgress(1)!
        let oldLog = await executor.savedLog(1)!
        coordinator.performDownloadAction(searchResult("101"))
        check(state("101") == .pausing && coordinator.isDownloading, "cover action enters pausing while executor still owns task")
        coordinator.resumeDownload(itemID: "101")
        coordinator.pauseDownload(itemID: "101")
        await waitFor("cancellation delivered") { await executor.cancelled.contains(1) }
        check(await executor.calls.count == 1 && state("102") == .queued, "cannot resume pausing or start duplicate before cleanup")
        await executor.emit(1, state: .downloading(fraction: 0.99, text: "late bytes"))
        try? await Task.sleep(for: .milliseconds(10))
        check(state("101") == .pausing, "progress cannot undo pausing")
        coordinator.setDownloadQueuePaused(true)
        await executor.finishCancelled(1)
        await waitFor("paused cleanup finished") { state("101") == .paused && !coordinator.isDownloading }
        check(coordinator.downloadProgress.items.first?.progressFraction == 0.4 && imports.isEmpty, "pause preserves measured bytes and never imports incomplete media")
        check(try Data(contentsOf: root.appendingPathComponent("101.part")) == Data("partial bytes for 101".utf8), "actual temporary partial bytes remain intact")
        coordinator.performDownloadAction(searchResult("101"))
        check(state("101") == .queued && !coordinator.isDownloading, "continue respects globally paused queue")
        check(coordinator.isWaitingForQueue(itemID: "101") && state("103") == .paused,
              "single resume exposes waiting state without opening gate or resuming another paused item")
        coordinator.setDownloadQueuePaused(false)
        await waitFor("resumed attempt") { await executor.calls.count == 2 }
        await waitFor("resumed measured progress") { if case .downloading(fraction: .some(0.4), _) = state("101") { return true }; return false }
        check(await executor.calls.last?.partialExisted == true && coordinator.downloadProgress.items.first?.attempts == 2, "continue invokes executor again over existing partial bytes, explicit attempt count")
        check(!coordinator.isWaitingForQueue(itemID: "101") && state("103") == .paused,
              "direct queue continuation starts eligible work and preserves individual pause")
        oldProgress(.validating("stale previous attempt"))
        oldLog("stale previous attempt log")
        try? await Task.sleep(for: .milliseconds(15))
        check(state("101") != .validating("stale previous attempt"), "previous attempt callback cannot mutate resumed attempt")
        check(!coordinator.downloadProgress.recentStatusLines.contains("stale previous attempt log"), "previous attempt log cannot contaminate resumed task")
        coordinator.setDownloadQueuePaused(true)
        await executor.succeed(2)
        await waitFor("completed resumed item") { state("101") == .completed && !coordinator.isDownloading }
        await waitFor("completed import callback") { imports == ["101"] }
        check(await executor.calls.count == 2 && state("102") == .queued, "queue pause lets current finish and blocks next")
        coordinator.pauseDownload(itemID: "102")
        check(state("102") == .paused && !coordinator.isDownloading, "queued item pause requires no executor/process")
        check(!coordinator.hasQueuedDownloads && coordinator.isDownloadQueuePaused,
              "paused gate remains explicit and recoverable even when no item is currently queued")
        coordinator.setDownloadQueuePaused(false)
        check(await executor.calls.count == 2, "paused item is not implicitly requeued by global continue")
        coordinator.resumeDownload(itemID: "102")
        await waitFor("second item starts") { await executor.calls.count == 3 }
        await executor.emit(3, state: .validating("fixture validation"))
        await waitFor("validating") { state("102") == .validating("fixture validation") }
        coordinator.pauseDownload(itemID: "102")
        check(await !executor.cancelled.contains(3) && state("102") == .validating("fixture validation"), "validation cannot pretend to be paused")
        coordinator.cancelDownload(itemID: "102")
        await waitFor("explicit cancel delivered") { await executor.cancelled.contains(3) }
        await executor.finishCancelled(3)
        await waitFor("explicit cancelled cleanup") { !coordinator.isDownloading }
        check(state("102") == .cancelled && imports == ["101"], "explicit cancellation is not paused and does not import")
        check(coordinator.downloadBanner == "下载已取消", "normal cancellation is readable cancellation, not a Swift error")
        coordinator.retryDownload(itemID: "102")
        await waitFor("retry cancelled item") { await executor.calls.count == 4 }
        await waitFor("retry downloading") { if case .downloading = state("102") { return true }; return false }
        coordinator.pauseDownload(itemID: "102")
        await waitFor("pause then cancel") { await executor.cancelled.contains(4) }
        coordinator.cancelDownload(itemID: "102")
        await executor.finishCancelled(4)
        await waitFor("cancel overrides pause") { !coordinator.isDownloading }
        check(state("102") == .cancelled, "explicit cancel while pausing revokes pause request")
        coordinator.retryDownload(itemID: "102")
        await waitFor("failure attempt") { await executor.calls.count == 5 }
        await waitFor("failure attempt downloading") { if case .downloading = state("102") { return true }; return false }
        coordinator.pauseDownload(itemID: "102")
        await executor.fail(5)
        await waitFor("actual failure") { !coordinator.isDownloading }
        check(state("102") == .failed(message: "下载失败：controlled failure"), "real non-cancellation failure is not disguised as paused")
        check(await executor.calls.count == 5 && state("103") == .paused, "scheduler skips individually paused queued item after other work finishes")
        coordinator.resumeDownload(itemID: "103")
        await waitFor("individual queued resume") { await executor.calls.count == 6 }
        await waitFor("individual resumed progress") { if case .downloading = state("103") { return true }; return false }
        coordinator.pauseDownload(itemID: "103")
        await waitFor("last pause cancellation") { await executor.cancelled.contains(6) }
        await executor.finishCancelled(6)
        await waitFor("last pause cleanup") { state("103") == .paused && !coordinator.isDownloading }
        check(imports == ["101"], "pausing and retrying never imports unfinished work")
        check(await executor.maximumConcurrent == 1, "executor concurrency never exceeds one")
        await waitFor("actual successful import badge") { coordinator.importedItemIDs.contains("101") }
        let completed = coordinator.downloadProgress.items.first { $0.id == "101" }!
        let bytes = try Data(contentsOf: root.appendingPathComponent("101.part"))
        coordinator.removeDownload(itemID: "101")
        check(!coordinator.downloadProgress.items.contains { $0.id == "101" } && coordinator.importedItemIDs.contains("101"),
              "session hide removes only the visible completed record, retaining actual successful import badge")
        check(try Data(contentsOf: root.appendingPathComponent("101.part")) == bytes,
              "session hide preserves real downloaded bytes")
        coordinator.downloadProgress.items.append(completed)
        check(coordinator.importedItemIDs.contains(completed.id), "redisplayed record still observes the genuine imported badge")
        coordinator.clearFinishedDownloads()
        check(!coordinator.downloadProgress.items.contains { $0.id == "101" } && coordinator.importedItemIDs.contains("101"),
              "batch session hide retains the same imported identity")
        check(state("102").isTerminal && state("103") == .paused &&
              (try? Data(contentsOf: root.appendingPathComponent("101.part"))) == bytes,
              "batch hide preserves non-success records, paused work and actual files")
        check(!account.isSignedIn && !FileManager.default.fileExists(atPath: account.layout.root.path), "no login, network, SteamCMD install or account files")
        print("PASS \(checks) controlled executor pause/resume/queue checks; real temp partial bytes, no account/network")
    }
}
