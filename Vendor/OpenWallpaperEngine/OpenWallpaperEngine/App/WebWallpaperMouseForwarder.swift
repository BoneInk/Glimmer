import AppKit

/// Passes the mouse to web wallpapers: their windows ignore mouse events, so a global monitor
/// sends the clicks, drags, scrolls and moves made over the desktop (Finder frontmost) to the page
/// under the pointer. The monitor sees every mouse event in the system, so it runs only while a
/// web wallpaper is shown (`update(needed:)`).
@MainActor
final class WebWallpaperMouseForwarder {
    /// The wallpaper windows the pages are in.
    private let windows: () -> [NSWindow]
    private var monitor: Any?

    init(windows: @escaping () -> [NSWindow]) {
        self.windows = windows
    }

    /// Whether the monitor is installed.
    var isForwarding: Bool { monitor != nil }

    /// Whether any display shows a web wallpaper: an enabled display's instance is a web page and
    /// the wallpapers aren't stopped. `instanceKeys` is keyed by display or split region.
    nonisolated static func isNeeded(instanceKeys: [String: WallpaperInstanceKey], enabledScreens: Set<String>,
                                     stopped: Bool) -> Bool {
        guard !stopped else { return false }
        return instanceKeys.contains { screen, key in
            key.type == "web" && enabledScreens.contains(DisplayLayoutResolution.screen(of: screen))
        }
    }

    /// Installs the monitor when `needed`, removes it otherwise.
    func update(needed: Bool) {
        guard needed != isForwarding else { return }
        if needed {
            install()
            OWELog.debug(.web, "Forwarding the mouse to web wallpapers")
        } else if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            OWELog.debug(.web, "Stopped forwarding the mouse to web wallpapers")
        }
    }

    private func install() {
        // Only the event types handled below: `.any` starves the main thread.
        let relevantEvents: NSEvent.EventTypeMask = [
            .scrollWheel, .mouseMoved, .mouseEntered, .mouseExited,
            .leftMouseUp, .rightMouseUp, .leftMouseDown,
            .leftMouseDragged, .rightMouseDragged
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: relevantEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.forward(event) }
        }
    }

    private func forward(_ event: NSEvent) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        // A split display has a page per region, and a stretched page is the canvas's size.
        let mouseLocation = NSEvent.mouseLocation
        guard let window = windows().first(where: { $0.frame.contains(mouseLocation) }),
              let webview = window.contentView?.webView(at: mouseLocation) else { return }
        switch event.type {
        case .scrollWheel: webview.scrollWheel(with: event)
        case .mouseMoved: webview.mouseMoved(with: event)
        case .mouseEntered: webview.mouseEntered(with: event)
        case .mouseExited: webview.mouseExited(with: event)
        case .leftMouseUp, .rightMouseUp: webview.mouseUp(with: event)
        case .leftMouseDown: webview.mouseDown(with: event)
        case .leftMouseDragged, .rightMouseDragged: webview.mouseDragged(with: event)
        default: break
        }
    }
}
