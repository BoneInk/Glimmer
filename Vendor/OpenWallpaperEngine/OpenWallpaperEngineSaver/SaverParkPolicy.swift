import CoreGraphics
import Foundation

/// Which saver views draw fewer frames. While a screen saver or lock session runs, none: every
/// view draws every frame (`LiveFrameDrawer`), since no signal tells a hidden stacked view from
/// the one shown under loginwindow's password prompt (there none reports its frames presented,
/// and the lock's windows report themselves occluded; guessing parked the visible views, lab run
/// 2). Only System Settings' preview, which isn't a session, parks at `parkedRate` once its window
/// stops being visible (the Settings window hidden or closed). Times are seconds on one
/// monotonic clock.
enum SaverParkPolicy {
    /// Full rate for this long after the view starts, before any frame could be presented.
    static let startGrace: TimeInterval = 3
    /// Full rate while the preview's window was visible within this long.
    static let visibleGrace: TimeInterval = 2
    static let parkedRate = 1

    /// Whether System Settings' preview, started at `startedAt`, parks at `now`.
    static func previewParked(startedAt: TimeInterval, lastVisible: TimeInterval?, at now: TimeInterval) -> Bool {
        guard now - startedAt > startGrace else { return false }
        return lastVisible.map { now - $0 > visibleGrace } ?? true
    }

    /// Whether a frame that came at `now` is drawn by a view that is `parked`: every one at full
    /// rate, one a second parked.
    static func mayDraw(parked: Bool, at now: TimeInterval, lastDrawn: TimeInterval?) -> Bool {
        guard parked, let lastDrawn else { return true }
        return now - lastDrawn >= 1 / Double(parkedRate)
    }

    /// Whether a view is the System Settings preview: its flag, which is unreliable from macOS 26
    /// (the preview and the real run go through the same host), or a frame too small for a screen.
    static func isPreview(flag: Bool, size: CGSize) -> Bool {
        flag || size.width < 600 || size.height < 400
    }
}
