import Metal

/// State of removed script clones (effect targets, material uniforms) that frames still on the
/// GPU may use. Each batch of state ids waits for the command buffer that last drew it; once that
/// has finished, ids that aren't live again are released. A clone re-created under the same id in
/// the meantime keeps its new state. Render thread only.
struct SceneDeferredReleases {
    private var pending: [(ids: [String], isFinished: () -> Bool)] = []

    var count: Int { pending.count }

    /// Queues `ids` until `buffer` completes (or fails); with no buffer, until the next drain.
    mutating func enqueue(_ ids: [String], after buffer: MTLCommandBuffer?) {
        enqueue(ids) { buffer.map { $0.status == .completed || $0.status == .error } ?? true }
    }

    mutating func enqueue(_ ids: [String], isFinished: @escaping () -> Bool) {
        guard !ids.isEmpty else { return }
        pending.append((ids, isFinished))
    }

    /// Releases every finished batch's ids that are not in `live`.
    mutating func drain(live: Set<String>, release: (String) -> Void) {
        pending.removeAll { batch in
            guard batch.isFinished() else { return false }
            for id in batch.ids where !live.contains(id) { release(id) }
            return true
        }
    }

    mutating func removeAll() { pending.removeAll() }
}
