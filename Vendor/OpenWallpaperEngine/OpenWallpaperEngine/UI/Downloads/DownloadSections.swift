import Foundation

/// The Downloads tab's groups, as Safari and the App Store list downloads: the one steamcmd is
/// running, the ones waiting for it, then the finished ones, newest first.
struct DownloadSections: Equatable {
    enum Kind: CaseIterable, Equatable {
        case inProgress, queued, failed, completed
    }

    var inProgress: [String] = []
    var queued: [String] = []
    var failed: [String] = []
    var completed: [String] = []

    /// Groups the ids `SteamCmdService` tracks. `startedAt` orders the finished ones, most recent
    /// first (ids without a start time last, by id, so the order never jumps).
    init(progress: [String: SteamCmdService.DownloadState], activeId: String?, queuedIds: [String],
         startedAt: [String: Date]) {
        if let activeId { inProgress = [activeId] }
        queued = queuedIds.filter { $0 != activeId }
        let newestFirst: (String, String) -> Bool = { left, right in
            switch (startedAt[left], startedAt[right]) {
            case let (leftDate?, rightDate?) where leftDate != rightDate: return leftDate > rightDate
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left < right
            }
        }
        for (id, state) in progress where id != activeId && !queuedIds.contains(id) {
            switch state {
            case .failed: failed.append(id)
            case .completed: completed.append(id)
            // Between leaving the queue and finishing: shown as running until the state lands.
            case .downloading: inProgress.append(id)
            }
        }
        failed.sort(by: newestFirst)
        completed.sort(by: newestFirst)
    }

    func ids(_ kind: Kind) -> [String] {
        switch kind {
        case .inProgress: return inProgress
        case .queued: return queued
        case .failed: return failed
        case .completed: return completed
        }
    }

    var isEmpty: Bool { Kind.allCases.allSatisfy { ids($0).isEmpty } }
}

/// A running download's speed and time left, from steamcmd's percentage and the item's Workshop
/// size; nil until there is enough to say (a few seconds in and some progress).
struct DownloadRateEstimate: Equatable {
    /// Bytes per second.
    let bytesPerSecond: Double
    let remaining: TimeInterval

    static let minimumElapsed: TimeInterval = 3
    static let minimumFraction = 0.01

    init?(fraction: Double?, fileSize: Int, startedAt: Date?, now: Date) {
        guard let fraction, fraction >= Self.minimumFraction, fraction < 1, fileSize > 0,
              let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= Self.minimumElapsed else { return nil }
        bytesPerSecond = Double(fileSize) * fraction / elapsed
        remaining = elapsed * (1 - fraction) / fraction
    }
}
