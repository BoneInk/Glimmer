import Foundation

/// A bounded pool for heavy preparation work (parsing, texture decode and compression, shader
/// translation, pipeline builds, cache files).
///
/// - Workers: `activeProcessorCount - 1` at `.utility`; library jobs are further held to
///   `libraryWorkers` (2) and run at `.background`.
/// - Memory: every job declares its estimated peak bytes. A job starts only while the running
///   jobs' estimates plus its own fit the budget; a job larger than the whole budget runs alone.
/// - Order: priority first (the wallpaper being set, then the displays' current wallpapers, then
///   the library), then submission order. A job that does not fit the budget holds back the jobs
///   behind it, so a large job is never starved by a stream of small ones.
/// - Library jobs also wait while `libraryGate` says no (the power policy); call `reevaluate()`
///   when its answer changes.
final class PreparationPool: @unchecked Sendable {
    enum Priority: Int, Comparable, Sendable, CaseIterable {
        case settingWallpaper = 0
        case currentWallpaper = 1
        case library = 2
        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A submitted job. `cancel()` drops it if it has not started; a running job sees
    /// `isCancelled` and should return early.
    final class Job: @unchecked Sendable {
        let priority: Priority
        let estimatedBytes: Int
        fileprivate let sequence: UInt64
        fileprivate let work: (Job) -> Void
        fileprivate let onCancel: (() -> Void)?
        fileprivate weak var pool: PreparationPool?
        private let lock = NSLock()
        private var _cancelled = false

        fileprivate init(priority: Priority, estimatedBytes: Int, sequence: UInt64,
                         work: @escaping (Job) -> Void, onCancel: (() -> Void)?) {
            self.priority = priority
            self.estimatedBytes = max(0, estimatedBytes)
            self.sequence = sequence
            self.work = work
            self.onCancel = onCancel
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

        func cancel() {
            lock.lock()
            let wasCancelled = _cancelled
            _cancelled = true
            lock.unlock()
            if !wasCancelled { pool?.cancelled(self) }
        }
    }

    static let shared = PreparationPool()

    static var defaultMemoryBudget: Int {
        let tenth = Int(min(ProcessInfo.processInfo.physicalMemory / 10, UInt64(Int.max)))
        return min(1 << 30, tenth)
    }

    let maxWorkers: Int
    let libraryWorkers: Int
    let memoryBudget: Int

    private let lock = NSLock()
    private var pending: [Job] = []          // kept sorted by (priority, sequence)
    private var running = 0
    private var runningLibrary = 0
    private var runningBytes = 0
    private var nextSequence: UInt64 = 0
    private var libraryGate: @Sendable () -> Bool = { true }
    private var idleWaiters: [() -> Void] = []

    init(maxWorkers: Int = max(1, ProcessInfo.processInfo.activeProcessorCount - 1),
         libraryWorkers: Int = 2,
         memoryBudget: Int = PreparationPool.defaultMemoryBudget) {
        self.maxWorkers = max(1, maxWorkers)
        self.libraryWorkers = max(1, min(libraryWorkers, self.maxWorkers))
        self.memoryBudget = max(1, memoryBudget)
    }

    /// Submits `work`, run on a pool thread. `onCancel` runs (on the cancelling thread) when the job
    /// is cancelled before it starts.
    @discardableResult
    func submit(priority: Priority, estimatedBytes: Int = 0,
                onCancel: (() -> Void)? = nil,
                _ work: @escaping (Job) -> Void) -> Job {
        lock.lock()
        let job = Job(priority: priority, estimatedBytes: estimatedBytes, sequence: nextSequence,
                      work: work, onCancel: onCancel)
        nextSequence &+= 1
        job.pool = self
        let index = pending.firstIndex { $0.priority > priority } ?? pending.endIndex
        pending.insert(job, at: index)
        let ready = takeReadyLocked()
        lock.unlock()
        start(ready)
        return job
    }

