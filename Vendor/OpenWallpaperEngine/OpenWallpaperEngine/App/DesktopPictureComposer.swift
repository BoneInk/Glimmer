import CoreGraphics

/// Draws a display's desktop picture from its plan (`DesktopPicturePlan`) the way the display's
/// windows show their wallpapers: on black (what a window shows where the picture leaves it
/// uncovered), each window clipped to its rect, mirrored when it is a flipped clone, moved, scaled
/// and mirrored by the wallpaper's display options, with the frame placed over its canvas (the
/// window, or a stretch's canvas, of which the display shows its part).
enum DesktopPictureComposer {
    /// A layer's picture and how it sits on its canvas: a snapshot is the frame as rendered, so it
    /// fills; a video's frame or a preview is placed as the wallpaper is.
    struct Source {
        var image: CGImage
        var placement: WallpaperPlacement
    }

    /// The picture at the plan's pixel size; `sources` match `plan.layers`, nil for a layer with
    /// nothing to show (it stays black).
    static func compose(_ plan: DesktopPicturePlan, sources: [Source?]) -> CGImage? {
        let width = plan.pixelSize.x
        let height = plan.pixelSize.y
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let size = CGSize(width: width, height: height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        for (layer, source) in zip(plan.layers, sources) {
            guard let source else { continue }
            let rect = denormalized(layer.rect, size)
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            if layer.mirrored {
                context.translateBy(x: rect.width, y: 0)
                context.scaleBy(x: -1, y: 1)
            }
            if layer.options.transformsPicture {
                context.concatenate(layer.options.transform(size: rect.size))
            }
            let canvas = denormalized(layer.canvas, size).offsetBy(dx: -rect.minX, dy: -rect.minY)
            let image = CGSize(width: source.image.width, height: source.image.height)
            let placed = DisplayPictureGeometry.imageRect(image: image, in: canvas.size, placement: source.placement)
            context.draw(source.image, in: placed.offsetBy(dx: canvas.minX, dy: canvas.minY))
            context.restoreGState()
        }
        return context.makeImage()
    }

    static func denormalized(_ rect: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }
}
