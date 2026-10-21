import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit sRGB image, RGBA, rows top-down: a WE capture or one of our frames, for
/// `WEReferenceComparisonTests`.
struct WEReferenceImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height * 4))
    }

    enum Failure: Error {
        case unreadable(URL)
        case unwritable(URL)
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A PNG, converted to sRGB, alpha dropped.
    static func load(_ url: URL) throws -> WEReferenceImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadable(url) }
        var result = WEReferenceImage(width: image.width, height: image.height)
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn = result.pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw Failure.unreadable(url) }
        return result
    }

    func write(to url: URL) throws {
        var copy = pixels
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let image = copy.withUnsafeMutableBytes { bytes -> CGImage? in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: Self.space, bitmapInfo: info)
            return context?.makeImage()
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.unwritable(url) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unwritable(url) }
    }

    /// The image scaled to cover `width`×`height` and centred (WE's default scene placement,
    /// `WallpaperPlacement.fill`), bilinear.
    func covering(width targetWidth: Int, height targetHeight: Int) -> WEReferenceImage {
        if targetWidth == width, targetHeight == height { return self }
        let scale = max(Double(targetWidth) / Double(width), Double(targetHeight) / Double(height))
        var result = WEReferenceImage(width: targetWidth, height: targetHeight)
        pixels.withUnsafeBufferPointer { source in
            result.pixels.withUnsafeMutableBufferPointer { target in
                for y in 0..<targetHeight {
                    let sy = (Double(y) + 0.5 - Double(targetHeight) / 2) / scale + Double(height) / 2 - 0.5
                    let y0 = min(max(Int(sy.rounded(.down)), 0), height - 1)
                    let y1 = min(y0 + 1, height - 1)
                    let fy = min(max(sy - Double(y0), 0), 1)
                    for x in 0..<targetWidth {
                        let sx = (Double(x) + 0.5 - Double(targetWidth) / 2) / scale + Double(width) / 2 - 0.5
                        let x0 = min(max(Int(sx.rounded(.down)), 0), width - 1)
                        let x1 = min(x0 + 1, width - 1)
                        let fx = min(max(sx - Double(x0), 0), 1)
                        for c in 0..<3 {
                            let a = Double(source[(y0 * width + x0) * 4 + c])
                            let b = Double(source[(y0 * width + x1) * 4 + c])
                            let d = Double(source[(y1 * width + x0) * 4 + c])
                            let e = Double(source[(y1 * width + x1) * 4 + c])
                            let top = a + (b - a) * fx
                            let bottom = d + (e - d) * fx
                            target[(y * targetWidth + x) * 4 + c] = UInt8((top + (bottom - top) * fy).rounded())
                        }
                    }
                }
            }
        }
        return result
    }

    /// Box-filtered down by `factor` in each direction.
    func reduced(by factor: Int) -> WEReferenceImage {
        let w = width / factor, h = height / factor
        var result = WEReferenceImage(width: w, height: h)
        let area = factor * factor
        pixels.withUnsafeBufferPointer { source in
            result.pixels.withUnsafeMutableBufferPointer { target in
                for y in 0..<h {
                    for x in 0..<w {
                        for c in 0..<3 {
                            var sum = 0
                            for dy in 0..<factor {
                                let row = (y * factor + dy) * width
                                for dx in 0..<factor { sum += Int(source[(row + x * factor + dx) * 4 + c]) }
                            }
                            target[(y * w + x) * 4 + c] = UInt8(sum / area)
                        }
                    }
                }
            }
        }
        return result
    }

    /// Rec. 709 luma of the (gamma-encoded) values, 0…255, box-filtered down by `factor`.
    func luma(reducedBy factor: Int) -> WEReferenceLuma {
        let w = width / factor, h = height / factor
        var values = [Float](repeating: 0, count: w * h)
        let area = Float(factor * factor)
        pixels.withUnsafeBufferPointer { source in
            for y in 0..<h {
                for x in 0..<w {
                    var sum: Float = 0
                    for dy in 0..<factor {
                        let row = (y * factor + dy) * width
                        for dx in 0..<factor {
                            let i = (row + x * factor + dx) * 4
                            let red = 0.2126 * Float(source[i])
                            let green = 0.7152 * Float(source[i + 1])
                            sum += red + green + 0.0722 * Float(source[i + 2])
                        }
                    }
                    values[y * w + x] = sum / area
                }
            }
        }
        return WEReferenceLuma(width: w, height: h, values: values)
    }

    /// `images` side by side, same height.
    static func sideBySide(_ images: [WEReferenceImage]) -> WEReferenceImage {
        let height = images.map(\.height).max() ?? 0
        let width = images.reduce(0) { $0 + $1.width }
        var result = WEReferenceImage(width: width, height: height)
        var left = 0
        for image in images {
            for y in 0..<image.height {
                let from = y * image.width * 4
                let to = (y * width + left) * 4
                result.pixels.replaceSubrange(to..<(to + image.width * 4), with: image.pixels[from..<(from + image.width * 4)])
            }
            left += image.width
        }
        return result
    }
}

/// A single-channel image, rows top-down.
struct WEReferenceLuma {
    let width: Int
    let height: Int
    var values: [Float]

    /// Sobel gradient magnitude.
    func edges() -> WEReferenceLuma {
        var result = WEReferenceLuma(width: width, height: height, values: [Float](repeating: 0, count: values.count))
        guard width > 2, height > 2 else { return result }
        values.withUnsafeBufferPointer { v in
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    let up = i - width, down = i + width
                    let right: Float = v[up + 1] + 2 * v[i + 1] + v[down + 1]
                    let left: Float = v[up - 1] + 2 * v[i - 1] + v[down - 1]
                    let below: Float = v[down - 1] + 2 * v[down] + v[down + 1]
                    let above: Float = v[up - 1] + 2 * v[up] + v[up + 1]
                    let gx = right - left
                    let gy = below - above
                    result.values[i] = (gx * gx + gy * gy).squareRoot()
                }
            }
        }
        return result
    }
}
