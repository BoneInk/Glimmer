import Foundation

/// `cv::distanceTransform(src, dst, DIST_L2, DIST_MASK_PRECISE)`: each pixel's exact Euclidean
/// distance to the nearest pixel that is off, 0 on those (Felzenszwalb and Huttenlocher's
/// two-pass lower envelope, which OpenCV's precise variant also runs).
public enum DistanceTransform {
    /// Distances from the pixels where `isOn` holds to the nearest pixel where it doesn't. A plane
    /// with no off pixel gets a distance larger than any in it.
    public static func distances(width: Int, height: Int, isOn: (Int) -> Bool) -> ImagePlane {
        let infinity = Float(width * width + height * height + 1)
        var squared = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) where isOn(index) { squared[index] = infinity }
        var line = [Float](repeating: 0, count: max(width, height))
        var output = [Float](repeating: 0, count: max(width, height))
        var hull = [Int](repeating: 0, count: max(width, height))
        var bounds = [Float](repeating: 0, count: max(width, height) + 1)
        // Columns, then rows.
        for x in 0..<width {
            for y in 0..<height { line[y] = squared[y * width + x] }
            lowerEnvelope(line, count: height, output: &output, hull: &hull, bounds: &bounds)
            for y in 0..<height { squared[y * width + x] = output[y] }
        }
        for y in 0..<height {
            for x in 0..<width { line[x] = squared[y * width + x] }
            lowerEnvelope(line, count: width, output: &output, hull: &hull, bounds: &bounds)
            for x in 0..<width { squared[y * width + x] = output[x] }
        }
        return ImagePlane(width: width, height: height, pixels: squared.map { $0.squareRoot() })
    }

    /// The distances of a plane's pixels above `threshold` to those at or below it.
    public static func distances(of plane: ImagePlane, above threshold: Float) -> ImagePlane {
        let pixels = plane.pixels
        return distances(width: plane.width, height: plane.height) { pixels[$0] > threshold }
    }

    /// The one-dimensional squared distance transform of `values` (the lower envelope of the
    /// parabolas rooted at each sample).
    private static func lowerEnvelope(_ values: [Float], count: Int, output: inout [Float], hull: inout [Int],
                                      bounds: inout [Float]) {
        guard count > 0 else { return }
        var k = 0
        hull[0] = 0
        bounds[0] = -.infinity
        bounds[1] = .infinity
        if count > 1 {
            for q in 1..<count {
                var s: Float
                repeat {
                    let p = hull[k]
                    s = ((values[q] + Float(q * q)) - (values[p] + Float(p * p))) / Float(2 * (q - p))
                    if s <= bounds[k] { k -= 1 } else { break }
                } while k >= 0
                k += 1
                hull[k] = q
                bounds[k] = s
                bounds[k + 1] = .infinity
            }
        }
        k = 0
        for q in 0..<count {
            while bounds[k + 1] < Float(q) { k += 1 }
            let offset = Float(q - hull[k])
            output[q] = offset * offset + values[hull[k]]
        }
    }
}
