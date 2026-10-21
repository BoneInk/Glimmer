import Foundation

/// Runs work on a concurrent queue at most `limit` items at a time, in submission order. A plain
/// concurrent queue starts a thread per blocked item: a scene with hundreds of cold pipelines
/// would start hundreds of Metal compiles at once.
///
/// Thread-safe: `lock` owns `waiting` and `running`.
final class BoundedWorkQueue {
    let limit: Int
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var waiting: [() -> Void] = []
    private var waitingStart = 0
    private var running = 0

    init(label: String, qos: DispatchQoS, limit: Int) {
        self.limit = max(1, limit)
        queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
    }

    /// Performance cores (`hw.perflevel0.physicalcpu`), or every active core on a Mac without
    /// performance levels.
    static var performanceCoreCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    func async(_ work: @escaping () -> Void) {
        lock.withLock { waiting.append(work) }
        drain()
    }

    private func drain() {
        while let work = claim() {
            queue.async { [self] in
                work()
                lock.withLock { running -= 1 }
                drain()
            }
        }
    }

    /// The next item, counted as running, while under the limit.
    private func claim() -> (() -> Void)? {
        lock.withLock {
            guard running < limit, waitingStart < waiting.count else { return nil }
            let work = waiting[waitingStart]
            waitingStart += 1
            if waitingStart == waiting.count {
                waiting.removeAll(keepingCapacity: true)
                waitingStart = 0
            }
            running += 1
            return work
        }
    }
}
