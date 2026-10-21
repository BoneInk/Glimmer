import CoreGraphics
import QuartzCore

extension Notification.Name {
    /// A running scene saved a loading snapshot (`SceneLoadingSnapshotCapture`); the object is the
    /// wallpaper's folder URL. Posted on the main thread.
    static let sceneLoadingSnapshotSaved = Notification.Name("OpenWallpaperEngine.sceneLoadingSnapshotSaved")
}

/// A running scene's side of its loading snapshots (`SceneLoadingSnapshotStore`): once the scene
/// has shown its content on a display for `delay`, the render loop (`SceneRenderLoop`) copies a
/// frame at that display's pixel size and this saves it, encoded off the render thread. Each
/// display size is captured once per session (`SceneLoadingSnapshotSession`), and again after the
/// user's properties change. Each saved snapshot is passed to `onSaved` (by default `didSave`:
/// `sceneLoadingSnapshotSaved`, which the views and the desktop pictures follow). Thread-safe: `lock` owns `armedAt`.
final class SceneLoadingSnapshotCapture: @unchecked Sendable {
    static let delay: CFTimeInterval = 4

    let wallpaperDirectory: URL
    let wallpaperKey: String
    private let session: SceneLoadingSnapshotSession
    private let onSaved: @Sendable (URL) -> Void
    private let lock = NSLock()
    /// When the picture last changed meaning (start, or a property change).
    private var armedAt: CFTimeInterval
    private static let queue = DispatchQueue(label: "OWE.LoadingSnapshots", qos: .utility)

    init(wallpaperDirectory: URL, session: SceneLoadingSnapshotSession, now: CFTimeInterval = CACurrentMediaTime(),
         onSaved: @escaping @Sendable (URL) -> Void = { SceneLoadingSnapshotCapture.didSave(wallpaperDirectory: $0) }) {
        self.wallpaperDirectory = wallpaperDirectory
        wallpaperKey = SceneLoadingSnapshotStore.wallpaperKey(for: wallpaperDirectory)
        self.session = session
        self.onSaved = onSaved
        armedAt = now
    }

    /// A snapshot of the wallpaper at `directory` was saved: posts `sceneLoadingSnapshotSaved` on
    /// the main thread for the views showing it and the desktop pictures
    /// (`DesktopPictureController`).
    static func didSave(wallpaperDirectory directory: URL) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sceneLoadingSnapshotSaved, object: directory)
        }
    }

    /// The user's properties changed: capture again once the new look has shown for `delay`.
    func rearm(now: CFTimeInterval = CACurrentMediaTime()) {
        lock.withLock { armedAt = now }
        session.forget(wallpaperKey)
    }

    /// Whether to capture now at `pixelSize`: the content has shown since `contentSince` for
    /// `delay` since it last changed meaning, and this size wasn't captured yet. Claims the size.
    func claim(pixelSize: SIMD2<Int>, contentSince: CFTimeInterval, now: CFTimeInterval) -> Bool {
        let armedAt = lock.withLock { self.armedAt }
        guard now - max(armedAt, contentSince) >= Self.delay else { return false }
        return session.claim(wallpaperKey, pixelSize: pixelSize)
    }

    /// Encodes and stores `image` on a utility queue, then calls `onSaved` there.
    func save(_ image: CGImage?) {
        guard let image else { return }
        let store = session.store
        let directory = wallpaperDirectory
        let onSaved = onSaved
        Self.queue.async {
            guard let contentKey = SceneLoadingSnapshotStore.contentKey(for: directory) else { return }
            do {
                let url = try store.write(image, forWallpaperAt: directory, contentKey: contentKey)
                OWELog.debug(.scene, "Loading snapshot saved: \(url.lastPathComponent)")
                onSaved(directory)
            } catch {
                OWELog.error(.scene, "Loading snapshot of \(directory.lastPathComponent) not saved: \(error)")
            }
        }
    }
}
