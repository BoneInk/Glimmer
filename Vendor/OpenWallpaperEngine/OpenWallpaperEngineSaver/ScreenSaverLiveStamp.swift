import Foundation

/// A live frame's announcement, the 64-bit state of its ring's Darwin notification
/// (`notify_set_state`): the manifest's generation, the frame's number and the ring slot it was
/// drawn into. A saver shows the slot when the generation is the manifest's it read and the frame
/// is newer than the one it shows; a frame number that stops moving means the app stopped
/// drawing, and the saver falls back to its still (`LiveFrameFallback`).
///
/// Layout: bits 0–7 the slot, 8–39 the frame (wrapping), 40–55 the generation; 0 is no frame.
struct ScreenSaverLiveStamp: Equatable {
    var generation: UInt16
    var frame: UInt32
    var slot: UInt8

    init(generation: UInt16, frame: UInt32, slot: UInt8) {
        self.generation = generation
        self.frame = frame
        self.slot = slot
    }

    /// The stamp in a notification's state; nil for 0 (nothing drawn yet).
    init?(state: UInt64) {
        guard state != 0 else { return nil }
        slot = UInt8(truncatingIfNeeded: state)
        frame = UInt32(truncatingIfNeeded: state >> 8)
        generation = UInt16(truncatingIfNeeded: state >> 40)
    }

    var state: UInt64 {
        UInt64(slot) | UInt64(frame) << 8 | UInt64(generation) << 40
    }

    /// A manifest generation as stamps carry it.
    static func generation(_ value: Int) -> UInt16 { UInt16(truncatingIfNeeded: value) }

    /// Whether `self` is a later frame than `other` of the same generation, allowing for the frame
    /// number wrapping.
    func isNewer(than other: ScreenSaverLiveStamp?) -> Bool {
        guard let other, other.generation == generation else { return true }
        return Int32(bitPattern: frame &- other.frame) > 0
    }
}

/// The names the app, the `.saver` and the extension share.
enum ScreenSaverLiveNames {
    /// loginwindow's distributed notifications (`ScreenSaverDaemon`), in the order a session
    /// posts them: `didstart` → (`screenIsLocked`) → `willstop` → `didstop` → (`screenIsUnlocked`).
    static let didStart = Notification.Name("com.apple.screensaver.didstart")
    static let willStop = Notification.Name("com.apple.screensaver.willstop")
    static let didStop = Notification.Name("com.apple.screensaver.didstop")
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    /// The Darwin notification a showing saver posts about once a second, so the app knows one is
    /// there to draw for; a saver's host can't post distributed notifications with a payload or
    /// reach the app over XPC, but Darwin notifications pass.
    static let saverAlive = "app.openwallpaperengine.saver.alive"
    /// The same from a System Settings Preview run: the app draws for it while it runs, but the
    /// broker never launches the app for it.
    static let saverPreviewAlive = "app.openwallpaperengine.saver.preview-alive"
    /// A ring's frame notification: `<prefix><ring>`.
    static let framePrefix = "app.openwallpaperengine.saver.frame."

    static func frameNotification(ring: Int) -> String { framePrefix + "\(ring)" }

    /// The App Group the app and the extension share (Mac style, team-prefixed).
    static let appGroup = "C33D7BSFGS.app.openwallpaperengine"
    /// The broker's Mach service (a launchd agent, `OWESaverBroker`): the extension finds the app's
    /// frame service through it. Prefixed with the App Group, so the extension's sandbox may look it up.
    static let brokerService = appGroup + ".saver-broker"
    /// The argument the broker launches the app with when a saver shows and the app isn't
    /// running: the app starts in the background, draws for the screen saver, and opens no window.
    static let launchArgument = "--screen-saver-launch"
}
