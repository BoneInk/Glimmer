import Foundation

/// The thread a `SceneScriptRuntime` lives on (docs/scenescript-plan.md §4.5, S19): a serial queue
/// of its own, off the main thread, so a script that hangs until the watchdog stops it (up to
/// 15 s, like WE) stalls only its own wallpaper's scripts, never the app's UI or other displays.
///
/// The owner (the renderer, WP11) creates one per wallpaper instance, creates the runtime inside
/// `sync`, and from then on reaches the runtime only through `async` (frames, loads, teardown) or
/// `sync` (reads that must not wait on a hung script should not use it). Other threads post
/// events through the runtime's `inbox`, which is thread-safe. JavaScriptCore serializes access
/// to a VM with its own lock, so a runtime may move between the queue's worker threads; what
/// matters is that only this queue runs it.
final class SceneScriptThread: @unchecked Sendable {
    let queue: DispatchQueue
    /// Marks `queue` so `isCurrent` can tell it apart from other queues (immutable).
    private let key = DispatchSpecificKey<Void>()
    /// Guards `frameInFlight`.
    private let lock = NSLock()
    private var frameInFlight = false

    init(label: String) {
        queue = DispatchQueue(label: "SceneScript \(label)", qos: .userInitiated)
        queue.setSpecific(key: key, value: ())
    }

    /// Whether the caller runs on this thread's queue.
    var isCurrent: Bool { DispatchQueue.getSpecific(key: key) != nil }

    /// Runs `body` on the queue, after everything posted before it.
    func async(_ body: @escaping () -> Void) {
        queue.async(execute: body)
    }

    /// Posts one frame's work unless the previous frame's is still queued or running; false when it
    /// was skipped. The renderer calls it every display refresh: while a script hangs, frames are
    /// dropped instead of piling up behind it, and the renderer keeps drawing with the last values.
    @discardableResult
    func asyncFrame(_ body: @escaping () -> Void) -> Bool {
        lock.lock()
        let busy = frameInFlight
        frameInFlight = true
        lock.unlock()
        guard !busy else { return false }
        queue.async { [self] in
            body()
            lock.lock()
            frameInFlight = false
            lock.unlock()
        }
        return true
    }

    /// Runs `body` on the queue and waits for it; runs it at once when already on the queue.
    func sync<Result>(_ body: () throws -> Result) rethrows -> Result {
        if isCurrent { return try body() }
        return try queue.sync(execute: body)
    }
}
