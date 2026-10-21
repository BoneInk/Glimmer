import Foundation

/// Runs in-process shader compiles on one dedicated thread, under a watchdog.
///
/// glslang can't be interrupted and a thread can't be killed, so a compile that never returns
/// (a preprocessor loop on a malformed WE shader) would stall its caller forever while holding
/// the library's global lock. A caller waits at most `timeout` of the job's own run time; after
/// that the thread is abandoned for the rest of the session (`isStuck`): jobs queued behind it
/// fail at once and new ones are refused, so their callers fail fast instead of waiting behind it.
///
/// Thread-safe: `State.condition` owns every field of `State`.
final class ShaderCompileThread {
    enum Failure: Error, CustomStringConvertible {
        /// This job ran longer than the timeout and is still running.
        case timedOut(TimeInterval)
        /// An earlier job is stuck on the thread; this one never ran.
        case stuck

        var description: String {
            switch self {
            case .timedOut(let seconds): return "timed out after \(Int(seconds.rounded())) s"
            case .stuck: return "an earlier in-process compile is stuck"
            }
        }
    }

    /// A single compile step takes milliseconds; the slowest WE shaders take well under a second.
    static let defaultTimeout: TimeInterval = 20
    /// glslang recurses per nested macro and expression; a secondary thread's default 512 KB stack
    /// is far less than the main thread's 8 MB.
    static let stackSize = 16 << 20

    let timeout: TimeInterval
    private let state = State()

    private final class Job {
        let execute: () -> Void
        let fail: (Failure) -> Void
        var startedAt: DispatchTime?

        init(execute: @escaping () -> Void, fail: @escaping (Failure) -> Void) {
            self.execute = execute
            self.fail = fail
        }
    }

    /// Shared with the thread, which must not keep the owner alive.
    private final class State {
        let condition = NSCondition()
        var jobs: [Job] = []
        var running: Job?
        var stuck = false
        var closed = false
    }

    /// The result of one job; written once, before `done` is signalled.
    private final class Outcome<T> {
        let done = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
    }

    init(name: String = "OWE shader compile", timeout: TimeInterval = ShaderCompileThread.defaultTimeout) {
        self.timeout = timeout
        let state = state
        let thread = Thread { Self.serve(state) }
        thread.name = name
        thread.stackSize = Self.stackSize
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    deinit {
        state.condition.lock()
        state.closed = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    /// Whether a job overran the timeout; the thread is never used again once it has.
    var isStuck: Bool {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.stuck
    }

    /// Runs `body` on the compile thread and returns its result, or throws `Failure` when it (or a
    /// job ahead of it) overruns the timeout.
    func run<T>(_ body: @escaping () throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let job = Job(execute: {
            outcome.result = Result { try body() }
            outcome.done.signal()
        }, fail: { failure in
            outcome.result = .failure(failure)
            outcome.done.signal()
        })
        state.condition.lock()
        guard !state.stuck else {
            state.condition.unlock()
            throw Failure.stuck
        }
        state.jobs.append(job)
        state.condition.signal()
        state.condition.unlock()

        // Wake up now and then to check the running job's age: the timeout counts its run time, not
        // the time this job spent queued behind healthy ones.
        let slice = max(timeout / 8, 0.005)
        while outcome.done.wait(timeout: .now() + slice) == .timedOut {
            try checkOverrun(waiting: job)
        }
        return try outcome.result!.get()
    }

    /// Marks the thread stuck when its running job has overrun, failing everything queued. Throws
    /// `timedOut` to the caller of the overrunning job.
    private func checkOverrun(waiting job: Job) throws {
        state.condition.lock()
        let running = state.running
        let overdue = running?.startedAt.map {
            Double(DispatchTime.now().uptimeNanoseconds - $0.uptimeNanoseconds) / 1e9 > timeout
        } ?? false
        var abandoned: [Job] = []
        if overdue && !state.stuck {
            state.stuck = true
            abandoned = state.jobs
            state.jobs.removeAll()
        }
        state.condition.unlock()
        for queued in abandoned { queued.fail(.stuck) }
        if overdue && running === job { throw Failure.timedOut(timeout) }
    }

    private static func serve(_ state: State) {
        while true {
            state.condition.lock()
            while state.jobs.isEmpty && !state.closed { state.condition.wait() }
            guard !state.jobs.isEmpty else {
                state.condition.unlock()
                return
            }
            let job = state.jobs.removeFirst()
            job.startedAt = .now()
            state.running = job
            state.condition.unlock()
            autoreleasepool { job.execute() }
            state.condition.lock()
            state.running = nil
            state.condition.unlock()
        }
    }
}
