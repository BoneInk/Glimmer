import Foundation

/// `CachesSection`'s state: the caches' size, measured off the main thread, and Clear Caches.
@MainActor
final class CachesSectionModel: ObservableObject {
    /// Nil while it is measured.
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var isClearing = false

    private let measure: @Sendable () async -> Int64
    private let clearAll: @Sendable () async -> CacheMaintenance.ClearResult

    init(measure: @escaping @Sendable () async -> Int64 = { await CacheMaintenance.totalSize() },
         clearAll: @escaping @Sendable () async -> CacheMaintenance.ClearResult = { await CacheMaintenance.clearAll() }) {
        self.measure = measure
        self.clearAll = clearAll
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        totalBytes = await measure()
    }

    func clear() {
        Task { await clearNow() }
    }

    func clearNow() async {
        guard !isClearing else { return }
        isClearing = true
        totalBytes = nil
        _ = await clearAll()
        isClearing = false
        await refreshNow()
    }
}
