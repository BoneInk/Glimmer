import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The QR code of the page's address, drawn with Core Graphics from the module matrix of
/// CoreImage's `CIQRCodeGenerator`: rounded finder patterns, rounded data modules, and the app
/// icon at the centre on a white rounded square of at most 20% of the code's width (4% of its
/// area, under error correction level H's 30%). Dark modules on white whatever the appearance, with
/// a 4-module quiet zone, for scanners.
enum AndroidWiFiQRCode {
    /// The logo square's largest share of the code's width.
    static let logoFraction: CGFloat = 0.2
    /// Modules of white around the code.
    static let quietZone = 4

    /// Which modules are dark, row 0 at the top, without a quiet zone.
    struct Matrix: Equatable {
        var size: Int
        var dark: [Bool]

        func isDark(row: Int, column: Int) -> Bool { dark[row * size + column] }
    }

    /// `text`'s modules at level H; nil when it doesn't fit a QR code.
    static func matrix(for text: String) -> Matrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        // One pixel per module, with the generator's own margin.
        guard let code = filter.outputImage,
              let bitmap = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(code, from: code.extent) else { return nil }
        let width = bitmap.width, height = bitmap.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The code is the dark modules' bounding box (the finder patterns mark three corners).
        var top = height, left = width, bottom = -1, right = -1
        for row in 0..<height {
            for column in 0..<width where pixels[row * width + column] < 128 {
                top = min(top, row); bottom = max(bottom, row); left = min(left, column); right = max(right, column)
            }
        }
        let size = right - left + 1
        guard bottom >= 0, size == bottom - top + 1, size >= 21 else { return nil }
        var dark = [Bool](repeating: false, count: size * size)
        for row in 0..<size {
            for column in 0..<size { dark[row * size + column] = pixels[(top + row) * width + left + column] < 128 }
        }
        return Matrix(size: size, dark: dark)
    }

    /// `text`'s QR code, `side` pixels square (the sheet's size times the screen's scale), with
    /// `logo` (the app icon, as the About window shows it; nil for none) drawn as `appearance`
    /// shows it; nil when the text doesn't fit.
    @MainActor
    static func image(for text: String, side: Int = 512, logo: NSImage? = NSImage(named: "AppIcon"),
                      appearance: NSAppearance? = nil) -> CGImage? {
        guard let matrix = matrix(for: text),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let count = matrix.size
        let module = CGFloat(side) / CGFloat(count + 2 * quietZone)
        let origin = CGFloat(quietZone) * module
        /// A module's square, row 0 at the top (Core Graphics counts from the bottom).
        func square(row: Int, column: Int, modules: Int = 1) -> CGRect {
            CGRect(x: origin + CGFloat(column) * module, y: CGFloat(side) - origin - CGFloat(row + modules) * module,
                   width: CGFloat(modules) * module, height: CGFloat(modules) * module)
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1))

        // The logo's square: an odd number of modules around the centre one, left blank.
        var logoModules = logo == nil ? 0 : Int(CGFloat(count) * logoFraction)
        if logoModules % 2 == 0 { logoModules = max(0, logoModules - 1) }
        let logoStart = (count - logoModules) / 2, logoRange = logoStart..<(logoStart + logoModules)

        // The finder patterns: a rounded ring around a rounded square.
        let finders = [(0, 0), (0, count - 7), (count - 7, 0)]
        func inFinder(_ row: Int, _ column: Int) -> Bool {
            finders.contains { row >= $0.0 && row < $0.0 + 7 && column >= $0.1 && column < $0.1 + 7 }
        }
        for (row, column) in finders {
            let outer = square(row: row, column: column, modules: 7)
            let ring = CGMutablePath()
            ring.addRoundedRect(in: outer, cornerWidth: module * 2.2, cornerHeight: module * 2.2)
            ring.addRoundedRect(in: outer.insetBy(dx: module, dy: module), cornerWidth: module * 1.4, cornerHeight: module * 1.4)
            context.addPath(ring)
            context.fillPath(using: .evenOdd)
            context.addPath(CGPath(roundedRect: outer.insetBy(dx: module * 2, dy: module * 2),
                                   cornerWidth: module, cornerHeight: module, transform: nil))
            context.fillPath()
        }

        // The data modules: rounded squares, a hair smaller than the grid.
        let modules = CGMutablePath()
        let radius = module * 0.38, inset = module * 0.04
        for row in 0..<count {
            for column in 0..<count where matrix.isDark(row: row, column: column) && !inFinder(row, column)
                && !(logoRange.contains(row) && logoRange.contains(column)) {
                modules.addRoundedRect(in: square(row: row, column: column).insetBy(dx: inset, dy: inset),
                                       cornerWidth: radius, cornerHeight: radius)
            }
        }
        context.addPath(modules)
        context.fillPath()

        if let logo, logoModules > 0 {
            let backing = square(row: logoStart, column: logoStart, modules: logoModules)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: backing, cornerWidth: backing.width * 0.22, cornerHeight: backing.width * 0.22, transform: nil))
            context.fillPath()
            context.interpolationQuality = .high
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (appearance ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
                logo.draw(in: backing.insetBy(dx: module / 2, dy: module / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }
}
