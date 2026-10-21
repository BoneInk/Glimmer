import Foundation
import Observation

/// A snapshot from this detail's own preview, not another window or desktop host.
struct ScenePreviewControlsState: Equatable {
    enum Phase: String { case unavailable, idle, loading, ready, paused, failed, disposed }
    var phase: Phase = .unavailable
    var hasError = false
    var canTogglePause: Bool { !hasError && (phase == .ready || phase == .paused) }
}

@MainActor @Observable
final class ScenePreviewControlsRelay {
    private(set) var itemID: UUID?
    private(set) var controls = ScenePreviewControlsState()
    func activate(itemID: UUID) {
        guard self.itemID != itemID else { return }
        self.itemID = itemID
        controls = .init()
    }
    func accept(itemID: UUID, state: ScenePreviewControlsState) {
        guard self.itemID == itemID else { return }
        controls = state
    }
}

/// Both display actions share one real asynchronous operation and cancellation boundary.
@MainActor @Observable
final class DetailWallpaperApplyState {
    enum Target: Equatable { case display(String), allDisplays }
    private(set) var target: Target?
    private(set) var error: String?
    private(set) var succeeded = false
    private var itemID: UUID?
    private var generation = 0
    private var task: Task<Void, Never>?
    var isPreparing: Bool { target != nil }

    @discardableResult
    func begin(itemID: UUID, target: Target, operation: @escaping @MainActor () async -> String?) -> Bool {
        guard !isPreparing else { return false }
        generation += 1
        let ticket = generation
        self.itemID = itemID
        self.target = target
        error = nil
        succeeded = false
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let failure = await operation()
            guard !Task.isCancelled, let self, self.generation == ticket, self.itemID == itemID else { return }
            self.task = nil
            self.target = nil
            self.error = failure
            self.succeeded = failure == nil
        }
        return true
    }

    /// Cancel the awaited backend task itself; a noncooperative completion still cannot publish.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        target = nil
        itemID = nil
        error = nil
        succeeded = false
    }
}
