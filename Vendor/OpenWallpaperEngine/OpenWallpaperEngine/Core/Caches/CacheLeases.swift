import Foundation

/// The cache files and folders this process uses right now: a texture blob a scene loaded, the
/// video a player has open, the loading snapshots of a scene on screen, the pipeline archive in
/// use. `CacheSweeper` never deletes a leased path, a file inside a leased folder, or a folder
/// holding a leased file.
///
/// A `CacheLease` holds its path until it is released or goes away. Global by necessity (rule 3):
/// the files are a process-wide resource that independently created players, scenes and renderers
/// use, and the sweeper runs apart from all of them. `lock` owns `counts`.
final class CacheLeases: @unchecked Sendable {
    static let current = CacheLeases()

    private let lock = NSLock()
    private var counts: [String: Int] = [:] // guarded by lock

    init() {}

    /// Leases `url` until the returned lease is released or deallocated.
    func lease(_ url: URL) -> CacheLease {
        let path = Self.key(url)
        lock.withLock { counts[path, default: 0] += 1 }
        return CacheLease(path: path, owner: self)
    }

    fileprivate func release(_ path: String) {
        lock.withLock {
            guard let count = counts[path] else { return }
            counts[path] = count > 1 ? count - 1 : nil
        }
    }

    /// The leased paths now.
    var paths: Set<String> { lock.withLock { Set(counts.keys) } }

    /// Whether `url` is leased, inside a leased folder, or a folder holding a leased path.
    func isLeased(_ url: URL) -> Bool {
        Self.isCovered(Self.key(url), by: paths)
    }

    static func isCovered(_ path: String, by leased: Set<String>) -> Bool {
        if leased.contains(path) { return true }
        let folder = path.hasSuffix("/") ? path : path + "/"
        return leased.contains { $0.hasPrefix(folder) || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// One use of a cache path (`CacheLeases`).
final class CacheLease: @unchecked Sendable { // Immutable after init; `release` is idempotent under the owner's lock.
    let path: String
    private weak var owner: CacheLeases?
    private let released = NSLock()
    private var isReleased = false // guarded by released

    fileprivate init(path: String, owner: CacheLeases) {
        self.path = path
        self.owner = owner
    }

    deinit { release() }

    func release() {
        let first = released.withLock { () -> Bool in
            defer { isReleased = true }
            return !isReleased
        }
        if first { owner?.release(path) }
    }
}
