import AppKit
import Combine

/// Animated library previews: a tile plays its Workshop preview GIF. Built in and always on (it
/// was the Animated Thumbnails plugin). It costs nothing where nobody sees it: the library scrolls
/// in a lazy grid, and `GifImage` plays a tile only while some of it is in the scroll view's
/// visible part and its window shows (not hidden, minimized or covered), letting a scrolled-away
/// tile's decoded frames go; in Low Power Mode a tile plays only under the pointer.
enum ThumbnailAnimation {
    /// The retired plugin's on/off preference. Ignored, and removed at launch.
    static let retiredPreferenceKey = "TestAnimates"

    /// Whether a shown tile plays: while the app is active, and in Low Power Mode only while
    /// hovered. (`windowShows` gates it further.)
    static func plays(isAppActive: Bool, isLowPowerMode: Bool, isHovered: Bool) -> Bool {
        isAppActive && (!isLowPowerMode || isHovered)
    }

    /// Whether `window` is on screen: ordered in, not minimized and not fully covered.
    static func windowShows(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    /// Drops the retired plugin's preference, so an old "off" is gone with it.
    static func removeRetiredPreference(from defaults: UserDefaults) {
        defaults.removeObject(forKey: retiredPreferenceKey)
    }
}

/// Low Power Mode, published on the main thread as it turns on and off.
final class LowPowerModeState: ObservableObject {
    static let shared = LowPowerModeState()

    @Published private(set) var isEnabled: Bool
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(read: @escaping () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         center: NotificationCenter = .default) {
        isEnabled = read()
        self.center = center
        // Posted on any thread; read and published on the main one.
        token = center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                   queue: nil) { [weak self] _ in
            let update = {
                let enabled = read()
                if let self, self.isEnabled != enabled { self.isEnabled = enabled }
            }
            if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
