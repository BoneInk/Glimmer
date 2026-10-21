import AppKit
import ScreenSaver

/// The extension's saver view: the app's live frames over XPC (`XPCFrameSource`), else the loop
/// video, through the same presenter as the `.saver` (`LiveSaverPresenter`).
final class OWEExtensionSaverView: ScreenSaverView {
    private var presenter: LiveSaverPresenter?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        presenter = LiveSaverPresenter(view: self, isPreview: isPreview, source: XPCFrameSource.shared)
        animationTimeInterval = 1
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        MainActor.assumeIsolated { presenter?.invalidate() }
    }

    override func startAnimation() {
        super.startAnimation()
        presenter?.start(reason: "startAnimation")
    }

    override func stopAnimation() {
        super.stopAnimation()
        presenter?.stop(reason: "stopAnimation")
    }

    override func animateOneFrame() {}

    override var hasConfigureSheet: Bool { false }

    /// The host may show the view without `startAnimation` (`SSENeedsAnimationTimer` is off).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { presenter?.start(reason: "window") }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        presenter?.layout()
    }
}
