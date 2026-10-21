import Foundation

/// Coalesces capture restarts and backs off when they keep failing.
///
/// Sleep, display changes and stream errors tend to arrive in bursts; each one used to start a
/// separate restart. Requests are debounced, at most one start is in flight, a failed start is
/// retried with exponential backoff, and after `maxFailures` consecutive failures the scheduler
/// gives up until `reset()`.
@MainActor
final class CaptureRestartScheduler {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    let debounce: TimeInterval
    let baseBackoff: TimeInterval
    let maxFailures: Int
    private let schedule: Schedule
    /// Starts capture; must eventually call `finished(success:)` exactly once.
    private let start: @MainActor () -> Void
    private var token = 0
    private var pendingRequest = false
    private(set) var isInFlight = false
    private(set) var consecutiveFailures = 0
    private(set) var hasGivenUp = false

    init(debounce: TimeInterval = 1.5, baseBackoff: TimeInterval = 2, maxFailures: Int = 4,
         schedule: @escaping Schedule, start: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.baseBackoff = baseBackoff
        self.maxFailures = maxFailures
        self.schedule = schedule
        self.start = start
    }

    func requestRestart() {
        guard !hasGivenUp else { return }
        fire(after: debounce)
    }

    /// Returns true exactly once, on the failure that makes the scheduler give up, so the caller
    /// logs that once instead of on every attempt.
    @discardableResult
    func finished(success: Bool) -> Bool {
        isInFlight = false
        if success {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            if consecutiveFailures >= maxFailures {
                hasGivenUp = true
                pendingRequest = false
                token &+= 1
                return true
            }
            fire(after: baseBackoff * pow(2, Double(consecutiveFailures - 1)))
        }
        if pendingRequest {
            pendingRequest = false
            requestRestart()
        }
        return false
    }

    /// Clears the failure history, e.g. after the permission was newly granted.
    func reset() {
        token &+= 1
        consecutiveFailures = 0
        hasGivenUp = false
        pendingRequest = false
    }

    private func fire(after delay: TimeInterval) {
        token &+= 1
        let expected = token
        schedule(delay) { [weak self] in
            guard let self, expected == self.token else { return }
            guard !self.isInFlight else {
                self.pendingRequest = true
                return
            }
            self.isInFlight = true
            self.start()
        }
    }
}
