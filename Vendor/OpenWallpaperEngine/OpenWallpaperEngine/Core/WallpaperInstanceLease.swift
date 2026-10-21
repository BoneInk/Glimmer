import Foundation

/// One display's hold on a shared wallpaper instance (`WallpaperInstanceRegistry`). The display
/// keeps the lease while it shows the instance; releasing it, or dropping the lease, lets the
/// instance stop once no display holds it.
@MainActor
final class WallpaperInstanceLease<Key: Hashable, Instance: AnyObject>: ObservableObject {
    /// Names this lease in the registry. Kept alive until the release has run, so its identity
    /// can't be reused by another lease in between.
    private final class Holder: Sendable {}

    let key: Key
    let instance: Instance
    private let holder = Holder()
    private weak var registry: WallpaperInstanceRegistry<Key, Instance>?

    init(_ registry: WallpaperInstanceRegistry<Key, Instance>, key: Key, make: () -> Instance) {
        self.key = key
        self.registry = registry
        instance = registry.acquire(key, holder: holder, make: make)
    }

    /// Lets go of the instance; later calls do nothing.
    func release() {
        registry?.release(key, holder: holder)
        registry = nil
    }

    deinit {
        // SwiftUI drops a view's state on the main thread, where the registry lives; anywhere
        // else the release waits for it.
        guard let registry else { return }
        let key = key
        let holder = holder
        if Thread.isMainThread {
            MainActor.assumeIsolated { registry.release(key, holder: holder) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { registry.release(key, holder: holder) } }
        }
    }
}
