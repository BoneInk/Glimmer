import CoreGraphics

/// The maths of Display Settings' miniature of a display: a frame shaped like the display, and
/// where the wallpaper's picture lands in it.
enum DisplayPictureGeometry {
    /// The largest size with the display's aspect that fits in `box`.
    static func frameSize(display: CGSize, fitting box: CGSize) -> CGSize {
        guard display.width > 0, display.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / display.width, box.height / display.height)
        return CGSize(width: display.width * scale, height: display.height * scale)
    }

    /// Where a picture of `image` size is drawn in `frame` with `placement`: Fill and Zoom cover the
    /// frame, cropping; Fit and Center fit inside it; Stretch takes the frame's shape. Centred.
    static func imageRect(image: CGSize, in frame: CGSize, placement: WallpaperPlacement) -> CGRect {
        guard image.width > 0, image.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let scaleX = frame.width / image.width
        let scaleY = frame.height / image.height
        let size: CGSize
        switch placement {
        case .stretch:
            size = frame
        case .fill, .zoom:
            let scale = max(scaleX, scaleY)
            size = CGSize(width: image.width * scale, height: image.height * scale)
        case .fit, .center:
            let scale = min(scaleX, scaleY)
            size = CGSize(width: image.width * scale, height: image.height * scale)
        }
        return CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// The longest side, in pixels, to decode `image` at to draw it in `frame` at `scale` pixels per
    /// point: never above the picture's own.
    static func decodePixelSize(image: CGSize, in frame: CGSize, placement: WallpaperPlacement, scale: CGFloat) -> Int {
        let rect = imageRect(image: image, in: frame, placement: placement)
        let needed = Int((max(rect.width, rect.height) * scale).rounded(.up))
        return max(1, min(needed, Int(max(image.width, image.height))))
    }
}
