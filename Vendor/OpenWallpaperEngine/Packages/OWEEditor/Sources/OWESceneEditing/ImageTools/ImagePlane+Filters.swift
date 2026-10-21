import Accelerate
import Foundation

/// The OpenCV filters WE's image tools run: `GaussianBlur`, `Sobel`, `resize` (bilinear),
/// with OpenCV's kernels and border handling so the results follow WE's.
extension ImagePlane {
    // MARK: Kernels

    /// `cv::getGaussianKernel(ksize, 0)`: OpenCV's fixed kernels up to 7 taps, else a Gaussian of
    /// sigma `0.3 × ((ksize − 1) / 2 − 1) + 0.8`, summing to 1.
    public static func gaussianKernel(size: Int) -> [Float] {
        switch size {
        case 1: return [1]
        case 3: return [0.25, 0.5, 0.25]
        case 5: return [0.0625, 0.25, 0.375, 0.25, 0.0625]
        case 7: return [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]
        default:
            let sigma = 0.3 * (Double(size - 1) * 0.5 - 1) + 0.8
            let centre = Double(size - 1) / 2
            let values: [Double] = (0..<size).map { (index: Int) -> Double in
                let offset = Double(index) - centre
                return exp(-offset * offset / (2 * sigma * sigma))
            }
            let sum = values.reduce(0, +)
            return values.map { Float($0 / sum) }
        }
    }

    /// `getSobelKernels` (unnormalised) for derivative `order` over `size` taps: binomial
    /// smoothing, then `order` differences, as OpenCV builds it.
    public static func sobelKernel(order: Int, size requested: Int) -> [Float] {
        let size = requested == 1 && order > 0 ? 3 : requested
        if size == 1 { return [1] }
        if size == 3 {
            switch order {
            case 0: return [1, 2, 1]
            case 1: return [-1, 0, 1]
            default: return [1, -2, 1]
            }
        }
        var kernel = [Int](repeating: 0, count: size + 1)
        kernel[0] = 1
        for _ in 0..<(size - order - 1) {
            var old = kernel[0]
            for j in 1...size {
                let new = kernel[j] + kernel[j - 1]
                kernel[j - 1] = old
                old = new
            }
        }
        for _ in 0..<order {
            var old = -kernel[0]
            for j in 1...size {
                let new = kernel[j - 1] - kernel[j]
                kernel[j - 1] = old
                old = new
            }
        }
        return kernel.prefix(size).map { Float($0) }
    }

    // MARK: Filtering

