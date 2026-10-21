import AppKit
import Metal

/// A clone's or stretch's member display showing the Chromium page its source display loads,
/// instead of loading its own (`WebPageMirroring`): the page's frames in a Metal layer of its own.
/// The frame fills the view at the scale that covers it (`WebPageMirroring.scale`), so a stretch
/// member, sized to the canvas like the source and offset in its window, shows its own rect of
/// the one canvas-sized page.
final class WebPageMirrorView: NSView {
    let sourceScreenId: String
    private weak var registry: WebPageMirrorRegistry?
    /// The view showing the page on the source display, while there is one.
    private(set) weak var source: NSView?
    private var presenter: ChromiumFramePresenter?
    private weak var observedPage: ChromiumBrowserPage?

    init(registry: WebPageMirrorRegistry, sourceScreenId: String) {
        self.registry = registry
        self.sourceScreenId = sourceScreenId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { registry?.add(self) } else { registry?.remove(self) }
    }

    /// Shows `source`'s page, or nothing.
    func attach(_ source: NSView?) {
        guard source !== self.source || (source == nil && presenter != nil) else { return }
        detach()
        self.source = source
        if let pageView = source as? ChromiumPageView {
            let presenter = ChromiumFramePresenter(device: MTLCreateSystemDefaultDevice())
            // A clone of a differently shaped display shows the page as a scene does: covering it.
            presenter.layer.contentsGravity = .resizeAspectFill
            presenter.layer.actions = Self.noAnimations
            layer?.addSublayer(presenter.layer)
            self.presenter = presenter
            observedPage = pageView.page
            pageView.page.addFrameObserver(self) { [presenter] frame in presenter.enqueue(frame) }
        }
        needsLayout = true
    }

    private func detach() {
        presenter?.layer.removeFromSuperlayer()
        presenter = nil
        observedPage?.removeFrameObserver(self)
        observedPage = nil
    }

    deinit {
        observedPage?.removeFrameObserver(self)
    }

    private static let noAnimations: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let presenter {
            presenter.layer.frame = bounds
            presenter.layer.contentsScale = window?.backingScaleFactor ?? 1
        }
    }

    /// The screen point over the source page (whose view's frame on screen is `sourceFrame`) that
    /// shows what `screenPoint` shows here; nil when the point isn't over this view's window.
    func sourcePoint(_ screenPoint: NSPoint, sourceFrame: NSRect) -> NSPoint? {
        guard let window, window.frame.contains(screenPoint) else { return nil }
        let frame = window.convertToScreen(convert(bounds, to: nil))
        guard frame.contains(screenPoint) else { return nil }
        return WebPageMirroring.sourcePoint(screenPoint, mirrorFrame: frame, sourceFrame: sourceFrame,
                                            mirroredIn: isMirroredOnScreen ? window.frame : nil)
    }
}
