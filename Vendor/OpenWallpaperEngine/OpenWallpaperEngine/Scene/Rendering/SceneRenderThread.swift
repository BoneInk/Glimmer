import Foundation

/// A thread with its own run loop that one scene instance renders on: its displays' links tick
/// there, and every access to the instance's renderer is a block sent to it (`perform`). The main
/// thread only handles UI, windows and displays, so a stall there doesn't delay a frame.
///
/// The whole run loop runs inside `ThreadGuards.renderFrame`, so the thread guards see this thread
/// as the render thread for anything it runs.
final class SceneRenderThread: @unchecked Sendable {
    /// Written once by the thread before `init` returns; read-only afterwards.
    private final class State: @unchecked Sendable {
        var runLoop: RunLoop?
        var stopped = false
        let ready = DispatchSemaphore(value: 0)
        /// Signalled once the run loop has returned for good.
        let exited = DispatchSemaphore(value: 0)
    }

    /// Holds a `sync` body while the render thread runs it; emptied before the caller resumes, so
    /// the block the run loop still holds keeps no reference to the body.
    private final class Pending: @unchecked Sendable { // `lock` owns `run`.
        private let lock = NSLock()
        var run: (() -> Void)?
        /// The body, once: whoever takes it first runs it.
        func take() -> (() -> Void)? {
            lock.withLock {
                defer { run = nil }
                return run
            }
        }
    }

    private let thread: Thread
    private let state: State
    /// The thread's run loop. Only the render thread adds sources to it (`RunLoop` isn't thread-safe).
    private let cfRunLoop: CFRunLoop

    init(name: String) {
        let state = State()
        self.state = state
        thread = Thread {
            ThreadGuards.renderFrame {
                state.runLoop = RunLoop.current
                // A port keeps the run loop running while no display link is attached.
                RunLoop.current.add(NSMachPort(), forMode: .default)
                state.ready.signal()
                while !state.stopped {
                    autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
                }
            }
            state.exited.signal()
        }
        thread.name = name
        // Settings › Process Priority (`ProcessPriority`); never below user-initiated.
        thread.qualityOfService = ProcessPriority.current.renderThreadQoS
        thread.start()
        state.ready.wait()
        cfRunLoop = state.runLoop!.getCFRunLoop()
        Self.registry.add(self)
    }

    // MARK: - Process priority

    /// Every live render thread, so a change of Process Priority reaches the running ones.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private let threads = NSHashTable<AnyObject>.weakObjects()
        func add(_ thread: SceneRenderThread) { lock.lock(); threads.add(thread); lock.unlock() }
        var all: [SceneRenderThread] {
            lock.lock(); defer { lock.unlock() }
            return threads.allObjects.compactMap { $0 as? SceneRenderThread }
        }
    }
    private static let registry = Registry()

    /// Moves every running render thread to `qos`, from the thread itself (a thread's QoS can only
    /// be changed from inside it once it runs).
    static func applyQoS(_ qos: DispatchQoS.QoSClass) {
        for thread in registry.all {
            thread.perform { _ = pthread_set_qos_class_self_np(qos.rawValue, 0) }
        }
    }

    var isCurrent: Bool { Thread.current == thread }

    /// The render thread's run loop; only use it from the render thread.
    var runLoop: RunLoop { state.runLoop! }

    /// Thread boundary: runs `block` on the render thread, after the blocks sent before it.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
    }

    /// Runs `body` on the render thread and waits for it. For tests and teardown only: the main
    /// thread must never wait on a frame in normal running.
    func sync<T>(_ body: () -> T) -> T {
        if isCurrent { return body() }
        var result: T?
        let done = DispatchSemaphore(value: 0)
        withoutActuallyEscaping(body) { body in
            // The run loop releases a block only after it returns, which can be after `done` lets
            // this thread go on: the block must not hold `body` then (`withoutActuallyEscaping`
            // traps if it is still referenced when its scope ends).
            let pending = Pending()
            pending.run = { result = body() }
            perform {
                pending.take()?()
                done.signal()
            }
            // A stopped thread never runs the block: once it has ended, nothing else touches what
            // it owned, so the body runs here rather than wait forever.
            while done.wait(timeout: .now() + 0.25) == .timedOut {
                guard thread.isFinished else { continue }
                pending.take()?()
                break
            }
        }
        return result!
    }

    /// Ends the thread once the blocks already sent have run, and waits for it to end, so nothing
    /// it drives (display links, frames) outlives its owner. From the render thread itself it only
    /// asks the run loop to stop.
    func stop() {
        let state = state
        perform {
            state.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        guard !isCurrent else { return }
        // A frame in flight waits at most for a drawable (a second); the bound only keeps a wedged
        // thread from hanging its owner.
        if state.exited.wait(timeout: .now() + 5) == .timedOut {
            OWELog.error(.scene, "\(thread.name ?? "render thread") did not stop within 5 s")
        }
    }
}
