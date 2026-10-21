import Foundation

/// The signed distance, in pixels, from each pixel of a coverage mask to its edge: positive
/// inside, negative outside. Exact Euclidean distances between pixel centres (Felzenszwalb and
/// Huttenlocher's separable transform), with pixels on an antialiased edge placed by their coverage.
enum SceneDistanceField {
    /// `coverage` is `width × height` bytes, row by row; 128 and above is inside.
    static func signedDistances(coverage: [UInt8], width: Int, height: Int) -> [Float] {
        precondition(coverage.count >= width * height)
        let count = width * height
        let far = Float(width * width + height * height + 1)
        var toInside = [Float](repeating: far, count: count)
        var toOutside = [Float](repeating: far, count: count)
        for i in 0..<count {
            if coverage[i] >= 128 { toInside[i] = 0 } else { toOutside[i] = 0 }
        }
        transform(&toInside, width: width, height: height)
        transform(&toOutside, width: width, height: height)
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let value = Float(coverage[i]) / 255
            if value > 0, value < 1 {
                // On the edge: its coverage says how far the edge is from the pixel's centre.
                result[i] = value - 0.5
            } else if coverage[i] >= 128 {
                result[i] = toOutside[i].squareRoot() - 0.5
            } else {
                result[i] = 0.5 - toInside[i].squareRoot()
            }
        }
        return result
    }

    /// Squared distances to the nearest zero, in place: columns, then rows.
    private static func transform(_ grid: inout [Float], width: Int, height: Int) {
        var line = [Float](repeating: 0, count: max(width, height))
        var output = [Float](repeating: 0, count: max(width, height))
        var hull = [Int](repeating: 0, count: max(width, height))
        var bounds = [Float](repeating: 0, count: max(width, height) + 1)
        for x in 0..<width {
            for y in 0..<height { line[y] = grid[y * width + x] }
            transform1D(line, count: height, into: &output, hull: &hull, bounds: &bounds)
            for y in 0..<height { grid[y * width + x] = output[y] }
        }
        for y in 0..<height {
            for x in 0..<width { line[x] = grid[y * width + x] }
            transform1D(line, count: width, into: &output, hull: &hull, bounds: &bounds)
            for x in 0..<width { grid[y * width + x] = output[x] }
        }
    }

    /// The lower envelope of the parabolas `(q − p)² + f(p)`.
    private static func transform1D(_ f: [Float], count: Int, into output: inout [Float], hull: inout [Int],
                                    bounds: inout [Float]) {
        guard count > 0 else { return }
        var k = 0
        hull[0] = 0
        bounds[0] = -.infinity
        bounds[1] = .infinity
        for q in 1..<max(count, 1) where count > 1 {
            var s: Float
            repeat {
                let p = hull[k]
                s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
                if s <= bounds[k] { k -= 1 } else { break }
            } while k >= 0
            k += 1
            hull[k] = q
            bounds[k] = s
            bounds[k + 1] = .infinity
        }
        k = 0
        for q in 0..<count {
            while bounds[k + 1] < Float(q) { k += 1 }
            let p = hull[k]
            output[q] = Float((q - p) * (q - p)) + f[p]
        }
    }
}
