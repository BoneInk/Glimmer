import AppKit
import OWETheming

/// The one hook theming has in the desktop pictures OWE sets (`DesktopPictureSync`): the menu bar
/// strip, filled with the scheme colour, drawn over each display's composed picture before it is
/// written and shown. The menu bar is translucent over the desktop picture, so the strip tints it
/// (docs/theming.md).
enum DesktopPictureTheming {
    /// The strips for the displays about to get a picture; set by Open Wallpaper Engine's delegate
    /// at launch (`ThemingController.strips`). Nil in the Wallpaper Editor's process and in tests,
    /// where pictures stay as they are. A registration, not state: the controller owns the strips.
    @MainActor static var provider: (() -> DesktopPictureStrips?)?

    /// The strips to draw, captured on the main thread before the pictures are drawn.
    @MainActor
    static func strips() -> DesktopPictureStrips? { provider?() }

    /// What `display`'s picture is drawn with, for the picture's signature: a new colour or menu
    /// bar height draws the picture again. Empty without a strip.
    static func signature(_ strips: DesktopPictureStrips?, display: CGDirectDisplayID) -> String {
        guard let strips, let geometry = strips.displays[display] else { return "" }
        return "|strip:\(strips.color.red),\(strips.color.green),\(strips.color.blue)"
            + ",\(geometry.size.width)x\(geometry.size.height),\(geometry.menuBarHeight)"
    }

    /// `picture` with `display`'s strip filled; `picture` itself without one. Off the main thread.
    static func draw(_ strips: DesktopPictureStrips?, over picture: CGImage, display: CGDirectDisplayID) -> CGImage {
        strips?.composed(picture, display: display) ?? picture
    }
}
