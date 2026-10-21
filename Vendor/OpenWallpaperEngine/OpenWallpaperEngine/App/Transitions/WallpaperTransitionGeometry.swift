import CoreGraphics

/// Where a transition shows for one changing wallpaper: rendered once, at `pixelSize`, and shown
/// by every display that shows that wallpaper. A clone's members each show the whole frame; a
/// stretch's members their rect of the canvas; a split region its rect of its display.
struct WallpaperTransitionGeometry: Equatable {
    /// One wallpaper window's part.
    struct Member: Equatable {
        /// The window's display.
        var windowId: String
        /// The overlay's frame in the window's content, in points from its bottom-left.
        var frame: CGRect
        /// The part of the transition's frame it shows, as fractions from the top-left.
        var contentsRect: CGRect
    }

    /// The display, region or group source the capture is of.
    var target: String
    var pixelSize: SIMD2<Int>
    var members: [Member]
    /// The window whose page a web wallpaper's capture reads.
    var captureWindowId: String
    var backingScale: CGFloat

    static let wholeFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// `target`'s geometry on the windows `windowIds`; nil when no window shows it.
    /// `frame`: a display's or region's rect in global points; `scale`: a display's pixels per point.
    static func make(target: String, windowIds: Set<String>, resolution: DisplayLayoutResolution,
                     frame: (String) -> CGRect?, scale: (String) -> CGFloat) -> WallpaperTransitionGeometry? {
        if resolution.region(target) != nil {
            let display = DisplayLayoutResolution.screen(of: target)
            guard windowIds.contains(display), let region = frame(target), let screen = frame(display) else { return nil }
            let factor = scale(display)
            let local = CGRect(x: region.minX - screen.minX, y: region.minY - screen.minY,
                               width: region.width, height: region.height)
            return WallpaperTransitionGeometry(
                target: target, pixelSize: pixels(region.size, factor),
                members: [Member(windowId: display, frame: local, contentsRect: wholeFrame)],
                captureWindowId: display, backingScale: factor)
        }
        let memberIds = windowIds.filter { resolution.source(of: $0) == target }.sorted()
        guard let first = memberIds.first else { return nil }
        var members: [Member] = []
        var canvasSize: CGSize?
        var factor: CGFloat = 1
        for id in memberIds {
            guard let display = frame(id) else { continue }
            factor = max(factor, scale(id))
            let bounds = CGRect(origin: .zero, size: display.size)
            if let canvas = resolution.canvases[id] {
                canvasSize = canvas.size
                members.append(Member(windowId: id, frame: bounds,
                                      contentsRect: DisplayCanvas.unitRect(of: display, in: canvas)))
            } else {
                members.append(Member(windowId: id, frame: bounds, contentsRect: wholeFrame))
            }
        }
        let sourceId = memberIds.contains(target) ? target : first
        guard !members.isEmpty, let size = canvasSize ?? frame(sourceId)?.size else { return nil }
        return WallpaperTransitionGeometry(target: target, pixelSize: pixels(size, factor), members: members,
                                           captureWindowId: sourceId, backingScale: factor)
    }

    private static func pixels(_ size: CGSize, _ scale: CGFloat) -> SIMD2<Int> {
        SIMD2(max(Int((size.width * scale).rounded()), 1), max(Int((size.height * scale).rounded()), 1))
    }
}
