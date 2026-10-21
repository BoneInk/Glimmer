import Cocoa

/// The Dock icon is shown while one of the app's windows is open, or always with Settings › General
/// › Show in Dock: without it, closing the last window leaves the app in the menu bar (or in the
/// background), and opening one (from the menu bar, a menu or a reopen) brings the icon back. A
/// minimised window keeps it, since the Dock is where it is restored from.
@MainActor
final class DockPresence {
    private var observers: [NSObjectProtocol] = []
    /// Settings › General › Show in Dock.
    var keepsIcon: () -> Bool = { false }

    func start() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow, Self.counts(window) else { return }
                    self?.show()
                }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow, Self.counts(window) else { return }
                    // The closing window is still visible here; look once it has gone.
                    DispatchQueue.main.async { self?.update() }
                }
            },
        ]
        update()
    }

    /// Shows the icon when an app window is open or minimised, or Show in Dock is on; hides it
    /// otherwise.
    func update() {
        if NSApp.windows.contains(where: { Self.counts($0) && ($0.isVisible || $0.isMiniaturized) }) {
            show()
        } else if keepsIcon() {
            // No window to bring forward: the icon appears without taking focus.
            guard NSApp.activationPolicy() != .regular else { return }
            NSApp.setActivationPolicy(.regular)
            DockBadge.current.apply()
        } else if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func show() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // A new Dock tile starts plain.
        DockBadge.current.apply()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The app's own titled windows: not the borderless wallpaper windows, panels or sheets.
    private static func counts(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel) && window.sheetParent == nil
    }
}
