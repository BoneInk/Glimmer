import Foundation

/// Which loading snapshots running scenes refreshed this launch (`SceneLoadingSnapshotCapture`):
/// a wallpaper refreshes its snapshot for a display size once per session, again only after its
/// user properties change. Owned by the wallpapers' model (`WallpaperViewModel`); thread-safe.
final class SceneLoadingSnapshotSession: @unchecked Sendable { // `lock` owns `claimed`.
    let store: SceneLoadingSnapshotStore
    private let lock = NSLock()
    private var claimed = Set<String>()

    init(store: SceneLoadingSnapshotStore) {
        self.store = store
    }

    /// True the first time this session asks for `wallpaperKey` at `pixelSize` (since `forget`).
    func claim(_ wallpaperKey: String, pixelSize: SIMD2<Int>) -> Bool {
        let key = "\(wallpaperKey)/\(pixelSize.x)x\(pixelSize.y)"
        return lock.withLock { claimed.insert(key).inserted }
    }

    /// The wallpaper changed (its user properties): its displays may refresh their snapshots again.
    func forget(_ wallpaperKey: String) {
        lock.withLock { claimed = claimed.filter { !$0.hasPrefix(wallpaperKey + "/") } }
    }
}
