import CoreGraphics
import Foundation
import ImageIO

/// The main colour of a picture, for a wallpaper without a scheme colour (its own `schemecolor` is
/// used as it is). K-means in OKLab over a 64×64 copy, then the clusters are scored in OKLCH by
/// pixel share times a chroma preference: grays, white and black (low chroma) and very dark or
/// very light clusters score almost nothing, so a chromatic minority (down to 3% of the pixels)
/// wins over a white or black majority. The pick is then nudged into a usable range (lightness
/// 0.40…0.78, chroma at least 0.08, the hue kept, inside sRGB). A monochrome picture (no cluster
/// with chroma 0.03 or more) gets a neutral mid gray, which the accent palette maps to Graphite.
/// Deterministic; call it off the main thread.
public enum DominantColor {
    /// The side of the square the picture is reduced to: 4 096 samples.
    public static let sampleSide = 64
    public static let clusterCount = 8
    public static let iterations = 8
    /// The smallest share of the pixels a picked cluster may have.
    public static let minimumShare = 0.03
    /// Below this chroma a cluster is gray, white or black, and isn't picked at all.
    public static let chromaticChroma = 0.03
    /// Below this chroma a cluster is strongly penalized.
    public static let lowChroma = 0.04
    /// Outside these lightnesses a cluster is strongly penalized.
    public static let usableLightness = 0.22...0.9
    /// The range the picked colour is nudged into.
    public static let outputLightness = 0.40...0.78
    public static let minimumOutputChroma = 0.08
    /// A monochrome picture's colour: a neutral mid gray (the Graphite accent).
    public static let neutral = AccentPalette.graphite.color

