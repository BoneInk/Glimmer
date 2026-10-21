import Foundation

/// WE's Normal Map Generation (the editor's material panel, Normal map › Generate): a normal map
/// made from an image layer's picture, its **shape** from the outline of its opaque pixels and
/// its **details** from its brightness, written as `<texture>_normal` and imported as a normal
/// map: RG88, as WE 2.8.0.42 writes a generated one (capture 544: `"format": "rg88"`, clamped,
/// mipmapped; blue is rebuilt in the shader).
///
/// The steps are those of `wallpaperui.exe` (`performGenerateNormalMap`, OpenCV 4.4):
/// - Shape, at most 512 pixels on the long side: the alpha above 250, bordered with transparency
///   by `64 / min(scale, 1)` pixels; its distance transform inside, cut at Threshold of its range,
///   normalised and rounded by Exponent (`1 − (1 − d)^e`); the same outside, scaled by the ratio of
///   the two ranges, subtracted; normalised, blurred by Blur, its Sobel gradients (13 taps)
///   normalised to −1…1 and turned into a normal with Depth.
/// - Details, at full size: the transparent part filled (Telea, radius 1), the mean of red, green
///   and blue normalised, blurred by Details › Blur, its Sobel gradients scaled by their largest
///   magnitude and turned into a normal with Details › Depth (Invert flips them), faded out
///   towards the edge (the inside distance clamped to 1–7 %, blurred).
/// - The details are turned onto the shape (the rotation taking straight up to the shape's
///   normal, the result kept in front), encoded as `n × 0.5 + 0.5` in red, green and blue, with
///   the picture's alpha.
public enum NormalMapGenerator {
    /// The generator's options, WE's defaults (`normalConfig`) and slider ranges.
    public struct Settings: Hashable, Codable, Sendable {
        /// Sobel kernel size (WE's hidden "Filter size", 3…31 odd).
        public var filter = 13
        /// Shape › Blur, 1…63 odd.
        public var blur = 63
        /// Shape › Depth, 0…1.
        public var depth: Double = 1
        /// Shape › Threshold, 0…1.
        public var threshold: Double = 1
        /// Details › Blur, 1…255 odd.
        public var detailsBlur = 21
        /// Details › Depth, 0…1.
        public var detailsDepth: Double = 1
        /// Details › Invert.
        public var detailsInvert = false
        /// Shape › Exponent, 1…8.
        public var exponent: Double = 4

        public init() {}

        public static let blurRange = 1...63
        public static let detailsBlurRange = 1...255
        public static let depthRange: ClosedRange<Double> = 0...1
        public static let thresholdRange: ClosedRange<Double> = 0...1
        public static let exponentRange: ClosedRange<Double> = 1...8

        /// The values clamped to WE's ranges, blur sizes odd.
        public var clamped: Settings {
            var copy = self
            func odd(_ value: Int, _ range: ClosedRange<Int>) -> Int {
                let clamped = min(max(value, range.lowerBound), range.upperBound)
                return clamped.isMultiple(of: 2) ? max(clamped - 1, range.lowerBound) : clamped
            }
            copy.filter = odd(filter, 3...31)
            copy.blur = odd(blur, Self.blurRange)
            copy.detailsBlur = odd(detailsBlur, Self.detailsBlurRange)
            copy.depth = min(max(depth, 0), 1)
            copy.detailsDepth = min(max(detailsDepth, 0), 1)
            copy.threshold = min(max(threshold, 0), 1)
            copy.exponent = min(max(exponent, 1), 8)
            return copy
        }
    }

    /// The long side the shape is worked out at.
    static let shapeSize: Float = 512

