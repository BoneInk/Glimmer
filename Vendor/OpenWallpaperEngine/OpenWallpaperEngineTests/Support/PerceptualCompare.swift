import Accelerate
import CoreGraphics
import Foundation
@testable import OpenWallpaperEngine

/// An opaque 8-bit sRGB frame for perceptual comparison. Alpha is ignored: rendered wallpaper
/// frames are composited over black, so colour is what the viewer sees.
struct PerceptualImage: Equatable {
    let width: Int
    let height: Int
    /// Tightly packed RGBA8, row-major, `width * height * 4` bytes.
    let rgba: [UInt8]

    init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4, "RGBA8 size mismatch")
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// Draws `image` into an sRGB RGBA8 buffer (premultiplied over black).
    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, rgba: bytes)
    }

    /// Rec. 709 luma in 0...1 (on the gamma-encoded values, as SSIM is usually computed).
    func luma() -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        rgba.withUnsafeBufferPointer { p in
            for i in 0..<(width * height) {
                let r = Float(p[i * 4]), g = Float(p[i * 4 + 1]), b = Float(p[i * 4 + 2])
                out[i] = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
            }
        }
        return out
    }
}

/// A per-pixel region selector (row-major, `width * height`). `true` pixels are measured.
struct PerceptualMask: Equatable {
    let width: Int
    let height: Int
    var bits: [Bool]

    init(width: Int, height: Int, fill: Bool = false) {
        self.width = width
        self.height = height
        bits = [Bool](repeating: fill, count: width * height)
    }

    /// Marks `rect` (pixel coordinates, origin top-left, clipped to the image).
    mutating func include(_ rect: CGRect) {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, !clipped.isEmpty else { return }
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) { bits[y * width + x] = true }
        }
    }

    var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// Text and line art from the pixels alone, for tests that have no layer classes: pixels
    /// within `radius` of a strong luma edge (Sobel magnitude ≥ `threshold`). Layer classes from
    /// the layer analysis are the primary source; this is the fallback.
    static func edges(of image: PerceptualImage, threshold: Float = 0.25, radius: Int = 2) -> PerceptualMask {
        let w = image.width, h = image.height
        let y = image.luma()
        var mask = PerceptualMask(width: w, height: h)
        guard w > 2, h > 2 else { return mask }
        var edge = [Bool](repeating: false, count: w * h)
        for row in 1..<(h - 1) {
            for col in 1..<(w - 1) {
                let i = row * w + col
                let gx = (y[i - w + 1] + 2 * y[i + 1] + y[i + w + 1]) - (y[i - w - 1] + 2 * y[i - 1] + y[i + w - 1])
                let gy = (y[i + w - 1] + 2 * y[i + w] + y[i + w + 1]) - (y[i - w - 1] + 2 * y[i - w] + y[i - w + 1])
                if (gx * gx + gy * gy).squareRoot() >= threshold * 4 { edge[i] = true }
            }
        }
        for row in 0..<h {
            for col in 0..<w where edge[row * w + col] {
                for dy in -radius...radius {
                    let yy = row + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -radius...radius {
                        let xx = col + dx
                        if xx >= 0, xx < w { mask.bits[yy * w + xx] = true }
                    }
                }
            }
        }
        return mask
    }
}

/// SSIM and CIEDE2000 comparison with the efficiency plan's thresholds (efficiency-plan-2d notes §4).
enum PerceptualCompare {
    /// Kinds of change, each with its own pass bar.
    enum ChangeKind {
        /// Culling, flattening, fusion, memoryless targets, exact target size.
        case losslessInIntent
        /// Half-res blur, half precision, BC7, render scale.
        case lossy
    }

    enum Threshold {
        static let losslessSSIM: Double = 0.995
        /// Below this a lossless-in-intent change needs an explanation in the report.
        static let losslessExplainSSIM: Double = 0.999
        static let lossySSIM: Double = 0.98
        static let lossyDeltaE99: Double = 2.0
        static let textSSIM: Double = 0.995
    }

