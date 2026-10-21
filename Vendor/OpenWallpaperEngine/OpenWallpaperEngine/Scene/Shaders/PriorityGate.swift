import Foundation

/// Lets one caller through at a time; waiting callers go in order of priority (higher first),
/// then arrival. Thread-safe: `condition` owns every field.
final class PriorityGate {
    private let condition = NSCondition()
    private var busy = false
    private var waiting: [(priority: Int, ticket: UInt64)] = []
    private var nextTicket: UInt64 = 0

    func enter(priority: Int) {
        condition.lock()
        defer { condition.unlock() }
        nextTicket &+= 1
        let ticket = nextTicket
        waiting.append((priority, ticket))
        while busy || !isNext(ticket) { condition.wait() }
        waiting.removeAll { $0.ticket == ticket }
        busy = true
    }

    func leave() {
        condition.lock()
        busy = false
        condition.broadcast()
        condition.unlock()
    }

    private func isNext(_ ticket: UInt64) -> Bool {
        let first = waiting.min { $0.priority != $1.priority ? $0.priority > $1.priority : $0.ticket < $1.ticket }
        return first?.ticket == ticket
    }
}
