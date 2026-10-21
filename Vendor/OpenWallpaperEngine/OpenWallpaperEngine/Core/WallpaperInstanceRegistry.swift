import Foundation

/// The running instances of wallpapers, one per wallpaper however many displays show it
/// (docs/architecture.md "Wallpaper instances").
///
/// Each display holds the instance it shows (`WallpaperInstanceLease`); the instance lives while
/// any display holds it. The last release doesn't tear it down at once but on the next turn of
/// the main queue: a display that is rebuilt (screens changed, a window recreated) takes hold of
/// it again first, so the wallpaper keeps running instead of loading again.
@MainActor
final class WallpaperInstanceRegistry<Key: Hashable, Instance: AnyObject> {
    private struct Entry {
        let instance: Instance
        var holders: Set<ObjectIdentifier>
    }

    private var entries: [Key: Entry] = [:]
    private let teardown: (Instance) -> Void
    private let deferTeardown: (@escaping @MainActor () -> Void) -> Void

    /// `teardown` stops an instance nothing holds any more; `deferTeardown` runs the check for
    /// that later (the next main-queue turn; tests pass one that runs it at once).
    init(teardown: @escaping (Instance) -> Void,
         deferTeardown: @escaping (@escaping @MainActor () -> Void) -> Void = { work in
             DispatchQueue.main.async { MainActor.assumeIsolated(work) }
         }) {
        self.teardown = teardown
        self.deferTeardown = deferTeardown
    }

    /// Instances still here when the registry goes (its owner went before a deferred teardown
    /// ran) stop now: nothing could release them any more, and a running instance keeps its
    /// render thread, display links and sound.
    deinit {
        let instances = entries.values.map(\.instance)
        guard !instances.isEmpty else { return }
        let teardown = teardown
        if Thread.isMainThread {
            MainActor.assumeIsolated { for instance in instances { teardown(instance) } }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { for instance in instances { teardown(instance) } } }
        }
    }

    /// The instance for `key`, made by `make` when none runs, now held by `holder` too.
    func acquire(_ key: Key, holder: AnyObject, make: () -> Instance) -> Instance {
        let id = ObjectIdentifier(holder)
        if var entry = entries[key] {
            entry.holders.insert(id)
            entries[key] = entry
            return entry.instance
        }
        let instance = make()
        entries[key] = Entry(instance: instance, holders: [id])
        return instance
    }

    /// `holder` no longer shows `key`'s instance; it stops once nothing holds it.
    func release(_ key: Key, holder: AnyObject) {
        let id = ObjectIdentifier(holder)
        guard var entry = entries[key], entry.holders.remove(id) != nil else { return }
        entries[key] = entry
        guard entry.holders.isEmpty else { return }
        deferTeardown { [weak self] in self?.tearDownIfUnheld(key) }
    }

    private func tearDownIfUnheld(_ key: Key) {
        guard let entry = entries[key], entry.holders.isEmpty else { return }
        entries[key] = nil
        teardown(entry.instance)
    }

    /// The running instance for `key`, if any.
    func instance(for key: Key) -> Instance? { entries[key]?.instance }

    /// How many displays hold `key`'s instance.
    func holderCount(for key: Key) -> Int { entries[key]?.holders.count ?? 0 }

    /// The running instances (held or waiting for their teardown).
    var instances: [Instance] { entries.values.map(\.instance) }
}