    struct Verdict: CustomStringConvertible {
        let kind: ChangeKind
        let ssim: Double
        let deltaE99: Double
        /// SSIM over the text/line-art region, or nil when the region is empty.
        let textSSIM: Double?
        let failures: [String]
        var passed: Bool { failures.isEmpty }
        /// A lossless-in-intent change that passed but is not near byte-identical.
        var needsExplanation: Bool { kind == .losslessInIntent && ssim < Threshold.losslessExplainSSIM }
        var description: String {
            let text = textSSIM.map { String(format: " textSSIM=%.5f", $0) } ?? ""
            let tail = failures.isEmpty ? "pass" : failures.joined(separator: "; ")
            return String(format: "SSIM=%.5f ΔE99=%.3f", ssim, deltaE99) + text + " → " + tail
        }
    }

    /// Mean SSIM of the luma planes (Wang et al. 2004: 11×11 Gaussian window, σ = 1.5,
    /// K1 = 0.01, K2 = 0.03, L = 1), averaged over `mask` when given. Computed at full
    /// resolution, without the usual downsampling, so 1-px shifts of thin strokes register.
    static func ssim(_ a: PerceptualImage, _ b: PerceptualImage, mask: PerceptualMask? = nil) -> Double {
        OWEPhaseTiming.measure(.compare) { () -> Double in
            precondition(a.width == b.width && a.height == b.height, "SSIM needs equal sizes")
            let w = a.width, h = a.height, n = w * h
            let x = a.luma(), y = b.luma()
            var xx = [Float](repeating: 0, count: n), yy = xx, xy = xx
            vDSP_vsq(x, 1, &xx, 1, vDSP_Length(n))
            vDSP_vsq(y, 1, &yy, 1, vDSP_Length(n))
            vDSP_vmul(x, 1, y, 1, &xy, 1, vDSP_Length(n))
            let mx = blur(x, w, h), my = blur(y, w, h)
            let sxx = blur(xx, w, h), syy = blur(yy, w, h), sxy = blur(xy, w, h)
            let c1: Float = 0.01 * 0.01, c2: Float = 0.03 * 0.03
            var sum = 0.0
            var count = 0
            for i in 0..<n {
                if let mask, !mask.bits[i] { continue }
                let ux = mx[i], uy = my[i]
                let vx = sxx[i] - ux * ux, vy = syy[i] - uy * uy, cov = sxy[i] - ux * uy
                let num = (2 * ux * uy + c1) * (2 * cov + c2)
                let den = (ux * ux + uy * uy + c1) * (vx + vy + c2)
                sum += Double(num / den)
                count += 1
            }
            return count == 0 ? 1 : sum / Double(count)
        }
    }

    /// 99th percentile of the per-pixel CIEDE2000 colour difference, over `mask` when given.
    static func deltaE99(_ a: PerceptualImage, _ b: PerceptualImage, mask: PerceptualMask? = nil) -> Double {
        deltaEPercentile(a, b, percentile: 0.99, mask: mask)
    }