    /// The normal map of `image` (straight alpha), the same size.
    public static func generate(_ image: RGBAImage, settings requested: Settings) -> RGBAImage {
        let settings = requested.clamped
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return image }
        let alpha = image.plane(3)
        let shape = shapeNormals(alpha: alpha, settings: settings)
        let details = detailNormals(image, alpha: alpha, settings: settings)
        var output = RGBAImage(width: width, height: height)
        for index in 0..<(width * height) {
            let base = SIMD3<Float>(shape.0.pixels[index], shape.1.pixels[index], shape.2.pixels[index])
            let detail = SIMD3<Float>(details.normals.0.pixels[index], details.normals.1.pixels[index], details.normals.2.pixels[index])
            let weight = details.weight.pixels[index]
            let faded = SIMD3<Float>(0, 0, 1) + (detail - SIMD3<Float>(0, 0, 1)) * weight
            let normal = reoriented(faded, onto: base)
            let encoded = encode(normal)
            output.pixels[index * 4] = encoded.0
            output.pixels[index * 4 + 1] = encoded.1
            output.pixels[index * 4 + 2] = encoded.2
            output.pixels[index * 4 + 3] = image.pixels[index * 4 + 3]
        }
        return output
    }

    // MARK: Shape

    /// The shape's normals (x, y, z planes) at the image's size.
    static func shapeNormals(alpha: ImagePlane, settings: Settings) -> (ImagePlane, ImagePlane, ImagePlane) {
        let width = alpha.width, height = alpha.height
        let scale = shapeSize / Float(max(width, height))
        let border = Int(64 / min(scale, 1))
        let workWidth = max(Int(Float(width) * scale), 1), workHeight = max(Int(Float(height) * scale), 1)
        // An opaque picture has no outline: its shape is flat.
        let hasOutline = alpha.pixels.contains { $0 <= 250 } && alpha.pixels.contains { $0 > 250 }
        let paddedAlpha = alpha.padded(by: border, mode: .zero)
        var inside = DistanceTransform.distances(of: paddedAlpha, above: 250)
        let (insideLow, insideHigh) = inside.minMax
        let cut = insideLow + (insideHigh - insideLow) * Float(settings.threshold)
        inside = inside.map { min($0, cut) }
        let insideRange = insideHigh > 1 ? insideHigh - insideLow : 1
        inside = rounded(inside.normalized(), exponent: Float(settings.exponent))
        var outside = DistanceTransform.distances(width: paddedAlpha.width, height: paddedAlpha.height) { paddedAlpha.pixels[$0] <= 250 }
        inside = inside.resized(width: workWidth, height: workHeight)
        outside = outside.resized(width: workWidth, height: workHeight)
        let (outsideLow, outsideHigh) = outside.minMax
        let outsideRange = outsideHigh > 1 ? outsideHigh - outsideLow : 1
        outside = rounded(outside.normalized(), exponent: Float(settings.exponent))
        let ratio = outsideRange / insideRange
        var heights = ImagePlane(width: workWidth, height: workHeight)
        for index in heights.pixels.indices { heights.pixels[index] = inside.pixels[index] - outside.pixels[index] * ratio }
        heights = heights.normalized()
        if settings.blur > 1 { heights = heights.gaussianBlurred(size: settings.blur, border: .replicate) }
        if !hasOutline { heights = ImagePlane(width: workWidth, height: workHeight, value: 1) }
        let gx = minMaxSigned(heights.sobel(dx: 1, dy: 0, size: settings.filter))
        let gy = minMaxSigned(heights.sobel(dx: 0, dy: 1, size: settings.filter))
        let normals = normalPlanes(gx: gx, gy: gy, depth: Float(settings.depth), invert: false)
        let paddedWidth = width + 2 * border, paddedHeight = height + 2 * border
        func back(_ plane: ImagePlane) -> ImagePlane {
            plane.resized(width: paddedWidth, height: paddedHeight).cropped(x: border, y: border, width: width, height: height)
        }
        return (back(normals.0), back(normals.1), back(normals.2))
    }

    /// `1 − (1 − v)^exponent` per pixel.
    static func rounded(_ plane: ImagePlane, exponent: Float) -> ImagePlane {
        plane.map { (value: Float) -> Float in 1 - pow(1 - value, exponent) }
    }

    /// A gradient normalised to −1…1 (min to −1, max to 1) when it has both signs.
    static func minMaxSigned(_ plane: ImagePlane) -> ImagePlane {
        let (low, high) = plane.minMax
        guard low < -Float.ulpOfOne, high > Float.ulpOfOne else { return plane }
        return plane.normalized(-1, 1)
    }

    /// A gradient divided by its largest magnitude when it has both signs.
    static func scaledSigned(_ plane: ImagePlane) -> ImagePlane {
        let (low, high) = plane.minMax
        guard low < -Float.ulpOfOne, high > Float.ulpOfOne else { return plane }
        let largest = max(abs(low), high)
        return plane.map { $0 / largest }
    }

    // MARK: Details

    static func detailNormals(_ image: RGBAImage, alpha: ImagePlane, settings: Settings)
        -> (normals: (ImagePlane, ImagePlane, ImagePlane), weight: ImagePlane) {
        let width = image.width, height = image.height
        let unknown: [Bool] = alpha.pixels.map { $0 <= 250 }
        var channels = [image.plane(0), image.plane(1), image.plane(2)]
        if unknown.contains(true) {
            // Only pixels the details' filters reach from the opaque ones matter.
            let reach = Float(settings.filter / 2 + settings.detailsBlur / 2 + 2)
            channels = Inpainting.telea(channels, unknown: unknown, radius: 1, limit: reach)
        }
        var brightness = ImagePlane(width: width, height: height)
        for index in brightness.pixels.indices {
            brightness.pixels[index] = (channels[0].pixels[index] + channels[1].pixels[index] + channels[2].pixels[index]) / 3
        }
        brightness = brightness.normalized()
        if settings.detailsBlur > 1 { brightness = brightness.gaussianBlurred(size: settings.detailsBlur, border: .replicate) }
        let gx = scaledSigned(brightness.sobel(dx: 1, dy: 0, size: settings.filter))
        let gy = scaledSigned(brightness.sobel(dx: 0, dy: 1, size: settings.filter))
        let normals = normalPlanes(gx: gx, gy: gy, depth: Float(settings.detailsDepth), invert: settings.detailsInvert)
        // The details fade out towards the outline: the inside distance, normalised, clamped to
        // 1–7 % of it, blurred and normalised again (an opaque picture keeps them everywhere).
        var weight: ImagePlane
        if unknown.contains(true) {
            weight = DistanceTransform.distances(of: alpha.padded(by: 1, mode: .zero), above: 250)
                .cropped(x: 1, y: 1, width: width, height: height)
            let (low, high) = weight.minMax
            if high - low > Float.ulpOfOne {
                weight = weight.normalized().map { min(max($0, 0.01), 0.07) }
                weight = weight.gaussianBlurred(size: settings.filter, border: .replicate).normalized()
            }
        } else {
            weight = ImagePlane(width: width, height: height, value: 1)
        }
        return (normals, weight)
    }

    // MARK: Normals

    /// WE's gradient to normal: the square of gradients mapped onto the disc
    /// (`x √(1 − y²/2)`), scaled by depth, kept inside the unit circle, z making it unit length.
    static func normalPlanes(gx: ImagePlane, gy: ImagePlane, depth: Float, invert: Bool) -> (ImagePlane, ImagePlane, ImagePlane) {
        var x = ImagePlane(width: gx.width, height: gx.height)
        var y = x, z = x
        for index in gx.pixels.indices {
            let n = normal(gx: gx.pixels[index], gy: gy.pixels[index], depth: depth, invert: invert)
            x.pixels[index] = n.x
            y.pixels[index] = n.y
            z.pixels[index] = n.z
        }
        return (x, y, z)
    }

    static func normal(gx rawX: Float, gy rawY: Float, depth: Float, invert: Bool) -> SIMD3<Float> {
        let gx = invert ? -rawX : rawX, gy = invert ? -rawY : rawY
        var x = (max(1 - 0.5 * gy * gy, 0)).squareRoot() * -gx * depth
        var y = (max(1 - 0.5 * gx * gx, 0)).squareRoot() * gy * depth
        let length = (x * x + y * y).squareRoot()
        if length > 1 {
            x /= length
            y /= length
        }
        let z: Float
        if length >= 0.999999 {
            z = 0
        } else if length <= 1e-6 {
            z = 1
        } else {
            z = max(1 - x * x - y * y, 0).squareRoot()
        }
        let vector = SIMD3<Float>(x, y, z)
        let size = (vector * vector).sum().squareRoot()
        return size > 0 ? vector / size : SIMD3<Float>(0, 0, 1)
    }

    /// `detail` turned by the rotation that takes straight up onto `base` (reoriented normal
    /// mapping), kept facing forward.
    static func reoriented(_ detail: SIMD3<Float>, onto base: SIMD3<Float>) -> SIMD3<Float> {
        let t = base + SIMD3<Float>(0, 0, 1)
        let u = detail * SIMD3<Float>(-1, -1, 1)
        var r: SIMD3<Float>
        if t.z > 1e-6 {
            r = t * ((t * u).sum() / t.z) - u
        } else {
            r = SIMD3<Float>(-detail.x, -detail.y, -detail.z)
        }
        if r.z < 0 { r.z = 0 }
        let size = (r * r).sum().squareRoot()
        return size > 0 ? r / size : SIMD3<Float>(0, 0, 1)
    }

    /// A normal as WE's bytes: `n × 0.5 + 0.5` scaled to 255, x and y rounded towards the middle
    /// (127 exactly at it), z rounded down.
    static func encode(_ normal: SIMD3<Float>) -> (UInt8, UInt8, UInt8) {
        let size = (normal * normal).sum().squareRoot()
        let n = size > 0 ? normal / size : SIMD3<Float>(0, 0, 1)
        func byte(_ value: Float, towardsMiddle: Bool) -> UInt8 {
            let mapped = value * 0.5 + 0.5
            let scaled: Float
            if !towardsMiddle {
                scaled = (mapped * 255).rounded(.down)
            } else if mapped > 0.5 {
                scaled = (mapped * 255).rounded(.down)
            } else if mapped < 0.5 {
                scaled = (mapped * 255).rounded(.up)
            } else {
                return 127
            }
            return UInt8(min(max(scaled, 0), 255))
        }
        return (byte(n.x, towardsMiddle: true), byte(n.y, towardsMiddle: true), byte(n.z, towardsMiddle: false))
    }
}
