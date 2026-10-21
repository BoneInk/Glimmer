import CoreGraphics
import Foundation

/// The still of a Live Photo: of the frames near the clip's middle, the sharpest, by the variance
/// of its luma's Laplacian, with frames nearer the middle preferred a little (`weight`), so the
/// still is a calm, representative moment rather than a blurred one mid-motion.
enum LivePhotoKeyFrame {
    /// The middle share of the clip the still is chosen from.
    static let candidateShare = 0.5
    /// The luma the sharpness is measured on, at most this many pixels on its longer side.
    static let measurePixels = 320
    /// How much a frame at the band's edge counts against one in the middle.
    static let edgePenalty = 0.25

    /// The earliest the still can be in the movie: the Lock Screen says "Motion Not Available"
    /// for a still up to about 0.33 s in, whatever the movie's length, and plays one at 0.5 s
    /// (Glitter Live's measurements on an iPhone 17 Pro, github.com/BuddhaNag12/glitter-live).
    static let earliestSeconds = 0.5

    /// The first frame the still can be at `frameRate`: `earliestSeconds` in, or the last frame of
    /// a shorter clip.
    static func earliestFrame(frameCount: Int, frameRate: Int = LivePhotoClip.frameRate) -> Int {
        min(Int((earliestSeconds * Double(frameRate)).rounded(.up)), max(frameCount - 1, 0))
    }

    /// The clip's middle frame, never before `earliestFrame`.
    static func middle(frameCount: Int) -> Int {
        max(frameCount / 2, earliestFrame(frameCount: frameCount))
    }

    /// The frames the still can be: the middle share of the clip, from `earliestFrame` on.
    static func candidates(frameCount: Int) -> ClosedRange<Int> {
        let middle = frameCount / 2
        let half = max(0, Int(Double(frameCount) * candidateShare / 2))
        let last = max(frameCount - 1, 0)
        let lower = max(middle - half, earliestFrame(frameCount: frameCount))
        return min(lower, last)...max(min(last, middle + half), min(lower, last))
    }

    /// 1 in the middle, `1 - edgePenalty` at the band's edges.
    static func weight(index: Int, frameCount: Int) -> Double {
        let band = candidates(frameCount: frameCount)
        let half = max(Double(band.upperBound - band.lowerBound) / 2, 1)
        let distance = abs(Double(index) - Double(middle(frameCount: frameCount)))
        return 1 - edgePenalty * min(distance / half, 1)
    }

    /// The still among `sharpness` (by frame index; frames outside the band are ignored): the
    /// highest weighted sharpness, the middle frame (`middle`) when there are none.
    static func choose(sharpness: [Int: Double], frameCount: Int) -> Int {
        let band = candidates(frameCount: frameCount)
        var best = middle(frameCount: frameCount)
        var bestScore = -Double.infinity
        for index in band {
            guard let value = sharpness[index] else { continue }
            let score = value * weight(index: index, frameCount: frameCount)
            if score > bestScore { best = index; bestScore = score }
        }
        return best
    }

    /// The variance of the 4-neighbour Laplacian of `image`'s luma, measured at most
    /// `measurePixels` on its longer side; 0 for an image that can't be read.
    static func sharpness(of image: CGImage) -> Double {
        let scale = min(1, Double(measurePixels) / Double(max(image.width, image.height, 1)))
        let width = max(3, Int(Double(image.width) * scale)), height = max(3, Int(Double(image.height) * scale))
        var luma = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = luma.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return laplacianVariance(luma.map { Double($0) / 255 }, width: width, height: height)
    }

    /// The variance of the 4-neighbour Laplacian over the interior of a `width` × `height` image.
    static func laplacianVariance(_ values: [Double], width: Int, height: Int) -> Double {
        guard width >= 3, height >= 3, values.count == width * height else { return 0 }
        var sum: Double = 0, squares: Double = 0
        var count: Double = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let center = values[y * width + x]
                let laplacian = values[y * width + x - 1] + values[y * width + x + 1]
                    + values[(y - 1) * width + x] + values[(y + 1) * width + x] - 4 * center
                sum += laplacian
                squares += laplacian * laplacian
                count += 1
            }
        }
        let mean = sum / count
        return max(0, squares / count - mean * mean)
    }
}