    static func deltaEPercentile(_ a: PerceptualImage, _ b: PerceptualImage, percentile: Double,
                                 mask: PerceptualMask? = nil) -> Double {
        OWEPhaseTiming.measure(.compare) { () -> Double in
            precondition(a.width == b.width && a.height == b.height, "ΔE needs equal sizes")
            let lut = linearLUT
            var cache: [UInt32: Lab] = [:]
            func lab(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) -> Lab {
                let key = UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2])
                if let hit = cache[key] { return hit }
                let v = Lab(r: lut[Int(p[o])], g: lut[Int(p[o + 1])], b: lut[Int(p[o + 2])])
                cache[key] = v
                return v
            }
            var values: [Double] = []
            values.reserveCapacity(mask?.count ?? a.width * a.height)
            a.rgba.withUnsafeBufferPointer { pa in
                b.rgba.withUnsafeBufferPointer { pb in
                    for i in 0..<(a.width * a.height) {
                        if let mask, !mask.bits[i] { continue }
                        let o = i * 4
                        if pa[o] == pb[o], pa[o + 1] == pb[o + 1], pa[o + 2] == pb[o + 2] { values.append(0); continue }
                        values.append(ciede2000(lab(pa, o), lab(pb, o)))
                    }
                }
            }
            guard !values.isEmpty else { return 0 }
            values.sort()
            let rank = Int((Double(values.count - 1) * percentile).rounded(.up))
            return values[min(rank, values.count - 1)]
        }
    }

    /// Applies §4: the change kind's bar on the whole frame, and SSIM ≥ 0.995 on the text and
    /// line-art region in every mode. `textMask` comes from the layer classes; nil means none.
    static func evaluate(reference: PerceptualImage, candidate: PerceptualImage, kind: ChangeKind,
                         textMask: PerceptualMask? = nil) -> Verdict {
        let s = ssim(reference, candidate)
        let e = deltaE99(reference, candidate)
        var failures: [String] = []
        switch kind {
        case .losslessInIntent:
            if s < Threshold.losslessSSIM { failures.append(String(format: "SSIM %.5f < %.3f", s, Threshold.losslessSSIM)) }
        case .lossy:
            if s < Threshold.lossySSIM { failures.append(String(format: "SSIM %.5f < %.2f", s, Threshold.lossySSIM)) }
            if e > Threshold.lossyDeltaE99 { failures.append(String(format: "ΔE99 %.3f > %.1f", e, Threshold.lossyDeltaE99)) }
        }
        var text: Double?
        if let textMask, textMask.count > 0 {
            let t = ssim(reference, candidate, mask: textMask)
            text = t
            if t < Threshold.textSSIM { failures.append(String(format: "text SSIM %.5f < %.3f", t, Threshold.textSSIM)) }
        }
        return Verdict(kind: kind, ssim: s, deltaE99: e, textSSIM: text, failures: failures)
    }

    // MARK: - Internals

    private static let gaussian: [Float] = {
        let sigma: Float = 1.5
        let taps = (-5...5).map { d -> Float in exp(-Float(d * d) / (2 * sigma * sigma)) }
        let total = taps.reduce(0, +)
        return taps.map { $0 / total }
    }()

    /// Separable 11-tap Gaussian, edges extended.
    private static func blur(_ source: [Float], _ w: Int, _ h: Int) -> [Float] {
        var input = source
        var temp = [Float](repeating: 0, count: w * h)
        var output = temp
        let kernel = gaussian
        input.withUnsafeMutableBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { tmp in
                output.withUnsafeMutableBufferPointer { dst in
                    var s = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var t = vImage_Buffer(data: tmp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    var d = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                    let flags = vImage_Flags(kvImageEdgeExtend)
                    _ = vImageConvolve_PlanarF(&s, &t, nil, 0, 0, kernel, 1, 11, 0, flags)
                    _ = vImageConvolve_PlanarF(&t, &d, nil, 0, 0, kernel, 11, 1, 0, flags)
                }
            }
        }
        return output
    }

    private static let linearLUT: [Double] = (0...255).map { v in
        let c = Double(v) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    struct Lab {
        let l: Double, a: Double, b: Double

        init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

        /// Linear sRGB (D65) → CIELAB.
        init(r: Double, g: Double, b: Double) {
            let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
            let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
            let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
            let fx = f(x), fy = f(y), fz = f(z)
            self.init(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
        }
    }

    /// CIEDE2000 (Sharma, Wu & Dalal 2005), kL = kC = kH = 1.
    static func ciede2000(_ p: Lab, _ q: Lab) -> Double {
        let deg = Double.pi / 180
        let c1 = hypot(p.a, p.b), c2 = hypot(q.a, q.b)
        let cMean7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - (cMean7 / (cMean7 + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let cp1 = hypot(a1, p.b), cp2 = hypot(a2, q.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dL = q.l - p.l, dC = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(dh / 2 * deg)
        let lMean = (p.l + q.l) / 2, cMean = (cp1 + cp2) / 2
        var hMean = h1 + h2
        if cp1 * cp2 != 0 {
            if abs(h1 - h2) <= 180 { hMean = (h1 + h2) / 2 }
            else if h1 + h2 < 360 { hMean = (h1 + h2 + 360) / 2 }
            else { hMean = (h1 + h2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hMean - 30) * deg) + 0.24 * cos(2 * hMean * deg)
            + 0.32 * cos((3 * hMean + 6) * deg) - 0.20 * cos((4 * hMean - 63) * deg)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let cMeanP7 = pow(cMean, 7)
        let rc = 2 * (cMeanP7 / (cMeanP7 + pow(25, 7))).squareRoot()
        let l50 = (lMean - 50) * (lMean - 50)
        let sl = 1 + 0.015 * l50 / (20 + l50).squareRoot()
        let sc = 1 + 0.045 * cMean
        let sh = 1 + 0.015 * cMean * t
        let rt = -sin(2 * dTheta * deg) * rc
        let tl = dL / sl, tc = dC / sc, th = dH / sh
        return (tl * tl + tc * tc + th * th + rt * tc * th).squareRoot()
    }
}
