import CoreGraphics
import Foundation

extension RGBAImage {
    /// The picture's pixels in sRGB with straight alpha.
    public init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // Core Graphics draws premultiplied; the tools work on straight colour.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, (Int(pixels[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// The image as a `CGImage` (straight alpha, sRGB).
    public var cgImage: CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The image as a PNG.
    public var pngData: Data? { cgImage.flatMap(EditorAssetStore.pngData) }
}
