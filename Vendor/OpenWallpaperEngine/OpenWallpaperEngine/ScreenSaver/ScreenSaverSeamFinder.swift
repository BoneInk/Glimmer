import CoreGraphics
import Foundation

/// How a rendered loop's seam is hidden, as the Live Photo and Android exports and the Wallpaper
/// Editor's previews loop their clips: the last `crossfadeSeconds` of frames are blended into the
/// first ones (`crossfadeWeight`), so the seam fades instead of jumping. (The screen saver's loop
/// videos, which the seam search was first made for, are gone: the screen saver is drawn live.)
enum ScreenSaverSeamFinder {
    static let crossfadeSeconds = 0.25

    /// The weight of the scene's frame `index - (loopFrames - fade)` (one of the first `fade`
    /// frames, which the video skips) blended over the video's frame `index` of a loop of
    /// `loopFrames` frames fading over `fade`: 0 before the fade, rising to just under 1 on the
    /// last frame, so the next frame (the scene's frame `fade`, the video's first) completes it.
    static func crossfadeWeight(index: Int, loopFrames: Int, fade: Int) -> Double {
        let start = loopFrames - fade
        guard fade > 0, index >= start, index < loopFrames else { return 0 }
        return Double(index - start + 1) / Double(fade + 1)
    }
}

/// A small perceptual fingerprint of a frame: its luma and chroma at 64×36, blurred by the
/// downscale, so noise and grain don't count and a moved object does.
struct ScreenSaverFrameSignature: Equatable {
    static let width = 64
    static let height = 36
    /// Interleaved Y, Cb, Cr per pixel, 0…1.
    let values: [Float]

    init(values: [Float]) { self.values = values }

    init?(_ image: CGImage) {
        let (width, height) = (Self.width, Self.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var values = [Float]()
        values.reserveCapacity(width * height * 3)
        for pixel in 0..<(width * height) {
            let r = Float(pixels[pixel * 4]) / 255, g = Float(pixels[pixel * 4 + 1]) / 255, b = Float(pixels[pixel * 4 + 2]) / 255
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            values.append(y)
            values.append((b - y) * 0.5)
            values.append((r - y) * 0.5)
        }
        self.values = values
    }

    /// The mean absolute difference, luma weighted twice chroma: 0 for the same picture, 1 at most.
    func difference(_ other: ScreenSaverFrameSignature) -> Double {
        guard values.count == other.values.count, !values.isEmpty else { return 1 }
        var total: Double = 0
        for index in values.indices {
            let weight: Double = index % 3 == 0 ? 2 : 1
            total += weight * Double(abs(values[index] - other.values[index]))
        }
        return total / (Double(values.count / 3) * 4)
    }
}
