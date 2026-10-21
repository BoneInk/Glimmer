import Foundation
import ScreenSaver

/// The `com.apple.screensaver` app extension's principal class: the system runs the extension in
/// its own sandboxed process with this target's entitlements (an App Group shared with the app and
/// the broker's Mach service), unlike a `.saver`, which runs inside Apple's `legacyScreenSaver`.
@objc(OWESaverExtension)
final class OWESaverExtension: ScreenSaverExtension {
    override init() {
        super.init()
        SaverLog.lifecycle.notice("extension init pid=\(getpid())")
    }
}
