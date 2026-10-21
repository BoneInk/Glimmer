import Foundation

/// Compresses RGBA pixels into DXT1 (BC1) and DXT5 (BC3) blocks, the `.tex` formats WE's importer
/// writes for "High Performance" (DXT1) and "Good Performance" (DXT5); `TEXParser` decodes them.
/// Each block's colours are fitted along their principal axis (a range fit, inset by 1/16 of the
/// range as common BC1 encoders do), each pixel taking its nearest palette entry. DXT1 uses its
/// three-colour mode with transparency for a block holding a pixel under half alpha.
enum BCBlockEncoder {
    /// `pixels`: straight RGBA, `width` × `height`, rows top to bottom. A partial block at the
    /// right or bottom edge repeats the edge pixels. DXT1 is 8 bytes a block, DXT5 16.
    static func encode(_ pixels: [UInt8], width: Int, height: Int, dxt5: Bool) -> [UInt8] {
        precondition(pixels.count >= width * height * 4, "one RGBA pixel per texel")
        let columns = (width + 3) / 4, rows = (height + 3) / 4
        var output: [UInt8] = []
        output.reserveCapacity(columns * rows * (dxt5 ? 16 : 8))
        var block = [UInt8](repeating: 0, count: 64)
        for blockY in 0..<rows {
            for blockX in 0..<columns {
                for y in 0..<4 {
                    for x in 0..<4 {
                        let sx = min(blockX * 4 + x, width - 1), sy = min(blockY * 4 + y, height - 1)
                        let source = (sy * width + sx) * 4, target = (y * 4 + x) * 4
                        for channel in 0..<4 { block[target + channel] = pixels[source + channel] }
                    }
                }
                if dxt5 {
                    output += alphaBlock(block)
                    output += colorBlock(block, oneBitAlpha: false)
                } else {
                    output += colorBlock(block, oneBitAlpha: true)
                }
            }
        }
        return output
    }

    // MARK: Colour

    static func color565(_ r: Double, _ g: Double, _ b: Double) -> UInt16 {
        func q(_ value: Double, _ levels: Double) -> UInt16 { UInt16(max(0, min(levels, (value / 255 * levels).rounded()))) }
        return q(r, 31) << 11 | q(g, 63) << 5 | q(b, 31)
    }

    /// The colour a 565 value decodes to, as `TEXParser` decodes it.
    static func rgb(_ color: UInt16) -> SIMD3<Double> {
        SIMD3(Double((color >> 11) * 255 / 31), Double(((color >> 5) & 0x3F) * 255 / 63), Double((color & 0x1F) * 255 / 31))
    }

    private static func colorBlock(_ block: [UInt8], oneBitAlpha: Bool) -> [UInt8] {
        var points: [SIMD3<Double>] = []
        var transparent = [Bool](repeating: false, count: 16)
        for index in 0..<16 {
            if oneBitAlpha, block[index * 4 + 3] < 128 {
                transparent[index] = true
            } else {
                points.append(SIMD3(Double(block[index * 4]), Double(block[index * 4 + 1]), Double(block[index * 4 + 2])))
            }
        }
        let hasTransparency = transparent.contains(true)
        guard !points.isEmpty else { return [0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF] }
        let (low, high) = endpoints(points)
        var c0 = color565(high.x, high.y, high.z), c1 = color565(low.x, low.y, low.z)
        // Four colours need c0 > c1; three and transparency c0 <= c1.
        if hasTransparency ? c0 > c1 : c0 < c1 { swap(&c0, &c1) }
        let e0 = rgb(c0), e1 = rgb(c1)
        let palette: [SIMD3<Double>?]
        if hasTransparency || c0 == c1 {
            palette = [e0, e1, (e0 + e1) / 2, hasTransparency ? nil : (e0 + e1) / 2]
        } else {
            palette = [e0, e1, (2 * e0 + e1) / 3, (e0 + 2 * e1) / 3]
        }
        var indices: UInt32 = 0
        for index in 0..<16 {
            var best = 0
            if transparent[index] {
                best = 3
            } else {
                let pixel = SIMD3(Double(block[index * 4]), Double(block[index * 4 + 1]), Double(block[index * 4 + 2]))
                var bestDistance = Double.infinity
                for (candidate, color) in palette.enumerated() {
                    guard let color else { continue }
                    let difference = pixel - color
                    let distance = (difference * difference).sum()
                    if distance < bestDistance { bestDistance = distance; best = candidate }
                }
            }
            indices |= UInt32(best) << (index * 2)
        }
        return [UInt8(c0 & 0xFF), UInt8(c0 >> 8), UInt8(c1 & 0xFF), UInt8(c1 >> 8),
                UInt8(indices & 0xFF), UInt8((indices >> 8) & 0xFF), UInt8((indices >> 16) & 0xFF), UInt8(indices >> 24)]
    }

    /// The ends of the points' spread along their principal axis, inset by 1/16 of it.
    private static func endpoints(_ points: [SIMD3<Double>]) -> (SIMD3<Double>, SIMD3<Double>) {
        let mean = points.reduce(SIMD3<Double>(repeating: 0), +) / Double(points.count)
        var covariance = [Double](repeating: 0, count: 6) // xx xy xz yy yz zz
        for point in points {
            let d = point - mean
            covariance[0] += d.x * d.x; covariance[1] += d.x * d.y; covariance[2] += d.x * d.z
            covariance[3] += d.y * d.y; covariance[4] += d.y * d.z; covariance[5] += d.z * d.z
        }
        var axis = SIMD3<Double>(1, 1, 1)
        for _ in 0..<8 {
            let next = SIMD3(covariance[0] * axis.x + covariance[1] * axis.y + covariance[2] * axis.z,
                             covariance[1] * axis.x + covariance[3] * axis.y + covariance[4] * axis.z,
                             covariance[2] * axis.x + covariance[4] * axis.y + covariance[5] * axis.z)
            let length = (next * next).sum().squareRoot()
            guard length > 1e-9 else { break }
            axis = next / length
        }
        var minimum = Double.infinity, maximum = -Double.infinity
        for point in points {
            let t = ((point - mean) * axis).sum()
            minimum = min(minimum, t); maximum = max(maximum, t)
        }
        let inset = (maximum - minimum) / 16
        func clamp(_ value: SIMD3<Double>) -> SIMD3<Double> { value.clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 255)) }
        return (clamp(mean + axis * (minimum + inset)), clamp(mean + axis * (maximum - inset)))
    }

    // MARK: Alpha

    private static func alphaBlock(_ block: [UInt8]) -> [UInt8] {
        let alphas = (0..<16).map { block[$0 * 4 + 3] }
        let a0 = alphas.max() ?? 255, a1 = alphas.min() ?? 255
        var palette = [Int(a0), Int(a1)]
        if a0 > a1 {
            for index in 1...6 { palette.append(((7 - index) * Int(a0) + index * Int(a1)) / 7) }
        }
        var indices: UInt64 = 0
        for (pixel, alpha) in alphas.enumerated() {
            var best = 0, bestDistance = Int.max
            for (candidate, value) in palette.enumerated() where abs(value - Int(alpha)) < bestDistance {
                bestDistance = abs(value - Int(alpha)); best = candidate
            }
            indices |= UInt64(best) << (pixel * 3)
        }
        return [a0, a1] + (0..<6).map { UInt8((indices >> ($0 * 8)) & 0xFF) }
    }
}