    /// Async form: the value of `work`, or `CancellationError` when cancelled (the task's
    /// cancellation cancels the job).
    func run<T: Sendable>(priority: Priority, estimatedBytes: Int = 0,
                          _ work: @escaping @Sendable (Job) throws -> T) async throws -> T {
        let box = JobBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                let once = ResumeOnce(continuation)
                let job = submit(priority: priority, estimatedBytes: estimatedBytes,
                                 onCancel: { once.resume(.failure(CancellationError())) }) { job in
                    if job.isCancelled { once.resume(.failure(CancellationError())); return }
                    once.resume(Result { try work(job) })
                }
                box.set(job)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Sets the gate library jobs wait on, and re-evaluates.
    func setLibraryGate(_ gate: @escaping @Sendable () -> Bool) {
        lock.lock(); libraryGate = gate; lock.unlock()
        reevaluate()
    }

    /// Starts whatever can start now (after the library gate's answer changed).
    func reevaluate() {
        lock.lock()
        let ready = takeReadyLocked()
        lock.unlock()
        start(ready)
    }

    struct Snapshot: Equatable, Sendable {
        let pending: Int
        let running: Int
        let runningBytes: Int
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(pending: pending.count, running: running, runningBytes: runningBytes)
    }

    /// Calls `body` once nothing is pending or running (for tests and shutdown).
    func whenIdle(_ body: @escaping () -> Void) {
        lock.lock()
        if pending.isEmpty && running == 0 { lock.unlock(); body(); return }
        idleWaiters.append(body)
        lock.unlock()
    }

    // MARK: - Private

    fileprivate func cancelled(_ job: Job) {
        lock.lock()
        let index = pending.firstIndex { $0 === job }
        if let index { pending.remove(at: index) }
        let ready = takeReadyLocked()
        let idle = drainIdleLocked()
        lock.unlock()
        if index != nil { job.onCancel?() }
        start(ready)
        idle.forEach { $0() }
    }

    private func takeReadyLocked() -> [Job] {
        var ready: [Job] = []
        var index = 0
        var libraryAllowed: Bool?
        while index < pending.count, running < maxWorkers {
            let job = pending[index]
            if job.priority == .library {
                if libraryAllowed == nil { libraryAllowed = libraryGate() }
                // Library jobs are last in order, so nothing behind them can start either.
                if libraryAllowed == false || runningLibrary >= libraryWorkers { break }
            }
            let fits = running == 0 || runningBytes + job.estimatedBytes <= memoryBudget
            if !fits { break }
            pending.remove(at: index)
            running += 1
            runningBytes += job.estimatedBytes
            if job.priority == .library { runningLibrary += 1 }
            ready.append(job)
            // An oversized job runs alone.
            if job.estimatedBytes > memoryBudget { break }
        }
        return ready
    }

    private func drainIdleLocked() -> [() -> Void] {
        guard pending.isEmpty, running == 0, !idleWaiters.isEmpty else { return [] }
        defer { idleWaiters.removeAll() }
        return idleWaiters
    }

    private func start(_ jobs: [Job]) {
        for job in jobs {
            // Settings › Process Priority (`ProcessPriority`).
            let qos = ProcessPriority.current.preparationQoS(job.priority)
            DispatchQueue.global(qos: qos).async { [self] in
                ThreadGuards.assertBackground("PreparationPool job")
                if !job.isCancelled { job.work(job) } else { job.onCancel?() }
                finished(job)
            }
        }
    }

    private func finished(_ job: Job) {
        lock.lock()
        running -= 1
        runningBytes -= job.estimatedBytes
        if job.priority == .library { runningLibrary -= 1 }
        let ready = takeReadyLocked()
        let idle = drainIdleLocked()
        lock.unlock()
        start(ready)
        idle.forEach { $0() }
    }
}

private final class JobBox: @unchecked Sendable {
    private let lock = NSLock()
    private var job: PreparationPool.Job?
    private var cancelled = false
    func set(_ job: PreparationPool.Job) {
        lock.lock(); self.job = job; let c = cancelled; lock.unlock()
        if c { job.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let j = job; lock.unlock()
        j?.cancel()
    }
}

private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func resume(_ result: Result<T, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with: result)
    }
}
