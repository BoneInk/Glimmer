import AppKit

/// What Wallpaper Engine's Play in Window opens (`playInWindow`): a wallpaper in an ordinary
/// window beside the desktop, named so a later request finds it again. The context menu's
/// Full HD, Phone and Maximized previews and the command line's `openWallpaper -playInWindow`
/// (with `-width`, `-height`, `-x`, `-y`, `borderless`, `activate`) all make one.
struct PlayInWindowRequest: Equatable {
    /// The window size WE's context menu offers, or the command line's.
    enum Size: Equatable {
        /// "Full HD Preview": 1920 × 1080 pixels.
        case fullHD
        /// "Phone Preview": WE's 607 × 1080 pixels, a phone's shape.
        case phone
        /// "Maximized Preview": the whole visible screen.
        case maximized
        /// `-width` and `-height`, in pixels.
        case pixels(width: Int, height: Int)

        /// The size in pixels; nil for `maximized`.
        var pixels: CGSize? {
            switch self {
            case .fullHD: return CGSize(width: 1920, height: 1080)
            case .phone: return CGSize(width: 607, height: 1080)
            case .maximized: return nil
            case let .pixels(width, height): return CGSize(width: width, height: height)
            }
        }
    }

    /// WE's name of the context menu's window, and of a command line's that names none.
    static let defaultName = "Wallpaper Pop-out"

    var wallpaper: WEWallpaper
    /// The window's name (WE's `location` for it): a request with the name of an open window
    /// shows its wallpaper there.
    var name: String = Self.defaultName
    var size: Size = .fullHD
    /// `-x` and `-y`: the window's top-left corner in pixels from the main display's top-left, as
    /// WE places windows; nil centres it.
    var origin: CGPoint?
    /// `borderless`: no title bar or border.
    var borderless = false
    /// Brings the window and the app forward (the context menu's always do; the command line's
    /// with `activate`).
    var activates = true

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.wallpaper.isSameWallpaper(as: rhs.wallpaper) && lhs.name == rhs.name && lhs.size == rhs.size
            && lhs.origin == rhs.origin && lhs.borderless == rhs.borderless && lhs.activates == rhs.activates
    }

    /// The window's content frame, in AppKit's global points, on a screen whose visible area is
    /// `visibleFrame` and which has `backingScale` pixels per point. `mainFrame` is the main
    /// display's frame, which `origin` is measured from. The window never comes out larger than
    /// the visible area: a size that doesn't fit keeps its shape and shrinks.
    static func contentFrame(size: Size, origin: CGPoint?, visibleFrame: CGRect, backingScale: CGFloat,
                             mainFrame: CGRect, titleBarHeight: CGFloat) -> CGRect {
        guard let pixels = size.pixels else {
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width, height: max(visibleFrame.height - titleBarHeight, 1))
        }
        let scale = max(backingScale, 1)
        var points = CGSize(width: max(pixels.width, 1) / scale, height: max(pixels.height, 1) / scale)
        let room = CGSize(width: visibleFrame.width, height: max(visibleFrame.height - titleBarHeight, 1))
        let fit = min(1, room.width / points.width, room.height / points.height)
        points = CGSize(width: (points.width * fit).rounded(), height: (points.height * fit).rounded())
        guard let origin else {
            return CGRect(x: (visibleFrame.midX - points.width / 2).rounded(),
                          y: (visibleFrame.midY - (points.height + titleBarHeight) / 2).rounded(),
                          width: points.width, height: points.height)
        }
        // From the main display's top-left corner, y down, to AppKit's bottom-left origin.
        let left = mainFrame.minX + origin.x / scale
        let top = mainFrame.maxY - origin.y / scale - titleBarHeight
        return CGRect(x: left.rounded(), y: (top - points.height).rounded(), width: points.width, height: points.height)
    }
}
