import Foundation

/// Time spent per load and render phase, for the test suite's slow-test report
/// (`TestPhaseTimer` in the tests). Debug builds only; release builds compile `measure` to a
/// plain call of its body.
///
/// Off until a test run turns it on (`setEnabled`): `measure` then reads one Bool and calls the
/// body. On, each call reads the clock twice and adds to its phase under a lock.
///
/// A phase's time is its *own* time: a phase measured inside another (a texture decoded while the
/// scene content is built) is subtracted from the outer one, per thread. Phases on different
/// threads add up, so the phases of a load that compiles on several queues can sum to more than
/// the wall time it took.
///
/// Global by necessity (rule 3): the phases run inside the loader and the renderers, on their own
/// queues, where a test can't hand a recorder in. `lock` owns `totals`.
enum OWEPhaseTiming {
    enum Phase: String, CaseIterable, Sendable {
        case sceneLoad = "scene load"
        case shaderTranslate = "shader translate"
        case pipeline = "pipeline"
        case texture = "texture"
        case particlesModels = "particles/models"
        case render = "render"
        case gpuWait = "GPU wait"
        case scripts = "scripts"
        case readback = "readback"
        case compare = "compare"
    }

    struct Total: Equatable, Sendable {
        var seconds: Double = 0
        var calls = 0
        /// Frames drawn, for `render`.
        var frames = 0
    }

    #if DEBUG
    private static let lock = NSLock()
    /// Written under `lock`, read without it by `measure`: a stale read only times, or skips, the
    /// one call that races with turning timing on or off.
    nonisolated(unsafe) private static var enabled = false
    nonisolated(unsafe) private static var totals: [Phase: Total] = [:] // guarded by lock
    /// Per thread: the time of the phases nested in each open phase, innermost last.
    private static let nestingKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, { Unmanaged<Nesting>.fromOpaque($0).release() })
        return key
    }()

    private final class Nesting {
        var inner: [UInt64] = []
    }
    #endif

    static var isEnabled: Bool {
        #if DEBUG
        enabled
        #else
        false
        #endif
    }

    /// Turns timing on or off and clears the totals.
    static func setEnabled(_ on: Bool) {
        #if DEBUG
        lock.withLock {
            enabled = on
            totals = [:]
        }
        #endif
    }

    /// The totals since the last call (or `setEnabled`), which start again from zero.
    static func take() -> [Phase: Total] {
        #if DEBUG
        lock.withLock {
            defer { totals = [:] }
            return totals
        }
        #else
        [:]
        #endif
    }

    /// Runs `body`, adding its own time to `phase` when timing is on. `frames` counts frames drawn.
    @inline(__always)
    static func measure<T>(_ phase: Phase, frames: Int = 0, _ body: () throws -> T) rethrows -> T {
        #if DEBUG
        guard enabled else { return try body() }
        return try timed(phase, frames: frames, body)
        #else
        return try body()
        #endif
    }

    #if DEBUG
    private static func timed<T>(_ phase: Phase, frames: Int, _ body: () throws -> T) rethrows -> T {
        let nesting = currentNesting()
        nesting.inner.append(0)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer {
            let elapsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) &- start
            let inner = nesting.inner.removeLast()
            if !nesting.inner.isEmpty { nesting.inner[nesting.inner.count - 1] &+= elapsed }
            let own = Double(elapsed &- min(inner, elapsed)) / 1e9
            lock.withLock {
                var total = totals[phase, default: Total()]
                total.seconds += own
                total.calls += 1
                total.frames += frames
                totals[phase] = total
            }
        }
        return try body()
    }

    private static func currentNesting() -> Nesting {
        if let raw = pthread_getspecific(nestingKey) {
            return Unmanaged<Nesting>.fromOpaque(raw).takeUnretainedValue()
        }
        let nesting = Nesting()
        pthread_setspecific(nestingKey, Unmanaged.passRetained(nesting).toOpaque())
        return nesting
    }
    #endif
}
