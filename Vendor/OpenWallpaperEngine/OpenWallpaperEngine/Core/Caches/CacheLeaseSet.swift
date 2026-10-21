import Foundation

/// The leases of one wallpaper instance, replaced as a whole when it shows another wallpaper.
/// Thread-safe: `lock` owns `scope` and `leases`.
final class CacheLeaseSet: @unchecked Sendable {
    private let registry: CacheLeases
    private let lock = NSLock()
    private var scope: URL? // guarded by lock
    private var leases: [String: CacheLease] = [:] // guarded by lock

    init(registry: CacheLeases = .current) {
        self.registry = registry
    }

    /// Holds `url` for the wallpaper in `scope`; a new scope releases the old one's leases first.
    func hold(_ url: URL, scope: URL) {
        let key = CacheLeases.key(url)
        var dropped: [CacheLease] = []
        lock.withLock {
            if self.scope != scope {
                dropped = Array(leases.values)
                leases = [:]
                self.scope = scope
            }
            if leases[key] == nil { leases[key] = registry.lease(url) }
        }
        dropped.forEach { $0.release() }
    }

    func releaseAll() {
        let dropped: [CacheLease] = lock.withLock {
            defer { leases = [:]; scope = nil }
            return Array(leases.values)
        }
        dropped.forEach { $0.release() }
    }
}
