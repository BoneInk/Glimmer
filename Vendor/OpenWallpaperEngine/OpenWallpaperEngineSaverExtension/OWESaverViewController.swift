import AppKit
import ScreenSaver

/// Makes the extension's view (`ScreenSaverViewControllerClass`).
@objc(OWESaverViewController)
final class OWESaverViewController: ScreenSaverViewController {
    /// Held so the host can't release the view while the controller lives.
    private var saverView: OWEExtensionSaverView?

    override func loadView() {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let view = OWEExtensionSaverView(frame: frame, isPreview: false)
        saverView = view
        self.view = view ?? NSView(frame: frame)
    }

    override func loadView(forFrame frame: NSRect, isPreview: Bool) {
        let view = OWEExtensionSaverView(frame: frame, isPreview: isPreview)
        saverView = view
        self.view = view ?? NSView(frame: frame)
    }
}
