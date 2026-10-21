import CoreGraphics
import Foundation

/// The colours of `MediaThumbnailEvent`, computed from the artwork as WE's media helper does
/// (`bin/winrtutil64.exe`: palette `0x140065590`, contrast `0x14002db80`, choice `0x140048179`):
///
/// 1. Every pixel with alpha ≥ 16 goes into one of 360 hue bins (HSV hue, truncated; grey pixels,
///    with max − min < 0.00001, go to bin 0 with saturation 0). Each bin sums saturation, value
///    (max), a score of int(value · saturation · 100) and a count.
/// 2. primary: the bin with the highest score; secondary: the highest score × d₁/180; tertiary:
///    the highest score × (d₁·d₂/180²)², where d₁ and d₂ are the circular hue distances to the
///    primary and secondary bins. Only a strictly higher weight replaces an earlier bin; a colour
///    no bin beats is black.
/// 3. Each colour is HSV(bin/360, the bin's mean saturation, its mean value), quantised to 8 bits.
/// 4. highContrastColor: black when the primary colour's WCAG contrast ratio with black is at
///    least 2.5, else white. textColor: the secondary colour when its ratio with the primary is at
///    least 2.5 and above the tertiary's, else the tertiary when that is at least 2.5, else
///    highContrastColor.
///
/// WE also crops transparent letterboxing from Windows thumbnails first; macOS artwork is opaque,
/// so that step is left out.
enum ArtworkPalette {
    /// Normalised RGB, like the event's `Vec3`s.
    struct Colors: Equatable {
        var primary: SIMD3<Float>
        var secondary: SIMD3<Float>
        var tertiary: SIMD3<Float>
        var text: SIMD3<Float>
        var highContrast: SIMD3<Float>
    }

    static let binCount = 360
    static let minimumContrast: Float = 2.5

