import Foundation

/// The binding revision of each object of a running scene: bumped when a user property one of the
/// object's bindings reads changes (`UserPropertyBindingTable.changes(for:)`), and for every object
/// when a scene-wide binding changes. Every cache that bakes a bound value keys on its owner's
/// revision, so none is reused across a change. Revisions only grow, also across content rebuilds,
/// so a value cached before can never match again. Render thread only.
struct SceneBindingRevisions {
    private var scene: UInt64 = 0
    private var objects: [String: UInt64] = [:]
    /// Cached results that were reused although their owner's revision had moved on (`noteReuse`):
    /// always 0 unless a cache forgot to key on the revision. Tests assert it.
    private(set) var staleReuses = 0

    /// Object `key`'s revision (`SceneMetalLayer.id`, a particle system's `objectID`).
    func revision(of key: String) -> UInt64 {
        (scene << 32) &+ (objects[key] ?? 0)
    }

    /// Marks `owners` changed: an object's own revision, or with `.scene` every object's.
    mutating func bump(_ owners: Set<UserPropertyBindingOwner>) {
        for owner in owners {
            if let key = owner.objectKey {
                objects[key, default: 0] &+= 1
            } else {
                scene &+= 1
            }
        }
    }

    /// A cache of object `key` is reusing what it computed at `revision`: counted and logged when
    /// that isn't the object's revision now.
    mutating func noteReuse(of key: String, cachedAt revision: UInt64) {
        guard revision != self.revision(of: key) else { return }
        staleReuses += 1
        OWELog.error(.scene, "A cache of object \(key) reused a value from binding revision \(revision), now \(self.revision(of: key))")
    }
}

/// One value cached per binding revision (`SceneBindingRevisions`): computed again only when the
/// owner's revision moved.
struct SceneBindingCache<Value> {
    private(set) var revision: UInt64?
    private var value: Value?

    init() {}

    /// The value at `revision`, from the cache when it was computed at that revision.
    mutating func value(at revision: UInt64, _ compute: () -> Value) -> Value {
        if self.revision == revision, let value { return value }
        let computed = compute()
        self.revision = revision
        value = computed
        return computed
    }
}
