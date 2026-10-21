import AppKit
import Foundation

struct ThumbnailSceneInspectionStub {}

enum SceneWallpaperInspector {
    static func inspectUsingAvailableEngineAssets(projectURL: URL) throws -> ThumbnailSceneInspectionStub {
        throw WebProjectError.invalid("Scene rendering is not part of this isolated cache probe")
    }
}

enum SceneWallpaperRenderer {
    static func render(inspection: ThumbnailSceneInspectionStub, pixelSize: CGSize) throws -> CGImage {
        throw WebProjectError.invalid("Scene rendering is not part of this isolated cache probe")
    }
}

private actor GatedGenerationProbe {
    private(set) var starts = 0
    private var releases: [CheckedContinuation<Void, Never>] = []

    func beginAndWait() async -> (call: Int, cancelled: Bool) {
        starts += 1
        let call = starts
        await withCheckedContinuation { releases.append($0) }
        return (call, Task.isCancelled)
    }

    func releaseAll() {
        let waiting = releases
        releases.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor CancellationProbe {
    private(set) var starts = 0
    private(set) var cancellations = 0
    private(set) var finishes = 0

    func begin() async -> Int {
        starts += 1
        let call = starts
        if call == 1 {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) }
                catch { break }
            }
            if Task.isCancelled { cancellations += 1 }
            finishes += 1
            return call
        }
        finishes += 1
        return call
    }
}

private actor StaleGenerationProbe {
    private(set) var starts = 0
    private(set) var firstFinished = false
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var firstFinishedWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() async -> Int {
        starts += 1
        let call = starts
        guard call == 1 else { return call }
        await withCheckedContinuation { firstRelease = $0 }
        firstFinished = true
        let waiting = firstFinishedWaiters
        firstFinishedWaiters.removeAll()
        waiting.forEach { $0.resume() }
        return call
    }

    func releaseFirst() {
        let continuation = firstRelease
        firstRelease = nil
        continuation?.resume()
    }

    func waitForFirstToFinish() async {
        guard !firstFinished else { return }
        await withCheckedContinuation { firstFinishedWaiters.append($0) }
    }
}

private actor CancelWaiterGate {
    private var entered = false
    private var exited = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        let waiting = entryWaiters
        entryWaiters.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
        exited = true
        let finished = exitWaiters
        exitWaiters.removeAll()
        finished.forEach { $0.resume() }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func waitUntilExited() async {
        guard !exited else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    func release() {
        let waiter = releaseWaiter
        releaseWaiter = nil
        waiter?.resume()
    }
}

private func makeThumbnailImage(width: Int, height: Int, brightness: UInt8) -> NSImage? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
    ) else { return nil }
    if let data = rep.bitmapData {
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            data[offset] = brightness
            data[offset + 1] = brightness / 2
            data[offset + 2] = 255 - brightness
            data[offset + 3] = 255
        }
    }
    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(rep)
    return image
}

@main struct ThumbnailCacheConcurrencyTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/gw-thumbnail-cache-\(UUID().uuidString)",
                       isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        func waitFor(_ label: String, _ condition: @escaping @MainActor () async -> Bool) async {
            let deadline = ContinuousClock.now + .seconds(5)
            while !(await condition()) {
                precondition(ContinuousClock.now < deadline, "Timed out: \(label)")
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        func mediaItem(_ name: String) throws -> WallpaperItem {
            let url = root.appendingPathComponent("\(name).mp4")
            try Data("thumbnail-cache-fixture".utf8).write(to: url)
            return WallpaperItem(title: name, filePath: url.path)
        }

        let storage = AppStorage(root: root.appendingPathComponent("App", isDirectory: true))
        try storage.prepareDirectories()

        // Two simultaneous card requests share exactly one decode. The generator
        // completes before the second waiter installs its continuation, exercising
        // the completion-before-install ordering as well as task coalescing.
        let sharedItem = try mediaItem("shared")
        let sharedProbe = GatedGenerationProbe()
        let sharedCache = ThumbnailCache(storage: storage) { _, _ in
            let result = await sharedProbe.beginAndWait()
            precondition(!result.cancelled, "A live shared waiter must keep generation alive")
            return makeThumbnailImage(width: 12, height: 8, brightness: UInt8(40 + result.call))
        }
        let first = Task { await sharedCache.thumbnail(for: sharedItem) }
        await waitFor("first generation starts") { await sharedProbe.starts == 1 }
        let second = Task { await sharedCache.thumbnail(for: sharedItem) }
        await waitFor("second waiter joins") {
            await sharedCache.inFlightWaiterCountForTesting(id: sharedItem.id) == 2
        }
        await sharedProbe.releaseAll()
        let firstImage = await first.value
        let secondImage = await second.value
        let sharedStarts = await sharedProbe.starts
        check(firstImage != nil && secondImage != nil && sharedStarts == 1,
              "two waiters receive one shared generation result")
        let warmCachedImage = await sharedCache.cachedThumbnail(for: sharedItem)
        let warmStarts = await sharedProbe.starts
        check(warmCachedImage != nil && warmStarts == 1,
              "warm cache probing never starts another decode")

        // Cancelling one view removes only that waiter. The remaining view still
        // receives the image and the shared worker is not cancelled.
        let partiallyCancelledItem = try mediaItem("partial-cancel")
        let partialProbe = GatedGenerationProbe()
        let partialCache = ThumbnailCache(storage: storage) { _, _ in
            let result = await partialProbe.beginAndWait()
            precondition(!result.cancelled, "One cancelled waiter must not cancel the shared worker")
            return makeThumbnailImage(width: 14, height: 7, brightness: 90)
        }
        let cancelledWaiter = Task { await partialCache.thumbnail(for: partiallyCancelledItem) }
        await waitFor("partial generation starts") { await partialProbe.starts == 1 }
        let survivingWaiter = Task { await partialCache.thumbnail(for: partiallyCancelledItem) }
        await waitFor("partial second waiter joins") {
            await partialCache.inFlightWaiterCountForTesting(id: partiallyCancelledItem.id) == 2
        }
        cancelledWaiter.cancel()
        let cancelledResult = await cancelledWaiter.value
        check(cancelledResult == nil, "cancelled waiter returns promptly with nil")
        await waitFor("cancelled waiter removed") {
            await partialCache.inFlightWaiterCountForTesting(id: partiallyCancelledItem.id) == 1
        }
        await partialProbe.releaseAll()
        let survivingImage = await survivingWaiter.value
        let partialStarts = await partialProbe.starts
        check(survivingImage != nil && partialStarts == 1,
              "surviving waiter still receives the shared image")

        // Cancelling the last waiter cancels the underlying AVFoundation-friendly
        // worker rather than leaving it decoding for no consumer.
        let abandonedItem = try mediaItem("abandoned")
        let cancellationProbe = CancellationProbe()
        let abandonedCache = ThumbnailCache(storage: storage) { _, _ in
            let call = await cancellationProbe.begin()
            guard call > 1 else { return nil }
            return makeThumbnailImage(width: 9, height: 9, brightness: 30)
        }
        let lastWaiter = Task { await abandonedCache.thumbnail(for: abandonedItem) }
        await waitFor("abandoned generation starts") { await cancellationProbe.starts == 1 }
        lastWaiter.cancel()
        let lastCancelledResult = await lastWaiter.value
        check(lastCancelledResult == nil, "last cancelled waiter returns immediately")
        await waitFor("underlying worker observes cancellation") {
            await cancellationProbe.cancellations == 1
        }
        check(await abandonedCache.inFlightWaiterCountForTesting(id: abandonedItem.id) == 0 &&
              !fm.fileExists(atPath: storage.thumbnailURL(for: abandonedItem.id).path),
              "last cancellation removes the generation without publishing a thumbnail")

        // The synchronous cancellation handler can finish before the actor's
        // cancelWaiter cleanup. Hold that cleanup with a deterministic gate and let
        // generation completion win the actor: with no active waiter left, it must
        // not publish a JPEG or memory entry.
        let cancellationRaceItem = try mediaItem("cancellation-publication-race")
        let cancellationRaceProbe = GatedGenerationProbe()
        let cancellationRaceCache = ThumbnailCache(storage: storage) { _, _ in
            let result = await cancellationRaceProbe.beginAndWait()
            return makeThumbnailImage(width: 17 + result.call,
                                      height: 9 + result.call,
                                      brightness: 130)
        }
        let cancelWaiterGate = CancelWaiterGate()
        await cancellationRaceCache.setCancelWaiterHookForTesting {
            await cancelWaiterGate.enterAndWait()
        }
        let cancellationRaceWaiter = Task {
            await cancellationRaceCache.thumbnail(for: cancellationRaceItem)
        }
        await waitFor("cancellation race generation starts") {
            await cancellationRaceProbe.starts == 1
        }
        cancellationRaceWaiter.cancel()
        let cancellationRaceResult = await cancellationRaceWaiter.value
        check(cancellationRaceResult == nil,
              "cancellation race waiter returns nil synchronously")
        await cancelWaiterGate.waitUntilEntered()
        await cancellationRaceProbe.releaseAll()
        await waitFor("completion bypasses blocked cancelWaiter cleanup") {
            await cancellationRaceCache.inFlightWaiterCountForTesting(
                id: cancellationRaceItem.id) == 0
        }
        let cancellationRaceMemory = await cancellationRaceCache.cachedThumbnail(
            for: cancellationRaceItem)
        check(cancellationRaceMemory == nil &&
              !fm.fileExists(atPath: storage.thumbnailURL(for: cancellationRaceItem.id).path),
              "a completion with no active waiter publishes neither memory nor disk")
        await cancelWaiterGate.release()
        await cancelWaiterGate.waitUntilExited()
        await cancellationRaceCache.setCancelWaiterHookForTesting(nil)

        // invalidate() invalidates the old generation immediately. A replacement
        // generation may publish a new image before the old worker returns, and
        // the stale worker must never overwrite either memory or disk.
        let invalidatedItem = try mediaItem("invalidate")
        let invalidateProbe = StaleGenerationProbe()
        let invalidateCache = ThumbnailCache(storage: storage) { _, _ in
            let call = await invalidateProbe.begin()
            return makeThumbnailImage(width: call == 1 ? 11 : 23,
                                      height: call == 1 ? 11 : 13,
                                      brightness: call == 1 ? 20 : 220)
        }
        let oldWaiter = Task { await invalidateCache.thumbnail(for: invalidatedItem) }
        await waitFor("old invalidated generation starts") { await invalidateProbe.starts == 1 }
        await invalidateCache.invalidate(id: invalidatedItem.id)
        let invalidatedResult = await oldWaiter.value
        check(invalidatedResult == nil, "invalidate wakes the old waiter with nil")
        let replacementWaiter = Task { await invalidateCache.thumbnail(for: invalidatedItem) }
        guard let replacement = await replacementWaiter.value else {
            preconditionFailure("replacement generation produced no image")
        }
        check(replacement.size.width == 23 && replacement.size.height == 13,
              "replacement generation publishes its own image")
        await invalidateProbe.releaseFirst()
        await invalidateProbe.waitForFirstToFinish()
        try? await Task.sleep(for: .milliseconds(30))
        let afterStaleCompletion = await invalidateCache.cachedThumbnail(for: invalidatedItem)
        check(afterStaleCompletion?.size.width == 23 && afterStaleCompletion?.size.height == 13,
              "stale generation cannot overwrite replacement memory cache")
        let diskImage = NSImage(contentsOf: storage.thumbnailURL(for: invalidatedItem.id))
        check(diskImage?.size.width == 23 && diskImage?.size.height == 13,
              "stale generation cannot overwrite replacement disk cache")

        // clearDiskCache() has the same generation boundary across every key.
        let clearedItem = try mediaItem("clear")
        let clearProbe = StaleGenerationProbe()
        let clearCache = ThumbnailCache(storage: storage) { _, _ in
            let call = await clearProbe.begin()
            return makeThumbnailImage(width: call == 1 ? 15 : 27,
                                      height: call == 1 ? 15 : 17,
                                      brightness: call == 1 ? 10 : 180)
        }
        let clearedWaiter = Task { await clearCache.thumbnail(for: clearedItem) }
        await waitFor("pre-clear generation starts") { await clearProbe.starts == 1 }
        await clearCache.clearDiskCache()
        let clearedResult = await clearedWaiter.value
        check(clearedResult == nil, "clearDiskCache wakes old waiters with nil")
        let afterClearWaiter = Task { await clearCache.thumbnail(for: clearedItem) }
        guard let afterClear = await afterClearWaiter.value else {
            preconditionFailure("post-clear generation produced no image")
        }
        check(afterClear.size.width == 27 && afterClear.size.height == 17,
              "post-clear generation publishes fresh image")
        await clearProbe.releaseFirst()
        await clearProbe.waitForFirstToFinish()
        try? await Task.sleep(for: .milliseconds(30))
        let postClearCache = await clearCache.cachedThumbnail(for: clearedItem)
        let postClearDisk = NSImage(contentsOf: storage.thumbnailURL(for: clearedItem.id))
        check(postClearCache?.size.width == 27 && postClearDisk?.size.width == 27,
              "discarded pre-clear worker cannot restore stale memory or disk state")

        // A missing file short-circuits before any generation attempt.
        let missingItem = WallpaperItem(
            title: "missing", filePath: root.appendingPathComponent("absent.mp4").path)
        let missingProbe = CancellationProbe()
        let missingCache = ThumbnailCache(storage: storage) { _, _ in
            _ = await missingProbe.begin()
            return makeThumbnailImage(width: 1, height: 1, brightness: 1)
        }
        let missingImage = await missingCache.thumbnail(for: missingItem)
        let missingStarts = await missingProbe.starts
        check(missingImage == nil && missingStarts == 0,
              "missing media never starts thumbnail generation")

        print("ThumbnailCacheConcurrencyTests: \(checks) checks passed; shared waiters, waiter-only cancellation, last-waiter cancellation, cancellation/publication race, invalidate/clear generation fences, cache probing")
    }
}
