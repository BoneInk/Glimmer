import Foundation

@MainActor final class SceneCacheCounter { var calls = 0 }
@MainActor final class SceneMaterialState {
    var payload: Data
    var engine: String
    init(payload: Data, engine: String) { self.payload = payload; self.engine = engine }
}
@MainActor final class SceneLeaseState {
    var url: URL?
    var released = false
}
@MainActor final class ScenePayloadLog { var values: [Data] = [] }

@main @MainActor enum SceneLockScreenCacheTests {
    struct Failure: Error { let message: String }
    static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(message: name) }
        checks += 1; print("PASS \(name)"); fflush(stdout)
    }
    static func wait(_ name: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "Timeout: " + name)
    }
    static func entryDirectories(_ root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.lastPathComponent.count == 64 && $0.lastPathComponent.allSatisfy(\.isHexDigit)
        }
    }
    static func hasStaging(_ root: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).contains {
            $0.hasPrefix(".staging-")
        }
    }
    static func manifest(_ directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    static func makeProject(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json","title":"Scene Cache"}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data(#"{"objects":[{"id":1}]}"#.utf8)
            .write(to: root.appendingPathComponent("scene.json"))
        try Data("scene-asset-v1".utf8).write(to: root.appendingPathComponent("asset.bin"))
    }
    static func material(projectRoot: URL, state: SceneMaterialState) async throws
        -> RenderedLockScreenVideoCache.Material {
        let projectHash = try await RenderedLockScreenVideoCache.projectHash(root: projectRoot)
        let identity = RenderedLockScreenVideoCache.contentHash(
            Data("\(projectHash)\u{0}engine:\(state.engine)".utf8))
        return .init(identityHash: identity,
                     payloadHash: RenderedLockScreenVideoCache.contentHash(state.payload),
                     payload: state.payload)
    }
    static func cache(root: URL, settings: RenderedLockScreenVideoCache.Settings,
                      projectRoot: URL, state: SceneMaterialState, counter: SceneCacheCounter,
                      delay: Duration? = nil, failure: Bool = false,
                      onExport: (@MainActor @Sendable () throws -> Void)? = nil,
                      onPayload: (@MainActor @Sendable (Data) -> Void)? = nil)
        -> RenderedLockScreenVideoCache {
        RenderedLockScreenVideoCache(root: root, settings: settings,
            materialProvider: { try await material(projectRoot: projectRoot, state: state) },
            exportOperation: { payload, directory, _ in
                counter.calls += 1
                onPayload?(payload)
                try onExport?()
                if let delay { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                if failure { throw Failure(message: "controlled export failure") }
                let output = directory.appendingPathComponent("generated.mp4")
                try await SyntheticVideoWriter.write(to: output, options: .init(
                    width: settings.width, height: settings.height,
                    frameRate: settings.framesPerSecond,
                    frameCount: Int(settings.duration * Double(settings.framesPerSecond))))
                return output
            })
    }

    static func main() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("SceneLockScreenCache-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let projectRoot = work.appendingPathComponent("Project", isDirectory: true)
        try makeProject(projectRoot)
        let settings = RenderedLockScreenVideoCache.Settings(signature: "scene-h264-v1",
            duration: 2, framesPerSecond: 20, width: 320, height: 180)

        // Reuse across instances and restarts.
        let reuseRoot = work.appendingPathComponent("Reuse", isDirectory: true)
        let counter = SceneCacheCounter()
        let state = SceneMaterialState(payload: Data(#"{"active":true}"#.utf8), engine: "engine-a")
        let firstCache = cache(root: reuseRoot, settings: settings, projectRoot: projectRoot,
                               state: state, counter: counter)
        let first = try await firstCache.video()
        let secondCache = cache(root: reuseRoot, settings: settings, projectRoot: projectRoot,
                                state: state, counter: counter)
        let second = try await secondCache.video()
        try check(first == second && counter.calls == 1, "scene cache reuses an identical project/payload/engine across instances")

        // Project bytes, payload, engine and export settings each invalidate.
        try Data("scene-asset-v2".utf8).write(to: projectRoot.appendingPathComponent("asset.bin"))
        _ = try await cache(root: reuseRoot, settings: settings, projectRoot: projectRoot,
                            state: state, counter: counter).video()
        try check(counter.calls == 2, "scene project content change records a new video")

        state.payload = Data(#"{"active":false}"#.utf8)
        _ = try await cache(root: reuseRoot, settings: settings, projectRoot: projectRoot,
                            state: state, counter: counter).video()
        try check(counter.calls == 3, "saved author payload change records a new video")

        state.engine = "engine-b"
        _ = try await cache(root: reuseRoot, settings: settings, projectRoot: projectRoot,
                            state: state, counter: counter).video()
        try check(counter.calls == 4, "engine binary/asset identity change records a new video")

        let changedSettings = RenderedLockScreenVideoCache.Settings(signature: "scene-h264-v1",
            duration: 2, framesPerSecond: 10, width: 320, height: 180)
        _ = try await cache(root: reuseRoot, settings: changedSettings, projectRoot: projectRoot,
                            state: state, counter: counter).video()
        try check(counter.calls == 5, "export settings change records a new video")

        // One mid-export project change retries against the latest bytes.
        let mutationRoot = work.appendingPathComponent("Mutation", isDirectory: true)
        let mutationCounter = SceneCacheCounter()
        let mutationState = SceneMaterialState(payload: Data(#"{"mutation":0}"#.utf8), engine: "engine-m")
        let assetURL = projectRoot.appendingPathComponent("asset.bin")
        let mutationVideo = try await cache(root: mutationRoot, settings: settings, projectRoot: projectRoot,
            state: mutationState, counter: mutationCounter,
            onExport: {
                guard mutationCounter.calls == 1 else { return }
                try Data("mutated-during-export".utf8).write(to: assetURL)
            }).video()
        let mutationEntries = entryDirectories(mutationRoot)
        let mutationManifest = mutationEntries.count == 1 ? try manifest(mutationEntries[0]) : [:]
        let latestMutation = try await material(projectRoot: projectRoot, state: mutationState)
        try check(mutationCounter.calls == 2 && mutationEntries.count == 1
                  && mutationVideo.deletingLastPathComponent().resolvingSymlinksInPath().path == mutationEntries[0].resolvingSymlinksInPath().path
                  && mutationManifest["projectHash"] as? String == latestMutation.identityHash
                  && mutationManifest["payloadHash"] as? String == latestMutation.payloadHash
                  && !hasStaging(mutationRoot),
                  "scene project change during export rebakes latest identity and publishes only the new entry")
        try Data("scene-asset-v1".utf8).write(to: assetURL)

        // One payload change similarly rebakes with the payload actually passed to the second export.
        let payloadMutationCounter = SceneCacheCounter()
        let payloadMutationState = SceneMaterialState(payload: Data(#"{"mutation":1}"#.utf8), engine: "engine-m")
        let payloadMutationRoot = work.appendingPathComponent("PayloadMutation", isDirectory: true)
        let payloadLog = ScenePayloadLog()
        _ = try await cache(root: payloadMutationRoot, settings: settings, projectRoot: projectRoot,
            state: payloadMutationState, counter: payloadMutationCounter,
            onExport: { payloadMutationState.payload = Data(#"{"mutation":2}"#.utf8) },
            onPayload: { payloadLog.values.append($0) }).video()
        let payloadEntries = entryDirectories(payloadMutationRoot)
        let payloadManifest = payloadEntries.count == 1 ? try manifest(payloadEntries[0]) : [:]
        try check(payloadMutationCounter.calls == 2 && payloadEntries.count == 1
                  && payloadLog.values.count == 2 && payloadLog.values[0] != payloadLog.values[1]
                  && payloadLog.values[1] == payloadMutationState.payload
                  && payloadManifest["payloadHash"] as? String
                    == RenderedLockScreenVideoCache.contentHash(payloadLog.values[1])
                  && !hasStaging(payloadMutationRoot),
                  "scene payload change rebakes with latest material and publishes only the new entry")

        // A second change during the retry stops after one bounded retry.
        let boundedRoot = work.appendingPathComponent("BoundedRetry", isDirectory: true)
        let boundedCounter = SceneCacheCounter()
        let boundedState = SceneMaterialState(payload: Data(#"{"bounded":0}"#.utf8), engine: "engine-m")
        do {
            _ = try await cache(root: boundedRoot, settings: settings, projectRoot: projectRoot,
                state: boundedState, counter: boundedCounter,
                onExport: {
                    boundedState.payload = Data("{\"bounded\":\(boundedCounter.calls)}".utf8)
                }).video()
            throw Failure(message: "second change unexpectedly succeeded")
        } catch let error as RenderedLockScreenVideoFailure {
            try check(error.message.contains("再次变化") && error.message.contains("重试"),
                      "second change reports a bounded finish-adjusting-then-retry failure")
        }
        try check(boundedCounter.calls == 2 && entryDirectories(boundedRoot).isEmpty
                  && !hasStaging(boundedRoot),
                  "second change stops after two exports and cleans staging")

        // Cancellation during the automatic restart remains cancellation, not a retry loop.
        let restartCancelRoot = work.appendingPathComponent("RestartCancellation", isDirectory: true)
        let restartCancelCounter = SceneCacheCounter()
        let restartCancelState = SceneMaterialState(payload: Data(#"{"restart":0}"#.utf8), engine: "engine-r")
        let restartCancelCache = cache(root: restartCancelRoot, settings: settings, projectRoot: projectRoot,
            state: restartCancelState, counter: restartCancelCounter, delay: .milliseconds(400),
            onExport: {
                guard restartCancelCounter.calls == 1 else { return }
                restartCancelState.payload = Data(#"{"restart":1}"#.utf8)
            })
        let restartCancellation = Task { @MainActor in try await restartCancelCache.video() }
        try await wait("automatic restart export starts") { restartCancelCounter.calls == 2 }
        restartCancellation.cancel()
        do { _ = try await restartCancellation.value; throw Failure(message: "cancelled restart succeeded") }
        catch is CancellationError {}
        for _ in 0..<50 where hasStaging(restartCancelRoot) { try await Task.sleep(for: .milliseconds(10)) }
        try check(entryDirectories(restartCancelRoot).isEmpty && !hasStaging(restartCancelRoot),
                  "cancellation during automatic restart publishes nothing and cleans staging")

        // Independent waiters coalesce onto the single retry flight.
        let coalescedRoot = work.appendingPathComponent("RestartCoalesced", isDirectory: true)
        let coalescedCounter = SceneCacheCounter()
        let coalescedState = SceneMaterialState(payload: Data(#"{"coalesce":0}"#.utf8), engine: "engine-co")
        let coalescedA = cache(root: coalescedRoot, settings: settings, projectRoot: projectRoot,
            state: coalescedState, counter: coalescedCounter, delay: .milliseconds(300),
            onExport: {
                guard coalescedCounter.calls == 1 else { return }
                coalescedState.payload = Data(#"{"coalesce":1}"#.utf8)
            })
        let coalescedB = cache(root: coalescedRoot, settings: settings, projectRoot: projectRoot,
            state: coalescedState, counter: coalescedCounter, delay: .milliseconds(300))
        let coalescedFirst = Task { @MainActor in try await coalescedA.video() }
        try await wait("coalesced first export starts") { coalescedCounter.calls == 1 }
        let coalescedSecond = Task { @MainActor in try await coalescedB.video() }
        let coalescedPair = try await (coalescedFirst.value, coalescedSecond.value)
        try check(coalescedCounter.calls == 2 && coalescedPair.0 == coalescedPair.1
                  && entryDirectories(coalescedRoot).count == 1 && !hasStaging(coalescedRoot),
                  "concurrent waiters coalesce across the automatic restart")

        // One waiter cancelling must not cancel another waiter's flight.
        let sharedRoot = work.appendingPathComponent("Shared", isDirectory: true)
        let sharedCounter = SceneCacheCounter()
        let sharedState = SceneMaterialState(payload: Data(#"{"shared":1}"#.utf8), engine: "engine-s")
        let abandonedCache = cache(root: sharedRoot, settings: settings, projectRoot: projectRoot,
            state: sharedState, counter: sharedCounter, delay: .milliseconds(600))
        let survivorCache = cache(root: sharedRoot, settings: settings, projectRoot: projectRoot,
            state: sharedState, counter: sharedCounter, delay: .milliseconds(600))
        let abandoned = Task { @MainActor in try await abandonedCache.video() }
        try await wait("shared export starts") { sharedCounter.calls == 1 }
        try await Task.sleep(for: .milliseconds(80))
        let survivor = Task { @MainActor in try await survivorCache.video() }
        try await Task.sleep(for: .milliseconds(80))
        abandoned.cancel()
        do { _ = try await abandoned.value; throw Failure(message: "cancelled waiter succeeded") }
        catch is CancellationError { }
        _ = try await survivor.value
        try check(sharedCounter.calls == 1, "cancelling one waiter keeps the shared scene recording alive")

        // Last waiter cancellation cancels the owned export work.
        let allCancelledRoot = work.appendingPathComponent("AllCancelled", isDirectory: true)
        let allCancelledCounter = SceneCacheCounter()
        let allCancelledState = SceneMaterialState(payload: Data(#"{"cancel":1}"#.utf8), engine: "engine-c")
        let cancelA = cache(root: allCancelledRoot, settings: settings, projectRoot: projectRoot,
            state: allCancelledState, counter: allCancelledCounter, delay: .seconds(5))
        let cancelB = cache(root: allCancelledRoot, settings: settings, projectRoot: projectRoot,
            state: allCancelledState, counter: allCancelledCounter, delay: .seconds(5))
        let taskA = Task { @MainActor in try await cancelA.video() }
        try await wait("cancelled export starts") { allCancelledCounter.calls == 1 }
        try await Task.sleep(for: .milliseconds(80))
        let taskB = Task { @MainActor in try await cancelB.video() }
        try await Task.sleep(for: .milliseconds(80))
        taskA.cancel(); taskB.cancel()
        do { _ = try await taskA.value; throw Failure(message: "first cancelled task returned a video") }
        catch is CancellationError { }
        do { _ = try await taskB.value; throw Failure(message: "second cancelled task returned a video") }
        catch is CancellationError { }
        try check(entryDirectories(allCancelledRoot).isEmpty,
                  "cancel of the last waiters cancels recording and publishes nothing")

        // LRU must not evict an entry while an operation leases it.
        let leaseRoot = work.appendingPathComponent("Lease", isDirectory: true)
        let leaseCounter = SceneCacheCounter()
        let leaseState = SceneMaterialState(payload: Data(#"{"lease":0}"#.utf8), engine: "engine-l")
        let leaseCache = cache(root: leaseRoot, settings: settings, projectRoot: projectRoot,
                               state: leaseState, counter: leaseCounter)
        let observedLease = SceneLeaseState()
        let leaseTask = Task { @MainActor in
            try await leaseCache.withVideo { url in
                observedLease.url = url
                while !observedLease.released { try await Task.sleep(for: .milliseconds(10)) }
                return FileManager.default.fileExists(atPath: url.path)
            }
        }
        try await wait("lease acquired") { observedLease.url != nil }
        for version in 1...10 {
            leaseState.payload = Data("{\"lease\":\(version)}".utf8)
            _ = try await cache(root: leaseRoot, settings: settings, projectRoot: projectRoot,
                                state: leaseState, counter: leaseCounter).video()
        }
        let leasedSurvived = observedLease.url.map { fm.fileExists(atPath: $0.path) } == true
        observedLease.released = true
        let operationSurvived = try await leaseTask.value
        try check(leasedSurvived && operationSurvived, "LRU keeps a leased scene video until its operation finishes")

        print("Scene lock-screen cache checks: \(checks) passed")
    }
}
