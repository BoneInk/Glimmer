import Cocoa
import SwiftUI
import AVKit
import WebKit

/// Non-interactive window that stays behind all other windows.
class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
