import AppKit
import CoreGraphics

/// Observes mouse events without consuming them, so Finder keeps normal icon handling.
@MainActor
final class DesktopWallpaperInputForwarder {
    private weak var window: NSWindow?
    private let deliver: (NSEvent, NSPoint) -> Void
    private var monitors: [Any] = []
    private var dragging = false
    private var lastMoveTime: TimeInterval = 0

    init(window: NSWindow, deliver: @escaping (NSEvent, NSPoint) -> Void) {
        self.window = window
        self.deliver = deliver
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event, at: NSEvent.mouseLocation) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.receive(event, at: NSEvent.mouseLocation) }
            return event
        }) { monitors.append(local) }
    }

    isolated deinit { stop() }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        dragging = false
    }

    private func receive(_ event: NSEvent, at point: NSPoint) {
        guard let window, window.isVisible else { return }
        if event.type == .leftMouseUp, dragging {
            dragging = false
            deliver(event, point)
            return
        }
        guard window.frame.contains(point) else { return }
        guard dragging || Self.landsOnDesktop(point) else { return }
        if event.type == .mouseMoved {
            guard event.timestamp - lastMoveTime >= 1.0 / 60 else { return }
            lastMoveTime = event.timestamp
        }
        if event.type == .leftMouseDown { dragging = true }
        deliver(event, point)
    }

    static func landsOnDesktop(_ point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0 else { return true }
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let layer = info[kCGWindowLayer as String] as? Int else { return false }
        return layer <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }
}