    /// The main colour of the picture file at `url`; nil when it can't be read.
    public static func of(fileAt url: URL) -> ThemeColor? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return of(image)
    }

    /// The main colour of `image`; nil when it can't be drawn.
    public static func of(_ image: CGImage) -> ThemeColor? {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var colors: [ThemeColor] = []
        colors.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            colors.append(ThemeColor(red: Double(pixels[index]) / 255, green: Double(pixels[index + 1]) / 255,
                                     blue: Double(pixels[index + 2]) / 255))
        }
        return dominant(of: colors)
    }

    /// The best-scoring chromatic k-means cluster of `colors`, nudged into the usable range; the
    /// neutral gray when none is chromatic; nil without colours.
    public static func dominant(of colors: [ThemeColor]) -> ThemeColor? {
        guard !colors.isEmpty else { return nil }
        let points = colors.map(OKLab.init)
        var centers = seeds(points)
        var assignment = [Int](repeating: 0, count: points.count)
        var sizes = [Int](repeating: 0, count: centers.count)
        for iteration in 0...iterations {
            for (index, point) in points.enumerated() {
                assignment[index] = nearest(point, in: centers)
            }
            var sums = [(l: Double, a: Double, b: Double)](repeating: (0, 0, 0), count: centers.count)
            sizes = [Int](repeating: 0, count: centers.count)
            for (index, cluster) in assignment.enumerated() {
                sums[cluster].l += points[index].lightness
                sums[cluster].a += points[index].a
                sums[cluster].b += points[index].b
                sizes[cluster] += 1
            }
            for cluster in centers.indices where sizes[cluster] > 0 {
                let count = Double(sizes[cluster])
                centers[cluster] = OKLab(lightness: sums[cluster].l / count, a: sums[cluster].a / count,
                                         b: sums[cluster].b / count)
            }
            if iteration == iterations { break }
        }
        let total = Double(points.count)
        var best: (center: OKLab, score: Double)?
        for cluster in centers.indices {
            let share = Double(sizes[cluster]) / total
            let center = centers[cluster]
            guard share >= minimumShare, center.chroma >= chromaticChroma else { continue }
            let score = share * preference(center)
            if score > (best?.score ?? 0) { best = (center, score) }
        }
        guard let best else { return neutral }
        return usable(best.center).themeColor
    }

    /// How much a cluster's colour is wanted, 0…1: chroma up to 0.12 counts more; low chroma
    /// and extreme lightness are strongly penalized.
    static func preference(_ color: OKLab) -> Double {
        let chroma = color.chroma
        var preference = chroma < lowChroma ? 0.02 : 0.5 + 0.5 * min(1, (chroma - lowChroma) / 0.08)
        if !usableLightness.contains(color.lightness) { preference *= 0.05 }
        return preference
    }

    /// `color` with its lightness clamped to `outputLightness` and its chroma raised to at least
    /// `minimumOutputChroma`, the hue kept; the chroma is then reduced until it is inside sRGB.
    public static func usable(_ color: OKLab) -> OKLab {
        var lightness = min(max(color.lightness, outputLightness.lowerBound), outputLightness.upperBound)
        let hue = color.hue
        let chroma = max(color.chroma, minimumOutputChroma)
        // Where sRGB can't hold the minimum chroma at this lightness (a light blue, a dark
        // yellow), the lightness moves toward the middle of the range until it can.
        let middle = (outputLightness.lowerBound + outputLightness.upperBound) / 2
        while !OKLab(lightness: lightness, chroma: minimumOutputChroma, hue: hue).isInSRGBGamut,
              abs(lightness - middle) > 0.005 {
            lightness += lightness < middle ? 0.01 : -0.01
        }
        let wanted = OKLab(lightness: lightness, chroma: chroma, hue: hue)
        if wanted.isInSRGBGamut { return wanted }
        var low = 0.0, high = chroma
        for _ in 0..<24 {
            let candidate = (low + high) / 2
            if OKLab(lightness: lightness, chroma: candidate, hue: hue).isInSRGBGamut { low = candidate } else { high = candidate }
        }
        return OKLab(lightness: lightness, chroma: low, hue: hue)
    }

    /// Farthest-point seeds: the first point, then each time the point farthest from every seed.
    private static func seeds(_ points: [OKLab]) -> [OKLab] {
        var centers = [points[0]]
        while centers.count < min(clusterCount, points.count) {
            var best = points[0]
            var bestDistance = -1.0
            for point in points {
                let distance = centers.map { $0.distance(to: point) }.min() ?? 0
                if distance > bestDistance {
                    best = point
                    bestDistance = distance
                }
            }
            guard bestDistance > 0 else { break }
            centers.append(best)
        }
        return centers
    }

    private static func nearest(_ point: OKLab, in centers: [OKLab]) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (index, center) in centers.enumerated() {
            let distance = center.distance(to: point)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }
}

/// The main colours already found, by picture file: a file's path, size and modification date, so
/// a rewritten snapshot is looked at again. Bounded; safe from any thread.
public final class DominantColorCache: @unchecked Sendable {
    private struct Key: Hashable {
        var path: String
        var size: Int
        var modified: Date
    }

    private let lock = NSLock()
    private var colors: [Key: ThemeColor] = [:]
    private var order: [Key] = []
    private let capacity: Int
    private let compute: (URL) -> ThemeColor?

    public init(capacity: Int = 32, compute: @escaping (URL) -> ThemeColor? = DominantColor.of(fileAt:)) {
        self.capacity = capacity
        self.compute = compute
    }

    /// The main colour of the file at `url`, computed once per version of the file; nil when it
    /// can't be read (not cached, so a later version is tried).
    public func color(fileAt url: URL) -> ThemeColor? {
        let path = url.standardizedFileURL.path
        // Read fresh each time (a URL caches its resource values). Optional: part of the key only.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let key = Key(path: path, size: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                      modified: attributes?[.modificationDate] as? Date ?? .distantPast)
        lock.lock()
        let cached = colors[key]
        lock.unlock()
        if let cached { return cached }
        guard let color = compute(url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if colors.updateValue(color, forKey: key) == nil {
            order.append(key)
            if order.count > capacity { colors[order.removeFirst()] = nil }
        }
        return color
    }
}
