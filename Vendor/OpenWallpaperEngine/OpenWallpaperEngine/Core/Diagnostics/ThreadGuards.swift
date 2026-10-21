import Foundation

/// Checks that heavy work stays off the main thread and the render thread, and that per-frame
/// work stays on the render thread. A check is a thread test; it never traps, in any build.
///
/// The render thread is whichever thread is inside `ThreadGuards.renderFrame { … }`: a scene
/// instance's `SceneRenderThread` runs its whole run loop inside it, and every frame entry wraps
/// itself in it too, so a renderer drawn by its view's own timer (tests, prewarm) still counts
/// the main thread as the render thread while it draws.
///
/// Every violation is recorded in `ThreadGuards.store` (thread, kind, what, call site, trimmed
/// call stack, time). What happens next depends on the build:
/// - **Tests:** the test bundle's observer fails the test that caused it, one issue per violation.
///   A test that expects violations collects them with `ThreadGuards.capture`, which keeps them
///   from failing it.
/// - **Dev builds** (DEBUG, or no release update key): also logged at error level, and counted
///   by `ThreadGuardMonitor`, which shows an indicator and lists them in Settings › Diagnostics.
/// - **Release:** only recorded.
enum ThreadGuards {
    struct Violation: Equatable, Sendable {
        enum Kind: String, Sendable {
            case onMainThread = "on the main thread"
            case onRenderThread = "on the render thread"
            case offRenderThread = "off the render thread"
        }
        let kind: Kind
        let what: String
        let file: String
        let line: UInt
        /// The thread it ran on: "main", the thread's name, or its queue's label.
        let thread: String
        /// The caller's frames, without the guard's own.
        let stack: [String]
        let timestamp: Date

        /// "TEXParser.decode ran on the main thread".
        var summary: String { "\(what) ran \(kind.rawValue)" }

        /// The summary, call site and thread, then the top `frames` stack frames, one per line.
        func message(frames: Int = 8) -> String {
            var lines = ["\(summary) (\(file):\(line), thread \(thread))"]
            lines += stack.prefix(frames).map { "    \($0)" }
            return lines.joined(separator: "\n")
        }
    }

    /// One call site and kind: its first violation and how often it happened.
    struct Site: Equatable, Sendable, Identifiable {
        let first: Violation
        var count: Int
        var last: Date
        var id: String { "\(first.kind.rawValue)|\(first.file):\(first.line)" }
    }

    /// Collects violations while a test expects them; they don't reach the test observer.
    final class Capture: @unchecked Sendable {
        fileprivate var list: [Violation] = []
        /// Guarded by `Store.lock`.
        var violations: [Violation] { store.lock.withLock { list } }
    }

    /// Every violation so far. One lock owns every field.
    final class Store: @unchecked Sendable {
        fileprivate let lock = NSLock()
        private var sitesByID: [String: Site] = [:]
        private var order: [String] = []
        private var pending: [Violation] = []
        private var collectsPending = false
        private var captures: [ObjectIdentifier: Capture] = [:]

        /// The call sites that violated, in order of their first violation.
        var sites: [Site] { lock.withLock { order.compactMap { sitesByID[$0] } } }
        var total: Int { lock.withLock { sitesByID.values.reduce(0) { $0 + $1.count } } }

        /// Returns true for the first violation at its call site.
        @discardableResult
        func record(_ violation: Violation) -> Bool {
            lock.lock()
            let id = "\(violation.kind.rawValue)|\(violation.file):\(violation.line)"
            let first = sitesByID[id] == nil
            if first {
                sitesByID[id] = Site(first: violation, count: 1, last: violation.timestamp)
                order.append(id)
            } else {
                sitesByID[id]?.count += 1
                sitesByID[id]?.last = violation.timestamp
            }
            if !captures.isEmpty {
                for capture in captures.values { capture.list.append(violation) }
            } else if collectsPending {
                pending.append(violation)
            }
            lock.unlock()
            return first
        }

        /// Counts a repeat at a call site already on record when nothing collects the violations
        /// themselves (no capture, no per-test list), so the stack isn't symbolicated again on
        /// every frame. False when the violation is to be recorded in full.
        func countRepeat(id: String, at date: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard captures.isEmpty, !collectsPending, sitesByID[id] != nil else { return false }
            sitesByID[id]?.count += 1
            sitesByID[id]?.last = date
            return true
        }

