import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The menu bar strips to draw into the desktop pictures OWE sets: a colour and each display's
/// geometry, captured on the main thread and applied where the picture is written.
public struct DesktopPictureStrips: Equatable, Sendable {
    public var color: ThemeColor
    public var displays: [UInt32: MenuBarStripDisplay]

    public init(color: ThemeColor, displays: [UInt32: MenuBarStripDisplay]) {
        self.color = color
        self.displays = displays
    }

    public enum Failure: Error {
        case unreadable(URL)
        case unwritable(URL)
    }

    /// `image` with the display's strip drawn, fading out downwards (`MenuBarStrip.fadeStops`);
    /// nil when the display has no strip.
    public func composed(_ image: CGImage, display: UInt32) -> CGImage? {
        guard let geometry = displays[display],
              let rect = MenuBarStrip.imageRect(height: MenuBarStrip.fadeHeight(menuBarHeight: geometry.menuBarHeight),
                                                displaySize: geometry.size,
                                                imageSize: CGSize(width: image.width, height: image.height)),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        let stops = MenuBarStrip.fadeStops
        let colors = stops.map { CGColor(colorSpace: space, components: [color.red, color.green, color.blue, $0.alpha])! }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray,
                                        locations: stops.map(\.location)) else { return nil }
        let strip = rect.intersection(bounds)
        context.saveGState()
        context.clip(to: strip)
        // Core Graphics' origin is the bottom left: the strip starts at its top.
        context.drawLinearGradient(gradient, start: CGPoint(x: strip.minX, y: strip.maxY),
                                   end: CGPoint(x: strip.minX, y: strip.minY), options: [])
        context.restoreGState()
        return context.makeImage()
    }

    /// Draws the display's strip into the picture file at `url`, in place and in its own format.
    /// Does nothing for a display without a strip. Runs off the main thread.
    public func apply(toFileAt url: URL, display: UInt32) throws {
        guard displays[display] != nil else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable(url) }
        guard let composed = composed(image, display: display) else { return }
        let type = CGImageSourceGetType(source) ?? (UTType.jpeg.identifier as CFString)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw Failure.unwritable(url)
        }
        CGImageDestinationAddImage(destination, composed,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable(url) }
        try (data as Data).write(to: url, options: .atomic)
    }
}
