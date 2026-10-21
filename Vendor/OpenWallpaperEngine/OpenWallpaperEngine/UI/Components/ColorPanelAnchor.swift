import SwiftUI
import AppKit

/// SwiftUI reuses the shared `NSColorPanel`, which reopens wherever macOS last left it — often far
/// from the control that opened it. This parks it just outside the left edge of that control.
private final class ColorPanelPositioner {
    static let shared = ColorPanelPositioner()

    private var observer: NSObjectProtocol?
    private var anchorScreenRect: CGRect = .zero

    func update(anchor: CGRect) {
        guard anchor.width > 0 else { return }
        anchorScreenRect = anchor
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let panel = notification.object as? NSColorPanel else { return }
            self?.position(panel)
        }
    }

    private func position(_ panel: NSColorPanel) {
        guard anchorScreenRect != .zero else { return }
        let size = panel.frame.size
        var origin = CGPoint(x: anchorScreenRect.minX - size.width - 12,
                             y: anchorScreenRect.maxY - size.height)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchorScreenRect) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Fall back to the right of the control when there is no room on the left.
            if origin.x < visible.minX { origin.x = anchorScreenRect.maxX + 12 }
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        panel.setFrameOrigin(origin)
    }
}

private struct ColorPanelAnchorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? TrackingView)?.reportAnchor()
    }

    final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportAnchor()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func reportAnchor() {
            guard let window, bounds.width > 0 else { return }
            ColorPanelPositioner.shared.update(anchor: window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}

extension View {
    /// Opens the shared colour panel beside this control rather than at its last screen position.
    func anchorsColorPanel() -> some View {
        background(ColorPanelAnchorView())
    }
}