    /// The colours of an image, or nil when it can't be drawn.
    static func colors(of image: CGImage) -> Colors? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        // WE reads straight alpha; CoreGraphics draws premultiplied.
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            guard alpha > 0, alpha < 255 else { continue }
            for channel in 0..<3 {
                pixels[index + channel] = UInt8(min(255, Int(pixels[index + channel]) * 255 / alpha))
            }
        }
        return colors(rgba: pixels, width: width, height: height)
    }

    /// The colours of straight-alpha RGBA8 pixels, row by row.
    static func colors(rgba pixels: [UInt8], width: Int, height: Int) -> Colors {
        precondition(pixels.count >= width * height * 4, "ArtworkPalette needs width × height RGBA pixels")
        var histogram = Histogram()
        for index in stride(from: 0, to: width * height * 4, by: 4) where pixels[index + 3] >= 16 {
            histogram.add(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2])
        }
        let primary = histogram.best { _ in 1 }
        let secondary = histogram.best { Float(distance($0, primary)) / 180 }
        let tertiary = histogram.best { bin in
            let factor = Float(distance(bin, primary)) / 180 * Float(distance(bin, secondary)) / 180
            return factor * factor
        }
        let colors = [primary, secondary, tertiary].map { bin -> SIMD3<Float> in
            guard let bin else { return .zero }
            return quantised(rgb(hue: Float(bin) / Float(binCount), saturation: histogram.meanSaturation(bin),
                                 value: histogram.meanValue(bin)))
        }
        let black = SIMD3<Float>.zero, white = SIMD3<Float>(1, 1, 1)
        let highContrast = contrastRatio(colors[0], black) >= minimumContrast ? black : white
        let secondaryRatio = contrastRatio(colors[0], colors[1])
        let tertiaryRatio = contrastRatio(colors[0], colors[2])
        let text: SIMD3<Float>
        if secondaryRatio >= minimumContrast && secondaryRatio > tertiaryRatio {
            text = colors[1]
        } else if tertiaryRatio >= minimumContrast {
            text = colors[2]
        } else {
            text = highContrast
        }
        return Colors(primary: colors[0], secondary: colors[1], tertiary: colors[2], text: text,
                      highContrast: highContrast)
    }

    /// WCAG 2 contrast ratio of two sRGB colours.
    static func contrastRatio(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: SIMD3<Float>) -> Float {
        func linear(_ channel: Float) -> Float {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.x) + 0.7152 * linear(color.y) + 0.0722 * linear(color.z)
    }

    /// HSV → RGB with hue in 0…1.
    static func rgb(hue: Float, saturation: Float, value: Float) -> SIMD3<Float> {
        let chroma = value * saturation
        let sector = Float(fmod(Double(hue * 6), 6))
        let x = chroma * Float(1 - abs(fmod(Double(sector), 2) - 1))
        let base: SIMD3<Float>
        switch sector {
        case 0..<1: base = SIMD3(chroma, x, 0)
        case 1..<2: base = SIMD3(x, chroma, 0)
        case 2..<3: base = SIMD3(0, chroma, x)
        case 3..<4: base = SIMD3(0, x, chroma)
        case 4..<5: base = SIMD3(x, 0, chroma)
        case 5..<6: base = SIMD3(chroma, 0, x)
        default: base = .zero
        }
        return base + SIMD3(repeating: value - chroma)
    }

    /// The 8-bit colour WE packs and the event unpacks (value · 255 truncated, then / 255).
    private static func quantised(_ color: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ value: Float) -> Float { Float(min(max(Int(value * 255), 0), 255)) / 255 }
        return SIMD3(channel(color.x), channel(color.y), channel(color.z))
    }

    /// Circular distance between two hue bins. A colour no bin won stands at bin 0, as in WE.
    private static func distance(_ bin: Int, _ other: Int?) -> Int {
        let direct = abs((other ?? 0) - bin)
        return direct > binCount / 2 ? binCount - direct : direct
    }

    private struct Histogram {
        var saturation = [Float](repeating: 0, count: ArtworkPalette.binCount)
        var value = [Float](repeating: 0, count: ArtworkPalette.binCount)
        var score = [Int](repeating: 0, count: ArtworkPalette.binCount)
        var count = [Int](repeating: 0, count: ArtworkPalette.binCount)

        mutating func add(r: UInt8, g: UInt8, b: UInt8) {
            let red = Float(r) / 255, green = Float(g) / 255, blue = Float(b) / 255
            let maximum = max(red, green, blue), minimum = min(red, green, blue)
            let delta = maximum - minimum
            var bin = 0
            var pixelSaturation: Float = 0
            if delta >= 0.00001 && maximum > 0 {
                pixelSaturation = delta / maximum
                var hue: Float
                if red >= maximum {
                    hue = (green - blue) / delta
                } else if green >= maximum {
                    hue = Float(Double((blue - red) / delta) + 2)
                } else {
                    hue = Float(Double((red - green) / delta) + 4)
                }
                hue /= 6
                if hue < 0 { hue += 1 }
                bin = min(max(Int(hue * Float(ArtworkPalette.binCount)), 0), ArtworkPalette.binCount - 1)
            }
            saturation[bin] += pixelSaturation
            value[bin] += maximum
            score[bin] += Int(maximum * pixelSaturation * 100)
            count[bin] += 1
        }

        func meanSaturation(_ bin: Int) -> Float { count[bin] > 0 ? saturation[bin] / Float(count[bin]) : 0 }
        func meanValue(_ bin: Int) -> Float { count[bin] > 0 ? value[bin] / Float(count[bin]) : 0 }

        /// The first bin whose score × weight beats every earlier one and 0; nil when none does.
        func best(weight: (Int) -> Float) -> Int? {
            var bestBin: Int?
            var bestScore = 0
            for bin in 0..<ArtworkPalette.binCount {
                let weighted = Float(score[bin]) * weight(bin)
                if weighted > Float(bestScore) {
                    bestScore = Int(weighted)
                    bestBin = bin
                }
            }
            return bestBin
        }
    }
}