    /// Correlates the plane with `rowKernel` along x and `columnKernel` along y (`sepFilter2D`),
    /// reading outside pixels by `border`.
    public func separableFiltered(rowKernel: [Float], columnKernel: [Float], border: BorderMode) -> ImagePlane {
        guard !isEmpty else { return self }
        let padX = rowKernel.count / 2, padY = columnKernel.count / 2
        let pad = max(padX, padY)
        var source = padded(by: pad, mode: border)
        var output = ImagePlane(width: source.width, height: source.height)
        let sourceWidth = source.width, sourceHeight = source.height
        source.pixels.withUnsafeMutableBytes { sourceBytes in
            output.pixels.withUnsafeMutableBytes { outputBytes in
                var sourceBuffer = vImage_Buffer(data: sourceBytes.baseAddress, height: vImagePixelCount(sourceHeight),
                                                 width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * 4)
                var outputBuffer = vImage_Buffer(data: outputBytes.baseAddress, height: vImagePixelCount(sourceHeight),
                                                 width: vImagePixelCount(sourceWidth), rowBytes: sourceWidth * 4)
                // The padding holds the border, so the edge mode vImage uses never reads past it.
                _ = vImageSepConvolve_PlanarF(&sourceBuffer, &outputBuffer, nil, 0, 0, rowKernel, UInt32(rowKernel.count),
                                              columnKernel, UInt32(columnKernel.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return output.cropped(x: pad, y: pad, width: width, height: height)
    }

    /// `cv::GaussianBlur(src, dst, Size(size, size), 0, 0, border)`; sizes below 2 leave it as it is.
    public func gaussianBlurred(size: Int, border: BorderMode = .replicate) -> ImagePlane {
        let size = size.isMultiple(of: 2) ? size + 1 : size
        guard size > 1 else { return self }
        let kernel = Self.gaussianKernel(size: size)
        return separableFiltered(rowKernel: kernel, columnKernel: kernel, border: border)
    }

    /// `cv::Sobel(src, dst, CV_32F, dx, dy, size, 1, 0, BORDER_DEFAULT)`. Its kernels are
    /// symmetric or antisymmetric, and summed in pairs as OpenCV's column and row filters do, so
    /// a flat run gives exactly 0 (an unpaired sum leaves rounding noise that a later
    /// normalisation would blow up).
    public func sobel(dx: Int, dy: Int, size: Int) -> ImagePlane {
        guard !isEmpty else { return self }
        let rows = Self.paired(Self.sobelKernel(order: dx, size: size))
        let columns = Self.paired(Self.sobelKernel(order: dy, size: size))
        let pad = max(rows.radius, columns.radius)
        let source = padded(by: pad, mode: .reflect101)
        let paddedWidth = source.width
        // Along x over every padded row, then along y.
        var horizontal = [Float](repeating: 0, count: width * source.height)
        source.pixels.withUnsafeBufferPointer { input in
            horizontal.withUnsafeMutableBufferPointer { output in
                for y in 0..<source.height {
                    let row = y * paddedWidth + pad
                    for x in 0..<width {
                        output[y * width + x] = rows.apply(input, at: row + x, stride: 1)
                    }
                }
            }
        }
        var result = ImagePlane(width: width, height: height)
        horizontal.withUnsafeBufferPointer { input in
            result.pixels.withUnsafeMutableBufferPointer { output in
                for y in 0..<height {
                    for x in 0..<width {
                        output[y * width + x] = columns.apply(input, at: (y + pad) * width + x, stride: width)
                    }
                }
            }
        }
        return result
    }

    /// A symmetric (or antisymmetric) kernel as its centre and its taps' pairs.
    struct PairedKernel {
        var centre: Float
        var taps: [Float]
        var antisymmetric: Bool
        var radius: Int { taps.count }

        func apply(_ values: UnsafeBufferPointer<Float>, at index: Int, stride: Int) -> Float {
            var sum = centre * values[index]
            for (offset, tap) in taps.enumerated() where tap != 0 {
                let step = (offset + 1) * stride
                sum += tap * (antisymmetric ? values[index + step] - values[index - step] : values[index + step] + values[index - step])
            }
            return sum
        }
    }

    static func paired(_ kernel: [Float]) -> PairedKernel {
        let radius = kernel.count / 2
        let antisymmetric = kernel[radius] == 0 && kernel.count > 1 && kernel[0] == -kernel[kernel.count - 1]
        return PairedKernel(centre: kernel[radius], taps: (1...max(radius, 1)).prefix(radius).map { kernel[radius + $0] },
                            antisymmetric: antisymmetric)
    }

    // MARK: Resizing

    /// `cv::resize(…, INTER_LINEAR)`: pixel centres aligned, the edge pixels repeated.
    public func resized(width newWidth: Int, height newHeight: Int) -> ImagePlane {
        guard newWidth > 0, newHeight > 0, !isEmpty else { return ImagePlane(width: max(newWidth, 0), height: max(newHeight, 0)) }
        if newWidth == width && newHeight == height { return self }
        func taps(_ count: Int, from sourceCount: Int) -> [(Int, Int, Float)] {
            let scale = Double(sourceCount) / Double(count)
            return (0..<count).map { (index: Int) -> (Int, Int, Float) in
                let position = (Double(index) + 0.5) * scale - 0.5
                var low = Int(floor(position))
                var fraction = Float(position - Double(low))
                if low < 0 { low = 0; fraction = 0 }
                if low >= sourceCount - 1 { low = sourceCount - 1; fraction = 0 }
                return (low, min(low + 1, sourceCount - 1), fraction)
            }
        }
        let columns = taps(newWidth, from: width), rows = taps(newHeight, from: height)
        // Along x first, then y.
        var horizontal = [Float](repeating: 0, count: newWidth * height)
        for y in 0..<height {
            let row = y * width
            for (x, tap) in columns.enumerated() {
                let a = pixels[row + tap.0], b = pixels[row + tap.1]
                horizontal[y * newWidth + x] = a + (b - a) * tap.2
            }
        }
        var result = ImagePlane(width: newWidth, height: newHeight)
        for (y, tap) in rows.enumerated() {
            let upper = tap.0 * newWidth, lower = tap.1 * newWidth
            for x in 0..<newWidth {
                let a = horizontal[upper + x], b = horizontal[lower + x]
                result.pixels[y * newWidth + x] = a + (b - a) * tap.2
            }
        }
        return result
    }
}
