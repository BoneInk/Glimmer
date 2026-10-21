import Combine
import Foundation
import OWEEditor
import OWESceneEditing

/// Renders every preview of the Wallpaper Editor's browsers in the background as soon as WE's
/// assets are there, so a browser's first open finds them cached: at launch (`launchDelay` later)
/// when any is missing, and whenever the assets change (an install from the setup assistant or
/// Settings › Assets, a chosen folder).
///
/// - **Order:** every effect of Add Effect, then every particle system of Add Particle System,
///   each in its browser's order. A browser that opens meanwhile hands its missing tiles over
///   (`EditorPreviewWants`), which go first.
/// - **Resumable and incremental:** what is cached is skipped. A new assets build or a kind's
///   revision carries over every preview whose inputs didn't change (`EditorPreviewInputs`,
///   `EditorPreviewCache.carryOver`); only the rest renders. A preview that failed isn't tried
///   again until its inputs change (a browser still asks for it).
/// - **Cost:** `laneCount` helpers in the background state, each kept for every preview it renders
///   (`EditorPreviewHelperLane`); a browser's tiles render at its own helper's priority. The
///   planning reads at utility priority.
/// - **Power:** `allowsEditorPreviewPrewarm`: on battery only above 30 %, never while critically hot. It pauses between previews (the
///   helpers exit, the lock is released so an editor renders on its own) and checks again every
///   `pauseRecheck`. Each start, pause, resume and finish is logged.
/// - **Progress:** `progress` while a run renders, for a line in Settings › Assets.
@MainActor
final class EditorPreviewPrewarm: ObservableObject {
    struct Environment {
        /// The asset tree in use; nil without WE's assets.
        var assets: () -> URL?
        /// The parent of the previews' cache (`EditorPreviewHelper.cachesDirectory`).
        var cachesDirectory: URL
        /// Every subject of both browsers, in the order to render them.
        var catalog: @Sendable (URL) -> [EditorPreviewSubject]
        var power: () -> PowerPolicy
        var makeLane: @MainActor () -> EditorPreviewLane?
        var sleep: (TimeInterval) async -> Void
        var now: () -> Date
        var log: (String) -> Void
        var laneCount: Int

