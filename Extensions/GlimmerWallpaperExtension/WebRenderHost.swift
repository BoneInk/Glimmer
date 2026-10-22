import AppKit
import WebKit

/// AppKit schedules the view in an unshown window. The compositor owns the
/// exported layer tree; no AppKit window is placed above the lock screen.
@MainActor
final class GWWebRenderHost {
    private final class SchedulingWindow: NSWindow {
        override var isVisible: Bool { true }
        override var occlusionState: NSWindow.OcclusionState { .visible }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    let window: NSWindow
    private let container: NSView
    private weak var output: CALayer?
    private var observer: NSObjectProtocol?
    private var closed = false
    private(set) var ownershipRepairs = 0
    var isExported: Bool { !closed && container.layer?.superlayer === output && output != nil }
    var isOrderedOnScreen: Bool {
        (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
    }

    init(webView: WKWebView) {
        _ = NSApplication.shared
        window = SchedulingWindow(contentRect: webView.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        container = NSView(frame: webView.frame)
        container.wantsLayer = true
        webView.wantsLayer = true
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileOwnership() }
            }
    }

    func export(to root: CALayer) throws {
        guard !closed else { throw GWError(80, "Web layer host is closed") }
        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        output = root
        reconcileOwnership()
        guard isExported else { throw GWError(81, "Web layer tree could not be exported") }
    }

    func resize(to size: CGSize) {
        guard !closed else { return }
        window.setContentSize(size)
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutSubtreeIfNeeded()
        reconcileOwnership()
    }

    private func reconcileOwnership() {
        guard !closed, let output, let tree = container.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.frame = output.bounds
        if tree.superlayer !== output {
            // AppKit may take its backing layer back during initial layout,
            // resize or a backing-scale update. Reconcile at that lifecycle
            // event, never by reading back pixels or running a frame timer.
            output.addSublayer(tree)
            ownershipRepairs += 1
        }
        CATransaction.commit()
        CATransaction.flush()
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        container.layer?.removeFromSuperlayer()
        output = nil
        window.contentView = nil
        window.close()
    }
}
