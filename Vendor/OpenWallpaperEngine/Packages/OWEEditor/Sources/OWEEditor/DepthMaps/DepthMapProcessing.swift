import Foundation

/// What turns a model's raw output into the depth map WE's depth parallax reads: normalised to
/// 0…1 with near white (`SceneDepthParallax`), brought up to the source's resolution along the
/// source's own edges (joint bilateral upsampling, guided by the source's luminance), and
/// optionally smoothed while keeping those edges (a guided filter, He et al., "Guided Image
/// Filtering", 2010).
public enum DepthMapProcessing {
    /// Bumped when the processing changes what a cached depth map holds (`DepthMapCache`).
    public static let revision = 1

    /// Stretches `raw` over 0…1. `inverseDepth`: the model's larger values are nearer (Depth
    /// Anything's relative inverse depth), which is already near-white; otherwise it is flipped.
    /// A flat map becomes mid grey (no parallax either way).
    public static func normalized(_ raw: DepthMapBuffer, inverseDepth: Bool = true) -> DepthMapBuffer {
        var lowest = Float.greatestFiniteMagnitude, highest = -Float.greatestFiniteMagnitude
        for value in raw.values where value.isFinite {
            lowest = min(lowest, value)
            highest = max(highest, value)
        }
        let span = highest - lowest
        guard span.isFinite, span > 1e-6 else { return DepthMapBuffer(width: raw.width, height: raw.height, repeating: 0.5) }
        let values = raw.values.map { value -> Float in
            let unit = value.isFinite ? (value - lowest) / span : 0
            return inverseDepth ? unit : 1 - unit
        }
        return DepthMapBuffer(width: raw.width, height: raw.height, values: values)
    }

