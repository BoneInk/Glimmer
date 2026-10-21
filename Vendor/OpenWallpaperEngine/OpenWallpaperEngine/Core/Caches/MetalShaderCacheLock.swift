import Darwin
import Foundation

/// The `flock` an OWE process holds on its Metal shader cache's lock file (`MetalShaderCache`):
/// shared while it runs, exclusive only for a reset. The descriptor stays open, and the lock held,
/// until the object goes (for the app's own lock: the process's end).
final class MetalShaderCacheLock {
    private var descriptor: Int32 = -1

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    func open(_ url: URL) -> Bool {
        if descriptor >= 0 { return true }
        // O_CLOEXEC: a helper the app starts takes its own lock instead of inheriting this one.
        descriptor = Darwin.open(url.path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        if descriptor < 0 {
            OWELog.error(.app, "Metal shader cache: can't open \(url.path): \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    /// Whether this process now holds the lock alone.
    func tryExclusive() -> Bool {
        descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    /// Holds the lock shared (from exclusive, or from nothing), waiting out another process's reset.
    func share() {
        guard descriptor >= 0 else { return }
        while flock(descriptor, LOCK_SH) != 0 && errno == EINTR {}
    }

    /// The process-wide lock `AppMain` takes. Global by necessity (rule 3): the lock belongs to the
    /// process, not to any wallpaper or window, and must outlive everything that uses Metal.
    static let process = MetalShaderCacheLock()
}
