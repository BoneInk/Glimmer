import CoreGraphics

/// How a clone's or stretch's other displays show the one page their source display loads, as
/// WE mirrors a clone's render (DirectComposition clones) instead of running it again.
///
/// - **Chromium:** the browser's frames are IOSurfaces, so each mirror blits the same frame into
///   its own Metal layer (`ChromiumBrowserPage.addFrameObserver`).
/// - **WebKit** keeps a page per display. A `WKWebView` draws in its own window only; snapshots
///   read the page back on the CPU every frame, and Core Animation's private portal layer
///   (`CAPortalLayer`), which can draw the page's layers in another window, measured no better
///   than a second page: the window server's GPU time grew by what the page's fell (a WebM clone
///   doubled it), and a canvas-sized page cost more CPU than two (WebKit keeps the tiles outside
///   its window up to date).
enum WebPageMirroring {
    /// Whether a display can mirror a page on `engine` instead of loading its own.
    static func canMirror(_ engine: WebEngine) -> Bool { engine == .chromium }

    /// The scale a mirror shows its source at: the source's frame covering the mirror's, centred
    /// (1 for a stretch's members, all the canvas's size, and for a clone of equal displays).
    static func scale(source: CGSize, mirror: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0, mirror.width > 0, mirror.height > 0 else { return 1 }
        return max(mirror.width / source.width, mirror.height / source.height)
    }

    /// The screen point over the source page that shows what `point`, over the mirror whose frame
    /// on screen is `mirrorFrame`, shows. `mirroredIn` is the window a flipped clone display
    /// mirrors its content in (`NSView.isMirroredOnScreen`).
    static func sourcePoint(_ point: CGPoint, mirrorFrame: CGRect, sourceFrame: CGRect,
                            mirroredIn window: CGRect? = nil) -> CGPoint {
        var point = point
        if let window { point.x = window.minX + window.maxX - point.x }
        let scale = scale(source: sourceFrame.size, mirror: mirrorFrame.size)
        return CGPoint(x: sourceFrame.midX + (point.x - mirrorFrame.midX) / scale,
                       y: sourceFrame.midY + (point.y - mirrorFrame.midY) / scale)
    }
}
