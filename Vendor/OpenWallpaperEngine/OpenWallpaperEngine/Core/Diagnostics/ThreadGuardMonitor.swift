import Foundation
import Combine

/// The thread guard violations a dev build shows: the indicator's count and the list in
/// Settings › Diagnostics. Refreshed from `ThreadGuards.store` on the main thread, at most once
/// per run loop turn however many violations arrive.
@MainActor
final class ThreadGuardMonitor: ObservableObject {
    static let shared = ThreadGuardMonitor()

    @Published private(set) var total = 0
    @Published private(set) var sites: [ThreadGuards.Site] = []

    /// Guarded by `refreshLock`: a refresh is queued on the main thread.
    nonisolated(unsafe) private static var refreshQueued = false
    private static let refreshLock = NSLock()

    /// Called from any thread after a violation is recorded.
    nonisolated static func violationRecorded() {
        let queue: Bool = refreshLock.withLock {
            defer { refreshQueued = true }
            return !refreshQueued
        }
        guard queue else { return }
        DispatchQueue.main.async {
            refreshLock.withLock { refreshQueued = false }
            MainActor.assumeIsolated { shared.refresh() }
        }
    }

    func refresh() {
        sites = ThreadGuards.store.sites
        total = sites.reduce(0) { $0 + $1.count }
    }

    func clear() {
        ThreadGuards.store.clear()
        refresh()
    }
}
