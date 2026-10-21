import Foundation

@MainActor final class CacheExportCounter { var calls = 0 }
@MainActor final class CacheLeaseState { var url: URL?; var released = false }
@MainActor final class CachePayloadLog { var values: [Data] = [] }

@main @MainActor enum WebLockScreenCacheTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    static func makeProject(_ root: URL, id: UUID) throws -> WallpaperItem {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"type":"web","file":"index.html","title":"Cache","general":{"properties":{"active":{"type":"bool","value":true}}}}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data("<canvas></canvas>".utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("asset-v1".utf8).write(to: root.appendingPathComponent("asset.txt"))
        return WallpaperItem(id: id, title: "Cache Fixture", filePath: root.appendingPathComponent("project.json").path,
                             contentKind: .web)
    }
    static func entryDirectories(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.lastPathComponent.count == 64 && $0.lastPathComponent.allSatisfy(\.isHexDigit)
        }
    }
    static func manifest(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    static func operation(counter: CacheExportCounter, settings: WebWallpaperLockScreenExporter.Settings,
                          delay: Duration? = nil, failure: Bool = false) -> WebWallpaperLockScreenVideoCache.ExportOperation {
        { _, _, directory, _ in
            counter.calls += 1
            if let delay { try await Task.sleep(for: delay) }
            try Task.checkCancellation()
            if failure { throw Failure(message: "controlled export failure") }
            let output = directory.appendingPathComponent("generated.mp4")
            try await SyntheticVideoWriter.write(to: output, options: .init(width: settings.width, height: settings.height,
                frameRate: settings.framesPerSecond, frameCount: Int(settings.duration * Double(settings.framesPerSecond))))
            return output
        }
    }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GW-Web-Cache-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let storage = AppStorage(root: root.appendingPathComponent("App")), projectRoot = root.appendingPathComponent("Project")
        let item = try makeProject(projectRoot, id: UUID()), cacheRoot = root.appendingPathComponent("Cache")
        let settings = WebWallpaperLockScreenExporter.Settings(duration: 2, framesPerSecond: 20, width: 320, height: 180)
        let counter = CacheExportCounter()
        var cache = WebWallpaperLockScreenVideoCache(root: cacheRoot, settings: settings,
            exportOperation: operation(counter: counter, settings: settings))
        let first = try await cache.video(item: item, storage: storage)
        let second = try await cache.video(item: item, storage: storage)
        cache = WebWallpaperLockScreenVideoCache(root: cacheRoot, settings: settings,
            exportOperation: operation(counter: counter, settings: settings))
        let restart = try await cache.video(item: item, storage: storage)
        try check(counter.calls == 1 && first == second && second == restart,
                  "same project and settings hit across a new cache instance with zero export calls")

        try Data("asset-v2".utf8).write(to: projectRoot.appendingPathComponent("asset.txt"))
        let changedFile = try await cache.video(item: item, storage: storage)
        try check(counter.calls == 2 && changedFile != first, "project byte change misses the content-addressed cache")

        let project = try AuthorPropertyProject.load(projectURL: item.fileURL, allowedRoot: projectRoot)
        let overrides = AuthorPropertyOverrideStore(directory: storage.root.appendingPathComponent("AuthorPropertyOverrides"))
        try await overrides.set(.bool(false), for: "active", itemID: item.id, project: project)
        let changedProperty = try await cache.video(item: item, storage: storage)
        try check(counter.calls == 3 && changedProperty != changedFile, "saved author value change misses the cache")

        let changedSettings = WebWallpaperLockScreenExporter.Settings(duration: 2, framesPerSecond: 10, width: 320, height: 180)
        let parameterCache = WebWallpaperLockScreenVideoCache(root: cacheRoot, settings: changedSettings,
            exportOperation: operation(counter: counter, settings: changedSettings))
        _ = try await parameterCache.video(item: item, storage: storage)
        try check(counter.calls == 4, "export parameter change misses the cache")

        try Data("tampered".utf8).append(to: changedProperty)
        _ = try await cache.video(item: item, storage: storage)
        try check(counter.calls == 5, "video hash mismatch rejects and regenerates a tampered entry")

        let goodEntries = Set(entryDirectories(cacheRoot).map(\.lastPathComponent))
        try Data("asset-failing-key".utf8).write(to: projectRoot.appendingPathComponent("asset.txt"))
        let failing = WebWallpaperLockScreenVideoCache(root: cacheRoot, settings: settings,
            exportOperation: operation(counter: counter, settings: settings, failure: true))
        do { _ = try await failing.video(item: item, storage: storage); throw Failure(message: "controlled failure succeeded") }
        catch { try check(Set(entryDirectories(cacheRoot).map(\.lastPathComponent)).isSuperset(of: goodEntries),
                          "failed regeneration does not overwrite previously published cache entries") }

        let cancelRoot = root.appendingPathComponent("CancelledCache"), cancelCounter = CacheExportCounter()
        let cancellable = WebWallpaperLockScreenVideoCache(root: cancelRoot, settings: settings,
            exportOperation: operation(counter: cancelCounter, settings: settings, delay: .seconds(10)))
        let cancellation = Task { @MainActor in try await cancellable.video(item: item, storage: storage) }
        try await Task.sleep(for: .milliseconds(100)); cancellation.cancel()
        do { _ = try await cancellation.value; throw Failure(message: "cancelled cache generation succeeded") } catch is CancellationError {}
        try check(entryDirectories(cancelRoot).isEmpty && !((try? fm.contentsOfDirectory(atPath: cancelRoot.path)) ?? []).contains(where: { $0.hasPrefix(".staging-") }),
                  "cancelled generation publishes no cache entry or staging residue")

        let registrationRoot = root.appendingPathComponent("RegistrationCancellation"), registrationCounter = CacheExportCounter()
        let registrationCache = WebWallpaperLockScreenVideoCache(root: registrationRoot, settings: settings,
            exportOperation: operation(counter: registrationCounter, settings: settings, delay: .seconds(10)),
            beforeWaitOperation: { try? await Task.sleep(for: .milliseconds(150)) })
        let registrationCancellation = Task { @MainActor in
            try await registrationCache.video(item: item, storage: storage)
        }
        try await Task.sleep(for: .milliseconds(30)); registrationCancellation.cancel()
        do { _ = try await registrationCancellation.value; throw Failure(message: "pre-registration cancellation succeeded") }
        catch is CancellationError {}
        for _ in 0..<50 where ((try? fm.contentsOfDirectory(atPath: registrationRoot.path)) ?? []).contains(where: { $0.hasPrefix(".staging-") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let registrationRecovery = WebWallpaperLockScreenVideoCache(root: registrationRoot, settings: settings,
            exportOperation: operation(counter: registrationCounter, settings: settings))
        _ = try await registrationRecovery.video(item: item, storage: storage)
        try check(registrationCounter.calls == 2 && entryDirectories(registrationRoot).count == 1
                  && !((try? fm.contentsOfDirectory(atPath: registrationRoot.path)) ?? []).contains(where: { $0.hasPrefix(".staging-") }),
                  "cancellation before waiter registration stops the empty flight and permits a clean retry")

        let concurrentRoot = root.appendingPathComponent("ConcurrentCache"), concurrentCounter = CacheExportCounter()
        let concurrentA = WebWallpaperLockScreenVideoCache(root: concurrentRoot, settings: settings,
            exportOperation: operation(counter: concurrentCounter, settings: settings, delay: .milliseconds(150)))
        let concurrentB = WebWallpaperLockScreenVideoCache(root: concurrentRoot, settings: settings,
            exportOperation: operation(counter: concurrentCounter, settings: settings, delay: .milliseconds(150)))
        async let a = concurrentA.video(item: item, storage: storage)
        async let b = concurrentB.video(item: item, storage: storage)
        let pair = try await (a, b)
        try check(concurrentCounter.calls == 1 && pair.0 == pair.1, "concurrent same-key requests share one export")

        let sharedRoot = root.appendingPathComponent("SharedCancellation"), sharedCounter = CacheExportCounter()
        let sharedA = WebWallpaperLockScreenVideoCache(root: sharedRoot, settings: settings,
            exportOperation: operation(counter: sharedCounter, settings: settings, delay: .milliseconds(250)))
        let sharedB = WebWallpaperLockScreenVideoCache(root: sharedRoot, settings: settings,
            exportOperation: operation(counter: sharedCounter, settings: settings, delay: .milliseconds(250)))
        let survivor = Task { @MainActor in try await sharedA.video(item: item, storage: storage) }
        let abandoned = Task { @MainActor in try await sharedB.video(item: item, storage: storage) }
        try await Task.sleep(for: .milliseconds(50)); abandoned.cancel()
        do { _ = try await abandoned.value; throw Failure(message: "cancelled shared waiter succeeded") } catch is CancellationError {}
        let survivingVideo = try await survivor.value
        try check(sharedCounter.calls == 1 && fm.fileExists(atPath: survivingVideo.path),
                  "cancelling one waiter keeps the shared export alive for remaining waiters")

        // One project change automatically retries against latest bytes.
        let mutationRoot = root.appendingPathComponent("MutationCache"), mutationCounter = CacheExportCounter()
        let baseMutationOperation = operation(counter: mutationCounter, settings: settings)
        let mutationCache = WebWallpaperLockScreenVideoCache(root: mutationRoot, settings: settings,
            exportOperation: { item, payload, directory, progress in
                if mutationCounter.calls == 0 {
                    try Data("changed-during-export".utf8).write(to: projectRoot.appendingPathComponent("asset.txt"))
                }
                let video = try await baseMutationOperation(item, payload, directory, progress)
                return video
            })
        let mutationVideo = try await mutationCache.video(item: item, storage: storage)
        let mutationEntries = entryDirectories(mutationRoot)
        let mutationManifest = mutationEntries.count == 1 ? try manifest(mutationEntries[0]) : [:]
        let latestProjectHash = try await RenderedLockScreenVideoCache.projectHash(root: projectRoot)
        try check(mutationCounter.calls == 2 && mutationEntries.count == 1
                  && mutationVideo.deletingLastPathComponent().resolvingSymlinksInPath().path == mutationEntries[0].resolvingSymlinksInPath().path
                  && mutationManifest["projectHash"] as? String == latestProjectHash,
                  "Web project change rebakes latest identity and publishes only the new entry")

        // Author values likewise retry once with the newest production payload.
        let propertyMutationRoot = root.appendingPathComponent("PropertyMutationCache"), propertyMutationCounter = CacheExportCounter()
        let basePropertyOperation = operation(counter: propertyMutationCounter, settings: settings)
        let propertyPayloads = CachePayloadLog()
        let propertyMutationCache = WebWallpaperLockScreenVideoCache(root: propertyMutationRoot, settings: settings,
            exportOperation: { item, payload, directory, progress in
                propertyPayloads.values.append(payload)
                let video = try await basePropertyOperation(item, payload, directory, progress)
                if propertyMutationCounter.calls == 1 {
                    try await overrides.set(.bool(true), for: "active", itemID: item.id, project: project)
                }
                return video
            })
        _ = try await propertyMutationCache.video(item: item, storage: storage)
        let propertyEntries = entryDirectories(propertyMutationRoot)
        let propertyManifest = propertyEntries.count == 1 ? try manifest(propertyEntries[0]) : [:]
        let latestPayload = try await WebWallpaperLockScreenConfiguration.payload(item: item, storage: storage)
        try check(propertyMutationCounter.calls == 2 && propertyEntries.count == 1
                  && propertyPayloads.values.count == 2
                  && propertyPayloads.values[0] != propertyPayloads.values[1]
                  && propertyPayloads.values[1] == latestPayload
                  && propertyManifest["payloadHash"] as? String
                    == RenderedLockScreenVideoCache.contentHash(latestPayload),
                  "Web author-property change rebakes latest payload and publishes only the new entry")

        let outside = root.appendingPathComponent("outside.txt"); try Data("outside".utf8).write(to: outside)
        let linked = projectRoot.appendingPathComponent("linked.txt"); try fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        do { _ = try await cache.video(item: item, storage: storage); throw Failure(message: "project symlink accepted") }
        catch { try check(try Data(contentsOf: outside) == Data("outside".utf8), "project symlink is rejected without touching its target") }
        try fm.removeItem(at: linked)

        let redirectedRoot = root.appendingPathComponent("RedirectedCache"), redirectTarget = root.appendingPathComponent("RedirectTarget")
        try fm.createDirectory(at: redirectTarget, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: redirectedRoot, withDestinationURL: redirectTarget)
        let redirected = WebWallpaperLockScreenVideoCache(root: redirectedRoot, settings: settings,
            exportOperation: operation(counter: CacheExportCounter(), settings: settings))
        do { _ = try await redirected.video(item: item, storage: storage); throw Failure(message: "cache-root symlink accepted") }
        catch { try check((try fm.contentsOfDirectory(atPath: redirectTarget.path)).isEmpty,
                          "cache-root symlink is rejected without writing through it") }

        let linkedEntryRoot = root.appendingPathComponent("LinkedEntryCache"), linkedCounter = CacheExportCounter()
        let linkedEntryCache = WebWallpaperLockScreenVideoCache(root: linkedEntryRoot, settings: settings,
            exportOperation: operation(counter: linkedCounter, settings: settings))
        let linkedVideo = try await linkedEntryCache.video(item: item, storage: storage)
        let preservedTarget = root.appendingPathComponent("preserved-cache-video.mp4")
        try fm.moveItem(at: linkedVideo, to: preservedTarget)
        try fm.createSymbolicLink(at: linkedVideo, withDestinationURL: preservedTarget)
        let regenerated = try await linkedEntryCache.video(item: item, storage: storage)
        try check(linkedCounter.calls == 2 && fm.fileExists(atPath: preservedTarget.path)
                  && (try regenerated.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true),
                  "symlinked cached video is replaced without touching its target")

        let preparedRoot = root.appendingPathComponent("PreparedAssets")
        let prepared = try await ExperimentalLockScreenAssetPreparer().prepare(item: item, sourceURL: regenerated, root: preparedRoot)
        try fm.removeItem(at: regenerated.deletingLastPathComponent())
        let preparedProbe = try await VideoProbe.probe(url: prepared.videoURL)
        try check(prepared.videoURL != regenerated && fm.fileExists(atPath: prepared.videoURL.path)
                  && preparedProbe.isPlayable,
                  "prepared lock-screen asset is an independent copy that survives cache eviction")

        let leaseState = CacheLeaseState()
        let leaseTask = Task { @MainActor in
            try await cache.withVideo(item: item, storage: storage) { url in
                leaseState.url = url
                while !leaseState.released { try await Task.sleep(for: .milliseconds(10)) }
                return fm.fileExists(atPath: url.path)
            }
        }
        while leaseState.url == nil { try await Task.sleep(for: .milliseconds(10)) }
        for version in 0..<10 {
            try Data("lru-\(version)".utf8).write(to: projectRoot.appendingPathComponent("asset.txt"))
            _ = try await cache.video(item: item, storage: storage)
        }
        let leasedStillExists = leaseState.url.map { fm.fileExists(atPath: $0.path) } == true
        leaseState.released = true
        let survivedCopy = try await leaseTask.value
        try check(survivedCopy && leasedStillExists,
                  "LRU keeps a cache entry leased while the preparer copies it")
        try check(entryDirectories(cacheRoot).count <= 8, "LRU retains at most eight private cache entries")
        print("RESULT \(checks) persistent Web lock-screen cache checks passed; temporary roots and injected exporters only")
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: self)
    }
}
