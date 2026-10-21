import Darwin
import Foundation

/// Held by the app's background pre-warm while it renders previews (`<EditorPreviews>/.prewarm.lock`,
/// an advisory `flock`): a Wallpaper Editor window that finds it held hands its browser's missing
/// previews to the pre-warm (`EditorPreviewWants`) instead of rendering them itself. The system
/// releases it when the process exits, so a crashed app never leaves it held.
public final class EditorPreviewPrewarmLock: @unchecked Sendable {
    public let url: URL
    /// The open lock file while held. Owned by the pre-warm's actor.
    private var descriptor: Int32 = -1

    public init(cache: EditorPreviewCache) {
        url = cache.root.appending(path: ".prewarm.lock")
    }

    public var isLocked: Bool { descriptor >= 0 }

    /// Takes the lock; false when another holder has it or the file can't be opened.
    public func lock() -> Bool {
        guard descriptor < 0 else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }
        let fd = open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }

    public func unlock() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { unlock() }

    /// Whether a pre-warm holds the lock of `cache` now.
    public static func isHeld(for cache: EditorPreviewCache) -> Bool {
        let url = cache.root.appending(path: ".prewarm.lock")
        let fd = open(url.path(percentEncoded: false), O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