        @MainActor static var live: Environment {
            Environment(assets: { WallpaperEngineAssets.directory },
                        cachesDirectory: EditorPreviewHelper.cachesDirectory,
                        catalog: { EditorPreviewPrewarm.catalog(assets: $0) },
                        power: { PowerPolicyMonitor.shared.policy },
                        makeLane: { EditorPreviewHelperLane() },
                        sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) }, // Optional: cancelled.
                        now: Date.init,
                        log: { OWELog.info(.ui, "Editor previews: \($0)") },
                        laneCount: EditorPreviewPrewarm.laneCount)
        }
    }

    /// The previews rendered at once. Two keep the GPU busy while a helper loads its next scene.
    static let laneCount = 2
    /// How long after launch the check starts, so the wallpapers load first.
    static let launchDelay: TimeInterval = 20
    /// How often a paused run checks the power state again.
    static let pauseRecheck: TimeInterval = 60

    /// What the last run did, for tests.
    struct Summary: Equatable {
        var rendered: [EditorPreviewSubject] = []
        var failed: [EditorPreviewSubject] = []
        var cached = 0
        var carriedOver = 0
    }

    /// How far a run is: previews of the browsers' catalog that are done (cached, rendered, or
    /// failed and waiting for new assets) out of all of them, and whether it is paused.
    struct Progress: Equatable {
        var done: Int
        var total: Int
        var isPaused = false
    }

    private let environment: Environment
    private var task: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var lastSummary: Summary?
    /// The progress of the run that renders now; nil when none does (none started, nothing was
    /// missing, or it ended).
    @Published private(set) var progress: Progress?

    init(environment: Environment) {
        self.environment = environment
    }

    /// Starts a run (`delay` seconds later), replacing one that runs or waits.
    func start(reason: String, after delay: TimeInterval = 0) {
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            await previous?.value
            if delay > 0, let self { await self.environment.sleep(delay) }
            guard !Task.isCancelled else { return }
            await self?.run(reason: reason)
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Waits for the current run, for tests.
    func wait() async {
        await task?.value
    }

    // MARK: Planning

    private struct Plan: Sendable {
        let cache: EditorPreviewCache
        /// Still to render, in order.
        let order: [EditorPreviewSubject]
        let fingerprints: [EditorPreviewSubject: String]
        let records: [String: EditorPreviewCache.InputRecord]
        let cached: Int
        let carriedOver: Int
        let failedBefore: Int
    }

    /// Carries over and prunes other builds' previews, records the inputs of cached ones that have
    /// none (an editor rendered them), and lists what is left.
    nonisolated private static func plan(assets: URL, cachesDirectory: URL, catalog: [EditorPreviewSubject]) throws -> Plan {
        ThreadGuards.assertBackground("EditorPreviewPrewarm.plan")
        let cache = EditorPreviewCache(cachesDirectory: cachesDirectory, build: EditorPreviewCache.assetsBuild(of: assets))
        let fingerprints = EditorPreviewInputs.fingerprints(of: catalog, assets: assets)
        let carried = try cache.carryOver(fingerprints)
        try cache.prune()
        var records = cache.inputs()
        var added: [String: EditorPreviewCache.InputRecord] = [:]
        var order: [EditorPreviewSubject] = []
        var cached = 0
        var failedBefore = 0
        for subject in catalog {
            let name = subject.cacheName
            let fingerprint = fingerprints[subject] ?? ""
            if cache.cachedPreview(for: subject) != nil {
                cached += 1
                if records[name] != EditorPreviewCache.InputRecord(fingerprint: fingerprint) {
                    added[name] = EditorPreviewCache.InputRecord(fingerprint: fingerprint)
                }
            } else if let record = records[name], record.failedAt != nil, record.fingerprint == fingerprint {
                failedBefore += 1
            } else {
                order.append(subject)
            }
        }
        try cache.record(added)
        records.merge(added) { _, new in new }
        return Plan(cache: cache, order: order, fingerprints: fingerprints, records: records,
                    cached: cached - carried.count, carriedOver: carried.count, failedBefore: failedBefore)
    }

    // MARK: Running

    /// One run's shared state; its lanes run on the main actor between their awaits.
    private final class Run {
        let cache: EditorPreviewCache
        let lock: EditorPreviewPrewarmLock
        let wants: EditorPreviewWants
        let fingerprints: [EditorPreviewSubject: String]
        var queue: EditorPreviewPrewarmQueue
        var records: [String: EditorPreviewCache.InputRecord]
        var summary: Summary
        var paused = false
        var pausedSeconds: TimeInterval = 0

        init(plan: Plan, summary: Summary) {
            cache = plan.cache
            lock = EditorPreviewPrewarmLock(cache: plan.cache)
            wants = EditorPreviewWants(cache: plan.cache)
            fingerprints = plan.fingerprints
            queue = EditorPreviewPrewarmQueue(plan.order)
            records = plan.records
            self.summary = summary
        }
    }

    private func run(reason: String) async {
        guard let assets = environment.assets() else {
            environment.log("pre-warm skipped (\(reason)): Wallpaper Engine's assets aren't installed")
            return
        }
        isRunning = true
        defer { isRunning = false }
        let started = environment.now()
        let cachesDirectory = environment.cachesDirectory
        let catalog = environment.catalog
        let planned = await Task.detached(priority: .utility) { () -> Result<Plan, Error> in
            Result { try EditorPreviewPrewarm.plan(assets: assets, cachesDirectory: cachesDirectory, catalog: catalog(assets)) }
        }.value
        guard case .success(let plan) = planned else {
            if case .failure(let error) = planned { OWELog.error(.ui, "Editor previews: pre-warm failed to start (\(reason)): \(error)") }
            return
        }
        let state = Run(plan: plan, summary: Summary(cached: plan.cached, carriedOver: plan.carriedOver))
        lastSummary = state.summary
        guard !Task.isCancelled else { return }
        guard !plan.order.isEmpty else {
            environment.log("pre-warm (\(reason)): all \(plan.cached + plan.carriedOver) previews are cached"
                            + (plan.carriedOver > 0 ? ", \(plan.carriedOver) carried over from an earlier build" : "")
                            + (plan.failedBefore > 0 ? "; \(plan.failedBefore) failed before and wait for new assets" : ""))
            return
        }
        guard state.lock.lock() else {
            environment.log("pre-warm skipped (\(reason)): another copy of the app is rendering the previews")
            return
        }
        defer { state.lock.unlock() }
        let total = plan.cached + plan.carriedOver + plan.failedBefore + plan.order.count
        progress = Progress(done: total - plan.order.count, total: total)
        defer { progress = nil }
        environment.log("pre-warm started (\(reason)): \(plan.order.count) to render on \(environment.laneCount) lanes; "
                        + "\(plan.cached) cached, \(plan.carriedOver) carried over, \(plan.failedBefore) failed before")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, environment.laneCount) {
                group.addTask { @MainActor in await self.runLane(state) }
            }
        }
        lastSummary = state.summary
        let seconds = environment.now().timeIntervalSince(started)
        let outcome = Task.isCancelled ? "stopped" : "finished"
        environment.log("pre-warm \(outcome): \(state.summary.rendered.count) rendered, \(state.summary.failed.count) failed in "
                        + String(format: "%.1f s", seconds)
                        + (state.pausedSeconds > 0 ? String(format: " (%.0f s paused)", state.pausedSeconds) : ""))
    }

    private func runLane(_ state: Run) async {
        var lane: EditorPreviewLane?
        defer { lane?.close() }
        while !Task.isCancelled {
            let policy = environment.power()
            if !policy.allowsEditorPreviewPrewarm {
                lane?.close()
                lane = nil
                guard await waitWhilePaused(state, policy: policy) else { return }
            }
            state.queue.prioritize(state.wants.take())
            guard let next = state.queue.next(where: { isNeeded($0, urgent: $1, in: state) }) else { return }
            let subject = next.subject
            if lane == nil { lane = environment.makeLane() }
            guard let current = lane else {
                state.queue.putBack(subject)
                OWELog.error(.ui, "Editor previews: the pre-warm can't start a helper")
                return
            }
            let item = EditorPreviewRenderItem(subject: subject, outputBase: state.cache.outputBase(for: subject))
            if !(await current.render(item, isUrgent: next.isUrgent)) {
                current.close()
                lane = nil
            }
            finished(subject, in: state)
        }
    }

    private func isNeeded(_ subject: EditorPreviewSubject, urgent: Bool, in state: Run) -> Bool {
        guard state.cache.cachedPreview(for: subject) == nil else { return false }
        if urgent { return true }
        guard let record = state.records[subject.cacheName], record.failedAt != nil else { return true }
        return record.fingerprint != (state.fingerprints[subject] ?? "")
    }

    private func finished(_ subject: EditorPreviewSubject, in state: Run) {
        let fingerprint = state.fingerprints[subject] ?? ""
        let record: EditorPreviewCache.InputRecord
        if state.cache.cachedPreview(for: subject) != nil {
            state.summary.rendered.append(subject)
            record = EditorPreviewCache.InputRecord(fingerprint: fingerprint)
        } else {
            state.summary.failed.append(subject)
            record = EditorPreviewCache.InputRecord(fingerprint: fingerprint, failedAt: environment.now())
        }
        state.records[subject.cacheName] = record
        if var current = progress {
            // A browser's tile the catalog doesn't list (a Workshop effect) doesn't count past it.
            current.done = min(current.total, current.done + 1)
            progress = current
        }
        do {
            try state.cache.record([subject.cacheName: record])
        } catch {
            OWELog.error(.ui, "Editor previews: can't record the inputs of \(subject.cacheName) in \(state.cache.directory.path): \(error)")
        }
    }

    /// Waits while the power policy holds the pre-warm back; false when the run was cancelled.
    private func waitWhilePaused(_ state: Run, policy first: PowerPolicy) async -> Bool {
        var policy = first
        while !policy.allowsEditorPreviewPrewarm {
            if !state.paused {
                state.paused = true
                progress?.isPaused = true
                state.lock.unlock()
                environment.log("pre-warm paused: \(Self.reason(policy)); \(state.queue.count) previews left")
            }
            let since = environment.now()
            await environment.sleep(Self.pauseRecheck)
            state.pausedSeconds += environment.now().timeIntervalSince(since)
            if Task.isCancelled { return false }
            policy = environment.power()
        }
        if state.paused {
            state.paused = false
            progress?.isPaused = false
            guard state.lock.lock() else {
                environment.log("pre-warm stopped: another copy of the app took over the previews")
                return false
            }
            environment.log("pre-warm resumed: \(state.queue.count) previews left")
        }
        return true
    }

    private static func reason(_ policy: PowerPolicy) -> String {
        if policy.state.thermal == .critical { return "the Mac is critically hot" }
        let level = policy.state.batteryLevel.map { "\(Int(($0 * 100).rounded())) %" } ?? "an unknown charge"
        return "on battery at \(level), below \(Int(PowerPolicy.editorPreviewPrewarmMinimumBattery * 100)) %"
    }

    // MARK: The catalog

    /// Both browsers' subjects in their order: Add Effect's built-in effects without a picture of
    /// their own (by group, then title), then Add Particle System's systems and presets (as a 2D
    /// scene groups them).
    nonisolated static func catalog(assets: URL) -> [EditorPreviewSubject] {
        let labels = WallpaperEngineLabels.load(assets: assets)
        let effects = EditorWallpaperResources.builtInEffects(labels: labels) { path in
            guard let url = WallpaperEngineAssets.locate([path], in: [assets]) else { return nil }
            do {
                return try AssetPathResolver.readRegularFile(at: url)
            } catch {
                OWELog.error(.ui, "Editor previews: \(url.path) can't be read: \(error)")
                return nil
            }
        }
        let shownEffects = EffectCatalog.grouped(EffectCatalog.filter(effects.filter { $0.preview == nil }, query: ""))
            .flatMap { $0.entries }.map(\.previewSubject)
        let particles = ParticleCatalog.load(assetsDirectory: assets, translate: { labels.translation($0) })
        let shownParticles = ParticleCatalog.grouped(particles.items, sceneIs3D: false).flatMap { $0.items }.map(\.previewSubject)
        return shownEffects + shownParticles
    }
}

extension PowerPolicy {
    /// The editor previews' background pre-warm waits on battery below this charge…
    static let editorPreviewPrewarmMinimumBattery = 0.3

    /// …and at `.critical` heat. On AC it always runs.
    var allowsEditorPreviewPrewarm: Bool {
        if state.thermal == .critical { return false }
        guard state.onBattery else { return true }
        return (state.batteryLevel ?? 0) >= Self.editorPreviewPrewarmMinimumBattery
    }
}