        /// Turns on the per-test list `takePending` drains (the test observer does).
        func collectPending() { lock.withLock { collectsPending = true } }

        /// The violations since the last call that no capture took.
        func takePending() -> [Violation] {
            lock.withLock { defer { pending.removeAll() }; return pending }
        }

        func clear() {
            lock.withLock { sitesByID.removeAll(); order.removeAll(); pending.removeAll() }
        }

        fileprivate func begin(_ capture: Capture) { lock.withLock { captures[ObjectIdentifier(capture)] = capture } }
        fileprivate func end(_ capture: Capture) { lock.withLock { _ = captures.removeValue(forKey: ObjectIdentifier(capture)) } }
    }

    static let store = Store()

    /// DEBUG, or a build without the release update key (`DockBadge.dev`).
    static let isDevBuild: Bool = {
        #if DEBUG
        return true
        #else
        return !AppUpdateConfiguration.main.isConfigured
        #endif
    }()

    /// Runs `body`, returning the violations it caused on any thread, which then don't fail the
    /// running test. Asynchronous work must finish inside `body`.
    static func capture<T>(_ body: () throws -> T) rethrows -> (T, [Violation]) {
        let capture = Capture()
        store.begin(capture)
        defer { store.end(capture) }
        let result = try body()
        return (result, capture.violations)
    }

    private static let renderKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// Marks the calling thread as the render thread for the duration of `body`. Nests.
    @inline(__always)
    static func renderFrame<T>(_ body: () throws -> T) rethrows -> T {
        let previous = pthread_getspecific(renderKey)
        pthread_setspecific(renderKey, UnsafeRawPointer(bitPattern: 1))
        defer { pthread_setspecific(renderKey, previous) }
        return try body()
    }

    static var isRenderThread: Bool { pthread_getspecific(renderKey) != nil }

    @inline(__always)
    static func assertNotMainThread(_ what: @autoclosure () -> String,
                                    file: StaticString = #fileID, line: UInt = #line) {
        if Thread.isMainThread { report(.onMainThread, what(), file, line) }
    }

    @inline(__always)
    static func assertNotRenderThread(_ what: @autoclosure () -> String,
                                      file: StaticString = #fileID, line: UInt = #line) {
        if isRenderThread { report(.onRenderThread, what(), file, line) }
    }

    /// Heavy work: neither the main thread nor the render thread.
    @inline(__always)
    static func assertBackground(_ what: @autoclosure () -> String,
                                 file: StaticString = #fileID, line: UInt = #line) {
        if Thread.isMainThread { report(.onMainThread, what(), file, line) }
        else if isRenderThread { report(.onRenderThread, what(), file, line) }
    }

    /// Per-frame work that must not run anywhere else.
    @inline(__always)
    static func assertRenderThread(_ what: @autoclosure () -> String,
                                   file: StaticString = #fileID, line: UInt = #line) {
        if !isRenderThread { report(.offRenderThread, what(), file, line) }
    }

    /// Frames kept per violation.
    static let stackDepth = 12
    /// This enum in a mangled frame symbol (`ThreadGuardsTests` doesn't match).
    static let ownSymbol = "19OpenWallpaperEngine12ThreadGuardsO"

    @inline(never)
    private static func report(_ kind: Violation.Kind, _ what: String, _ file: StaticString, _ line: UInt) {
        if store.countRepeat(id: "\(kind.rawValue)|\(file):\(line)", at: Date()) { return }
        // Drop this frame and the check that called it (the mangled `ThreadGuards` enum).
        let stack = Thread.callStackSymbols.dropFirst().drop { $0.contains(ownSymbol) }
        let violation = Violation(kind: kind, what: what, file: "\(file)", line: line, thread: currentThreadName(),
                                  stack: Array(stack.prefix(stackDepth)), timestamp: Date())
        let first = store.record(violation)
        guard isDevBuild else { return }
        if first { OWELog.error(.perf, "Thread guard: " + violation.message(frames: stackDepth)) }
        ThreadGuardMonitor.violationRecorded()
    }

    static func currentThreadName() -> String {
        if Thread.isMainThread { return "main" }
        if let name = Thread.current.name, !name.isEmpty { return name }
        if let label = String(validatingCString: __dispatch_queue_get_label(nil)), !label.isEmpty { return label }
        return "\(pthread_mach_thread_np(pthread_self()))"
    }
}
