import CoreGraphics

/// The menu bar's strip of a desktop picture. macOS has no API for the menu bar's colour: the bar
/// is translucent over the desktop picture, so the picture's top strip, filled with the colour,
/// shows through it.
public enum MenuBarStrip {
    /// The strip fades out downwards over this many menu bar heights, from `peakOpacity` at the
    /// top to nothing, so the colour tints the bar and dissolves into the wallpaper.
    public static let fadeHeightRatio: CGFloat = 1.5

    /// The strip's opacity at its top: a tint over the wallpaper rather than a solid band.
    public static let peakOpacity: CGFloat = 0.4

    /// The fade's stops, top to bottom: (location in the strip, opacity).
    public static let fadeStops: [(location: CGFloat, alpha: CGFloat)] =
        [(0, 1), (0.3, 0.9), (0.65, 0.35), (1, 0)].map { ($0.0, $0.1 * peakOpacity) }

    /// The faded strip's height for a menu bar `height` points tall.
    public static func fadeHeight(menuBarHeight height: CGFloat) -> CGFloat {
        height * fadeHeightRatio
    }

    /// The menu bar's height on a display, in points: what the visible frame leaves at the top,
    /// or the safe area's top inset (the camera housing) when that is taller. 0 when the menu bar
    /// hides itself.
    public static func height(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat) -> CGFloat {
        max(frame.maxY - visibleFrame.maxY, safeAreaTop, 0)
    }

    /// The strip in the pixels of an image of `imageSize`, shown on a display of `displaySize`
    /// points as macOS's default "Fill Screen" does (scaled to cover, centred). Core Graphics
    /// coordinates: the origin is the bottom left. It spans the image's whole width; nil when
    /// there is no strip.
    public static func imageRect(height: CGFloat, displaySize: CGSize, imageSize: CGSize) -> CGRect? {
        guard height > 0, displaySize.width > 0, displaySize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = max(displaySize.width / imageSize.width, displaySize.height / imageSize.height)
        let visibleHeight = displaySize.height / scale
        let visibleTop = (imageSize.height + visibleHeight) / 2
        let stripHeight = min(height, displaySize.height) / scale
        let top = visibleTop.rounded(.up)
        let bottom = (visibleTop - stripHeight).rounded(.down)
        return CGRect(x: 0, y: bottom, width: imageSize.width, height: top - bottom)
    }
}

/// A display's geometry for the strip, taken from its screen on the main thread.
public struct MenuBarStripDisplay: Equatable, Sendable {
    public var size: CGSize
    public var menuBarHeight: CGFloat

    public init(size: CGSize, menuBarHeight: CGFloat) {
        self.size = size
        self.menuBarHeight = menuBarHeight
    }
}