    /// Bilinear resampling to `width` × `height`, pixel centres aligned.
    public static func resized(_ source: DepthMapBuffer, width: Int, height: Int) -> DepthMapBuffer {
        guard source.width != width || source.height != height else { return source }
        var result = DepthMapBuffer(width: width, height: height)
        let scaleX = Float(source.width) / Float(width), scaleY = Float(source.height) / Float(height)
        let maxX = source.width - 1, maxY = source.height - 1
        source.values.withUnsafeBufferPointer { input in
            result.values.withUnsafeMutableBufferPointer { output in
                for y in 0..<height {
                    let sy = max(0, min(Float(maxY), (Float(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(sy), y1 = min(y0 + 1, maxY), fy = sy - Float(y0)
                    for x in 0..<width {
                        let sx = max(0, min(Float(maxX), (Float(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(sx), x1 = min(x0 + 1, maxX), fx = sx - Float(x0)
                        let top = input[y0 * source.width + x0] * (1 - fx) + input[y0 * source.width + x1] * fx
                        let bottom = input[y1 * source.width + x0] * (1 - fx) + input[y1 * source.width + x1] * fx
                        output[y * width + x] = top * (1 - fy) + bottom * fy
                    }
                }
            }
        }
        return result
    }

    /// The mean over a (2r+1)² window, clamped at the borders, through a summed-area table.
    static func boxMean(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return values }
        let stride = width + 1
        var table = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0.0
            for x in 0..<width {
                row += Double(values[y * width + x])
                table[(y + 1) * stride + x + 1] = table[y * stride + x + 1] + row
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            for x in 0..<width {
                let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
                let sum = table[y1 * stride + x1] - table[y0 * stride + x1] - table[y1 * stride + x0] + table[y0 * stride + x0]
                result[y * width + x] = Float(sum / Double((y1 - y0) * (x1 - x0)))
            }
        }
        return result
    }

    /// The guided filter of `input` with `guide` (same size): `input`'s values, following the
    /// guide's edges. `epsilon` is the regularisation (in squared 0…1 units): smaller keeps more
    /// of the guide's edges.
    public static func guidedFilter(_ input: DepthMapBuffer, guide: DepthMapBuffer, radius: Int, epsilon: Float) -> DepthMapBuffer {
        precondition(input.width == guide.width && input.height == guide.height, "the guide must match the input")
        let width = input.width, height = input.height, count = width * height
        let I = guide.values, p = input.values
        var ii = [Float](repeating: 0, count: count), ip = [Float](repeating: 0, count: count)
        for index in 0..<count {
            ii[index] = I[index] * I[index]
            ip[index] = I[index] * p[index]
        }
        let meanI = boxMean(I, width: width, height: height, radius: radius)
        let meanP = boxMean(p, width: width, height: height, radius: radius)
        let corrI = boxMean(ii, width: width, height: height, radius: radius)
        let corrIP = boxMean(ip, width: width, height: height, radius: radius)
        var a = [Float](repeating: 0, count: count), b = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let variance = corrI[index] - meanI[index] * meanI[index]
            let covariance = corrIP[index] - meanI[index] * meanP[index]
            a[index] = covariance / (variance + epsilon)
            b[index] = meanP[index] - a[index] * meanI[index]
        }
        let meanA = boxMean(a, width: width, height: height, radius: radius)
        let meanB = boxMean(b, width: width, height: height, radius: radius)
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            output[index] = min(max(meanA[index] * I[index] + meanB[index], 0), 1)
        }
        return DepthMapBuffer(width: width, height: height, values: output)
    }

    /// The normalised model output at the guide's (the source's) resolution, by joint bilateral
    /// upsampling (Kopf et al., 2007): each pixel averages the model's 4 × 4 nearest samples,
    /// weighted by distance (in model pixels, `sigmaSpatial`) and by how close the source's
    /// luminance there is to the sample's cell (`sigmaRange`), so depth edges land on the
    /// picture's edges instead of being smeared over a model pixel as plain stretching does.
    public static func upscaled(_ depth: DepthMapBuffer, guide: DepthMapBuffer,
                                sigmaSpatial: Float = 1, sigmaRange: Float = 0.1) -> DepthMapBuffer {
        let lowWidth = depth.width, lowHeight = depth.height, width = guide.width, height = guide.height
        guard width > lowWidth || height > lowHeight else { return resized(depth, width: width, height: height) }

        // The guide averaged over each model pixel's cell.
        var cell = [Float](repeating: 0, count: lowWidth * lowHeight)
        var counts = [Float](repeating: 0, count: lowWidth * lowHeight)
        for y in 0..<height {
            let j = min(lowHeight - 1, y * lowHeight / height)
            for x in 0..<width {
                let index = j * lowWidth + min(lowWidth - 1, x * lowWidth / width)
                cell[index] += guide.values[y * width + x]
                counts[index] += 1
            }
        }
        for index in cell.indices where counts[index] > 0 { cell[index] /= counts[index] }

        // Range weights by the luminance difference, in 1/255 steps.
        let rangeWeights = (0...255).map { step -> Float in
            let difference = Float(step) / 255
            return expf(-(difference * difference) / (2 * sigmaRange * sigmaRange))
        }
        // Spatial taps: four per column and four per row, separable.
        func taps(count: Int, lowCount: Int) -> (first: [Int], weights: [Float]) {
            var first = [Int](repeating: 0, count: count)
            var weights = [Float](repeating: 0, count: count * 4)
            for position in 0..<count {
                let u = (Float(position) + 0.5) * Float(lowCount) / Float(count) - 0.5
                let start = Int(u.rounded(.down)) - 1
                first[position] = start
                for tap in 0..<4 {
                    let sample = start + tap
                    guard sample >= 0, sample < lowCount else { continue }
                    let distance = Float(sample) - u
                    weights[position * 4 + tap] = expf(-(distance * distance) / (2 * sigmaSpatial * sigmaSpatial))
                }
            }
            return (first, weights)
        }
        let columns = taps(count: width, lowCount: lowWidth)
        let rows = taps(count: height, lowCount: lowHeight)

        var output = [Float](repeating: 0, count: width * height)
        depth.values.withUnsafeBufferPointer { low in
            guide.values.withUnsafeBufferPointer { picture in
                for y in 0..<height {
                    let rowStart = rows.first[y]
                    for x in 0..<width {
                        let luminance = picture[y * width + x]
                        let columnStart = columns.first[x]
                        var total: Float = 0, sum: Float = 0, spatialTotal: Float = 0, spatialSum: Float = 0
                        for rowTap in 0..<4 {
                            let rowWeight = rows.weights[y * 4 + rowTap]
                            guard rowWeight > 0 else { continue }
                            let j = rowStart + rowTap
                            for columnTap in 0..<4 {
                                let columnWeight = columns.weights[x * 4 + columnTap]
                                guard columnWeight > 0 else { continue }
                                let index = j * lowWidth + columnStart + columnTap
                                let spatial = rowWeight * columnWeight
                                let step = min(255, Int(abs(luminance - cell[index]) * 255 + 0.5))
                                let weight = spatial * rangeWeights[step]
                                total += weight
                                sum += weight * low[index]
                                spatialTotal += spatial
                                spatialSum += spatial * low[index]
                            }
                        }
                        // A pixel unlike every cell around it falls back to the distance weights.
                        let value = total > 1e-6 ? sum / total : (spatialTotal > 0 ? spatialSum / spatialTotal : 0)
                        output[y * width + x] = min(max(value, 0), 1)
                    }
                }
            }
        }
        return DepthMapBuffer(width: width, height: height, values: output)
    }

    /// `smoothing` 0…1: 0 leaves the map; more blurs flat areas over a wider window while keeping
    /// the source's edges.
    public static func smoothed(_ depth: DepthMapBuffer, guide: DepthMapBuffer, smoothing: Double) -> DepthMapBuffer {
        guard let filter = guidedFilterParameters(smoothing: smoothing, width: depth.width, height: depth.height) else { return depth }
        return guidedFilter(depth, guide: guide, radius: filter.radius, epsilon: filter.epsilon)
    }

    /// The guided filter `smoothing` (0…1) runs on a `width` × `height` map; nil for none.
    static func guidedFilterParameters(smoothing: Double, width: Int, height: Int) -> (radius: Int, epsilon: Float)? {
        let amount = min(max(smoothing, 0), 1)
        guard amount > 0.001 else { return nil }
        let shortSide = Double(min(width, height))
        let radius = max(1, Int((amount * shortSide / 48).rounded()))
        return (radius, Float(0.0005 + amount * amount * 0.02))
    }
}
