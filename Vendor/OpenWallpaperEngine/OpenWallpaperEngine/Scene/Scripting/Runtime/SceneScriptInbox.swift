import Foundation

/// The one thread-safe entry into a `SceneScriptRuntime`: property changes, resizes, media and
/// cursor events are posted from any thread and drained by the runtime at the start of a frame.
/// `lock` guards `events`.
///
/// While frames run, every event is delivered as posted. When frames stop (a paused, occluded or
/// sleeping wallpaper) and `capacity` undrained events pile up, the inbox coalesces by each
/// event's `Coalescing` instead of dropping the oldest (SF4, SF15): state events keep their newest
/// value, change sets are merged, so a property change or a track change made during the pause
/// still reaches scripts on resume. Only `.keep` events are ever dropped, oldest first.
final class SceneScriptInbox: @unchecked Sendable {
    static let capacity = 1024

    private let lock = NSLock()
    private var events: [SceneScriptEvent] = []

    func post(_ event: SceneScriptEvent) {
        lock.lock()
        events.append(event)
        if events.count > Self.capacity { events = Self.compacted(events) }
        lock.unlock()
    }

    func drain() -> [SceneScriptEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard !events.isEmpty else { return [] }
        let drained = events
        events.removeAll(keepingCapacity: true)
        return drained
    }

    /// `events` with every `.latest` kind (per target) reduced to its newest event and every
    /// `.merge` kind to one event at its newest position; then, while still over capacity, the
    /// oldest `.keep` events dropped.
    static func compacted(_ events: [SceneScriptEvent]) -> [SceneScriptEvent] {
        struct Key: Hashable {
            var kind: SceneScriptEvent.Kind
            var target: Int?
        }
        var newest: [Key: Int] = [:]
        var merged: [SceneScriptEvent.Kind: [String: Any]] = [:]
        for (index, event) in events.enumerated() {
            switch event.coalescing {
            case .latest:
                newest[Key(kind: event.kind, target: event.target)] = index
            case .merge:
                newest[Key(kind: event.kind, target: nil)] = index
                if let changes = event.payload as? [String: Any] {
                    merged[event.kind, default: [:]].merge(changes) { _, new in new }
                }
            case .keep:
                break
            }
        }
        var result: [SceneScriptEvent] = []
        result.reserveCapacity(events.count)
        for (index, event) in events.enumerated() {
            switch event.coalescing {
            case .keep:
                result.append(event)
            case .latest:
                if newest[Key(kind: event.kind, target: event.target)] == index { result.append(event) }
            case .merge:
                guard newest[Key(kind: event.kind, target: nil)] == index else { continue }
                var event = event
                if let changes = merged[event.kind] { event.payload = changes }
                result.append(event)
            }
        }
        var excess = result.count - capacity
        if excess > 0 {
            result.removeAll { event in
                guard excess > 0, event.coalescing == .keep else { return false }
                excess -= 1
                return true
            }
        }
        return result
    }
}
