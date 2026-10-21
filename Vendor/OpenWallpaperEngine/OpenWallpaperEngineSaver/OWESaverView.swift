import AppKit
import ScreenSaver

/// The bundled screen saver. While the app draws the screen saver live, it shows the app's frames
/// (global IOSurfaces it finds through `live.json` and Darwin notifications,
/// `GlobalSurfaceFrameSource`); otherwise each display's still (`ScreenSaverStills`). Each display
/// shows what is listed for it; a stretched one its rect. Black when the app has neither. `LiveSaverPresenter`
/// does the work and the host's lifecycle workarounds.
class OWESaverViewBase: ScreenSaverView {
    private var presenter: LiveSaverPresenter?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        presenter = LiveSaverPresenter(view: self, isPreview: isPreview, source: GlobalSurfaceFrameSource.shared)
        // The presenter's display link paces the frames; the host's timer isn't used.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presenter?.windowChanged()
    }

    override var hasConfigureSheet: Bool { false }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        presenter?.layout()
    }
}

// The principal class. The lab build (`OWE_SAVER_LAB`) names it differently, so the lab saver and
// the installed one can be loaded by the same host process.
#if OWE_SAVER_LAB
@objc(OWELiveLabSaverView)
final class OWELiveLabSaverView: OWESaverViewBase {}
#else
@objc(OWESaverView)
final class OWESaverView: OWESaverViewBase {}
#endif
