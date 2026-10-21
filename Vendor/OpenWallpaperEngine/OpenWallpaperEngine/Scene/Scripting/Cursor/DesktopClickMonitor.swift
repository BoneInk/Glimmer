import AppKit

/// The left button as the wallpaper receives it (docs/scenescript-plan.md §4.8): pressed only by
/// a click that lands on the wallpaper, not on another window, wherever the app in front is.
/// WE's scripts (`input.cursorLeftDown`, the cursor pass) and its `g_PointerState` see only
/// clicks the wallpaper window gets.
///
/// Wallpaper windows ignore mouse events, so the clicks are watched with a global monitor (clicks
/// sent to other apps, Finder's desktop included) and a local one (clicks sent to this app).
/// Mouse events need no Accessibility permission; only key events do (`NSEvent`
/// `addGlobalMonitorForEvents` docs). A press counts when no window that takes mouse events is
/// above the desktop at that point (`landsOnWallpaper`), checked once per press, not per frame.
///
/// One per app (`SceneScriptServices`); monitors run on the main thread and readers may be on any
/// thread, so `lock` owns `isDown` and `presses`.
final class DesktopClickMonitor {
    /// What a reader sees: whether the button is held on the wallpaper, and how many presses
    /// landed on it so far (so a press and release between two frames still counts for one).
    struct State: Equatable {
        var isDown = false
        var presses = 0
    }

    /// Whether a press at a screen point (AppKit coordinates) lands on the wallpaper.
    private let hitTest: (NSPoint) -> Bool
    private let lock = NSLock()
    private var current = State()
    private var monitors: [Any] = []

    init(hitTest: @escaping (NSPoint) -> Bool = DesktopClickMonitor.landsOnWallpaper) {
        self.hitTest = hitTest
    }

    deinit { stop() }

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Installs the monitors (main thread); again is a no-op.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event.type, at: NSEvent.mouseLocation)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event.type, at: NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    /// A left button event at a screen point: a press counts only on the wallpaper, a release
    /// anywhere lets go.
    func handle(_ type: NSEvent.EventType, at location: NSPoint) {
        switch type {
        case .leftMouseDown:
            guard hitTest(location) else { return }
            lock.lock()
            current.isDown = true
            current.presses &+= 1
            lock.unlock()
        case .leftMouseUp:
            lock.lock()
            current.isDown = false
            lock.unlock()
        default:
            break
        }
    }

    /// Whether a press at `point` reaches the wallpaper: no window that takes mouse events is at
    /// that point (`windowNumber(at:)` skips click-through windows such as ours and overlays), the
    /// one that is sits at or below the desktop icons' level (Finder's desktop), or it is a Play
    /// in Window window, whose wallpaper takes the window's clicks.
    static func landsOnWallpaper(_ point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return true }
        // The monitors call this on the main thread.
        if Thread.isMainThread, MainActor.assumeIsolated({
            NSApp.window(withWindowNumber: number)?.identifier == PlayInWindowWindow.identifier
        }) {
            return true
        }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return false }
        return layer <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}

/// One reader's view of a `DesktopClickMonitor` (a renderer, once per frame): down while held, and
/// for one frame after a press that was released before the frame saw it.
struct DesktopClickReader {
    private var seenPresses: Int?

    mutating func isDown(_ state: DesktopClickMonitor.State) -> Bool {
        defer { seenPresses = state.presses }
        guard let seenPresses else { return state.isDown }
        return state.isDown || state.presses != seenPresses
    }
}
