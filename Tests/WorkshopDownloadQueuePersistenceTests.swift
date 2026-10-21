import Foundation

@main @MainActor enum WorkshopDownloadQueuePersistenceTests {
    struct Failure: Error { let message: String }
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        checks += 1
        print("PASS \(message)")
    }

    static func wait(_ message: String, _ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw Failure(message: "timeout: \(message)")
    }

    static func item(_ id: String) -> WorkshopDownloadItem {
        WorkshopDownloadItem(publishedFileID: id, title: "Item \(id)", kind: .video,
                             declaredTags: ["Video"], previewImageURLString: "https://example.invalid/\(id).jpg",
                             fileSizeBytes: 1234)
    }

    static func coordinator(root: URL, queueURL: URL) -> WorkshopCoordinator {
        WorkshopCoordinator(
            account: SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("Workshop/SteamCMD"))),
            browserStore: WorkshopBrowserStore(persistenceURL: nil),
            downloadPreflight: { "fixture scheduler blocked" },
            queuePersistence: .file(queueURL)
        )
    }

    static func main() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("GWQueuePersistence-\(UUID().uuidString)")
        let queueURL = root.appendingPathComponent("Workshop/download-queue.json")
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }

            let first = coordinator(root: root, queueURL: queueURL)
            await first.loadDownloadQueueIfNeeded()
            first.setDownloadQueuePaused(true)
            first.enqueueDownload(item("1001"))
            first.enqueueDownload(item("1002"))
            first.enqueueDownload(item("1003"))
            first.moveQueuedDownload(itemID: "1003", direction: .up)
            first.pauseDownload(itemID: "1001")
            first.cancelDownload(itemID: "1002")
            first.downloadProgress.items[first.downloadProgress.items.firstIndex { $0.id == "1003" }!].state =
                .downloading(fraction: 0.87, text: "untrusted cached rate")
            await first.flushDownloadQueuePersistence()
            try check(first.queuePersistenceError == nil && fm.fileExists(atPath: queueURL.path),
                      "first coordinator atomically persists explicit queue intent")

            let second = coordinator(root: root, queueURL: queueURL)
            await second.loadDownloadQueueIfNeeded()
            try check(second.downloadProgress.items.map(\.id) == ["1001", "1003", "1002"],
                      "second coordinator restores durable order")
            try check(second.isDownloadQueuePaused, "global queue pause intent survives restart")
            try check(second.downloadProgress.items[0].state == .paused && second.downloadProgress.items[1].state == .queued,
                      "paused stays paused and an in-flight item becomes re-verifiable queued work")
            try check(second.downloadProgress.items[1].progressFraction == nil && second.downloadProgress.items[1].progressText.isEmpty,
                      "cached byte fraction and transfer rate text are never restored as current progress")
            try check(second.downloadProgress.items[2].state == .cancelled,
                      "explicit user cancellation remains terminal and is not auto-retried")

            let quitRoot = root.appendingPathComponent("Quit")
            let quitURL = quitRoot.appendingPathComponent("Workshop/download-queue.json")
            let quitAccount = SteamAccountManager(layout: SteamCMDLayout(root: quitRoot.appendingPathComponent("Workshop/SteamCMD")))
            let quitting = WorkshopCoordinator(
                account: quitAccount, browserStore: WorkshopBrowserStore(persistenceURL: nil),
                downloadOperation: { _, _, _, _ in
                    while true { try await Task.sleep(for: .seconds(30)) }
                },
                downloadPreflight: { nil }, queuePersistence: .file(quitURL)
            )
            await quitting.loadDownloadQueueIfNeeded()
            quitting.enqueueDownload(item("1501"))
            try await wait("active download begins") { quitting.downloadProgress.activeItemID == "1501" }
            await quitting.shutdownDownloads()
            let afterQuit = coordinator(root: quitRoot, queueURL: quitURL)
            await afterQuit.loadDownloadQueueIfNeeded()
            try check(afterQuit.downloadProgress.items.first?.state == .queued,
                      "normal quit cancellation persists active work as recoverable queued intent")

            let cancelQuitRoot = root.appendingPathComponent("CancelThenQuit")
            let cancelQuitURL = cancelQuitRoot.appendingPathComponent("Workshop/download-queue.json")
            let cancelThenQuit = WorkshopCoordinator(
                account: SteamAccountManager(layout: SteamCMDLayout(root: cancelQuitRoot.appendingPathComponent("Workshop/SteamCMD"))),
                browserStore: WorkshopBrowserStore(persistenceURL: nil),
                downloadOperation: { _, _, _, _ in
                    while true { try await Task.sleep(for: .seconds(30)) }
                },
                downloadPreflight: { nil }, queuePersistence: .file(cancelQuitURL)
            )
            await cancelThenQuit.loadDownloadQueueIfNeeded()
            cancelThenQuit.enqueueDownload(item("1502"))
            try await wait("cancel-then-quit download begins") { cancelThenQuit.downloadProgress.activeItemID == "1502" }
            cancelThenQuit.cancelDownload(itemID: "1502")
            await cancelThenQuit.shutdownDownloads()
            let afterCancelQuit = coordinator(root: cancelQuitRoot, queueURL: cancelQuitURL)
            await afterCancelQuit.loadDownloadQueueIfNeeded()
            try check(afterCancelQuit.downloadProgress.items.first?.state == .cancelled,
                      "explicit cancel followed immediately by quit stays cancelled across restart")

            let raceRoot = root.appendingPathComponent("ConcurrentLoad")
            let raceURL = raceRoot.appendingPathComponent("Workshop/download-queue.json")
            let raceStore = WorkshopDownloadQueueStore(persistenceURL: raceURL, permittedRoot: raceURL.deletingLastPathComponent())
            try await raceStore.save(.init(queuePaused: true, items: [
                .init(publishedFileID: "1601", title: "durable", kind: "video", declaredTags: [],
                      previewImageURLString: nil, fileSizeBytes: nil, state: .queued,
                      attempts: 0, queuedAt: Date(), completedAt: nil)
            ]))
            let racing = coordinator(root: raceRoot, queueURL: raceURL)
            let loadOne = Task { @MainActor in await racing.loadDownloadQueueIfNeeded() }
            let loadTwo = Task { @MainActor in await racing.loadDownloadQueueIfNeeded() }
            racing.enqueueDownload(item("1602"))
            await loadOne.value
            await loadTwo.value
            try check(racing.queueRestoreState == .ready && Set(racing.downloadProgress.items.map(\.id)) == ["1601", "1602"],
                      "concurrent load callers share completion and preserve an enqueue made before restore finishes")

            var failedSnapshot = WorkshopDownloadQueueSnapshot(queuePaused: false, items: [
                .init(publishedFileID: "2001", title: "download", kind: "video", declaredTags: [],
                      previewImageURLString: nil, fileSizeBytes: nil, state: .downloading,
                      attempts: 3, queuedAt: Date(), completedAt: nil),
                .init(publishedFileID: "2002", title: "pause", kind: "video", declaredTags: [],
                      previewImageURLString: nil, fileSizeBytes: nil, state: .pausing,
                      attempts: 2, queuedAt: Date(), completedAt: nil),
                .init(publishedFileID: "2003", title: "validate", kind: "web", declaredTags: [],
                      previewImageURLString: nil, fileSizeBytes: nil, state: .validating,
                      attempts: 1, queuedAt: Date(), completedAt: nil),
                .init(publishedFileID: "2004", title: "failed", kind: "video", declaredTags: [],
                      previewImageURLString: nil, fileSizeBytes: nil,
                      state: .failed("fixture failure password: swordfish\nusername alice"),
                      attempts: 1, queuedAt: Date(), completedAt: nil)
            ])
            let store = WorkshopDownloadQueueStore(persistenceURL: queueURL, permittedRoot: queueURL.deletingLastPathComponent())
            try await store.save(failedSnapshot)
            let recovered = coordinator(root: root, queueURL: queueURL)
            await recovered.loadDownloadQueueIfNeeded()
            let recoveredStates = recovered.downloadProgress.items.map(\.state)
            try check(Array(recoveredStates.prefix(3)) == [.queued, .paused, .queued] && {
                guard case .failed(let message) = recoveredStates[3] else { return false }
                return !message.contains("swordfish") && !message.contains("alice")
            }(),
                      "downloading and validating recover queued, pausing recovers paused, and failed does not retry")

            recovered.downloadProgress.items.append(item("3001"))
            let deleteIndex = recovered.downloadProgress.items.firstIndex { $0.id == "3001" }!
            recovered.downloadProgress.items[deleteIndex].state = .completed
            recovered.onDeleteWallpaper = { _ in nil }
            await recovered.flushDownloadQueuePersistence()
            try check(await recovered.deleteDownloadedWallpaper(itemID: "3001") == nil,
                      "successful deletion completes only after queue persistence flush")
            let afterDelete = coordinator(root: root, queueURL: queueURL)
            await afterDelete.loadDownloadQueueIfNeeded()
            try check(!afterDelete.downloadProgress.items.contains { $0.id == "3001" },
                      "successfully deleted record cannot be resurrected on restart")
            var retained = item("3002")
            retained.state = .cancelled
            afterDelete.downloadProgress.items.append(retained)
            afterDelete.onDeleteWallpaper = { _ in "fixture delete failure" }
            await afterDelete.flushDownloadQueuePersistence()
            try check(await afterDelete.deleteDownloadedWallpaper(itemID: "3002") == "fixture delete failure",
                      "failed deletion retains its visible record")
            let afterFailedDelete = coordinator(root: root, queueURL: queueURL)
            await afterFailedDelete.loadDownloadQueueIfNeeded()
            try check(afterFailedDelete.downloadProgress.items.first(where: { $0.id == "3002" })?.state == .cancelled,
                      "failed deletion rolls back its durable tombstone")

            failedSnapshot.items.append(failedSnapshot.items[0])
            failedSnapshot.items.append(.init(publishedFileID: "../unsafe", title: "bad", kind: "video", declaredTags: [],
                                               previewImageURLString: "file:///etc/passwd", fileSizeBytes: -1,
                                               state: .queued, attempts: -4, queuedAt: Date(), completedAt: nil))
            try await store.save(failedSnapshot)
            let sanitized = try await store.load()!
            try check(sanitized.items.count == 4 && sanitized.items.allSatisfy { WorkshopItemID($0.publishedFileID) != nil },
                      "duplicate and invalid IDs are dropped during durable load (\(sanitized.items.map(\.publishedFileID)))")

            try Data("not-json".utf8).write(to: queueURL, options: .atomic)
            let malformed = coordinator(root: root, queueURL: queueURL)
            await malformed.loadDownloadQueueIfNeeded()
            if case .failed = malformed.queueRestoreState {} else { throw Failure(message: "malformed restore was not reported") }
            try check(malformed.queuePersistenceError != nil,
                      "malformed queue remains readable failure feedback and does not start scheduling")

            try Data(repeating: 0x20, count: WorkshopDownloadQueueStore.maximumBytes + 1).write(to: queueURL, options: .atomic)
            do { _ = try await store.load(); throw Failure(message: "oversize queue accepted") }
            catch WorkshopDownloadQueueStoreError.oversized { checks += 1; print("PASS oversized queue is rejected before decoding") }

            let unsafeStore = WorkshopDownloadQueueStore(
                persistenceURL: root.appendingPathComponent("outside/download-queue.json"),
                permittedRoot: root.appendingPathComponent("Workshop")
            )
            do { try await unsafeStore.save(.init(queuePaused: false, items: [])); throw Failure(message: "unsafe root accepted") }
            catch WorkshopDownloadQueueStoreError.unsafeLocation { checks += 1; print("PASS unsafe persistence root is rejected") }

            let realRoot = root.appendingPathComponent("RealRoot")
            let linkedRoot = root.appendingPathComponent("LinkedRoot")
            try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
            let linkedStore = WorkshopDownloadQueueStore(
                persistenceURL: linkedRoot.appendingPathComponent("download-queue.json"), permittedRoot: linkedRoot)
            do { try await linkedStore.save(.init(queuePaused: false, items: [])); throw Failure(message: "symlink root accepted") }
            catch WorkshopDownloadQueueStoreError.unsafeLocation { checks += 1; print("PASS symlink persistence root is rejected without rejecting temp root aliases") }

            let directoryTargetRoot = root.appendingPathComponent("DirectoryTarget")
            let directoryTargetURL = directoryTargetRoot.appendingPathComponent("download-queue.json")
            try fm.createDirectory(at: directoryTargetURL, withIntermediateDirectories: true)
            let directoryTargetStore = WorkshopDownloadQueueStore(persistenceURL: directoryTargetURL,
                                                                   permittedRoot: directoryTargetRoot)
            do { try await directoryTargetStore.save(.init(queuePaused: false, items: [])); throw Failure(message: "directory target accepted") }
            catch WorkshopDownloadQueueStoreError.unsafeLocation { checks += 1; print("PASS non-regular existing queue target is rejected") }

            let blockedParent = root.appendingPathComponent("Blocked")
            try Data("regular file".utf8).write(to: blockedParent)
            let failedSaveURL = blockedParent.appendingPathComponent("download-queue.json")
            let saveFailure = coordinator(root: root.appendingPathComponent("SaveFailure"), queueURL: failedSaveURL)
            await saveFailure.loadDownloadQueueIfNeeded()
            saveFailure.enqueueDownload(item("4001"))
            await saveFailure.flushDownloadQueuePersistence()
            try check(saveFailure.queuePersistenceError != nil && saveFailure.downloadBanner?.contains("未能保存") == true,
                      "save failure is surfaced and never claimed as durable")
            var destructiveCalls = 0
            saveFailure.onDeleteWallpaper = { _ in destructiveCalls += 1; return nil }
            _ = await saveFailure.deleteDownloadedWallpaper(itemID: "4001")
            try check(destructiveCalls == 0 && saveFailure.downloadProgress.items.contains { $0.id == "4001" },
                      "delete does not touch files when durable deletion intent cannot be saved")

            print("RESULT \(checks) durable queue persistence checks passed")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
