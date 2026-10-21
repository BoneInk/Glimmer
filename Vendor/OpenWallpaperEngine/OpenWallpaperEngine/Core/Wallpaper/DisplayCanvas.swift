import CoreGraphics

/// The canvas a stretched wallpaper is drawn on (WE's span): the bounding box of its displays'
/// desktop rects, in global points (AppKit's, origin bottom-left). Gaps between displays are part
/// of the canvas but no display shows them; there's no bezel or density compensation, so each
/// display shows its own rect of the one canvas, as WE does (`ui.js` sizes a group this way).
enum DisplayCanvas {
    /// WE's group rect: `x = min(x)`, `y = min(y)`, `w = max(x + w) - x`, `h = max(y + h) - y`.
    static func bounds(of frames: [CGRect]) -> CGRect {
        guard let first = frames.first else { return .null }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// `frame`'s rect within `canvas`, in points from the canvas's top-left: where a view the size
    /// of the canvas is offset to so the display shows its part.
    static func rect(of frame: CGRect, in canvas: CGRect) -> CGRect {
        CGRect(x: frame.minX - canvas.minX, y: canvas.maxY - frame.maxY, width: frame.width, height: frame.height)
    }

    /// `frame`'s part of `canvas` as fractions of it from the top-left (a texture's coordinates,
    /// a layer's `contentsRect`).
    static func unitRect(of frame: CGRect, in canvas: CGRect) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let rect = rect(of: frame, in: canvas)
        return CGRect(x: rect.minX / canvas.width, y: rect.minY / canvas.height,
                      width: rect.width / canvas.width, height: rect.height / canvas.height)
    }

    /// A desktop point (global, origin bottom-left) on the canvas, origin bottom-left.
    static func point(_ point: CGPoint, in canvas: CGRect) -> CGPoint {
        CGPoint(x: point.x - canvas.minX, y: point.y - canvas.minY)
    }

    /// The canvas in pixels at `scale` pixels per point, fitted (aspect kept) into
    /// `maximumDimension` per side: the GPU's limit is the only cap.
    static func pixelSize(of canvas: CGSize, scale: CGFloat, maximumDimension: CGFloat) -> CGSize {
        let pixels = CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
        let largest = max(pixels.width, pixels.height)
        guard largest > maximumDimension, largest > 0 else { return pixels }
        let fit = maximumDimension / largest
        return CGSize(width: (pixels.width * fit).rounded(.down), height: (pixels.height * fit).rounded(.down))
    }
}
